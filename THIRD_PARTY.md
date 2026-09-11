# Third-party materials

The Linux kernel is GPL-2.0-only. Device-tree bindings and upstream patches
retain their original licenses and notices.

The Qualcomm WCN7850 Wi-Fi reference set in
`build/archlinux-reference/surface-pve-wifi-reference.tar.gz` is copied from
the working `surface-pve` boot image and is included to make the Arch Linux CI
image reproducible. Its hashes are recorded in
`drivers/firmware-manifest.json`; the archive includes Qualcomm's `Notice.txt`.
The Qualcomm Adreno reference set in
`build/archlinux-reference/surface-laptop13-gpu-reference.tar.gz` contains the
X1P firmware files used by the Adreno driver. The Surface Laptop 13-specific
`qcdxkmsucpurwa.mbn` was extracted from Microsoft's official
`SurfaceLaptop_13in_1st_Edition_Win11_26100_26.080.5528.0.msi`; the other two
files originate from linux-firmware. Their hashes are recorded in
`drivers/firmware-manifest.json`. Check the vendor terms before redistribution.
Bluetooth firmware is fetched separately from the pinned linux-firmware
revision. Check the vendor terms before redistribution.
