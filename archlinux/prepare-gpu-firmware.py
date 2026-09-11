#!/usr/bin/env python3
"""Validate and stage the Surface Adreno X1P42100 firmware set."""

import argparse
import hashlib
import json
from pathlib import Path
import tarfile


REFERENCES = (
    ("qcom/gen71500_sqe.fw", "qcom/gen71500_sqe.fw"),
    ("qcom/gen71500_gmu.bin", "qcom/gen71500_gmu.bin"),
    # The redistributable X1P zap blob is stored at the generic qcom root in
    # the reference archive, but the upstream X1P DT binding requests it from
    # the qcom/x1p42100 directory.
    ("qcom/gen71500_zap.mbn", "qcom/x1p42100/gen71500_zap.mbn"),
)
MANIFEST = Path(__file__).resolve().parents[1] / "drivers/firmware-manifest.json"


def _directory_member(source: Path, name: str) -> Path:
    """Resolve either a tree containing qcom/ or the qcom/ directory itself."""

    candidate = source / name
    if candidate.is_file():
        return candidate
    if source.name == "qcom":
        candidate = source / name.removeprefix("qcom/")
        if candidate.is_file():
            return candidate
    raise ValueError(f"firmware file is missing: {name}")


def load_reference(source: Path):
    expected = json.loads(MANIFEST.read_text())["files"]
    result = {}
    archive = None if source.is_dir() else tarfile.open(source, "r:*")
    try:
        for source_name, staged_name in REFERENCES:
            entry = expected[source_name]
            if archive is None:
                with _directory_member(source, source_name).open("rb") as stream:
                    data = stream.read(entry["bytes"] + 1)
            else:
                matches = [member for member in archive.getmembers() if member.name == source_name]
                if len(matches) != 1 or not matches[0].isfile():
                    raise ValueError(f"expected one regular archive member: {source_name}")
                if matches[0].size != entry["bytes"]:
                    raise ValueError(f"unexpected archive member size: {source_name}")
                with archive.extractfile(matches[0]) as stream:
                    data = stream.read(entry["bytes"] + 1)
            digest = hashlib.sha256(data).hexdigest()
            if len(data) != entry["bytes"] or digest != entry["sha256"]:
                raise ValueError(f"{source_name}: does not match the validated X1P firmware ({digest})")
            result[staged_name] = data
    finally:
        if archive is not None:
            archive.close()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="firmware tree or tar archive")
    parser.add_argument("--output", type=Path, help="stage only after all files pass validation")
    args = parser.parse_args()
    try:
        files = load_reference(args.source)
        if args.output:
            for name, data in files.items():
                destination = args.output / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
                destination.chmod(0o644)
        for name, data in files.items():
            print(f"{hashlib.sha256(data).hexdigest()}  {name}")
    except (OSError, ValueError, tarfile.TarError) as error:
        parser.exit(1, f"GPU firmware validation failed: {error}\n")


if __name__ == "__main__":
    main()
