#!/usr/bin/env python3
"""Test late and missing Wi-Fi hardware without touching host networking."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).with_name('surface-wifi-start.sh').read_text()


class StartupTest(unittest.TestCase):
    def run_startup(self, appearance):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bindir = root / 'bin'
            bindir.mkdir()
            (root / 'net').mkdir()
            mock = bindir / 'mock'
            mock.write_text('''#!/bin/sh
case "${0##*/}" in
 NetworkManager) touch "$TEST_ROOT/manager" ;;
 pidof) [ "$1" = dbus-daemon ] ;;
 nmcli) test -e "$TEST_ROOT/manager" ;;
 sleep)
   n=0
   [ ! -f "$TEST_ROOT/ticks" ] || read -r n < "$TEST_ROOT/ticks"
   n=$((n + 1))
   echo "$n" > "$TEST_ROOT/ticks"
   if [ "$n" = "$APPEARANCE" ]; then
     mkdir -p "$TEST_ROOT/net/wlan0/wireless"
   fi
   /bin/sleep 0.01
   ;;
 *) echo "diagnostic: ${0##*/}" ;;
esac
''')
            mock.chmod(0o755)
            for name in ('NetworkManager', 'pidof', 'nmcli', 'sleep', 'lspci', 'ip', 'iw', 'dmesg'):
                (bindir / name).symlink_to(mock)
            script = SOURCE.replace('/sys/class/net', str(root / 'net'))
            script = script.replace('/sys/bus/pci', str(root / 'pci'))
            script = script.replace('/lib/firmware', str(root / 'firmware'))
            script = script.replace('/usr/sbin/NetworkManager', str(bindir / 'NetworkManager'))
            script = script.replace('/run/proxmox-installer', str(root / 'diagnostics'))
            script = script.replace('/tmp/surface-', str(root / 'surface-'))
            result = subprocess.run(
                ['/bin/sh', '-c', script], capture_output=True, text=True, timeout=5,
                env={**os.environ, 'PATH': f'{bindir}:/usr/bin:/bin',
                     'TEST_ROOT': str(root), 'APPEARANCE': str(appearance)},
            )
            return result, (root / 'manager').exists(), (root / 'diagnostics/surface-wifi.log').exists()

    def test_late_interface_after_old_ten_second_limit(self):
        result, manager, diagnostics = self.run_startup(15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(manager)
        self.assertFalse(diagnostics)

    def test_absent_hardware_keeps_manager_and_collects_log(self):
        result, manager, diagnostics = self.run_startup(100)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertTrue(manager)
        self.assertTrue(diagnostics)
        self.assertIn('NetworkManager remains running', result.stderr)


class ProbeTest(unittest.TestCase):
    def probe(self, *, bound=False, firmware=True, vendor='0x17cb', device_id='0x1107'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            device = root / 'pci/devices/0004:01:00.0'
            device.mkdir(parents=True)
            (device / 'vendor').write_text(vendor + '\n')
            (device / 'device').write_text(device_id + '\n')
            if bound:
                (device / 'driver').symlink_to(root)
            probe = root / 'pci/drivers_probe'
            probe.write_text('')
            fw = root / 'firmware/ath12k/WCN7850/hw2.0'
            fw.mkdir(parents=True)
            if firmware:
                for name in ('amss.bin', 'm3.bin', 'board-2.bin'):
                    (fw / name).write_bytes(b'firmware')
            script = SOURCE.split('surface_wifi_present || surface_wifi_probe', 1)[0]
            script = script.replace('/sys/bus/pci', str(root / 'pci'))
            script = script.replace('/lib/firmware', str(root / 'firmware'))
            result = subprocess.run(['/bin/sh', '-c', script + '\nsurface_wifi_probe\n'],
                                    capture_output=True, text=True, timeout=5)
            return result.returncode, probe.read_text()

    def test_retries_unbound_wcn7850(self):
        self.assertEqual(self.probe(), (0, '0004:01:00.0\n'))

    def test_leaves_bound_driver_alone(self):
        self.assertEqual(self.probe(bound=True), (0, ''))

    def test_requires_firmware_before_retry(self):
        self.assertEqual(self.probe(firmware=False), (1, ''))

    def test_does_not_probe_other_hardware(self):
        self.assertEqual(self.probe(vendor='0x8086'), (0, ''))
        self.assertEqual(self.probe(device_id='0x1111'), (0, ''))


if __name__ == '__main__':
    unittest.main()
