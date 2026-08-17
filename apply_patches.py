#!/usr/bin/env python3
# =============================================================================
# apply_patches.py  —  OpenMinis Android: Alpine(musl) -> Debian(glibc) for Remotion
# -----------------------------------------------------------------------------
# Applies the two Kotlin edits needed so the PRoot sandbox boots a Debian
# rootfs (glibc) instead of Alpine (musl), and binds /dev/shm so headless
# Chromium (Remotion's renderer) has shared memory.
#
# Run from the OpenMinis repo root:
#   python3 apply_patches.py            # auto-detects src/android
#   python3 apply_patches.py /path/to/OpenMinis
#
# Safe by design: each replacement must match EXACTLY. If anything drifts
# (e.g. upstream changed the file), the script aborts without editing.
# =============================================================================
import sys
import os

REPO = sys.argv[1] if len(sys.argv) > 1 else "."
SANDBOX = os.path.join(
    REPO, "src/android/app/src/main/java/com/openminis/app/sandbox")

ROOTFS = os.path.join(SANDBOX, "RootfsManager.kt")
PROOT = os.path.join(SANDBOX, "PRootKernel.kt")


def replace_once(path, old, new, label):
    if not os.path.isfile(path):
        print(f"  [SKIP] {path} not found")
        return False
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    if old not in text:
        print(f"  [FAIL] pattern not found in {os.path.basename(path)}:\n"
              f"         {label}\n         → aborting (file may have changed).")
        sys.exit(1)
    if text.count(old) != 1:
        print(f"  [WARN] pattern matched {text.count(old)} times in "
              f"{os.path.basename(path)}; applying to first only.")
    text = text.replace(old, new, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"  [OK]   patched {os.path.basename(path)} — {label}")
    return True


print("== OpenMinis: Alpine→Debian (glibc) patch for Remotion ==\n")

# ---------------------------------------------------------------------------
# 1. RootfsManager.kt — point at a Debian rootfs asset + extract dir
# ---------------------------------------------------------------------------
print("[1/2] RootfsManager.kt")
replace_once(
    ROOTFS,
    'val rootfsDir: File = File(context.filesDir, "alpine-rootfs")',
    'val rootfsDir: File = File(context.filesDir, "debian-rootfs")',
    'rootfsDir path: alpine-rootfs -> debian-rootfs')

replace_once(
    ROOTFS,
    'private const val ROOTFS_ASSET = "alpine-minirootfs.tar.gz"',
    'private const val ROOTFS_ASSET = "debian-minirootfs.tar.gz"',
    'ROOTFS_ASSET: debian-minirootfs.tar.gz')

replace_once(
    ROOTFS,
    'private const val ROOTFS_ASSET_TAR = "alpine-minirootfs.tar"',
    'private const val ROOTFS_ASSET_TAR = "debian-minirootfs.tar"',
    'ROOTFS_ASSET_TAR: debian-minirootfs.tar')

replace_once(
    ROOTFS,
    'Log.i(TAG, "Installing Alpine rootfs...")',
    'Log.i(TAG, "Installing Debian rootfs...")',
    'log string: Alpine -> Debian')

# If the project carries a Debian-incompatible "default_mount" overlay
# (Alpine-specific /etc/apk, openrc, etc.), flag it for manual review.
print("  -> Review applyDefaultMountOverlay() / the default_mount asset:")
print("     replace any Alpine-only files (apk repos, openrc) with")
print("     Debian equivalents (apt sources, profile.d). See debian_default_mount/.")

# ---------------------------------------------------------------------------
# 2. PRootKernel.kt — bind /dev/shm for Chromium shared memory
# ---------------------------------------------------------------------------
print("\n[2/2] PRootKernel.kt")
OLD_BIND = '''        // Bind essential pseudo-filesystems
        cmd.add("-b")
        cmd.add("/dev")
        cmd.add("-b")
        cmd.add("/proc")
        cmd.add("-b")
        cmd.add("/sys")'''

NEW_BIND = '''        // Bind essential pseudo-filesystems
        cmd.add("-b")
        cmd.add("/dev")
        cmd.add("-b")
        cmd.add("/proc")
        cmd.add("-b")
        cmd.add("/sys")

        // Bind host /dev/shm so headless Chromium / Remotion has shared memory.
        // Without this, Chrome's renderer/GPU process crashes on launch under PRoot.
        cmd.add("-b")
        cmd.add("/dev/shm")'''

replace_once(PROOT, OLD_BIND, NEW_BIND,
             'add -b /dev/shm bind mount')

print("\n== Done. Next steps ==")
print("  1. Build the Debian rootfs:  sudo ./prepare_debian_rootfs_android.sh bookworm")
print("  2. Copy debian-minirootfs.tar.gz into")
print("     src/android/app/src/main/assets/")
print("  3. Rebuild the Android app. Remotion will now boot on a glibc rootfs.")
print("  (iOS/iSH route is NOT covered here — see README.md for why.)")
