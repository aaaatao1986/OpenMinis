#!/bin/bash
# =============================================================================
# prepare_debian_rootfs_android.sh
# -----------------------------------------------------------------------------
# Builds a Debian (glibc) aarch64 rootfs for OpenMinis on Android (PRoot),
# preloaded with Node.js + headless Chromium so that Remotion can render.
#
# WHY THIS APPROACH (vs. debootstrap / vs. raw chroot):
#   OpenMinis ships an Alpine (musl) rootfs. Remotion needs Node + Chromium,
#   and Chromium's official binaries require glibc. We swap the rootfs for a
#   Debian (glibc) arm64 image.
#
#   The CI host is x86_64, the rootfs target is arm64. Doing a raw `chroot`
#   into an arm64 tree requires a qemu binfmt interpreter registered on the
#   HOST and is extremely fragile on GitHub Actions (dies in <1 min).
#
#   RELIABLE METHOD used here: run an arm64 *container* via
#   `docker run --platform linux/arm64`, install everything inside that
#   (Docker itself emulates arm64 with qemu once binfmt is registered), then
#   `tar` the container filesystem out as the rootfs. No host chroot, no
#   fragile bind-mounts.
#
# OUTPUT: debian-minirootfs.tar.gz  (drop into src/android/.../assets/)
#
# PREREQUISITES
#   - A Linux host with Docker (GitHub ubuntu-latest runner has it).
#   - Internet access to Docker Hub, deb.debian.org and NodeSource.
#   - ~4 GB free disk.
#
# USAGE:
#   sudo ./prepare_debian_rootfs_android.sh [suite]   # e.g. bookworm
# =============================================================================
set -euo pipefail

# Print the failing command + line number on any error (great for CI logs).
trap 'echo "[ERROR] command failed at line $LINENO: $BASH_COMMAND" >&2' ERR

SUITE="${1:-bookworm}"
case "$SUITE" in
  bookworm) DOCKER_IMG="debian:bookworm" ;;
  bullseye) DOCKER_IMG="debian:bullseye" ;;
  *)        DOCKER_IMG="debian:$SUITE" ;;
esac

OUT_TARBALL="debian-minirootfs.tar.gz"
OUT_DIR="$(pwd)"

log() { echo -e "\033[1;34m[debian-rootfs]\033[0m $*" ; }
err() { echo -e "\033[0;31m[debian-rootfs] ERROR:\033[0m $*" >&2 ; }

# ---- DEBUG block (helps pinpoint CI failures; safe to keep) ----------------
echo "===== DEBUG: docker version ====="
docker version 2>&1 | head -20 || true
echo "===== DEBUG: binfmt_misc entries ====="
ls -1 /proc/sys/fs/binfmt_misc/ 2>&1 | head -40 || true
echo "===== DEBUG: uname ====="
uname -m
# ---------------------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
  err "Docker 不可用。GitHub ubuntu-latest 默认自带 docker；若你用自定义 runner 请先装 Docker。"
  exit 1
fi

# ---------------------------------------------------------------------------
# 0. Register qemu-aarch64 binfmt so the host can RUN arm64 containers.
#    Without this, `docker run --platform linux/arm64` fails with
#    "exec format error". We try two well-known images; if both fail we
#    abort loudly instead of silently continuing into a doomed chroot.
# ---------------------------------------------------------------------------
log "注册 qemu-aarch64 binfmt（让 docker 能运行 arm64 容器）..."
set +e
docker run --privileged --rm tonistiigi/binfmt:latest --install aarch64 2>&1 | tail -5
RC1=$?
docker run --privileged --rm multiarch/qemu-user-static --reset -p yes 2>&1 | tail -5
RC2=$?
set -e
if [ "${RC1:-1}" -ne 0 ] && [ "${RC2:-1}" -ne 0 ]; then
  err "binfmt 注册失败（两个镜像都拉不到）。arm64 容器将无法运行。"
  err "请确认 runner 能访问 Docker Hub，或换用原生 arm64 主机。"
  exit 1
fi
log "binfmt 注册完成。"

# ---------------------------------------------------------------------------
# 1. Run an arm64 Debian container, install Node 20 + Chromium inside it,
#    then tar the whole filesystem out as the rootfs.
#    All provisioning happens INSIDE the container (Docker emulates arm64),
#    so we never rely on a host-side chroot/qemu.
# ---------------------------------------------------------------------------
log "在 arm64 容器内安装 Node20 + Chromium 并打包 rootfs（可能要 10-20 分钟）..."
docker run --rm --platform linux/arm64 \
  -e SUITE="$SUITE" \
  -v "$OUT_DIR:/out" \
  "$DOCKER_IMG" bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  S="$SUITE"

  echo "[PHASE] 写 apt 源 ($S)"
  cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian $S main contrib non-free
deb http://deb.debian.org/debian $S-updates main contrib non-free
deb http://deb.debian.org/debian-security $S-security main
EOF
  echo "openminis" > /etc/hostname
  printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf

  echo "[PHASE] apt update"
  apt-get update -qq

  echo "[PHASE] 基础工具"
  apt-get install -y -qq --no-install-recommends \
    ca-certificates curl wget gnupg lsb-release xz-utils \
    git python3 make g++ pkg-config

  echo "[PHASE] Node.js 20"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq --no-install-recommends nodejs
  node --version
  npm --version

  echo "[PHASE] Chromium + 运行库"
  apt-get install -y -qq --no-install-recommends \
    chromium \
    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    libgbm1 libasound2 libpango-1.0-0 libcairo2 libatspi2.0-0 \
    fonts-liberation fonts-noto-core
  chromium --version || true

  echo "[PHASE] 清理 + 打包 rootfs"
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* 2>/dev/null || true
  # 排除挂载的 /out 与虚拟文件系统，避免递归打包宿主机/虚拟内容
  tar -czf /out/'"$OUT_TARBALL"' --exclude=/out --exclude=/proc --exclude=/sys --exclude=/dev -C / .
  echo "[PHASE] 完成: $(du -h /out/'"$OUT_TARBALL"' | cut -f1)"
'
log "rootfs 已生成: $OUT_DIR/$OUT_TARBALL"
