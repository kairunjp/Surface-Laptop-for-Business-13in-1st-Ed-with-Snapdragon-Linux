#!/usr/bin/env python3
"""Verify raw USB GPT geometry and bytes against the ISO's extracted efi.img."""
import hashlib
from pathlib import Path
import struct
import sys
import uuid
import zlib


def verify(iso, efi):
    size = iso.stat().st_size
    with iso.open('rb') as stream:
        def read(offset, length):
            stream.seek(offset)
            data = stream.read(length)
            if len(data) != length:
                raise ValueError('Partition table points outside the ISO')
            return data

        def header(lba):
            raw = read(lba * 512, 512)
            if raw[:8] != b'EFI PART':
                raise ValueError(f'GPT header missing at LBA {lba}')
            length, checksum = struct.unpack_from('<II', raw, 12)
            if not 92 <= length <= 512:
                raise ValueError('Invalid GPT header length')
            check = bytearray(raw[:length])
            check[16:20] = bytes(4)
            if zlib.crc32(check) != checksum:
                raise ValueError('GPT header CRC mismatch')
            current, backup, first, last = struct.unpack_from('<QQQQ', raw, 24)
            if current != lba or not first <= last < size // 512:
                raise ValueError('Invalid GPT LBA range')
            table_lba, count, entry_size, crc = struct.unpack_from('<QIII', raw, 72)
            if entry_size < 128 or count * entry_size > 16 * 1024 * 1024:
                raise ValueError('Invalid GPT entry dimensions')
            table = read(table_lba * 512, count * entry_size)
            if zlib.crc32(table) != crc:
                raise ValueError('GPT partition array CRC mismatch')
            return backup, first, last, entry_size, table

        backup, first, last, stride, table = header(1)
        reverse, _, _, _, backup_table = header(backup)
        if reverse != 1 or backup != size // 512 - 1 or backup_table != table:
            raise ValueError('GPT backup does not match current image geometry')
        esp_type = uuid.UUID('c12a7328-f81f-11d2-ba4b-00a0c93ec93b').bytes_le
        entries = [table[i:i + stride] for i in range(0, len(table), stride)]
        esps = [entry for entry in entries if entry[:16] == esp_type]
        if len(esps) != 1:
            raise ValueError(f'Expected one USB ESP, found {len(esps)}')
        start, end = struct.unpack_from('<QQ', esps[0], 32)
        if not first <= start <= end <= last:
            raise ValueError('ESP outside usable GPT range')
        expected = efi.read_bytes()
        if (end - start + 1) * 512 != len(expected):
            raise ValueError('GPT ESP size differs from efi.img')
        actual = read(start * 512, len(expected))
        if actual != expected:
            raise ValueError('GPT ESP bytes differ from efi.img (stale start LBA)')
        print(f'USB GPT verified: ESP LBA={start}, bytes={len(actual)}, '
              f'sha256={hashlib.sha256(actual).hexdigest()}')


if __name__ == '__main__':
    try:
        verify(Path(sys.argv[1]), Path(sys.argv[2]))
    except (ValueError, IndexError) as error:
        sys.exit(f'USB ESP verification failed: {error}')
