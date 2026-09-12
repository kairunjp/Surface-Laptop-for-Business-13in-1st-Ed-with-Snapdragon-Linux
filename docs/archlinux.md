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
The Adreno GPU uses `gen71500_sqe.fw` and `gen71500_gmu.bin` from
linux-firmware plus the device-specific `qcdxkmsucpurwa.mbn` extracted from
Microsoft's official Surface Laptop 13 driver MSI. The signed blob is staged
at `qcom/x1p42100/Microsoft/SurfaceLaptop13/qcdxkmsucpurwa.mbn`; the generic
X1P zap blob and the similarly named Surface Pro 12 blob are rejected by this
machine's TrustZone with `-22`. Both firmware sets are copied into the live
root, the early initramfs, and the kernel's built-in firmware directory so
PCI/DRM probes cannot race the root filesystem. The kernel also adds the
Surface compatible to the Qualcomm QSEECOM allowlist. The builder imports the
official Arch Linux ARM keyring, locally signs its package-build key to account
for the key's legacy certification, and keeps package signature verification
enabled.

CI uses the checked-in archive
`build/archlinux-reference/surface-pve-wifi-reference.tar.gz` by default. A
manual run may override it with an HTTPS URL through `wifi_firmware_url` (or
the `WCN7850_FIRMWARE_URL` repository variable). The archive must contain
`amss.bin`, `m3.bin`, `board.bin`, `board-2.bin`, and `Notice.txt` at its root.
The builder checks every file's size and SHA-256 before building the kernel.
Missing or mismatched reference inputs fail the build; it does not substitute
another board's calibration.

CI also uses the checked-in
`build/archlinux-reference/surface-laptop13-gpu-reference.tar.gz` by default. A
manual run may override it explicitly with `gpu_firmware_url`. It must contain
`gen71500_sqe.fw`, `gen71500_gmu.bin`,
and `x1p42100/Microsoft/SurfaceLaptop13/qcdxkmsucpurwa.mbn` under `qcom/`.
The builder checks every file's size and SHA-256 before staging it.

The workflow also uses the committed Surface ADSP/CDSP and AudioReach
firmware tree under `archlinux/firmware-tree/`. Its five files are checked
against `drivers/firmware-manifest.json` and are embedded in the kernel as
well as staged into the live root, target root, and early initramfs. The
AudioReach topology is stored under the exact model-specific filename that
the X1P42100 sound driver requests; its contents come from the redistributable
Surface Pro 12in topology in linux-firmware. CI therefore builds the
battery-capable, audio-enabled DSP DTB without an additional URL or manual
input. The build verifies the initramfs that archiso places at
`arch/boot/aarch64/initramfs-linux.img`, not only the copy in the live root.

The WCN7850 and regulatory blobs are also embedded into the Arch kernel with
`CONFIG_EXTRA_FIRMWARE`. The device's built-in ath12k/MHI probe can run before
the live root's filesystem firmware path is usable, so the initramfs copy is
kept as a second source and the kernel copy is the early-boot source.

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
  GPU_FIRMWARE_SOURCE=/path/to/surface-laptop13-gpu-reference.tar.gz \
  ./archlinux/build-iso.sh
