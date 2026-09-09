#!/usr/bin/env python3
"""Exercise the supervisor's background launch with a real pseudo terminal."""

import fcntl
import os
from pathlib import Path
import pty
import struct
import subprocess
import tempfile
import termios
import unittest


SOURCE = Path(__file__).with_name("surface-installer-init.sh").read_text()


class ConsoleTest(unittest.TestCase):
    def launch(self, source, cmdline):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            master, slave = pty.openpty()
            try:
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
                for name in ("tty1", "ttyS0"):
                    (root / name).symlink_to(os.ttyname(slave))
                (root / "cmdline").write_text(cmdline)
                # Only replace the unavailable ARM64 BusyBox and filesystem
                # paths; retain the actual background job and setsid logic.
                bb = root / "busybox"
                bb.write_text('#!/bin/sh\nexec "$@"\n')
                bb.chmod(0o755)
                probe = root / "probe"
                result = root / "result"
                probe.write_text(
                    '#!/bin/sh\n'
                    'stty size || exit 31\n'
                    'test -t 0 && test -t 1 && test -t 2 || exit 32\n'
                    'test -r /dev/tty && stty size </dev/tty || exit 33\n'
                    f'printf "console-ok" > "{result}"\n'
                    'exit 17\n'
                )
                probe.chmod(0o755)
                script = source.split('echo "surface-init: installer exited', 1)[0]
                script = script.replace('/surface-installer/busybox', str(bb))
                script = script.replace('/sbin/unconfigured.sh', str(probe))
                script = script.replace('/proc/cmdline', str(root / "cmdline"))
                script = script.replace('/dev/', str(root) + '/')
                script = script.replace('mkdir -p /run', f'mkdir -p "{root}/run"')
                script += '\nexit "$status"\n'
                completed = subprocess.run(
                    ["/bin/sh", "-c", script], stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5,
                )
                return completed.returncode, result.exists()
            finally:
                os.close(master)
                os.close(slave)

    def test_default_console_and_exit_status(self):
        self.assertEqual(self.launch(SOURCE, "quiet"), (17, True))

    def test_serial_console_with_options(self):
        self.assertEqual(self.launch(SOURCE, "console=tty0 console=ttyS0,115200n8"), (17, True))

    def test_old_background_launch_reproduces_stty_failure(self):
        old = SOURCE.replace(
            '''"$bb" setsid "$bb" sh -c 'exec /sbin/unconfigured.sh <"$1" >"$1" 2>&1' sh "$console" &''',
            '''"$bb" setsid /sbin/unconfigured.sh &''',
        )
        self.assertNotEqual(old, SOURCE)
        self.assertEqual(self.launch(old, "quiet"), (31, False))


if __name__ == "__main__":
    unittest.main()
