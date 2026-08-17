#!/bin/bash
# =============================================================================
# prepare_debian_rootfs_android.sh
# -----------------------------------------------------------------------------
# Builds a Debian (glibc) aarch64 rootfs for OpenMinis on Android (PRoot).
#
# WHY:  OpenMinis ships an Alpine (musl) rootfs. Remotion's renderer is
#       Node.js + headless Chromium, and Chromium's official binaries require
#       glibc. musl (Alpine) cannot run them. This script produces a Debian
#       arm64 (glibc) rootfs that PRoot can boot on Android, with Node.js,
#       Chromium and the shared libraries Remotion needs preinstalled.
#
# OUTPUT: debian-minirootfs.tar.gz  (drop into src/android/.../assets/ and
#         rename the constants in RootfsManager.kt — see README.md)
#
# PREREQUISITES
#   - Linux build host (x86_64 or aarch64). On x86_64 you need qemu-user-static
#     + binfmt_misc so debootstrap can run arm64 binaries during second stage.
#   - Root (we use chroot / mount --bind for /proc, /sys, /dev).
#   - ~2 GB free disk for the working rootfs, ~600 MB for the final tarball.
#   - Internet access to deb.debian.org and NodeSource.
#
# USAGE:
#   sudo ./prepare_debian_rootfs_android.sh [debian-version]
#   e.g. sudo ./prepare_debian_rootfs_android.sh bookworm
# =============================================================================
set -euo pipefail

DEBIAN_VER="${1:-bookworm}"
WORKDIR="$(pwd)/.debian-rootfs-build"
ROOTFS="$WORKDIR/rootfs"
CACHE_DIR="$WORKDIR/cache"
OUT_TARBALL="debian-minirootfs.tar.gz"
OUT_DIR="${2:-$(pwd)}"