```

On Arch Linux ARM, install the equivalent packages with `pacman` instead.

The default scratch path is under `/tmp` (or `$RUNNER_TEMP` in Actions). The
Arch Linux ARM rootfs download alone is roughly 800 MiB compressed, and the
kernel and archiso work trees need additional free space.

`WCN7850_FIRMWARE_SOURCE` also accepts an extracted `hw2.0` directory. Validate
it independently with `python3 archlinux/prepare-wifi-firmware.py PATH`.
`GPU_FIRMWARE_SOURCE` accepts the checked-in GPU archive or an extracted
directory containing its `qcom/` tree; validate it independently with
`python3 archlinux/prepare-gpu-firmware.py PATH`.
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

By default, the ISO contains two menu entries: the default touchscreen/USB
entry and a Bluetooth-enabled entry. Both use the main-branch DSP-enabled EL1
DTB with ADSP and CDSP active for PMIC GLINK battery/charger communication.
The committed DSP/audio firmware is included in the live root, early initramfs,
and installed target. Wi-Fi uses the reference set above; Bluetooth uses
downloaded QCA firmware. The output is an unsigned development image; disable
Secure Boot before booting it.

The live profile includes an ALSA UCM2 card-name mapping and a machine-specific
profile for this exact Surface model. The profile initializes the AudioReach
playback gain, both WSA884x speaker amplifiers, and the VA DMIC routes; the
`surface-audio-init.service` reapplies those controls after the ALSA/SoundWire
devices appear. The base `alsa-ucm-conf`, `alsa-utils`, mapping, profile, and
service are copied into the target root during archinstall as well. The new
DMIC regulator, pinctrl, and 2.4 MHz clock settings are validated in every
DTB variant produced by the builder.

The ISO is a live environment, not an unattended disk installer. Log in as
`root` at the console and use the included `archinstall` command. The live
environment leaves NetworkManager stopped until the Wi-Fi menu needs it. The
image patches archinstall's Wi-Fi handler to start NetworkManager and connect
with `nmcli`, which avoids the `wpa_supplicant` connection race on the WCN7850.
NetworkManager remains installed for the target system.

The live image also prepares the Arch Linux ARM PGP keyring. Because archinstall
uses `pacstrap -K`, the image's `pacstrap` wrapper initializes each new target
with the official ARM keyring and locally trusts the official build key before
the first package is downloaded. The installed system therefore remains on
`SigLevel = Required DatabaseOptional` for both installation and later
`pacman -Syu`; package signature checks are not disabled.

The battery- and audio-capable DTB and firmware are the default. The
committed tree is:

```text
archlinux/firmware-tree/
```

It contains the four remoteproc files:

```text
qcom/x1p42100/Microsoft/Surface12/qcadsp8380.mbn
qcom/x1p42100/Microsoft/Surface12/adsp_dtbs.elf
qcom/x1p42100/Microsoft/Surface12/qccdsp8380.mbn
qcom/x1p42100/Microsoft/Surface12/cdsp_dtbs.elf
```

and the AudioReach topology:

```text
qcom/x1e80100/X1P42100-Microsoft-Surface-Laptop-13-tplg.bin
```

For a local build using another extracted tree, set
`DSP_FIRMWARE_SOURCE=/path/to/firmware-tree`; CI uses the committed tree
automatically. The builder validates all five files against the recorded
sizes and SHA-256 hashes before generating the image.

The image also enables `surface-wifi-reprobe.service`. It retries the WCN7850
PCI probe after the live root and its firmware are available, covering boots
where the built-in `ath12k` driver probes too early during initramfs startup.
The laptop exposes TPM firmware tables but no `/dev/tpm0` or `/dev/tpmrm0`
device. The live root and the installed target mask `tpm2.target` for this
hardware, avoiding systemd's 90-second wait for nonexistent TPM device nodes.

Arch Linux ARM installs its kernel preset as `linux-aarch64.preset`, whereas
archinstall's default `linux` entry expects `linux.preset` when UKI boot is
selected. The live `pacstrap` wrapper creates that compatibility preset after
the kernel package is installed, preserving the ARM kernel version and
initramfs settings while adding the UKI output entries expected by archinstall.

## Installed kernel

The ISO also carries a local `linux-surface-laptop-13` package. It contains
the same Surface kernel image and modules used by the live environment, the
Bluetooth-, battery-, and audio-enabled Surface DTB, and a mkinitcpio preset for a Surface
UKI. The live ISO exposes only the Bluetooth + battery communication GRUB
entry, and the same DTB is installed into the target system. The live
archinstall package is patched at image-build time so `Kernels` includes
`linux-surface-laptop-13` and selects it by default. The pacstrap wrapper
copies and checksum-verifies the validated GPU, Wi-Fi, Bluetooth, ADSP/CDSP,
and AudioReach firmware into the new root *before* installing the bundled
local kernel package. Its mkinitcpio settings therefore include the required Surface
firmware in the first installed initramfs.

When systemd-boot UKI mode is selected, archinstall generates
`arch-linux-surface-laptop-13.efi` with `/boot/surface-laptop-13.dtb` embedded
through `/etc/kernel/uki.conf`. The installed system therefore boots the
Surface kernel rather than falling back to the generic Arch Linux ARM kernel.
