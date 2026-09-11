#!/usr/bin/env bash
set -Eeuo pipefail

surface_root=/usr/lib/surface-laptop-13
surface_image="$surface_root/Image"
surface_kernel_package=$(find "$surface_root" -maxdepth 1 -type f \
    -name 'linux-surface-laptop-13-*.pkg.tar.*' ! -name '*.sig' -print -quit)
archlinuxarm_build_key=68B3537F39A313B3E574D06777193F152BDBE6A6
[[ -f "$surface_image" ]] || {
    printf 'missing Surface kernel: %s\n' "$surface_image" >&2
    exit 1
}
[[ -n "$surface_kernel_package" && -f "$surface_kernel_package" ]] || {
    printf 'missing target Surface kernel package in %s\n' "$surface_root" >&2
    exit 1
}

# A base package may provide its own ARM kernel.  Keep only the kernel and
# initramfs generated from the matching Surface module tree in the ISO boot
# directory.
rm -f /boot/vmlinuz-linux /boot/initramfs-*.img
install -D -m 0644 "$surface_image" /boot/vmlinuz-linux
find /boot -maxdepth 1 -type f -name 'vmlinuz-*' ! -name 'vmlinuz-linux' -delete

surface_release=
for module_dir in /usr/lib/modules/*surface-laptop-13; do
    if [[ -d "$module_dir" ]]; then
        surface_release=${module_dir##*/}
        break
    fi
done
[[ -n "$surface_release" ]] || {
    printf 'Surface kernel module tree is missing\n' >&2
    exit 1
}

for firmware in amss.bin m3.bin board.bin board-2.bin; do
    if [[ ! -s "/lib/firmware/ath12k/WCN7850/hw2.0/$firmware" ]]; then
        printf 'missing WCN7850 firmware: %s\n' "$firmware" >&2
        exit 1
    fi
done

for firmware in \
    qcom/gen71500_sqe.fw \
    qcom/gen71500_gmu.bin \
    qcom/x1p42100/Microsoft/SurfaceLaptop13/qcdxkmsucpurwa.mbn; do
    if [[ ! -s "/lib/firmware/$firmware" ]]; then
        printf 'missing Surface GPU firmware: %s\n' "$firmware" >&2
        exit 1
    fi
done

# Detect package installation replacing any part of the reference set before
# mkinitcpio copies it into the boot image.
(
    cd /lib/firmware/ath12k/WCN7850/hw2.0
    sha256sum -c "$surface_root/wifi-sha256sums"
)

depmod -a "$surface_release"
mkinitcpio \
    -c /etc/mkinitcpio.conf.d/archiso.conf \
    -k "$surface_release" \
    -g /boot/initramfs-linux.img

# The built-in ath12k driver can probe before the compressed main CPIO is
# available on this platform.  Keep the WCN7850 reference set in the early
# uncompressed CPIO and fail the image build if any file is missing there.
for firmware in \
    ath12k/WCN7850/hw2.0/amss.bin \
    ath12k/WCN7850/hw2.0/m3.bin \
    ath12k/WCN7850/hw2.0/board.bin \
    ath12k/WCN7850/hw2.0/board-2.bin \
    regulatory.db regulatory.db.p7s; do
    if ! lsinitcpio --early /boot/initramfs-linux.img | grep -Fq \
        "usr/lib/firmware/$firmware"; then
        printf 'Required Wi-Fi firmware is not in the early initramfs: %s\n' "$firmware" >&2
        exit 1
    fi
done

for firmware in \
    qcom/gen71500_sqe.fw \
    qcom/gen71500_gmu.bin \
    qcom/x1p42100/Microsoft/SurfaceLaptop13/qcdxkmsucpurwa.mbn; do
    if ! lsinitcpio --early /boot/initramfs-linux.img | grep -Fq \
        "usr/lib/firmware/$firmware"; then
        printf 'Required GPU firmware is not in the early initramfs: %s\n' "$firmware" >&2
        exit 1
    fi
done

