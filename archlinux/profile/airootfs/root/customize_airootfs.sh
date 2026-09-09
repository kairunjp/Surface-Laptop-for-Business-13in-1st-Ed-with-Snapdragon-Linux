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

depmod -a "$surface_release"
mkinitcpio \
    -c /etc/mkinitcpio.conf.d/archiso.conf \
    -k "$surface_release" \
    -g /boot/initramfs-linux.img

systemctl enable NetworkManager.service
