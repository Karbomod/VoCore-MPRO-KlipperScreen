#!/usr/bin/env bash
# Beta installer for the specific tested Raspberry Pi 4 configuration.
# Run as an ordinary user; do NOT pipe this script into sudo bash.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$(uname -r)"
ORIENTATION=90
DRY_RUN=0
UPSTREAM_COMMIT=007705aec068fa0fbef440f593bc24a380156596
CACHE="$HOME/.cache/vocore-mpro-installer"
TARGET="/lib/modules/$KERNEL/extra/mpro.ko"
XORG=/etc/X11/xorg.conf.d/99-vocore.conf
AUTO=/etc/modules-load.d/mpro.conf
BACKUPS=/var/backups/vocore-mpro

info() { printf '[vocore] %s\n' "$*"; }
fail() { printf '[vocore] ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Usage: bash install.sh [--orientation 0|90] [--dry-run]
  0: portrait 480x800, 90: clockwise landscape 800x480.
  180 and 270 are not implemented. Other kernels are not supported.
  Dry-run performs checks without changing anything.
HELP
}
while (($#)); do
    case "$1" in
        --orientation) (($# > 1)) || fail "Missing orientation"; ORIENTATION="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
case "$ORIENTATION" in 0) MODE=480x800 ;; 90) MODE=800x480 ;;
    *) fail "Only 0 and 90 degrees are implemented" ;;
esac
[[ "$EUID" -ne 0 ]] || fail "Run as your regular user, not root."
[[ "$KERNEL" == 6.1.21-v8+ && "$(uname -m)" == aarch64 &&
   "$(dpkg --print-architecture)" == armhf ]] ||
    fail "Only kernel 6.1.21-v8+ (aarch64) with armhf userspace is supported in this beta."
command -v lsusb >/dev/null || fail "Install usbutils first (lsusb)."
lsusb -d c872:1004 | grep -q 'c872:1004' || fail "VoCore M-PRO c872:1004 not detected."
systemctl cat KlipperScreen >/dev/null 2>&1 || fail "Install KlipperScreen first."
command -v Xorg >/dev/null || fail "Xorg is required."
command -v sudo >/dev/null || fail "sudo is required."
[[ -f "$HERE/tools/patch_mpro_6_1.py" ]] || fail "Missing tools/patch_mpro_6_1.py"
info "Kernel: $KERNEL; VoCore USB: c872:1004; target $ORIENTATION degrees ($MODE)."
info "Will install only after explicit confirmation. No kernel or RatOS updates."
if [[ "$DRY_RUN" == 1 ]]; then
    info "Dry-run complete; no files changed."
    exit 0
fi

read -r -p "Confirm that the printer is IDLE and SSH recovery is available (type YES): " answer
[[ "$answer" == YES ]] || fail "Cancelled."
sudo -v

# APT can be reviewed in advance; do not update the kernel to make a driver work.
DEPS=(git make python3 wget flex bison bc libssl-dev libelf-dev gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu)
info "APT dependency plan:"
sudo apt-get -s install --no-install-recommends "${DEPS[@]}" |
    grep -E '^(Inst|Remv|Conf|[0-9]+ upgraded|The following)' || true
read -r -p "Install missing build dependencies shown above (type YES): " answer
[[ "$answer" == YES ]] || fail "Cancelled."
sudo apt-get install --no-install-recommends -y "${DEPS[@]}"

mkdir -p "$CACHE"
UPSTREAM="$CACHE/upstream"
if [[ ! -d "$UPSTREAM/.git" ]]; then
    git clone --depth 1 https://github.com/Vonger/mpro_drm.git "$UPSTREAM"
fi
[[ "$(git -C "$UPSTREAM" rev-parse HEAD)" == "$UPSTREAM_COMMIT" ]] ||
    fail "Pinned upstream revision changed; refusing to patch it."

TREE="$HOME/linux-6.1.21-rpi"
if [[ ! -f "$TREE/Makefile" || ! -s "$TREE/Module.symvers" ]]; then
    TREE="$CACHE/linux-6.1.21-rpi"