patch_archinstall_kernel_menu() {
    local package_types
    package_types=$(find /usr/lib -type f \
        -path '*/site-packages/archinstall/lib/models/package_types.py' \
        -print -quit)
    [[ -n "$package_types" && -f "$package_types" ]] || {
        printf 'archinstall package type definitions are missing\n' >&2
        return 1
    }

    # archinstall gets its kernel choices from this enum. Patch the installed
    # package after pacman has installed it so the custom local package is
    # visible in the Kernels menu and selected by default.
    python3 - "$package_types" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
enum_entry = "SURFACE = 'linux-surface-laptop-13'"
if enum_entry not in text:
    marker = 'class Kernel(StrEnum):\n'
    match = re.search(r'^class Kernel\(StrEnum\):\n([ \t]+)\w+', text, re.MULTILINE)
    if marker not in text or not match:
        raise SystemExit('Kernel enum was not found')
    indent = match.group(1)
    text = text.replace(marker, marker + indent + enum_entry + '\n', 1)

text, replacements = re.subn(
    r'(DEFAULT_KERNEL(?:\s*:\s*[^=]+)?\s*=\s*)Kernel\.\w+',
    r'\1Kernel.SURFACE',
    text,
    count=1,
)
if replacements != 1:
    raise SystemExit('DEFAULT_KERNEL was not found')

compile(text, str(path), 'exec')
path.write_text(text)
PY
    python3 -m py_compile "$package_types"
    grep -Fq "SURFACE = 'linux-surface-laptop-13'" "$package_types"
    grep -Eq 'DEFAULT_KERNEL([^=]|[[:space:]])*=[[:space:]]*Kernel\.SURFACE' "$package_types"
}

patch_archinstall_kernel_menu

patch_archinstall_dms_greeter() {
	local profiles_handler
	profiles_handler=$(find /usr/lib -type f \
		-path '*/site-packages/archinstall/lib/profile/profiles_handler.py' \
		-print -quit)
	[[ -n "$profiles_handler" && -f "$profiles_handler" ]] || {
		printf 'archinstall profile handler is missing\n' >&2
		return 1
	}

	# Recent archinstall releases still write the pre-1.6 DMS path from the
	# old Quickshell bundle. The standalone greeter package installed by the
	# pacstrap wrapper exposes /usr/bin/dms-greeter instead.
	python3 - "$profiles_handler" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
new_command = '/usr/bin/dms-greeter --command niri'

text, replacements = re.subn(
    r'command = "[^"\n]*dms-greeter[^"\n]*"',
    f'command = "{new_command}"',
    text,
    count=1,
)
if replacements != 1:
    raise SystemExit('the archinstall DMS greeter command was not found')

compile(text, str(path), 'exec')
path.write_text(text)
PY
	python3 -m py_compile "$profiles_handler"
	grep -Eq 'command[[:space:]]*=[[:space:]]*"/usr/bin/dms-greeter --command niri"' "$profiles_handler"
}

patch_archinstall_zram_setup() {
	local installer
	installer=$(find /usr/lib -type f \
		-path '*/site-packages/archinstall/lib/installer.py' \
		-print -quit)
	[[ -n "$installer" && -f "$installer" ]] || {
		printf 'archinstall installer module is missing\n' >&2
		return 1
	}

	# Keep archinstall's normal zram setup, but make the generated device
	# explicit and give it a useful priority on this 16 GiB machine. The
	# pacstrap wrapper also seeds the same file before archinstall writes it.
	python3 - "$installer" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = (
    "\t\t\tzram_conf.write('[zram0]\\n')\n"
    "\t\t\tzram_conf.write(f'compression-algorithm = {algo.value}\\n')"
)
new = (
    "\t\t\tzram_conf.write('[zram0]\\n')\n"
    "\t\t\tzram_conf.write('zram-size = min(ram / 2, 8192)\\n')\n"
    "\t\t\tzram_conf.write(f'compression-algorithm = {algo.value}\\n')\n"
    "\t\t\tzram_conf.write('swap-priority = 100\\n')"
)

if old in text:
    text = text.replace(old, new, 1)
elif 'zram-size = min(ram / 2, 8192)' not in text:
    raise SystemExit('archinstall zram configuration block was not found')

compile(text, str(path), 'exec')
path.write_text(text)
PY
	python3 -m py_compile "$installer"
	grep -Fq "zram-size = min(ram / 2, 8192)" "$installer"
}

patch_archinstall_dms_greeter
patch_archinstall_zram_setup

