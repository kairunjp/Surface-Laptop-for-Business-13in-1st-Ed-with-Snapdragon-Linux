#!/usr/bin/env bash
# shellcheck disable=SC2034

# This profile is assembled on an AArch64 Arch Linux ARM build host.  The
# upstream archiso baseline remains the source for the bootable ISO layout;
# this profile supplies the Surface-specific kernel, DTB, firmware, and live
# userspace additions.
arch="aarch64"
iso_name="surface-archlinux"
iso_label="SURFACE_ARCH"
iso_publisher="Surface Laptop 13 Linux"
iso_application="Surface Laptop 13 Arch Linux ARM64"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('uefi.grub')
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=(-comp zstd -Xcompression-level 19)
file_permissions=(
  ["/etc/shadow"]="0:0:400"
)
