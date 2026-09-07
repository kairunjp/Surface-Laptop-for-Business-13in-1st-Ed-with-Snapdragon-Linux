#!/usr/bin/env python3
"""Add or repair early Surface device-mapper loading in a Proxmox ISO init."""

from __future__ import annotations

import pathlib
import sys


LVM_BLOCK = r'''# The installer switches from this initramfs to the stock Proxmox SquashFS.
# That filesystem only carries modules for its stock kernel, so modules for
# the Surface kernel must be loaded before switch_root.  LVM can create a PV
# and VG without device-mapper, but its first lvcreate (normally the swap LV)
# fails unless dm_mod is already active.  Preload the complete thin-pool stack
# as well, because the installer creates pve/data later in the same run.
load_surface_dm_module() {
    module_name=$1

    if grep -qw "$module_name" /proc/modules; then
        return 0
    fi

    echo "surface-initramfs: loading $module_name"
    if ! /sbin/modprobe "$module_name"; then
        dmesg | tail -60
        debugsh_err_reboot "failed to load Surface LVM module: $module_name"
    fi
}

# dm_thin_pool pulls in bio-prison, bufio and persistent-data according to the
# kernel's modules.dep.  Let modprobe resolve their installed paths instead of
# duplicating those paths here. The archive builder must include their parent
# directories so the kernel can actually unpack the module files.
load_surface_dm_module dm_mod
load_surface_dm_module dm_thin_pool
/sbin/mdev -s

for module_name in \
    dm_mod dm_bio_prison dm_bufio dm_persistent_data dm_thin_pool; do
    if [ ! -d "/sys/module/$module_name" ]; then
        debugsh_err_reboot "Surface LVM module did not remain active: $module_name"
    fi
done

'''

START_MARKER = "# The installer switches from this initramfs to the stock Proxmox SquashFS."
END_MARKER = '# we have no iscsi daemon, so we need to scan iscsi device manually.'


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} PROXMOX-INIT")

    path = pathlib.Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")
    if "Proxmox Server Solutions" not in text:
        raise SystemExit(f"not a Proxmox installer init: {path}")

    if START_MARKER in text:
        start = text.index(START_MARKER)
        try:
            end = text.index(END_MARKER, start)
        except ValueError as error:
            raise SystemExit("existing Surface LVM block has no safe end marker") from error
        text = text[:start] + LVM_BLOCK + text[end:]
    else:
        try:
            insertion = text.index(END_MARKER)
        except ValueError as error:
            raise SystemExit("cannot locate Proxmox storage-driver insertion point") from error
        text = text[:insertion] + LVM_BLOCK + text[insertion:]

    if 'insmod "$module_path"' in text:
        raise SystemExit("unsafe direct insmod remains in Surface LVM loader")
    if "surface_dm_base=" in text or 'module_path=$2' in text:
        raise SystemExit("fixed Surface LVM module path remains in loader")
    if text.count("load_surface_dm_module dm_thin_pool") != 1:
        raise SystemExit("Surface LVM loader was not installed exactly once")
    path.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
