#!/usr/bin/env bash
set -Eeuo pipefail

surface_root=/usr/lib/surface-laptop-13
surface_image="$surface_root/Image"
surface_kernel_package=$(find "$surface_root" -maxdepth 1 -type f \
    -name 'linux-surface-laptop-13-*.pkg.tar.*' ! -name '*.sig' -print -quit)
archlinuxarm_build_key=68B3537F39A313B3E574D06777193F152BDBE6A6
[[ -f "$surface_image" ]] || {
    printf 'missing Surface kernel: %s\n' "$surface_image" >&2
    exit 1
}
[[ -n "$surface_kernel_package" && -f "$surface_kernel_package" ]] || {
    printf 'missing target Surface kernel package in %s\n' "$surface_root" >&2
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

patch_archinstall_kernel_menu() {
    local package_types
    package_types=$(find /usr/lib -type f \
        -path '*/site-packages/archinstall/lib/models/package_types.py' \
        -print -quit)
    [[ -n "$package_types" && -f "$package_types" ]] || {
        printf 'archinstall package type definitions are missing\n' >&2
        return 1
    }

    # archinstall gets its kernel choices from this enum. Patch the installed
    # package after pacman has installed it so the custom local package is
    # visible in the Kernels menu and selected by default.
    python3 - "$package_types" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
enum_entry = "SURFACE = 'linux-surface-laptop-13'"
if enum_entry not in text:
    marker = 'class Kernel(StrEnum):\n'
    match = re.search(r'^class Kernel\(StrEnum\):\n([ \t]+)\w+', text, re.MULTILINE)
    if marker not in text or not match:
        raise SystemExit('Kernel enum was not found')
    indent = match.group(1)
    text = text.replace(marker, marker + indent + enum_entry + '\n', 1)

text, replacements = re.subn(
    r'(DEFAULT_KERNEL(?:\s*:\s*[^=]+)?\s*=\s*)Kernel\.\w+',
    r'\1Kernel.SURFACE',
    text,
    count=1,
)
if replacements != 1:
    raise SystemExit('DEFAULT_KERNEL was not found')

compile(text, str(path), 'exec')
path.write_text(text)
PY
    python3 -m py_compile "$package_types"
    grep -Fq "SURFACE = 'linux-surface-laptop-13'" "$package_types"
    grep -Eq 'DEFAULT_KERNEL([^=]|[[:space:]])*=[[:space:]]*Kernel\.SURFACE' "$package_types"
}

patch_archinstall_kernel_menu

# Arch Linux ARM's package signing key is officially shipped by
# archlinuxarm-keyring, but its old certifications can remain at unknown or
# marginal trust with current GnuPG. Keep signature verification enabled and
# locally sign only the imported official build key. This keyring is used by
# both live pacman and the pacstrap wrapper below.
install -d -m 700 /etc/pacman.d/gnupg
pacman-key --init
if ! grep -Fqx allow-weak-key-signatures /etc/pacman.d/gnupg/gpg.conf 2>/dev/null; then
    printf '%s\n' allow-weak-key-signatures >> /etc/pacman.d/gnupg/gpg.conf
fi
pacman-key --populate archlinuxarm
pacman-key --lsign-key "$archlinuxarm_build_key"

# archinstall invokes pacstrap with -K, which intentionally creates an empty
# target keyring. That is correct for a normal Arch ISO but leaves the Arch
# Linux ARM build key untrusted before archlinuxarm-keyring can be installed.
# Seed a fresh target keyring with the official ARM keys before the real
# pacstrap starts; package signatures remain Required throughout installation.
pacstrap_real="$surface_root/pacstrap.real"
if [[ -x /usr/bin/pacstrap && ! -e "$pacstrap_real" ]]; then
    mv /usr/bin/pacstrap "$pacstrap_real"
fi
[[ -x "$pacstrap_real" ]] || {
    printf 'missing pacstrap implementation: %s\n' "$pacstrap_real" >&2
    exit 1
}
install -D -m 0755 /usr/local/libexec/archlinuxarm-pacstrap \
    /usr/bin/pacstrap

# Leave NetworkManager stopped in the live environment.  archinstall owns
# wpa_supplicant while its Wi-Fi menu scans for networks; starting
# NetworkManager here makes its wpa_cli scan fail with FAIL-BUSY.  The
# NetworkManager package remains available for the installed system.
systemctl enable surface-wifi-reprobe.service
