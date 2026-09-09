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
locked in `kernel/source.lock`, and obtains the required WCN7850/BT
firmware files from the pinned linux-firmware revision. The firmware files are
checked against SHA-256 values before they enter the image. The builder also
handles the legacy Arch Linux ARM key certification required by newer GnuPG
versions without disabling package signature verification.

## Local build

The builder must run as root on an AArch64 Linux host because it creates a
chroot and mounts `/dev`, `/proc`, `/sys`, and `/run`. On Debian or Ubuntu,
install the host tools with:

```sh
sudo apt-get install build-essential bc bison cpio device-tree-compiler \
  flex git libarchive-tools libelf-dev libssl-dev openssl patch python3 ripgrep curl xz-utils
sudo ARCHLINUX_BUILD_DIR=/var/tmp/surface-archlinux \
  ARCHLINUX_OUTPUT_DIR="$PWD/build/archlinux" \
  ./archlinux/build-iso.sh
```

On Arch Linux ARM, install the equivalent packages with `pacman` instead.

The default scratch path is under `/tmp` (or `$RUNNER_TEMP` in Actions). The
Arch Linux ARM rootfs download alone is roughly 800 MiB compressed, and the
kernel and archiso work trees need additional free space.

## Boot behavior

The ISO contains two menu entries: the default touchscreen/USB entry and a
Bluetooth-enabled entry. Both use a DTB with ADSP, CDSP, and the sound card
disabled. This is intentional: the Surface DSP/remoteproc firmware is an
external, device-specific input and is not available in this repository. Wi-Fi
and Bluetooth use the WCN7850 firmware downloaded by the builder. The output
is an unsigned development image; disable Secure Boot before booting it.

The ISO is a live environment, not an unattended disk installer. Log in as
`root` at the console and use the normal Arch installation tools or the
included `archinstall` command after bringing up networking with
NetworkManager/iwd.
