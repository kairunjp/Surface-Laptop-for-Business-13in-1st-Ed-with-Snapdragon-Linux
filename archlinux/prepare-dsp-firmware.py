#!/usr/bin/env python3
"""Validate and stage the private Surface ADSP/CDSP firmware set."""

import argparse
from pathlib import Path
import tarfile


FILES = (
    "qcom/x1p42100/Microsoft/Surface12/qcadsp8380.mbn",
    "qcom/x1p42100/Microsoft/Surface12/adsp_dtbs.elf",
    "qcom/x1p42100/Microsoft/Surface12/qccdsp8380.mbn",
    "qcom/x1p42100/Microsoft/Surface12/cdsp_dtbs.elf",
)


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
    archive = None if source.is_dir() else tarfile.open(source, "r:*")
    result = {}
    try:
        for name in FILES:
            if archive is None:
                path = _directory_member(source, name)
                data = path.read_bytes()
            else:
                matches = [member for member in archive.getmembers() if member.name == name]
                if len(matches) != 1 or not matches[0].isfile():
                    raise ValueError(f"expected one regular archive member: {name}")
                stream = archive.extractfile(matches[0])
                if stream is None:
                    raise ValueError(f"cannot read archive member: {name}")
                with stream:
                    data = stream.read()
            if not data:
                raise ValueError(f"firmware file is empty: {name}")
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
            print(f"{len(data)} bytes  {name}")
    except (OSError, ValueError, tarfile.TarError) as error:
        parser.exit(1, f"DSP firmware validation failed: {error}\n")


if __name__ == "__main__":
    main()