patch_archinstall_wifi_handler() {
    local wifi_handler
    wifi_handler=$(find /usr/lib -type f \
        -path '*/site-packages/archinstall/lib/network/wifi_handler.py' \
        -print -quit)
    [[ -n "$wifi_handler" && -f "$wifi_handler" ]] || {
        printf 'archinstall Wi-Fi handler is missing\n' >&2
        return 1
    }

    # The upstream handler scans through wpa_cli and then tries to connect by
    # editing wpa_supplicant.conf. NetworkManager already owns the working
    # WCN7850 setup on this image, so hand the selected SSID and password to
    # NetworkManager instead of competing with its wpa_supplicant instance.
    python3 - "$wifi_handler" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()


def replace_method(source: str, method: str, next_method: str, replacement: str) -> str:
    pattern = re.compile(
        rf'(?ms)^\t(?:async )?def {re.escape(method)}\b.*?'
        rf'(?=^\t(?:async )?def {re.escape(next_method)}\b)'
    )
    # Use a replacement function so backslashes in the generated Python
    # source (the nmcli escaped-field parser) are not interpreted by re.sub.
    updated, count = pattern.subn(lambda _match: replacement, source, count=1)
    if count != 1:
        raise SystemExit(f'{method} was not found in {path}')
    return updated


enable_network_manager = '''\
\tasync def _enable_network_manager(self, wifi_iface: str) -> bool:
\t\tdebug('Ensuring NetworkManager is ready for Wi-Fi')

\t\ttry:
\t\t\tSysCommand(['systemctl', 'start', 'NetworkManager.service'])
\t\t\tSysCommand(['/usr/bin/nmcli', 'radio', 'wifi', 'on'])
\t\t\tSysCommand(['/usr/bin/nmcli', 'device', 'set', wifi_iface, 'managed', 'yes'])
\t\texcept SysCallError as err:
\t\t\tdebug(f'failed to enable NetworkManager Wi-Fi: {err}')
\t\t\treturn False

\t\treturn True

'''

setup_wifi = '''\
\tasync def _setup_wifi(self, wifi_iface: str) -> bool:
\t\tdebug('Setting up wifi')

\t\tif not await self._enable_network_manager(wifi_iface):
\t\t\tdebug('Failed to enable NetworkManager')
\t\t\treturn False

\t\tif not wifi_iface:
\t\t\tdebug('No wifi interface found')
\t\t\tawait NotifyScreen(header=tr('No wifi interface found')).run()
\t\t\treturn False

\t\tdebug(f'Found wifi interface: {wifi_iface}')

\t\twifi_networks = await self._scan_wifi(wifi_iface)

\t\tif not wifi_networks:
\t\t\tdebug('No networks found')
\t\t\tawait NotifyScreen(header=tr('No wifi networks found')).run()
\t\t\ttui.exit(Result.false())
\t\t\treturn False

\t\titems = [MenuItem(network.ssid, value=network) for network in wifi_networks]

\t\tresult = await TableSelectionScreen[WifiNetwork](
\t\t\theader=tr('Select wifi network to connect to'),
\t\t\tgroup=MenuItemGroup(items),
\t\t\tallow_skip=True,
\t\t\tallow_reset=True,
\t\t).run()

\t\tmatch result.type_:
\t\t\tcase ResultType.Selection:
\t\t\t\tnetwork = result.get_value()
\t\t\tcase ResultType.Skip | ResultType.Reset:
\t\t\t\ttui.exit(Result.false())
\t\t\t\treturn False
\t\t\tcase _:
\t\t\t\tassert_never(result.type_)

\t\tpsk = await self._prompt_psk()

\t\tif not psk:
\t\t\tdebug('No password specified')
\t\t\treturn False

\t\tif not self._connect_network_manager(wifi_iface, network.ssid, psk):
\t\t\tdebug('Failed to connect with NetworkManager')
\t\t\tawait self._notify_failure()
\t\t\treturn False

\t\tawait LoadingScreen(timer=5, header='Connecting wifi...').run()

\t\treturn True

\tdef _connect_network_manager(self, wifi_iface: str, ssid: str, psk: str) -> bool:
\t\tdebug(f'Connecting to Wi-Fi network through NetworkManager: {ssid}')

\t\ttry:
\t\t\tSysCommand([
\t\t\t\t'/usr/bin/nmcli',
\t\t\t\t'--wait',
\t\t\t\t'60',
\t\t\t\t'device',
\t\t\t\t'wifi',
\t\t\t\t'connect',
\t\t\t\tssid,
\t\t\t\t'password',
\t\t\t\tpsk,
\t\t\t\t'ifname',
\t\t\t\twifi_iface,
\t\t\t])
\t\texcept SysCallError as err:
\t\t\tdebug(f'NetworkManager failed to connect to Wi-Fi: {err}')
\t\t\treturn False

\t\treturn True

'''

scan_wifi = '''\
\tasync def _scan_wifi(self, wifi_iface: str) -> list[WifiNetwork]:
\t\tdebug('Scanning Wifi networks through NetworkManager')

\t\ttry:
\t\t\ttry:
\t\t\t\tSysCommand([
\t\t\t\t\t'/usr/bin/nmcli',
\t\t\t\t\t'device',
\t\t\t\t\t'wifi',
\t\t\t\t\t'rescan',
\t\t\t\t\t'ifname',
\t\t\t\t\twifi_iface,
\t\t\t\t])
\t\t\texcept SysCallError as err:
\t\t\t\t# A scan can already be in progress; the list command below
\t\t\t\t# still returns the most recent results in that case.
\t\t\t\tdebug(f'NetworkManager Wi-Fi rescan request failed: {err}')

\t\t\tawait LoadingScreen(timer=5, header=tr('Scanning wifi networks...')).run()
\t\t\tresult = SysCommand([
\t\t\t\t'/usr/bin/nmcli',
\t\t\t\t'-t',
\t\t\t\t'-e',
\t\t\t\t'yes',
\t\t\t\t'-f',
\t\t\t\t'BSSID,FREQ,SIGNAL,SECURITY,SSID',
\t\t\t\t'device',
\t\t\t\t'wifi',
\t\t\t\t'list',
\t\t\t\t'ifname',
\t\t\t\twifi_iface,
\t\t\t])
\t\texcept SysCallError as err:
\t\t\tdebug(f'Failed to retrieve Wi-Fi networks from NetworkManager: {err}')
\t\t\treturn []

\t\tnetworks = []
\t\tfor line in result.decode().splitlines():
\t\t\tparts = self._split_nmcli_row(line)
\t\t\tif len(parts) != 5 or not parts[0]:
\t\t\t\tcontinue

\t\t\tnetworks.append(
\t\t\t\tWifiNetwork(
\t\t\t\t\tbssid=parts[0],
\t\t\t\t\tfrequency=parts[1].removesuffix(' MHz'),
\t\t\t\t\tsignal_level=parts[2],
\t\t\t\t\tflags=parts[3],
\t\t\t\t\tssid=parts[4],
\t\t\t\t)
\t\t\t)

\t\treturn networks

\tdef _split_nmcli_row(self, line: str) -> list[str]:
\t\tfields = []
\t\tfield = []
\t\tescaped = False

\t\tfor character in line:
\t\t\tif escaped:
\t\t\t\tfield.append(character)
\t\t\t\tescaped = False
\t\t\telif character == '\\\\':
\t\t\t\tescaped = True
\t\t\telif character == ':':
\t\t\t\tfields.append(''.join(field))
\t\t\t\tfield = []
\t\t\telse:
\t\t\t\tfield.append(character)

\t\tif escaped:
\t\t\tfield.append('\\\\')
\t\tfields.append(''.join(field))
\t\treturn fields

'''

text = replace_method(text, '_enable_supplicant', '_find_wifi_interface', enable_network_manager)
text = replace_method(text, '_setup_wifi', '_scan_wifi', setup_wifi)
text = replace_method(text, '_scan_wifi', '_notify_failure', scan_wifi)
compile(text, str(path), 'exec')
path.write_text(text)
PY
    python3 -m py_compile "$wifi_handler"
    grep -Fq "async def _enable_network_manager" "$wifi_handler"
    grep -Fq "def _connect_network_manager" "$wifi_handler"
    grep -Fq "async def _scan_wifi" "$wifi_handler"
    grep -Fq "'/usr/bin/nmcli'" "$wifi_handler"
}