fi
if [[ ! -f "$TREE/Makefile" ]]; then
    info "Cloning matching Raspberry Pi Linux 6.1.21 sources (may take several minutes)."
    git clone --depth 1 --branch 1.20230405 \
        https://github.com/raspberrypi/linux.git "$TREE"
fi
[[ "$(make -s -C "$TREE" kernelversion)" == 6.1.21 ]] ||
    fail "Kernel source version does not match."
if [[ ! -s "$TREE/Module.symvers" ]]; then
    sudo modprobe configs || fail "Cannot access the running kernel configuration."
    [[ -r /proc/config.gz ]] || fail "/proc/config.gz is missing."
    zcat /proc/config.gz > "$TREE/.config"
    grep -qx 'CONFIG_LOCALVERSION="-v8"' "$TREE/.config" ||
        fail "Kernel local version differs from -v8."
    grep -qx 'CONFIG_MODVERSIONS=y' "$TREE/.config" ||
        fail "Expected CONFIG_MODVERSIONS=y."
    make -C "$TREE" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
    make -j2 -C "$TREE" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- prepare modules_prepare
    DEB="$CACHE/rpi-headers-1.20230405-1-arm64.deb"
    wget -O "$DEB" \
        'https://archive.raspberrypi.com/debian/pool/main/r/raspberrypi-firmware/raspberrypi-kernel-headers_1.20230405-1_arm64.deb'
    [[ "$(dpkg-deb -f "$DEB" Architecture)" == arm64 ]] ||
        fail "Unexpected header package architecture."
    [[ "$(dpkg-deb -f "$DEB" Version)" == '1:1.20230405-1' ]] ||
        fail "Unexpected header package version."
    mkdir -p "$CACHE/extracted-headers"
    dpkg-deb -x "$DEB" "$CACHE/extracted-headers"
    SYMVERS="$CACHE/extracted-headers/usr/src/linux-headers-6.1.21-v8+/Module.symvers"
    [[ -s "$SYMVERS" ]] || fail "Matching ARM64 Module.symvers not found."
    cp "$SYMVERS" "$TREE/Module.symvers"
fi
[[ -s "$TREE/Module.symvers" ]] || fail "Cannot compile without Module.symvers."
[[ "$(make -s -C "$TREE" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- kernelrelease)" == "$KERNEL" ]] ||
    fail "The prepared source kernel release differs from the running kernel."

BUILD="$CACHE/build-$ORIENTATION"
mkdir -p "$BUILD"
python3 "$HERE/tools/patch_mpro_6_1.py" \
    "$UPSTREAM/mpro.c" "$BUILD/mpro.c" --orientation "$ORIENTATION"
cp "$UPSTREAM/Makefile" "$BUILD/Makefile"
make -C "$TREE" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M="$BUILD" clean
make -j2 -C "$TREE" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M="$BUILD" modules
[[ -s "$BUILD/mpro.ko" ]] || fail "Module build failed."
VM="$(modinfo -F vermagic "$BUILD/mpro.ko")"
[[ "$VM" == "$KERNEL "* && "$VM" == *"modversions aarch64"* ]] ||
    fail "Compiled module does not match kernel: $VM"

# Snapshot current files before changing the system.
sudo mkdir -p "$BACKUPS"
BACKUP="$(sudo mktemp -d "$BACKUPS/$(date -u +%Y%m%dT%H%M%SZ)-XXXX")"
had_module=0; had_xorg=0; had_auto=0; had_enabled=0
if [[ -e "$TARGET" ]]; then sudo cp -a "$TARGET" "$BACKUP/mpro.ko"; had_module=1; fi
if [[ -e "$XORG" ]]; then sudo cp -a "$XORG" "$BACKUP/99-vocore.conf"; had_xorg=1; fi
if [[ -e "$AUTO" ]]; then sudo cp -a "$AUTO" "$BACKUP/mpro.conf"; had_auto=1; fi
if systemctl is-enabled --quiet KlipperScreen; then had_enabled=1; fi
printf 'had_module=%s\nhad_xorg=%s\nhad_auto=%s\nhad_enabled=%s\nkernel=%s\n' \
    "$had_module" "$had_xorg" "$had_auto" "$had_enabled" "$KERNEL" |
    sudo tee "$BACKUP/state" >/dev/null
