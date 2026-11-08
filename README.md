# VoCore M-PRO USB Touchscreen for KlipperScreen

> **Beta — limited compatibility.** This project is an independent community integration, not an official VoCore, KlipperScreen, or Klipper release.

Run the **standard KlipperScreen interface** on a VoCore M-PRO USB touchscreen with a single USB data cable (no HDMI), using a Linux DRM kernel driver and Xorg.

## What has actually been tested

| Component | Tested setup |
| --- | --- |
| Host | Raspberry Pi 4 Model B |
| OS | Raspberry Pi OS Bullseye, **32-bit armhf userspace** |
| Kernel | **6.1.21-v8+**, 64-bit aarch64 (Raspberry Pi firmware package `1:1.20230405-1`) |
| Display | VoCore **M-PRO 4-inch**, USB VID:PID `c872:1004` |
| Display modes | Portrait **480 × 800** and clockwise landscape **800 × 480** |
| Input | VoCore Touch, working in both modes |
| UI | Standard KlipperScreen on Xorg, automatic startup |

Both portrait and landscape and their touch mappings were tested on the above device. **180° and 270° have not been tested**, and switching among all four orientations inside KlipperScreen Settings has **not yet been implemented**. Other VoCore hardware IDs, sizes, operating systems and kernel versions are **not covered by this beta installer**.

### Orientation status

| Selection | Logical size | Status |
| --- | --- | --- |
| `--orientation 0` | 480 × 800 | Verified on the reference device |
| `--orientation 90` | 800 × 480 | Verified on the reference device |
| `180` | 480 × 800 | Planned; unavailable |
| `270` | 800 × 480 | Planned; unavailable |

The landscape driver rotates RGB565 pixels and touch coordinates before sending them to the physical 480 × 800 panel. **Do not use `xrandr --rotate right`** on this setup: it caused a black screen during testing. The Xorg output should be set to `normal`.

## Installation (beta)

**Back up your system first and work only while your printer is idle.** You need SSH access, `sudo`, an existing working **KlipperScreen + Xorg installation**, internet access and adequate disk space (several GB). The installer only supports the exact Raspberry Pi kernel listed above and stops on other kernels.

```bash
git clone https://github.com/Karbomod/VoCore-MPRO-KlipperScreen.git
cd VoCore-MPRO-KlipperScreen
bash install.sh --dry-run
bash install.sh --orientation 90
```

Choose `--orientation 0` for portrait. The installer displays checks and asks for confirmation before installing dependencies or changing system files. It downloads a **pinned upstream M-PRO source**, prepares a kernel 6.1.21-v8+ ARM64 build tree, applies the Linux 6.1 compatibility changes, compiles a kernel-specific module, creates a backup, configures Xorg and enables module auto-loading. It **does not** update your installed Linux kernel or modify Klipper/RatOS configuration.

This is a **beta automation path**, not a fully hardware-validated public installer. Review the code before running it. First-time installs on other machines may require additional diagnosis.

**Important:** Never pipe a downloaded script directly into a root shell. Clone the repository, inspect the scripts, then run them.

## Verify installation

After reboot, check the module, USB device, DRM connector and touchscreen:

```bash
uname -r
lsusb -d c872:1004
modinfo -n mpro
lsmod | grep mpro
for f in /sys/class/drm/card*-USB-1/modes; do [ -e "$f" ] && echo "$f: $(cat "$f")"; done
grep -A9 'Name="VoCore Touch"' /proc/bus/input/devices
systemctl status KlipperScreen --no-pager
```

Xorg should use the VoCore DRM device as the primary screen, with its EDID mode `480x800` (portrait) or `800x480` (landscape). The number of `/dev/dri/cardN` may change between boots; the installer uses a device-specific symlink under `/dev/dri/by-path/`.

## Recovery / uninstall

The installer stores backups under `/var/backups/vocore-mpro/`, including any previously installed M-PRO module and Xorg configuration. Keep SSH available in case the screen is blank.

To restore the latest backup:

```bash
bash uninstall.sh
```

Read the proposed restore actions and confirm; reboot after restoring. If an install fails before writing files, no reboot should be necessary.

For troubleshooting:

```bash
sudo journalctl -u KlipperScreen -b -n 80 --no-pager
sudo grep -E '\(EE\)|using drv|no screens|No modes' /var/log/Xorg.0.log | tail -60
sudo dmesg | grep -Ei 'mpro|drm|vocore|usb' | tail -70
```

**Screen shows only the VoCore logo:** check USB enumeration, kernel-module loading and `dmesg`.

**Linux console but not KlipperScreen:** inspect Xorg logs and KlipperScreen service; verify the expected DRM device is selected.

**`no screens found` / `No modes`:** Xorg may have selected the Raspberry Pi GPU rather than the USB display.

**Touch does not track the image:** verify you installed the driver for the chosen orientation; avoid applying an additional `xinput` transform to an already-rotated touch input.

**`invalid module format`:** compare `uname -r` with `modinfo -F vermagic /path/to/mpro.ko`.

## Technical background

The original [Vonger M-PRO DRM driver](https://github.com/Vonger/mpro_drm) targets newer kernel APIs. The verified reference Pi used Linux 6.1, requiring changes such as replacing `drm_fbdev_ttm_setup()` with `drm_fbdev_generic_setup()` and adapting the RGB565 DRM-format conversion API. The matching 64-bit `Module.symvers` was obtained from the Raspberry Pi April 2023 ARM64 header package. Do not substitute `v7l+` (32-bit) header symbols for `v8+` (ARM64).

The beta automation fetches a pinned source revision rather than treating the latest upstream branch as automatically compatible.

## Roadmap

- [x] Portrait 0°, KlipperScreen and touch on the reference Raspberry Pi
- [x] Landscape 90°, KlipperScreen and touch on the reference Raspberry Pi
- [x] Automatic startup after reboot on the reference Raspberry Pi
- [ ] Installer tested on additional fresh systems
- [ ] 180° rotation
- [ ] 270° rotation
- [ ] Orientation selector within the original KlipperScreen Settings
- [ ] Additional kernels and VoCore sizes

## Upstream projects and credits

- [VoCore M-PRO DRM](https://github.com/Vonger/mpro_drm) — original driver, copyright and upstream license notices must be preserved in modified derivatives
- [KlipperScreen](https://github.com/KlipperScreen/KlipperScreen) — standard touch UI
- [Raspberry Pi Linux](https://github.com/raspberrypi/linux) — matching kernel source

The installer is provided **as-is, with no warranty**. Kernel modules can affect system stability; always keep a working backup and remote access.
