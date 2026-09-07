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
surface_dm_base="/lib/modules/$(uname -r)/kernel/drivers/md"

load_surface_dm_module() {
    module_name=$1
    module_path=$2

    if grep -qw "$module_name" /proc/modules; then
        return 0
    fi

    echo "surface-initramfs: loading $module_name"
    if [ ! -f "$module_path" ]; then
        debugsh_err_reboot "required Surface LVM module is missing: $module_path"
    fi
    if ! /sbin/modprobe "$module_name"; then
        debugsh_err_reboot "failed to load Surface LVM module: $module_name"
    fi
}

load_surface_dm_module dm_mod "$surface_dm_base/dm-mod.ko"
load_surface_dm_module dm_bio_prison "$surface_dm_base/dm-bio-prison.ko"
load_surface_dm_module dm_bufio "$surface_dm_base/dm-bufio.ko"
load_surface_dm_module dm_persistent_data \
    "$surface_dm_base/persistent-data/dm-persistent-data.ko"
load_surface_dm_module dm_thin_pool "$surface_dm_base/dm-thin-pool.ko"
/sbin/mdev -s

if [ ! -d /sys/module/dm_mod ] || [ ! -d /sys/module/dm_thin_pool ]; then
    debugsh_err_reboot "Surface LVM modules did not remain active"
fi

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
    if text.count("surface_dm_base=") != 1:
        raise SystemExit("Surface LVM loader was not installed exactly once")
    path.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