sudo chmod 600 "$BACKUP/state"

restore_files() {
    if [[ "$had_module" == 1 ]]; then sudo cp -a "$BACKUP/mpro.ko" "$TARGET"; else sudo rm -f "$TARGET"; fi
    if [[ "$had_xorg" == 1 ]]; then sudo cp -a "$BACKUP/99-vocore.conf" "$XORG"; else sudo rm -f "$XORG"; fi
    if [[ "$had_auto" == 1 ]]; then sudo cp -a "$BACKUP/mpro.conf" "$AUTO"; else sudo rm -f "$AUTO"; fi
    sudo depmod -a || true
}
SHOULD_ROLLBACK=1
on_exit() {
    local exit_code=$?
    if ((exit_code != 0 && SHOULD_ROLLBACK == 1)); then
        info "An error occurred. Restoring prior module and Xorg files from $BACKUP."
        restore_files || true
        info "If a test module is already loaded, reboot to reapply the restored files."
    fi
}
trap on_exit EXIT

sudo install -D -m 0644 "$BUILD/mpro.ko" "$TARGET"
sudo depmod -a
sudo mkdir -p /etc/modules-load.d /etc/X11/xorg.conf.d
printf 'mpro\n' | sudo tee "$AUTO" >/dev/null
if ! lsmod | grep -q '^mpro '; then sudo modprobe mpro; fi
if command -v udevadm >/dev/null; then sudo udevadm settle || true; fi

# Resolve the real VoCore USB DRM device; cardN numbers change between boots.
KMS=""
for CARD in /dev/dri/card[0-9]*; do
    [[ -e "$CARD" ]] || continue
    DRIVER="/sys/class/drm/$(basename "$CARD")/device/driver"
    [[ -L "$DRIVER" ]] || continue
    [[ "$(basename "$(readlink -f "$DRIVER")")" == mpro ]] || continue
    for LINK in /dev/dri/by-path/*-card; do
        [[ -L "$LINK" ]] || continue
        if [[ "$(readlink -f "$LINK")" == "$(readlink -f "$CARD")" ]]; then
            KMS="$LINK"
            break 2
        fi
    done
done
[[ -n "$KMS" ]] || fail "No M-PRO by-path DRM link. Restoring backup."

TEMP_CONF="$(mktemp)"
cat > "$TEMP_CONF" <<EOF
# Generated by VoCore-MPRO-KlipperScreen beta installer.
Section "ServerFlags"
    Option "AutoAddGPU" "false"
EndSection
Section "Device"
    Identifier "VoCoreMPro"
    Driver "modesetting"
    Option "kmsdev" "$KMS"
    Option "AccelMethod" "none"
    Option "SWcursor" "true"
EndSection
Section "Monitor"
    Identifier "VoCoreMonitor"
    Option "PreferredMode" "$MODE"
EndSection
Section "Screen"
    Identifier "VoCoreScreen"
    Device "VoCoreMPro"
    Monitor "VoCoreMonitor"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "$MODE"
    EndSubSection
EndSection
Section "ServerLayout"
    Identifier "VoCoreLayout"
    Screen 0 "VoCoreScreen" 0 0
EndSection
Section "OutputClass"
    Identifier "VoCorePrimary"
    MatchDriver "mpro"
    Driver "modesetting"
    Option "PrimaryGPU" "true"
EndSection
EOF
sudo install -m 0644 "$TEMP_CONF" "$XORG"
rm -f "$TEMP_CONF"
sudo systemctl enable KlipperScreen
SHOULD_ROLLBACK=0
trap - EXIT
info "Installation complete: $ORIENTATION° ($MODE). Previous files: $BACKUP."
info "A reboot is required to load the newly installed driver."
info "Rollback: bash uninstall.sh"
read -r -p "Reboot Raspberry Pi now? [y/N] " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then sudo reboot; else info "Reboot when idle: sudo reboot"; fi
