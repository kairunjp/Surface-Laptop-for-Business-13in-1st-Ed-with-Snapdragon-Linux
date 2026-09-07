#!/usr/bin/env python3
"""Replace/add regular files in a gzip-compressed newc initramfs."""

from __future__ import annotations

import gzip
import os
import stat
import sys
import time


def align4(value: int) -> int:
    return (value + 3) & ~3


def newc_entry(name: bytes, payload: bytes, mode: int, ino: int) -> bytes:
    namesize = len(name) + 1
    header = (
        b"070701"
        + f"{ino:08x}".encode()
        + f"{mode:08x}".encode()
        + f"{0:08x}".encode()
        + f"{0:08x}".encode()
        + f"{1:08x}".encode()
        + f"{int(time.time()):08x}".encode()
        + f"{len(payload):08x}".encode()
        + f"{0:08x}".encode()
        + f"{0:08x}".encode()
        + f"{0:08x}".encode()
        + f"{0:08x}".encode()
        + f"{namesize:08x}".encode()
        + f"{0:08x}".encode()
    )
    assert len(header) == 110
    name_block = name + b"\0" + b"\0" * (align4(110 + namesize) - 110 - namesize)
    data_block = payload + b"\0" * (align4(len(payload)) - len(payload))
    return header + name_block + data_block


def parse_entries(cpio: bytes) -> tuple[list[tuple[str, bytes]], bytes]:
    entries: list[tuple[str, bytes]] = []
    offset = 0
    while offset + 110 <= len(cpio):
        header = cpio[offset : offset + 110]
        if header[:6] not in (b"070701", b"070702"):
            raise ValueError(f"invalid newc header at offset {offset}")
        filesize = int(header[54:62], 16)
        namesize = int(header[94:102], 16)
        name_start = offset + 110
        name_end = name_start + namesize
        name = cpio[name_start:name_end].rstrip(b"\0").decode("utf-8", "surrogateescape")
        data_start = align4(name_end)
        next_offset = data_start + align4(filesize)
        raw = cpio[offset:next_offset]
        if name == "TRAILER!!!":
            return entries, raw
        entries.append((name, raw))
        offset = next_offset
    raise ValueError("newc trailer not found")


def read_manifest(path: str) -> dict[str, tuple[bytes, int]]:
    replacements: dict[str, tuple[bytes, int]] = {}
    with open(path, encoding="utf-8") as manifest:
        for line_number, line in enumerate(manifest, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split()
            if len(fields) not in (2, 3):
                raise ValueError(f"manifest line {line_number}: expected DEST SOURCE [MODE]")
            destination, source = fields[:2]
            if destination.startswith("/") or ".." in destination.split("/"):
                raise ValueError(f"unsafe destination: {destination}")
            mode = int(fields[2], 8) if len(fields) == 3 else stat.S_IMODE(os.stat(source).st_mode)
            replacements[destination] = (open(source, "rb").read(), stat.S_IFREG | mode)
    return replacements


def ensure_parent_entries(entries: list[tuple[str, bytes]]) -> list[tuple[str, bytes]]:
    """Emit parents before children, including files already in a broken input.

    The kernel unpacker does not implement mkdir -p. Archive listing and
    cpio --to-stdout cannot detect files which it will silently fail to create.
    Preserve explicit directory metadata and existing symlinks (e.g. usrmerge).
    """
    explicit = {os.path.normpath(name): (name, raw) for name, raw in entries}
    emitted: set[str] = {"."}
    result: list[tuple[str, bytes]] = []
    ino = max((int(raw[6:14], 16) for _, raw in entries), default=0) + 1

    def parent(name: str) -> None:
        nonlocal ino
        if name in emitted:
            return
        parent(os.path.dirname(name) or ".")
        if name in explicit:
            entry = explicit[name]
            mode = int(entry[1][14:22], 16)
            if not (stat.S_ISDIR(mode) or stat.S_ISLNK(mode)):
                raise ValueError(f"archive parent is not a directory or symlink: {name}")
        else:
            entry = (name, newc_entry(name.encode(), b"", stat.S_IFDIR | 0o755, ino))
            ino += 1
        result.append(entry)
        emitted.add(name)

    for name, raw in entries:
        normalized = os.path.normpath(name)
        if normalized.startswith("/") or ".." in normalized.split("/"):
            raise ValueError(f"unsafe archive path: {name}")
        parent(os.path.dirname(normalized) or ".")
        if normalized not in emitted or normalized == ".":
            result.append((name, raw))
            emitted.add(normalized)
    return result


def main() -> None:
    raw = len(sys.argv) == 5 and sys.argv[1] == "--raw"
    args = sys.argv[2:] if raw else sys.argv[1:]
    if len(args) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} [--raw] INPUT OUTPUT MANIFEST")
    source, target, manifest = args
    source_data = open(source, "rb").read()
    entries, trailer = parse_entries(source_data if raw else gzip.decompress(source_data))
    replacements = read_manifest(manifest)
    kept = [(name, raw) for name, raw in entries if name not in replacements]
    ino = len(kept) + 1
    additions = [
        (name, newc_entry(name.encode("utf-8", "surrogateescape"), payload, mode, ino + i))
        for i, (name, (payload, mode)) in enumerate(replacements.items())
    ]
    archive = b"".join(raw_entry for _, raw_entry in ensure_parent_entries(kept + additions)) + trailer
    packed = archive if raw else gzip.compress(archive, compresslevel=9, mtime=0)
    os.makedirs(os.path.dirname(os.path.abspath(target)), exist_ok=True)
    with open(target, "xb") as output:
        output.write(packed)
    os.chmod(target, 0o644)


if __name__ == "__main__":
    main()