patch_archinstall_wifi_handler

# Arch Linux ARM's package signing key is officially shipped by
# archlinuxarm-keyring, but its old certifications can remain at unknown or
# marginal trust with current GnuPG. Keep signature verification enabled and
# locally sign only the imported official build key. This keyring is used by
# both live pacman and the pacstrap wrapper below.
install -d -m 700 /etc/pacman.d/gnupg
pacman-key --init
if ! grep -Fqx allow-weak-key-signatures /etc/pacman.d/gnupg/gpg.conf 2>/dev/null; then
    printf '%s\n' allow-weak-key-signatures >> /etc/pacman.d/gnupg/gpg.conf
fi
pacman-key --populate archlinuxarm
pacman-key --lsign-key "$archlinuxarm_build_key"

# archinstall invokes pacstrap with -K, which intentionally creates an empty
# target keyring. That is correct for a normal Arch ISO but leaves the Arch
# Linux ARM build key untrusted before archlinuxarm-keyring can be installed.
# Seed a fresh target keyring with the official ARM keys before the real
# pacstrap starts; package signatures remain Required throughout installation.
pacstrap_real="$surface_root/pacstrap.real"
if [[ -x /usr/bin/pacstrap && ! -e "$pacstrap_real" ]]; then
    mv /usr/bin/pacstrap "$pacstrap_real"
fi
[[ -x "$pacstrap_real" ]] || {
    printf 'missing pacstrap implementation: %s\n' "$pacstrap_real" >&2
    exit 1
}
install -D -m 0755 /usr/local/libexec/archlinuxarm-pacstrap \
    /usr/bin/pacstrap

# Leave NetworkManager stopped until the archinstall Wi-Fi menu needs it.
# The patched handler starts NetworkManager and uses nmcli for the selected
# network, matching the connection method that works on this hardware.
systemctl enable surface-wifi-reprobe.service
