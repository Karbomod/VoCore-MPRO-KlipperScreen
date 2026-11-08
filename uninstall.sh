#!/usr/bin/env bash
# Restore the latest snapshot made by install.sh. Does not touch Klipper/RatOS.
set -Eeuo pipefail
[[ "$EUID" -ne 0 ]] || { echo "Run as your regular user, not as root."; exit 1; }
command -v sudo >/dev/null || { echo "sudo is required."; exit 1; }

BACKUPS=/var/backups/vocore-mpro
KERNEL="$(uname -r)"
TARGET="/lib/modules/$KERNEL/extra/mpro.ko"
XORG=/etc/X11/xorg.conf.d/99-vocore.conf
AUTO=/etc/modules-load.d/mpro.conf

[[ -d "$BACKUPS" ]] || { echo "No VoCore backup directory exists."; exit 1; }
LATEST="$(sudo find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tail -1)"
[[ -n "$LATEST" ]] || { echo "No VoCore backups found."; exit 1; }
BACKUP="$BACKUPS/$LATEST"
[[ -f "$BACKUP/state" ]] || { echo "Backup state missing; nothing changed."; exit 1; }

# Read only fixed-name booleans from a root-owned backup, not shell code.
had_module="$(sudo sed -n 's/^had_module=//p' "$BACKUP/state" | head -1)"
had_xorg="$(sudo sed -n 's/^had_xorg=//p' "$BACKUP/state" | head -1)"
had_auto="$(sudo sed -n 's/^had_auto=//p' "$BACKUP/state" | head -1)"
had_enabled="$(sudo sed -n 's/^had_enabled=//p' "$BACKUP/state" | head -1)"
backup_kernel="$(sudo sed -n 's/^kernel=//p' "$BACKUP/state" | head -1)"

for status in "$had_module" "$had_xorg" "$had_auto" "$had_enabled"; do
    [[ "$status" == 0 || "$status" == 1 ]] || {
        echo "Invalid backup state. Nothing changed." >&2
        exit 1
    }
done
if [[ -n "$backup_kernel" && "$backup_kernel" != "$KERNEL" ]]; then
    echo "Backup was made on kernel $backup_kernel; current kernel is $KERNEL."
    echo "Refusing to overwrite a different kernel's module."
    exit 1
fi
[[ "$had_module" == 0 || -s "$BACKUP/mpro.ko" ]] || { echo "Missing backed-up module."; exit 1; }
[[ "$had_xorg" == 0 || -f "$BACKUP/99-vocore.conf" ]] || { echo "Missing Xorg backup."; exit 1; }
[[ "$had_auto" == 0 || -f "$BACKUP/mpro.conf" ]] || { echo "Missing autoload backup."; exit 1; }

echo "Restore snapshot: $BACKUP"
echo "Kernel: $KERNEL"
echo "Previous module present: $had_module"
echo "Previous Xorg config present: $had_xorg"
echo "Previous auto-load config present: $had_auto"
echo "Previous KlipperScreen enabled: $had_enabled"
read -r -p "Printer IDLE and SSH recovery available? Type RESTORE to proceed: " answer
[[ "$answer" == RESTORE ]] || { echo "Cancelled."; exit 1; }

if [[ "$had_module" == 1 ]]; then
    sudo install -D -m 0644 "$BACKUP/mpro.ko" "$TARGET"
else
    sudo rm -f "$TARGET"
fi
if [[ "$had_xorg" == 1 ]]; then
    sudo install -D -m 0644 "$BACKUP/99-vocore.conf" "$XORG"
else
    sudo rm -f "$XORG"
fi
if [[ "$had_auto" == 1 ]]; then
    sudo install -D -m 0644 "$BACKUP/mpro.conf" "$AUTO"
else
    sudo rm -f "$AUTO"
fi
sudo depmod -a
if [[ "$had_enabled" == 1 ]]; then
    sudo systemctl enable KlipperScreen
else
    sudo systemctl disable KlipperScreen
fi

echo "Files restored. The running module remains in memory until reboot."
read -r -p "Reboot now? [y/N] " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
    sudo reboot
else
    echo "Reboot when idle: sudo reboot"
fi
