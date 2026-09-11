#!/usr/bin/env python3
"""Validate and stage the Surface ADSP/CDSP firmware set."""

import argparse
import hashlib
import json
from pathlib import Path
import tarfile


FILES = (
    "qcom/x1p42100/Microsoft/Surface12/qcadsp8380.mbn",
    "qcom/x1p42100/Microsoft/Surface12/adsp_dtbs.elf",
    "qcom/x1p42100/Microsoft/Surface12/qccdsp8380.mbn",
    "qcom/x1p42100/Microsoft/Surface12/cdsp_dtbs.elf",
)
MANIFEST = Path(__file__).resolve().parents[1] / "drivers/firmware-manifest.json"


def _directory_member(source: Path, name: str) -> Path:
    candidate = source / name
    if candidate.is_file():
        return candidate
    if source.name == "qcom":
        candidate = source / name.removeprefix("qcom/")
        if candidate.is_file():
            return candidate
    raise ValueError(f"firmware file is missing: {name}")


def load_firmware(source: Path):
    expected = json.loads(MANIFEST.read_text())["files"]
    archive = None if source.is_dir() else tarfile.open(source, "r:*")
    result = {}
    try:
        for name in FILES:
            if archive is None:
                path = _directory_member(source, name)
                with path.open("rb") as stream:
                    data = stream.read(expected[name]["bytes"] + 1)
            else:
                matches = [member for member in archive.getmembers() if member.name == name]
                if len(matches) != 1 or not matches[0].isfile():
                    raise ValueError(f"expected one regular archive member: {name}")
                if matches[0].size != expected[name]["bytes"]:
                    raise ValueError(f"unexpected archive member size: {name}")
                stream = archive.extractfile(matches[0])
                if stream is None:
                    raise ValueError(f"cannot read archive member: {name}")
                with stream:
                    data = stream.read(expected[name]["bytes"] + 1)
            digest = hashlib.sha256(data).hexdigest()
            if (len(data) != expected[name]["bytes"] or
                    digest != expected[name]["sha256"]):
                raise ValueError(f"{name}: checksum or size mismatch ({digest})")
            result[name] = data
    finally:
        if archive is not None:
            archive.close()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="firmware tree or tar archive")
    parser.add_argument("--output", type=Path, help="stage the files after validation")
    args = parser.parse_args()
    try:
        files = load_firmware(args.source)
        if args.output:
            for name, data in files.items():
                destination = args.output / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
                destination.chmod(0o644)
        for name, data in files.items():
            print(f"{hashlib.sha256(data).hexdigest()}  {name}")
    except (OSError, ValueError, tarfile.TarError) as error:
        parser.exit(1, f"DSP firmware validation failed: {error}\n")


if __name__ == "__main__":
    main()
