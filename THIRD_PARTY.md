# Third-party materials

The Linux kernel is GPL-2.0-only. Device-tree bindings and upstream patches
retain their original licenses and notices.

The Qualcomm WCN7850 Wi-Fi reference set in
`build/archlinux-reference/surface-pve-wifi-reference.tar.gz` is copied from
the working `surface-pve` boot image and is included to make the Arch Linux CI
image reproducible. Its hashes are recorded in
`drivers/firmware-manifest.json`; the archive includes Qualcomm's `Notice.txt`.
The Qualcomm Adreno reference set in
`build/archlinux-reference/surface-pve-gpu-reference.tar.gz` is copied from
the same machine's firmware installation. Its hashes are recorded in
`drivers/firmware-manifest.json` and it includes the Surface-specific signed
KMS firmware required by the Adreno driver. Check the vendor terms before
redistribution.
Bluetooth firmware is fetched separately from the pinned linux-firmware
revision. Check the vendor terms before redistribution.
