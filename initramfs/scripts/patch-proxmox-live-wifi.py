#!/usr/bin/env python3
"""Start Surface NetworkManager after Proxmox initializes udev and D-Bus."""

from __future__ import annotations

import pathlib
import sys


ORIGINAL = """    if [ $proxdebug -ne 0 ]; then # FIXME: better integration, e.g., use iwgtk?
        handle_wireless # no-op if not wireless dev is found
    fi
"""

PATCHED = """    if [ -x /usr/local/sbin/surface-wifi-start ]; then
        echo "starting Surface Wi-Fi and NetworkManager"
        /usr/local/sbin/surface-wifi-start || echo "Surface Wi-Fi startup failed ($?)"
    fi

    if [ $proxdebug -ne 0 ] && ! pidof NetworkManager >/dev/null 2>&1; then
        handle_wireless # fallback for an installer image which only carries iwd
    fi
"""


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} UNCONFIGURED-SCRIPT")

    path = pathlib.Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")
    if "Starting Proxmox installation" not in text:
        raise SystemExit(f"not a Proxmox unconfigured.sh: {path}")

    if text.count(ORIGINAL) == 1:
        text = text.replace(ORIGINAL, PATCHED, 1)
    elif text.count(PATCHED) != 1:
        raise SystemExit("cannot safely patch Proxmox live Wi-Fi startup")

    if text.count('echo "starting Surface Wi-Fi and NetworkManager"') != 1:
        raise SystemExit("Surface live Wi-Fi startup was not installed exactly once")
    path.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
