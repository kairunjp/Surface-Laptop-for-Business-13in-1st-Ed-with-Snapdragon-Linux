# Arch Linux ARM64 ISO

The `archlinux` branch builds a live Arch Linux ARM64 ISO for the Surface
Laptop for Business 13-inch (X1P42100). The workflow is
`.github/workflows/archlinux.yml`.

## GitHub Actions

The workflow uses the native `ubuntu-24.04-arm` GitHub-hosted runner. Archiso
does not cross-build images, so an x86_64 runner is not interchangeable with
this runner. Pushes to `archlinux` and manual runs from the Actions page build
the ISO and upload these artifacts:

- `surface-archlinux-*.iso`
- `SHA256SUMS`

The runner downloads the current Arch Linux ARM AArch64 bootstrap rootfs and
updates it with `pacman`. It fetches archiso `v90`, builds the kernel revision
locked in `kernel/source.lock`, and obtains Bluetooth firmware from the pinned
linux-firmware revision. Wi-Fi uses the exact files from the working
`surface-pve` boot initramfs, validated against `drivers/firmware-manifest.json`.
Both the live root and the early initramfs receive that same Wi-Fi set. The
builder also handles the legacy Arch Linux ARM key certification required by
newer GnuPG versions without disabling package signature verification.

For CI, provide an HTTPS reference archive URL in the manual run's
`wifi_firmware_url` input, or the repository variable `WCN7850_FIRMWARE_URL`
for push builds. The archive must contain `amss.bin`, `m3.bin`, `board.bin`,
`board-2.bin`, and `Notice.txt` at its root. The builder checks every file's
size and SHA-256 before building the kernel. Missing or mismatched reference
inputs fail the build; it does not substitute another board's calibration.
The archive is an external build input, not committed firmware.

## Local build

The builder must run as root on an AArch64 Linux host because it creates a
chroot and mounts `/dev`, `/proc`, `/sys`, and `/run`. On Debian or Ubuntu,
install the host tools with:

```sh
sudo apt-get install build-essential bc bison cpio device-tree-compiler \
  flex git libarchive-tools libelf-dev libssl-dev openssl patch python3 ripgrep curl xz-utils
sudo ARCHLINUX_BUILD_DIR=/var/tmp/surface-archlinux \
  ARCHLINUX_OUTPUT_DIR="$PWD/build/archlinux" \
  WCN7850_FIRMWARE_SOURCE=/path/to/surface-pve-wifi-reference.tar.gz \
  ./archlinux/build-iso.sh
```

On Arch Linux ARM, install the equivalent packages with `pacman` instead.

The default scratch path is under `/tmp` (or `$RUNNER_TEMP` in Actions). The
Arch Linux ARM rootfs download alone is roughly 800 MiB compressed, and the
kernel and archiso work trees need additional free space.

`WCN7850_FIRMWARE_SOURCE` also accepts an extracted `hw2.0` directory. Validate
it independently with `python3 archlinux/prepare-wifi-firmware.py PATH`.
Keep this input outside the disposable build directory.

## Reference checked on 2026-09-09

SSH inspection of `surface-pve` confirmed PCI `17cb:1107`, subsystem
`00ab:1414`, driver `ath12k_wifi7_pci`, and a managed `wlan0` with neither
software nor hardware rfkill. The running kernel is
`7.2.0-rc5-surface-laptop-13`, with built-in ATH12K/MHI/QRTR support.
The actual ESP boot payload `/EFI/BOOT/surface-kvm-initrd.img` contains:

| File | SHA-256 |
| --- | --- |
| amss.bin (c5-00310, 2025-07-07) | `74f2ffde049d523cba7bc7660f4d9806110bbe1d1ecac9565f50028652a861f3` |
| board.bin | `b24438910ff0383d299798a997d3ef3484be624ac013aec2ce7939ec32900c4f` |
| board-2.bin | `1abee7132dbccb523cca44a8de4e8968aa7bf5a5fcc032c338f687f94ea5bf4e` |
| m3.bin | `0e72f44df7defc269fe92dcea25d4d409046c04b77d41c510c52879b3dfc1055` |

The installed rootfs has a newer `amss.bin` (c7-00108, `43aadf…`) that was
not used for this successful boot. Copying only its current rootfs would
therefore not reproduce the working combination. The previous Arch builder's
3378/255 extraction (`board.bin` hash `0ef5f6…`) also differs from this
reference. Its successful extraction was not a hardware compatibility test.
Arch boot and network association still require testing on the target.

## Boot behavior

The ISO contains two menu entries: the default touchscreen/USB entry and a
Bluetooth-enabled entry. Both use a DTB with ADSP, CDSP, and the sound card
disabled. This is intentional: the Surface DSP/remoteproc firmware is an
external, device-specific input and is not available in this repository. Wi-Fi
uses the reference set above; Bluetooth uses downloaded QCA firmware. The output
is an unsigned development image; disable Secure Boot before booting it.

The ISO is a live environment, not an unattended disk installer. Log in as
`root` at the console and use the normal Arch installation tools or the
included `archinstall` command after bringing up networking with
NetworkManager/iwd.

The image also enables `surface-wifi-reprobe.service`. It retries the WCN7850
PCI probe after the live root and its firmware are available, covering boots
where the built-in `ath12k` driver probes too early during initramfs startup.