log()  { echo -e "\033[1;34m[debian-rootfs]\033[0m $*"; }
ok()   { echo -e "\033[0;32m[debian-rootfs]\033[0m $*"; }
err()  { echo -e "\033[0;31m[debian-rootfs] ERROR:\033[0m $*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  err "This script must run as root (needs chroot + mount --bind)."
  exit 1
fi

# ---------------------------------------------------------------------------
# 0. Host tooling
# ---------------------------------------------------------------------------
log "Installing build host tooling (debootstrap, qemu)..."
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq debootstrap qemu-user-static binfmt-support \
    ca-certificates curl xz-utils pigz 2>/dev/null || \
  apt-get install -y -qq debootstrap qemu-user-static binfmt-support \
    ca-certificates curl xz-utils gzip
fi

HOST_ARCH="$(uname -m)"
if [ "$HOST_ARCH" != "aarch64" ] && [ "$HOST_ARCH" != "arm64" ]; then
  log "Host is $HOST_ARCH — enabling qemu-aarch64 binfmt for cross-debootstrap."
  # Ensure the arm64 emulator is registered so chroot can run arm64 binaries.
  if [ -x /usr/bin/qemu-aarch64-static ]; then
    if ! grep -q qemu-aarch64 /proc/sys/fs/binfmt_misc/status 2>/dev/null; then
      if [ -f /usr/share/binfmt-support/qemu-aarch64 ]; then
        ./usr/share/binfmt-support/qemu-aarch64 2>/dev/null || true
      fi
      update-binfmts --enable qemu-aarch64 2>/dev/null || true
    fi
  else
    err "qemu-aarch64-static not found. Install qemu-user-static."
    exit 1
  fi
fi

mkdir -p "$ROOTFS" "$CACHE_DIR"

# ---------------------------------------------------------------------------
# 1. First stage debootstrap (arm64)
# ---------------------------------------------------------------------------
log "Stage 1: debootstrap --arch=arm64 --foreign $DEBIAN_VER ..."
if [ "$HOST_ARCH" = "aarch64" ] || [ "$HOST_ARCH" = "arm64" ]; then
  debootstrap --arch=arm64 --no-check-gpg "$DEBIAN_VER" "$ROOTFS" http://deb.debian.org/debian
else
  # Copy the static emulator into the rootfs so the foreign chroot can run.
  cp /usr/bin/qemu-aarch64-static "$ROOTFS/qemu-aarch64-static" 2>/dev/null || true
  debootstrap --arch=arm64 --foreign --no-check-gpg "$DEBIAN_VER" "$ROOTFS" http://deb.debian.org/debian
fi

# ---------------------------------------------------------------------------
# 2. Second stage inside chroot
# ---------------------------------------------------------------------------
log "Stage 2: completing debootstrap inside chroot..."
mount --bind /proc  "$ROOTFS/proc"  2>/dev/null || true
mount --bind /sys   "$ROOTFS/sys"   2>/dev/null || true
mount --bind /dev   "$ROOTFS/dev"   2>/dev/null || true
mount --bind /dev/pts "$ROOTFS/dev/pts" 2>/dev/null || true
# Allow network + DNS resolution inside the chroot (needed for apt + NodeSource).
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true
trap 'umount -l "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev/pts" "$ROOTFS/dev" 2>/dev/null || true' EXIT

chroot "$ROOTFS" /bin/bash -c '
  set -e
  if [ -x /qemu-aarch64-static ]; then
    /qemu-aarch64-static /bin/sh -c "/debootstrap/debootstrap --second-stage"
  else
    /debootstrap/debootstrap --second-stage
  fi
'

# ---------------------------------------------------------------------------
# 3. Install Node.js (arm64), Chromium and Remotion runtime deps
# ---------------------------------------------------------------------------
log "Configuring apt + installing Node, Chromium and Remotion deps..."

cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb http://deb.debian.org/debian $DEBIAN_VER main contrib non-free
deb http://deb.debian.org/debian-security $DEBIAN_VER-security main
deb http://deb.debian.org/debian $DEBIAN_VER-updates main
EOF

chroot "$ROOTFS" /bin/bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  # --- Base tooling -------------------------------------------------------
  apt-get install -y -qq --no-install-recommends \
    ca-certificates curl wget gnupg lsb-release xz-utils \
    git python3 make g++ pkg-config

  # --- Node.js (NodeSource, arm64) ---------------------------------------
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq --no-install-recommends nodejs
  node --version && npm --version

  # --- Chromium + Remotion/headless-Chrome shared libraries --------------
  # Debian "chromium" is the arm64 build. The extra libs cover what Chrome
  # needs to launch headless under PRoot with software GL (SwiftShader).
  apt-get install -y -qq --no-install-recommends \
    chromium chromium-driver \
    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
    libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 \
    libxrandr2 libgbm1 libpango-1.0-0 libcairo2 libasound2 \
    libxshmfence1 libx11-xcb1 libxcb-dri3-0 libxext6 libxrender1 \
    libpangocairo-1.0-0 libgtk-3-0 fonts-liberation fonts-noto \
    libgles2 mesa-vdpau-drivers 2>/dev/null || \
  apt-get install -y -qq --no-install-recommends \
    chromium chromium-driver libnss3 libgbm1 libasound2 libpangocairo-1.0-0 \
    libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 libxcomposite1 \
    libxdamage1 libxfixes3 libxrandr2 libx11-xcb1 libxshmfence1 \
    fonts-liberation fonts-noto

  # --- npm global tooling (optional, speeds up Remotion projects) --------
  npm install -g npm@latest

  # --- Clean apt caches to shrink the image ------------------------------
  apt-get clean
  rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /root/.npm/_logs 2>/dev/null || true
'

# Sanity: confirm glibc + chromium + node are present and glibc-based.
log "Verifying toolchain inside rootfs..."
chroot "$ROOTFS" /usr/bin/chromium --version 2>&1 | head -1 || true
chroot "$ROOTFS" /usr/bin/node --version 2>&1 | head -1 || true
if ! chroot "$ROOTFS" /usr/bin/node -e 'console.log("glibc ok")' 2>/dev/null; then
  err "Node did not run — rootfs may still be musl or missing libs."
fi

# ---------------------------------------------------------------------------
# 4. Tune for PRoot / headless rendering
# ---------------------------------------------------------------------------
log "Writing Chromium/Remotion profile tweaks..."

# Make Chromium usable without a GPU and without a real /dev/shm on some hosts.
mkdir -p "$ROOTFS/etc/chromium/policies" 2>/dev/null || true
cat > "$ROOTFS/etc/profile.d/zz-minis-remotion.sh" <<'EOF'
# OpenMinis: Remotion / headless Chromium defaults for the PRoot sandbox.
export CHROME_HEADLESS=1
# Tell Chromium to use software rendering (no GPU in the sandbox).
export CHROMIUM_FLAGS="--no-sandbox --disable-gpu --use-gl=swiftshader --enable-unsafe-swiftshader --disable-dev-shm-usage --disable-software-rasterizer --no-first-run"
EOF

# Ensure /dev/shm exists (PRootKernel.kt also binds host /dev/shm).
mkdir -p "$ROOTFS/dev/shm"
chmod 1777 "$ROOTFS/dev/shm" 2>/dev/null || true

# Remove the qemu emulator we copied in (only needed during build).
rm -f "$ROOTFS/qemu-aarch64-static"

# ---------------------------------------------------------------------------
# 5. Package into the asset tarball OpenMinis expects
# ---------------------------------------------------------------------------
log "Creating $OUT_TARBALL (this can take a minute)..."
rm -f "$OUT_DIR/$OUT_TARBALL"
if command -v pigz >/dev/null 2>&1; then
  GZIP=pigz tar --numeric-owner --owner=0 --group=0 -C "$ROOTFS" -cf - . \
    | pigz -9 > "$OUT_DIR/$OUT_TARBALL"
else
  tar --numeric-owner --owner=0 --group=0 -C "$ROOTFS" -czf "$OUT_DIR/$OUT_TARBALL" .
fi

SIZE=$(du -h "$OUT_DIR/$OUT_TARBALL" | cut -f1)
ok "Built $OUT_DIR/$OUT_TARBALL ($SIZE)"
ok "Next: copy it to src/android/app/src/main/assets/ and apply the Kotlin patches (see README.md)."

# Cleanup
trap - EXIT
umount -l "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev/pts" "$ROOTFS/dev" 2>/dev/null || true
log "Build artifacts left in $WORKDIR (delete when done)."
