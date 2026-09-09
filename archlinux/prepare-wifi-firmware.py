#!/usr/bin/env python3
"""Validate and stage the Wi-Fi set observed in surface-pve's boot initramfs."""

import argparse
import hashlib
import json
from pathlib import Path
import tarfile


NAMES = ("amss.bin", "m3.bin", "board.bin", "board-2.bin", "Notice.txt")
PREFIX = "ath12k/WCN7850/hw2.0/"
MANIFEST = Path(__file__).resolve().parents[1] / "drivers/firmware-manifest.json"


def load_reference(source):
    expected = json.loads(MANIFEST.read_text())["files"]
    result = {}
    archive = None if source.is_dir() else tarfile.open(source, "r:*")
    try:
        for name in NAMES:
            entry = expected[PREFIX + name]
            if archive is None:
                with (source / name).open("rb") as stream:
                    data = stream.read(entry["bytes"] + 1)
            else:
                matches = [m for m in archive.getmembers() if m.name == name]
                if len(matches) != 1 or not matches[0].isfile():
                    raise ValueError(f"expected one regular archive member: {name}")
                if matches[0].size != entry["bytes"]:
                    raise ValueError(f"unexpected archive member size: {name}")
                with archive.extractfile(matches[0]) as stream:
                    data = stream.read(entry["bytes"] + 1)
            digest = hashlib.sha256(data).hexdigest()
            if len(data) != entry["bytes"] or digest != entry["sha256"]:
                raise ValueError(f"{name}: does not match surface-pve boot firmware ({digest})")
            result[name] = data
    finally:
        if archive is not None:
            archive.close()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="hw2.0 directory or tar archive with files at its root")
    parser.add_argument("--output", type=Path, help="stage only after all files pass validation")
    args = parser.parse_args()
    try:
        files = load_reference(args.source)
        if args.output:
            args.output.mkdir(parents=True, exist_ok=True)
            for name, data in files.items():
                (args.output / name).write_bytes(data)
                (args.output / name).chmod(0o644)
        for name, data in files.items():
            print(f"{hashlib.sha256(data).hexdigest()}  {name}")
    except (OSError, ValueError, tarfile.TarError) as error:
        parser.exit(1, f"Wi-Fi reference validation failed: {error}\n")


if __name__ == "__main__":
    main()
