#!/usr/bin/env python3
"""Check real extraction without cpio -d (the kernel does not create parents)."""
import importlib.util
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "augment", pathlib.Path(__file__).with_name("augment-newc-initramfs.py"))
augment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(augment)


class ParentEntriesTest(unittest.TestCase):
    def test_missing_and_late_parents(self):
        target = "lib/modules/test/kernel/drivers/md/persistent-data/dm-persistent-data.ko"
        entries = [(target, augment.newc_entry(target.encode(), b"module", stat.S_IFREG | 0o644, 1)),
                   ("lib", augment.newc_entry(b"lib", b"", stat.S_IFDIR | 0o750, 2))]
        trailer = augment.newc_entry(b"TRAILER!!!", b"", 0, 3)
        with tempfile.TemporaryDirectory() as directory:
            broken = subprocess.run(["cpio", "-i", "--quiet"], cwd=directory,
                                    input=b"".join(raw for _, raw in entries) + trailer,
                                    capture_output=True)
            self.assertNotEqual(broken.returncode, 0)
            self.assertFalse((pathlib.Path(directory) / target).exists())
        fixed = augment.ensure_parent_entries(entries)
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(["cpio", "-i", "--quiet"], cwd=directory,
                           input=b"".join(raw for _, raw in fixed) + trailer,
                           capture_output=True, check=True)
            self.assertEqual((pathlib.Path(directory) / target).read_bytes(), b"module")
            self.assertEqual(stat.S_IMODE((pathlib.Path(directory) / "lib").stat().st_mode), 0o750)
        self.assertEqual(fixed, augment.ensure_parent_entries(fixed))


if __name__ == "__main__":
    unittest.main()
