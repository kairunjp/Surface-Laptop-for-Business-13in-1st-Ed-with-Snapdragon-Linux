#!/usr/bin/env bash
set -Eeuo pipefail

surface_root=/usr/lib/surface-laptop-13
surface_image="$surface_root/Image"
[[ -f "$surface_image" ]] || {
    printf 'missing Surface kernel: %s\n' "$surface_image" >&2
    exit 1
}

# A base package may provide its own ARM kernel.  Keep only the kernel and
# initramfs generated from the matching Surface module tree in the ISO boot
# directory.
rm -f /boot/vmlinuz-linux /boot/initramfs-*.img
install -D -m 0644 "$surface_image" /boot/vmlinuz-linux
find /boot -maxdepth 1 -type f -name 'vmlinuz-*' ! -name 'vmlinuz-linux' -delete

surface_release=
for module_dir in /usr/lib/modules/*surface-laptop-13; do
    if [[ -d "$module_dir" ]]; then
        surface_release=${module_dir##*/}
        break
    fi
done
[[ -n "$surface_release" ]] || {
    printf 'Surface kernel module tree is missing\n' >&2
    exit 1
}

for firmware in amss.bin m3.bin board.bin board-2.bin; do
    if [[ ! -s "/lib/firmware/ath12k/WCN7850/hw2.0/$firmware" ]]; then
        printf 'missing WCN7850 firmware: %s\n' "$firmware" >&2
        exit 1
    fi
done

# Detect package installation replacing any part of the reference set before
# mkinitcpio copies it into the boot image.
(
    cd /lib/firmware/ath12k/WCN7850/hw2.0
    sha256sum -c "$surface_root/wifi-sha256sums"
)

depmod -a "$surface_release"
mkinitcpio \
    -c /etc/mkinitcpio.conf.d/archiso.conf \
    -k "$surface_release" \
    -g /boot/initramfs-linux.img

# The built-in ath12k driver can probe before the compressed main CPIO is
# available on this platform.  Keep the WCN7850 reference set in the early
# uncompressed CPIO and fail the image build if any file is missing there.
for firmware in \
    ath12k/WCN7850/hw2.0/amss.bin \
    ath12k/WCN7850/hw2.0/m3.bin \
    ath12k/WCN7850/hw2.0/board.bin \
    ath12k/WCN7850/hw2.0/board-2.bin \
    regulatory.db regulatory.db.p7s; do
    if ! lsinitcpio --early /boot/initramfs-linux.img | grep -Fq \
        "usr/lib/firmware/$firmware"; then
        printf 'Required Wi-Fi firmware is not in the early initramfs: %s\n' "$firmware" >&2
        exit 1
    fi
done

# Leave NetworkManager stopped in the live environment.  archinstall owns
# wpa_supplicant while its Wi-Fi menu scans for networks; starting
# NetworkManager here makes its wpa_cli scan fail with FAIL-BUSY.  The
# NetworkManager package remains available for the installed system.
systemctl enable surface-wifi-reprobe.service
