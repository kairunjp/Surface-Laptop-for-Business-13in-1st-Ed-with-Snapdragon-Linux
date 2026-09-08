#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INPUT_ISO=${INPUT_ISO:-$ROOT_DIR/proxmox-ve_9.2-1-arm64.iso}
OUTPUT_DIR=${OUTPUT_DIR:-$ROOT_DIR/build}
OUTPUT_ISO=${OUTPUT_ISO:-$OUTPUT_DIR/proxmox-ve_9.2-1-arm64-surface.iso}
WORK_DIR=${WORK_DIR:-$OUTPUT_DIR/.work}
KERNEL_SOURCE=${KERNEL_SOURCE:-/root/linux}
KERNEL_IMAGE=${KERNEL_IMAGE:-$WORK_DIR/kernel/Image}
DTB_FILE=${DTB_FILE:-$WORK_DIR/dtb/surface-laptop-13-current.dtb}
DTB_NAME=${DTB_NAME:-surface-laptop-13-current.dtb}
INITRD_FILE=${INITRD_FILE:-}
LVM_MODULE_TREE=${LVM_MODULE_TREE:-}
WCN7850_FIRMWARE_SOURCE=${WCN7850_FIRMWARE_SOURCE:-}
# Optional ARM64 Debian package bundle for NetworkManager and the Wi-Fi CLI.
# The binary packages are deliberately kept outside Git; pass a directory
# containing network-manager, wpasupplicant, iw, rfkill, wireless-regdb and
# their ARM64 dependencies when building an ISO.
NETWORK_MANAGER_PACKAGE_DIR=${NETWORK_MANAGER_PACKAGE_DIR:-}
EFI_IMAGE=${EFI_IMAGE:-}
EL2_DTB_FILE=${EL2_DTB_FILE:-}
EL2_DTB_NAME=${EL2_DTB_NAME:-surface-laptop-13-el2.dtb}
EL2_DTB_WITHOUT_UFS_FILE=${EL2_DTB_WITHOUT_UFS_FILE:-}
EL2_DTB_WITHOUT_UFS_NAME=${EL2_DTB_WITHOUT_UFS_NAME:-surface-laptop-13-el2-without-ufs.dtb}
# X1P42100 EL2 needs the clocks and power domains left on across the handoff.
# Keep this overridable for other Qualcomm platforms with different firmware
# ownership rules.
# Keep the USB installer KVM handoff identical to the known-good installed
# Surface entry.  The verbose/no-auto-reboot options are intentional: if EL2
# fails, the display remains available long enough to show the failure and the
# outer USB GRUB can select Ready on the next boot.
EL2_KERNEL_ARGS=${EL2_KERNEL_ARGS:-"clk_ignore_unused pd_ignore_unused console=tty0 usbcore.autosuspend=-1 id_aa64mmfr0.ecv=1 loglevel=7 ignore_loglevel panic=-1"}
KERNEL_APPLY_PATCHES=${KERNEL_APPLY_PATCHES:-1}
BUILD_MISSING=1
INCLUDE_MODULES=1
GRUB_MODULE_DIR=${GRUB_MODULE_DIR:-}
ALLOW_UNTESTED_TCB=${ALLOW_UNTESTED_TCB:-0}
FAT_BOOT=${FAT_BOOT:-0}
FAT_BOOT_SIZE=${FAT_BOOT_SIZE:-268435456}

# X1P42100 reference TCB validated with the Surface Secure Launch path.
KNOWN_GOOD_TCB_SHA256=5dfcd0253b6ee99499ab33cac221e8a9cea47f3fdf6d4e11de9a9f3c4770d03d

DEFAULT_OUTPUT_ISO=$OUTPUT_ISO
DEFAULT_WORK_DIR=$WORK_DIR
DEFAULT_KERNEL_IMAGE=$KERNEL_IMAGE
DEFAULT_DTB_FILE=$DTB_FILE

STAGE_DIR=
NETWORK_MANAGER_PACKAGE_FILES=()

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

log() {
	printf '\n==> %s\n' "$*"
}

need() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

absolute_path() {
	local path=$1
	if [[ "$path" == /* ]]; then
		printf '%s\n' "$path"
	else
		printf '%s/%s\n' "$ROOT_DIR" "$path"
	fi
}

usage() {
	cat <<'EOF'
Usage: ./build-proxmox-iso.sh [options]

Patch an existing Proxmox VE ARM64 ISO with the Surface kernel and DTB.
The patched ISO is written below ./build by default.

Options:
  --iso FILE          Input Proxmox ARM64 ISO.
  --output FILE       Output ISO (default: ./build/proxmox-ve_9.2-1-arm64-surface.iso).
  --kernel DIR        Linux source tree used when the kernel image is absent.
  --kernel-image FILE Use an existing ARM64 kernel Image instead of building one.
  --dtb FILE          Use an existing Surface DTB instead of building one.
  --dtb-name NAME     Name of the DTB inside /boot (default: current DTB name).
  --el2-dtb FILE      Add a separate EL2/KVM DTB and installer menu entries.
  --el2-dtb-name NAME Name of the EL2 DTB inside /boot (default: surface-laptop-13-el2.dtb).
  --el2-dtb-without-ufs FILE
                      Add a UFS-disabled EL2 DTB to Advanced Options; the
                      normal EL2/KVM entry continues to use --el2-dtb.
  --el2-dtb-without-ufs-name NAME
                      Name of the UFS-disabled DTB inside /boot (default:
                      surface-laptop-13-el2-without-ufs.dtb).
  --efi-image FILE    Replace the ISO EFI image (required for --el2-dtb).
  --initrd FILE       Replace the ISO initrd with this archive.
  --lvm-module-tree DIR
                      Replace the LVM modules with files built with --kernel-image.
  --wcn7850-firmware DIR
                      Add ath12k/WCN7850 Wi-Fi firmware to the ISO initrd.
  --network-manager-packages DIR
                      Add ARM64 NetworkManager/nmcli, wpa_supplicant, iw,
                      rfkill, wireless-regdb and dependency .deb files to the
                      installer and installed target. Packages are build
                      inputs and are not stored in Git.
  --no-initrd-modules Keep the selected initrd without adding built modules.
  --allow-untested-tcb Permit an EFI image containing another TCB build.
  --fat-boot          Put kernel/initramfs/DTBs/KVM EFI payload in one El Torito
                      FAT image and boot it through cmdpath without disk search.
  --work DIR          Scratch directory (default: ./build/.work).
  --no-build           Fail if --kernel-image or --dtb is missing.
  -h, --help          Show this help.

The original Proxmox installer initrd is preserved unless --initrd is given.
The selected initrd is augmented with the built kernel modules by default. The
ISO's GRUB entries are changed to load the Surface DTB. The output kernel is
an unsigned development artifact; Secure Boot may need to be disabled or the
kernel signed before booting it.

When --el2-dtb is used, an ARM64 GRUB module directory containing kernel.img
is required. Set GRUB_MODULE_DIR when it is not installed at
/usr/lib/grub/arm64-efi (Debian package: grub-efi-arm64-bin).
EOF
}

parse_args() {
	while (($#)); do
		case "$1" in
			--iso)
				shift
				(($#)) || die "--iso needs a file"
				INPUT_ISO=$1
				;;
			--output)
				shift
				(($#)) || die "--output needs a file"
				OUTPUT_ISO=$1
				;;
			--kernel)
				shift
				(($#)) || die "--kernel needs a directory"
				KERNEL_SOURCE=$1
				;;
			--kernel-image)
				shift
				(($#)) || die "--kernel-image needs a file"
				KERNEL_IMAGE=$1
				;;
			--dtb)
				shift
				(($#)) || die "--dtb needs a file"
				DTB_FILE=$1
				;;
			--dtb-name)
				shift
				(($#)) || die "--dtb-name needs a name"
				DTB_NAME=$1
				;;
			--el2-dtb)
				shift
				(($#)) || die "--el2-dtb needs a file"
				EL2_DTB_FILE=$1
				;;
			--el2-dtb-name)
				shift
				(($#)) || die "--el2-dtb-name needs a name"
				EL2_DTB_NAME=$1
				;;
			--el2-dtb-without-ufs)
				shift
				(($#)) || die "--el2-dtb-without-ufs needs a file"
				EL2_DTB_WITHOUT_UFS_FILE=$1
				;;
			--el2-dtb-without-ufs-name)
				shift
				(($#)) || die "--el2-dtb-without-ufs-name needs a name"
				EL2_DTB_WITHOUT_UFS_NAME=$1
				;;
			--efi-image)
				shift
				(($#)) || die "--efi-image needs a file"
				EFI_IMAGE=$1
				;;
			--initrd)
				shift
				(($#)) || die "--initrd needs a file"
				INITRD_FILE=$1
				;;
			--lvm-module-tree)
				shift
				(($#)) || die "--lvm-module-tree needs a directory"
				LVM_MODULE_TREE=$1
				;;
			--wcn7850-firmware)
				shift
				(($#)) || die "--wcn7850-firmware needs a directory"
				WCN7850_FIRMWARE_SOURCE=$1
				;;
			--network-manager-packages)
				shift
				(($#)) || die "--network-manager-packages needs a directory"
				NETWORK_MANAGER_PACKAGE_DIR=$1
				;;
			--no-initrd-modules)
				INCLUDE_MODULES=0
				;;
			--allow-untested-tcb)
				ALLOW_UNTESTED_TCB=1
				;;
			--fat-boot)
				FAT_BOOT=1
				;;
			--work)
				shift
				(($#)) || die "--work needs a directory"
				WORK_DIR=$1
				;;
			--no-build)
				BUILD_MISSING=0
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				die "unknown argument: $1 (use --help)"
				;;
		esac
		shift
	done
}

cleanup() {
	if [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]]; then
		rm -rf -- "$STAGE_DIR"
	fi
}

trap cleanup EXIT

build_missing_components() {
	local build_wrapper="$ROOT_DIR/build-debian.sh"
	[[ -x "$build_wrapper" ]] || die "build wrapper is not executable: $build_wrapper"

	if [[ ! -f "$KERNEL_IMAGE" ]]; then
		[[ "$BUILD_MISSING" -eq 1 ]] || die "kernel image not found: $KERNEL_IMAGE"
		log "Building Surface ARM64 kernel"
		KERNEL_SOURCE="$KERNEL_SOURCE" \
		KERNEL_APPLY_PATCHES="$KERNEL_APPLY_PATCHES" \
		SURFACE_OUTPUT_DIR="$OUTPUT_DIR" \
		SURFACE_WORK_DIR="$WORK_DIR" \
			"$build_wrapper" kernel
	fi

	if [[ ! -f "$DTB_FILE" ]]; then
		[[ "$BUILD_MISSING" -eq 1 ]] || die "DTB not found: $DTB_FILE"
		log "Building Surface DTB"
		KERNEL_SOURCE="$KERNEL_SOURCE" \
		KERNEL_APPLY_PATCHES="$KERNEL_APPLY_PATCHES" \
		SURFACE_OUTPUT_DIR="$OUTPUT_DIR" \
		SURFACE_WORK_DIR="$WORK_DIR" \
			"$build_wrapper" dtb
	fi
}

patch_grub_config() {
	local grub_cfg="$1"
	local dtb_path="$2"
	python3 - "$grub_cfg" "$dtb_path" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
dtb_path = sys.argv[2]
text = path.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)
result = []
patched = 0
for line in lines:
    # Make repeated rebuilds deterministic.  Older patched inputs may already
    # contain one or more Surface DTB directives; replace them with exactly one
    # directive after each Proxmox kernel line below.
    if re.match(r"^\s*devicetree\s+/boot/", line):
        continue
    result.append(line)
    if re.match(r"^\s*linux\s+/boot/linux26(?:\s|$)", line):
        newline = "\n" if line.endswith("\n") else ""
        indent = re.match(r"^\s*", line).group(0)
        result.append(f"{indent}devicetree /boot/{dtb_path}{newline}")
        patched += 1

if patched == 0:
    raise SystemExit(f"no Proxmox linux /boot/linux26 entries found in {path}")

path.write_text("".join(result), encoding="utf-8")
print(f"patched GRUB entries: {patched}")
PY
}

verify_efi_tcb() {
	local efi_image=$1 hash
	hash=$(7z e -so "$efi_image" tcblaunch.exe 2>/dev/null | sha256sum | cut -d ' ' -f1)
	if [[ "$hash" == "$KNOWN_GOOD_TCB_SHA256" ]]; then
		printf 'EFI TCB: validated X1P42100 build (%s)\n' "$hash"
		return 0
	fi
	if [[ "$ALLOW_UNTESTED_TCB" -ne 1 ]]; then
		die "EFI image contains unvalidated tcblaunch.exe ($hash); rebuild it with X1P42100 TCB SHA256 $KNOWN_GOOD_TCB_SHA256, or pass --allow-untested-tcb for another platform"
	fi
	printf 'WARNING: EFI image contains unvalidated tcblaunch.exe (%s); X1P42100 may hang or reset\n' "$hash" >&2
}

verify_efi_slbounce() {
	local efi_image=$1 marker
	marker='surface-x1p: safe ExitBootServices cache mode'
	if 7z e -so "$efi_image" EFI/BOOT/slbounceaa64.efi 2>/dev/null |
		strings -el | grep -Fq "$marker"; then
		printf 'EFI slbounce: X1P42100-safe ExitBootServices build\n'
		return 0
	fi
	die "EFI image does not contain the X1P42100-safe slbounce build; rebuild it with --slbounce-source and tools/slbounce-x1p42100-safe-ebs.patch"
}

verify_efi_default_shim() {
	local efi_image=$1 boot_hash shim_hash shell_hash
	boot_hash=$(7z e -so "$efi_image" 'EFI/BOOT/BOOTAA64.EFI' 2>/dev/null |
		sha256sum | cut -d ' ' -f1)
	shim_hash=$(7z e -so "$efi_image" 'EFI/BOOT/shimaa64.efi' 2>/dev/null |
		sha256sum | cut -d ' ' -f1)
	shell_hash=$(7z e -so "$efi_image" 'EFI/BOOT/surface-kvm-shell-bridge.efi' 2>/dev/null |
		sha256sum | cut -d ' ' -f1)
	[[ -n "$boot_hash" && -n "$shim_hash" && "$boot_hash" != \
		"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" &&
		"$shim_hash" != \
		"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]] ||
		die "EFI image is missing BOOTAA64.EFI or shimaa64.efi"
	if [[ "$boot_hash" != "$shim_hash" ]]; then
		die "EFI default BOOTAA64.EFI is not the Proxmox shimaa64.efi; rebuild the EFI image without --shell before patching an ISO"
	fi
	if [[ -n "$shell_hash" && "$shell_hash" != \
		"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" &&
		"$shim_hash" == "$shell_hash" ]]; then
		die "EFI shimaa64.efi is the Surface EFI Shell bridge, not the Proxmox shim; rebuild the EFI image from a normal Proxmox EFI image"
	fi
	printf 'EFI default: BOOTAA64.EFI matches shimaa64.efi (%s)\n' "$boot_hash"
}

add_network_manager_packages() {
	local package package_name architecture target
	local required

	NETWORK_MANAGER_PACKAGE_FILES=()
	[[ -n "$NETWORK_MANAGER_PACKAGE_DIR" ]] || return 0
	[[ -d "$NETWORK_MANAGER_PACKAGE_DIR" ]] ||
		die "NetworkManager package directory not found: $NETWORK_MANAGER_PACKAGE_DIR"

	mkdir -p "$STAGE_DIR/proxmox/packages"
	while IFS= read -r -d '' package; do
		package_name=$(dpkg-deb -f "$package" Package) ||
			die "cannot read package metadata: $package"
		architecture=$(dpkg-deb -f "$package" Architecture) ||
			die "cannot read package architecture: $package"
		case "$architecture" in
			arm64|all) ;;
			*) die "NetworkManager package is not ARM64 or all-arch: $package_name ($architecture)" ;;
		esac
		target="$STAGE_DIR/proxmox/packages/$(basename "$package")"
		cp --preserve=mode,timestamps "$package" "$target"
		NETWORK_MANAGER_PACKAGE_FILES+=("$target")
	done < <(find "$NETWORK_MANAGER_PACKAGE_DIR" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)

	((${#NETWORK_MANAGER_PACKAGE_FILES[@]} > 0)) ||
		die "NetworkManager package directory contains no .deb files: $NETWORK_MANAGER_PACKAGE_DIR"
	for required in network-manager libnm0 wpasupplicant iw rfkill wireless-regdb; do
		if ! printf '%s\n' "${NETWORK_MANAGER_PACKAGE_FILES[@]}" |
			while IFS= read -r package; do
				[[ "$(dpkg-deb -f "$package" Package)" == "$required" ]] && exit 0
			done; then
			die "NetworkManager package bundle is missing required package: $required"
		fi
	done
	log "Adding ARM64 NetworkManager packages to installer and target"
	printf '  %s\n' "${NETWORK_MANAGER_PACKAGE_FILES[@]##*/}"
}

augment_proxmox_installer_squashfs() {
	local squashfs="$STAGE_DIR/pve-installer.squashfs"
	local root_dir output_dir package wifi_firmware_dir
	[[ -n "$NETWORK_MANAGER_PACKAGE_DIR" ]] || return 0
	[[ -f "$squashfs" ]] || die "Proxmox installer squashfs not found: $squashfs"

	root_dir=$(mktemp -d "$WORK_DIR/pve-installer-wifi.XXXXXX")
	output_dir=$(mktemp "$WORK_DIR/pve-installer-squashfs.XXXXXX")
	rm -f -- "$output_dir"
	log "Adding nmcli and NetworkManager to the installer live environment"
	unsquashfs -no-xattrs -d "$root_dir" "$squashfs" >/dev/null
	for package in "${NETWORK_MANAGER_PACKAGE_FILES[@]}"; do
		dpkg-deb -x "$package" "$root_dir"
	done
	if [[ -n "$WCN7850_FIRMWARE_SOURCE" ]]; then
		wifi_firmware_dir="$root_dir/lib/firmware/ath12k/WCN7850/hw2.0"
		mkdir -p "$wifi_firmware_dir"
		cp -a "$WCN7850_FIRMWARE_SOURCE"/. "$wifi_firmware_dir"/
	fi

	# The live installer is SysV based rather than systemd based.  Start
	# NetworkManager after D-Bus and keep ifupdown-managed bridges untouched;
	# wlan* is intentionally left out of /etc/network/interfaces by the
	# installer module patch below.
	mkdir -p "$root_dir/etc/NetworkManager/conf.d" \
		"$root_dir/etc/NetworkManager/system-connections" \
		"$root_dir/usr/local/sbin"
	cat >"$root_dir/etc/NetworkManager/conf.d/10-surface-wifi.conf" <<'EOF'
[main]
plugins=keyfile,ifupdown

[ifupdown]
managed=false

[device-surface-wifi]
match-device=interface-name:wlan*
managed=true
EOF
	cat >"$root_dir/usr/local/sbin/surface-wifi-start" <<'EOF'
#!/bin/sh
# Reprobe WCN7850 after the installer SquashFS is mounted, then start the live
# installer's NetworkManager without relying on systemd or a SysV init script.
set -u

surface_wifi_present() {
    for iface in /sys/class/net/*; do
        [ -d "$iface/wireless" ] && return 0
    done
    return 1
}

if ! surface_wifi_present; then
    for pci_device in /sys/bus/pci/devices/*; do
        [ -r "$pci_device/vendor" ] || continue
        [ -r "$pci_device/device" ] || continue
        [ "$(cat "$pci_device/vendor")" = "0x17cb" ] || continue
        [ "$(cat "$pci_device/device")" = "0x1107" ] || continue

        pci_address=${pci_device##*/}
        echo "surface-wifi: reprobe WCN7850 at $pci_address" >&2
        if [ -L "$pci_device/driver" ]; then
            pci_driver=$(readlink -f "$pci_device/driver")
            echo "$pci_address" >"$pci_driver/unbind" || true
            sleep 1
            echo "$pci_address" >"$pci_driver/bind" || true
        else
            echo "$pci_address" >/sys/bus/pci/drivers_probe || true
        fi
    done
    command -v udevadm >/dev/null 2>&1 && udevadm settle || true
    sleep 2
fi

if ! surface_wifi_present; then
    echo "surface-wifi: WCN7850 did not create a wireless interface" >&2
    exit 1
fi

if ! pidof dbus-daemon >/dev/null 2>&1; then
    if [ -x /etc/init.d/dbus ]; then
        /etc/init.d/dbus start >/tmp/surface-dbus.log 2>&1 || true
    else
        mkdir -p /run/dbus
        dbus-daemon --system --fork >/tmp/surface-dbus.log 2>&1 || true
    fi
fi
if ! pidof NetworkManager >/dev/null 2>&1; then
    /usr/sbin/NetworkManager --no-daemon \
        >/tmp/surface-network-manager.log 2>&1 &
fi
for wait_try in 1 2 3 4 5; do
    nmcli general status >/dev/null 2>&1 && break
    sleep 1
done
if ! nmcli general status >/dev/null 2>&1; then
    echo "surface-wifi: NetworkManager did not start; see /tmp/surface-network-manager.log" >&2
    exit 1
fi
nmcli radio wifi on >/dev/null 2>&1 || true
echo "surface-wifi: Wi-Fi is ready; use nmcli device wifi list/connect" >&2
EOF
	chmod 0755 "$root_dir/usr/local/sbin/surface-wifi-start"
	sh -n "$root_dir/usr/local/sbin/surface-wifi-start"
	python3 "$ROOT_DIR/initramfs/scripts/patch-proxmox-live-wifi.py" \
		"$root_dir/usr/sbin/unconfigured.sh"
	bash -n "$root_dir/usr/sbin/unconfigured.sh"
	mksquashfs "$root_dir" "$output_dir" -comp zstd -Xcompression-level 19 \
		-b 1048576 -no-xattrs -noappend >/dev/null
	mv -- "$output_dir" "$squashfs"
	rm -rf -- "$root_dir"
}

verify_proxmox_installer_squashfs() {
	local listing required squashfs="$STAGE_DIR/pve-installer.squashfs"
	local unconfigured_text helper_text expected actual
	[[ -n "$NETWORK_MANAGER_PACKAGE_DIR" ]] || return 0
	listing=$(mktemp "$WORK_DIR/installer-squash-list.XXXXXX")
	unsquashfs -no-progress -ll "$squashfs" >"$listing"
	for required in \
		usr/bin/nmcli \
		usr/sbin/NetworkManager \
		usr/sbin/wpa_supplicant \
		usr/sbin/iw \
		usr/sbin/rfkill \
		usr/local/sbin/surface-wifi-start \
		etc/NetworkManager/conf.d/10-surface-wifi.conf; do
		grep -Eq "squashfs-root/$required$" "$listing" || {
			rm -f -- "$listing"
			die "installer squashfs is missing NetworkManager Wi-Fi file: $required"
		}
	done
	if [[ -n "$WCN7850_FIRMWARE_SOURCE" ]]; then
		for required in amss.bin m3.bin board-2.bin; do
			grep -Eq "squashfs-root/lib/firmware/ath12k/WCN7850/hw2.0/$required$" \
				"$listing" || {
				rm -f -- "$listing"
				die "installer squashfs is missing WCN7850 firmware: $required"
			}
			expected=$(sha256sum "$WCN7850_FIRMWARE_SOURCE/$required" | awk '{print $1}')
			actual=$(unsquashfs -cat "$squashfs" \
				"lib/firmware/ath12k/WCN7850/hw2.0/$required" | sha256sum | awk '{print $1}')
			[[ "$actual" == "$expected" ]] || {
				rm -f -- "$listing"
				die "installer squashfs WCN7850 firmware hash mismatch: $required"
			}
		done
	fi
	unconfigured_text=$(unsquashfs -cat "$squashfs" usr/sbin/unconfigured.sh)
	grep -Fq '/usr/local/sbin/surface-wifi-start' <<<"$unconfigured_text" || {
		rm -f -- "$listing"
		die "live installer does not start the Surface Wi-Fi service"
	}
	helper_text=$(unsquashfs -cat "$squashfs" usr/local/sbin/surface-wifi-start)
	grep -Fq '/usr/sbin/NetworkManager --no-daemon' <<<"$helper_text" || {
		rm -f -- "$listing"
		die "live installer Wi-Fi helper does not start NetworkManager directly"
	}
	grep -Fq '/sys/bus/pci/drivers_probe' <<<"$helper_text" || {
		rm -f -- "$listing"
		die "live installer Wi-Fi helper cannot reprobe WCN7850"
	}
	rm -f -- "$listing"
}

patch_proxmox_initrd_lvm() {
	local initrd=$1 raw_initrd init_file manifest patched compressed release relative source metadata
	local installer_module
	raw_initrd=$(mktemp "$WORK_DIR/proxmox-initrd-lvm-raw.XXXXXX.img")
	init_file=$(mktemp "$WORK_DIR/proxmox-init-lvm.XXXXXX")
	manifest=$(mktemp "$WORK_DIR/proxmox-initrd-lvm.XXXXXX.manifest")
	patched=$(mktemp "$WORK_DIR/proxmox-initrd-lvm-patched.XXXXXX.img")
	compressed=$(mktemp "$WORK_DIR/proxmox-initrd-lvm-compressed.XXXXXX.img")
	rm -f -- "$raw_initrd" "$patched" "$compressed"

	log "Enabling Surface device-mapper/LVM in Proxmox initrd"
	if zstd -t "$initrd" >/dev/null 2>&1; then
		zstd -q -dc "$initrd" >"$raw_initrd"
	elif gzip -t "$initrd" >/dev/null 2>&1; then
		gzip -dc "$initrd" >"$raw_initrd"
	else
		die "unsupported initrd compression: $initrd (expected zstd or gzip)"
	fi

	cpio -i --to-stdout init 2>/dev/null <"$raw_initrd" >"$init_file" ||
		die "cannot extract Proxmox installer init from $initrd"
	python3 "$ROOT_DIR/initramfs/scripts/patch-proxmox-init-lvm.py" "$init_file"
	# Patch the installer's second stage too: its target-chroot efivarfs mount
	# otherwise aborts installation on this Surface after the GUI has started.
	installer_module=$(mktemp "$WORK_DIR/proxmox-installer-efi.XXXXXX.pm")
	unsquashfs -cat "$STAGE_DIR/pve-installer.squashfs" \
		usr/share/perl5/Proxmox/Install.pm >"$installer_module" ||
		die "cannot extract Proxmox::Install from the selected ISO"
	python3 "$ROOT_DIR/initramfs/scripts/patch-proxmox-installer-efi.py" \
		"$installer_module" "$init_file"
	if [[ -n "$NETWORK_MANAGER_PACKAGE_DIR" ]]; then
		python3 "$ROOT_DIR/initramfs/scripts/patch-proxmox-installer-wifi.py" \
			"$installer_module"
	fi
	# Ventoy's cpio hook targets the older Proxmox /sys/block/hd* scanner.
	# Current installer init uses /sys/class/block, so invoke Ventoy's official
	# Proxmox disk hook explicitly before the ISO scan and accept its dm mapping.
	python3 "$ROOT_DIR/initramfs/scripts/patch-proxmox-installer-ventoy.py" \
		"$init_file"
	sh -n "$init_file"
	printf 'init %s 0755\n' "$init_file" >"$manifest"
	printf 'surface-installer/Install.pm %s 0644\n' "$installer_module" >>"$manifest"
	printf 'surface-installer/SurfaceEFI.pm %s 0644\n' \
		"$ROOT_DIR/initramfs/installer/SurfaceEFI.pm" >>"$manifest"
	printf 'surface-installer/powerctl %s 0755\n' \
		"$ROOT_DIR/initramfs/scripts/surface-installer-powerctl.sh" >>"$manifest"
	if [[ -n "$LVM_MODULE_TREE" ]]; then
		release=$(basename "$LVM_MODULE_TREE")
		for relative in \
			kernel/drivers/md/dm-mod.ko \
			kernel/drivers/md/dm-bio-prison.ko \
			kernel/drivers/md/dm-bufio.ko \
			kernel/drivers/md/persistent-data/dm-persistent-data.ko \
			kernel/drivers/md/dm-thin-pool.ko \
			kernel/drivers/net/mii.ko \
			kernel/drivers/net/usb/r8152.ko \
			kernel/drivers/net/usb/usbnet.ko \
			kernel/drivers/net/usb/cdc_ether.ko \
			kernel/drivers/net/usb/cdc_ncm.ko \
			kernel/drivers/net/usb/asix.ko \
			kernel/drivers/net/usb/ax88179_178a.ko; do
			source="$LVM_MODULE_TREE/$relative"
			[[ -f "$source" ]] || die "matching Surface early-boot module is missing: $source"
			printf 'lib/modules/%s/%s %s 0644\n' "$release" "$relative" "$source" >>"$manifest"
		done
		while IFS= read -r -d '' metadata; do
			printf 'lib/modules/%s/%s %s 0644\n' \
				"$release" "$(basename "$metadata")" "$metadata" >>"$manifest"
		done < <(find "$LVM_MODULE_TREE" -maxdepth 1 -type f -name 'modules.*' -print0 | sort -z)
	fi
	python3 "$ROOT_DIR/initramfs/scripts/augment-newc-initramfs.py" --raw \
		"$raw_initrd" "$patched" "$manifest"
	zstd -q -T0 -19 -f "$patched" -o "$compressed"
	mv -- "$compressed" "$initrd"
	zstd -q -dc "$initrd" | cpio -it --quiet >/dev/null
	rm -f -- "$raw_initrd" "$init_file" "$manifest" "$patched" "$installer_module"
}

verify_proxmox_installer_initrd() {
	local initrd=$1 listing init_text installer_text required release relative expected actual extract_dir
	[[ -s "$initrd" ]] || die "installer initrd is missing or empty: $initrd"
	listing=$(mktemp "$WORK_DIR/initrd-list.XXXXXX")
	if ! zstd -q -dc "$initrd" | cpio -it --quiet >"$listing" 2>/dev/null; then
		rm -f -- "$listing"
		die "installer initrd is not a readable zstd cpio archive: $initrd"
	fi
	grep -Fxq '.cd-info' "$listing" || {
		rm -f -- "$listing"
		die "initrd is not a Proxmox installer initrd (.cd-info is missing): $initrd"
	}
	init_text=$(zstd -q -dc "$initrd" | cpio -i --to-stdout init 2>/dev/null || true)
	for required in surface-installer/Install.pm surface-installer/SurfaceEFI.pm surface-installer/powerctl; do
		grep -Fxq "$required" "$listing" || die "installer EFI fallback payload is missing: $required"
	done
	grep -Fq 'cp /surface-installer/Install.pm "$surface_perl_dir/Install.pm"' <<<"$init_text" ||
		die "installer init does not activate the Surface EFI fallback"
	if ! grep -Fq 'Proxmox Server Solutions' <<<"$init_text"; then
		rm -f -- "$listing"
		die "initrd has generic root-mount logic; use the Proxmox installer initrd instead: $initrd"
	fi
	grep -Fq 'if ! /sbin/modprobe "$module_name"; then' <<<"$init_text" || {
		rm -f -- "$listing"
		die "initrd does not preload Surface device-mapper modules with modprobe: $initrd"
	}
	if grep -Fq 'insmod "$module_path"' <<<"$init_text"; then
		rm -f -- "$listing"
		die "initrd still uses unavailable insmod for Surface LVM modules: $initrd"
	fi
	if grep -Fq 'surface_dm_base=' <<<"$init_text" || grep -Fq 'module_path=$2' <<<"$init_text"; then
		rm -f -- "$listing"
		die "initrd still uses fixed Surface LVM module paths: $initrd"
	fi
	grep -Fq 'load_surface_dm_module dm_thin_pool' <<<"$init_text" || {
		rm -f -- "$listing"
		die "initrd does not ask modprobe to resolve the thin-pool dependency stack: $initrd"
	}
	if [[ -n "$NETWORK_MANAGER_PACKAGE_DIR" ]]; then
		installer_text=$(zstd -q -dc "$initrd" |
			cpio -i --to-stdout surface-installer/Install.pm 2>/dev/null || true)
		grep -Fq 'next if $name =~ /^wl/;' <<<"$installer_text" || {
			rm -f -- "$listing"
			die "installer module still emits an ifupdown stanza for Surface Wi-Fi"
		}
		grep -Fq 'match-device=interface-name:wlan*' <<<"$installer_text" || {
			rm -f -- "$listing"
			die "installer module does not install NetworkManager Wi-Fi configuration"
		}
	fi
	grep -Fq 'SURFACE_USB_NET_DRIVERS="mii r8152 usbnet' <<<"$init_text" || {
		rm -f -- "$listing"
		die "initrd does not preload Surface USB network drivers: $initrd"
	}
	grep -Fq 'cp /surface-installer/powerctl' <<<"$init_text" || {
		rm -f -- "$listing"
		die "initrd does not install Surface power controls: $initrd"
	}
	grep -Fq 'dm_mod dm_bio_prison dm_bufio dm_persistent_data dm_thin_pool' <<<"$init_text" || {
		rm -f -- "$listing"
		die "initrd does not verify the complete Surface LVM module stack: $initrd"
	}
	grep -Fq 'surface_ventoy_prepare_dm' <<<"$init_text" || {
		rm -f -- "$listing"
		die "initrd does not invoke the Ventoy Proxmox ISO hook: $initrd"
	}
	grep -Fq '/sys/class/block/dm-*' <<<"$init_text" || {
		rm -f -- "$listing"
		die "initrd does not scan Ventoy device-mapper ISO devices: $initrd"
	}
	grep -Fq 'mount -t iso9660 -o loop,ro' <<<"$init_text" || {
		rm -f -- "$listing"
		die "initrd does not use a loop mount for Ventoy sector-size compatibility: $initrd"
	}
	grep -Fq 'losetup -r "$surface_iso_loop" "$1"' <<<"$init_text" || {
		rm -f -- "$listing"
		die "initrd does not explicitly loop-map block devices for Ventoy: $initrd"
	}
	for required in \
		dm-mod.ko \
		dm-bio-prison.ko \
		dm-bufio.ko \
		dm-persistent-data.ko \
		dm-thin-pool.ko; do
		grep -Eq "^lib/modules/[^/]*surface-laptop-13/kernel/drivers/md/(persistent-data/)?$required$" "$listing" || {
			rm -f -- "$listing"
			die "initrd is missing Surface LVM module $required: $initrd"
		}
	done
	for required in mii r8152 usbnet cdc_ether cdc_ncm asix ax88179_178a; do
		grep -Eq "^lib/modules/[^/]*surface-laptop-13/kernel/drivers/net/(usb/)?$required\\.ko$" "$listing" || {
			rm -f -- "$listing"
			die "initrd is missing Surface USB network module $required: $initrd"
		}
	done
	grep -Fxq 'sbin/lvm' "$listing" || {
		rm -f -- "$listing"
		die "initrd is missing the LVM userspace tool: $initrd"
	}
	# Listing/--to-stdout succeeds even if the kernel cannot unpack a file
	# because its parent directory is absent. Do not use cpio -d here.
	extract_dir=$(mktemp -d "$WORK_DIR/lvm-unpack.XXXXXX")
	if ! zstd -q -dc "$initrd" | (cd "$extract_dir" && cpio -i --quiet \
		'lib' 'lib/modules' 'lib/modules/*surface-laptop-13' \
		'lib/modules/*surface-laptop-13/kernel' \
		'lib/modules/*surface-laptop-13/kernel/drivers' \
		'lib/modules/*surface-laptop-13/kernel/drivers/md*' \
		'lib/modules/*surface-laptop-13/kernel/drivers/net' \
		'lib/modules/*surface-laptop-13/kernel/drivers/net/*' \
		'lib/modules/*surface-laptop-13/kernel/drivers/net/usb' \
		'lib/modules/*surface-laptop-13/kernel/drivers/net/usb/*'); then
		rm -rf -- "$extract_dir"
		die "Surface LVM files cannot be unpacked without creating missing parents"
	fi
	for required in dm-mod dm-bio-prison dm-bufio dm-persistent-data dm-thin-pool; do
		if ! find "$extract_dir" -type f -name "$required.ko" -size +0c | grep -q .; then
			rm -rf -- "$extract_dir"
			die "Surface LVM module was not unpacked: $required"
		fi
	done
	for required in mii r8152 usbnet cdc_ether cdc_ncm asix ax88179_178a; do
		if ! find "$extract_dir" -type f -name "$required.ko" -size +0c | grep -q .; then
			rm -rf -- "$extract_dir"
			die "Surface USB network module was not unpacked: $required"
		fi
	done
	rm -rf -- "$extract_dir"
	if [[ -n "$LVM_MODULE_TREE" ]]; then
		release=$(basename "$LVM_MODULE_TREE")
		for relative in \
			kernel/drivers/md/dm-mod.ko \
			kernel/drivers/md/dm-bio-prison.ko \
			kernel/drivers/md/dm-bufio.ko \
			kernel/drivers/md/persistent-data/dm-persistent-data.ko \
			kernel/drivers/md/dm-thin-pool.ko \
			kernel/drivers/net/mii.ko \
			kernel/drivers/net/usb/r8152.ko \
			kernel/drivers/net/usb/usbnet.ko \
			kernel/drivers/net/usb/cdc_ether.ko \
			kernel/drivers/net/usb/cdc_ncm.ko \
			kernel/drivers/net/usb/asix.ko \
			kernel/drivers/net/usb/ax88179_178a.ko; do
			expected=$(sha256sum "$LVM_MODULE_TREE/$relative" | cut -d ' ' -f1)
			actual=$(zstd -q -dc "$initrd" | cpio -i --to-stdout \
				"lib/modules/$release/$relative" 2>/dev/null | sha256sum | cut -d ' ' -f1)
			[[ "$actual" == "$expected" ]] || {
				rm -f -- "$listing"
				die "initrd early-boot module does not match selected kernel module tree: $relative"
			}
		done
	fi
	rm -f -- "$listing"
	printf 'Installer initrd: Proxmox ISO init and Surface LVM stack detected (%s)\n' "$initrd"
}

append_el2_without_ufs_advanced_entries() {
	local grub_cfg=$1
	[[ -n "$EL2_DTB_WITHOUT_UFS_FILE" ]] || return 0
	python3 - "$grub_cfg" "$EL2_DTB_WITHOUT_UFS_NAME" "$EL2_KERNEL_ARGS" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
dtb_name = sys.argv[2]
kernel_args = sys.argv[3]
if 'module_blacklist=' not in kernel_args:
    kernel_args += ' module_blacklist=ufs_qcom,phy_qcom_qmp_ufs'

lines = path.read_text(encoding='utf-8').splitlines(keepends=True)
start = None
depth = 0
end = None
for index, line in enumerate(lines):
    if start is None:
        if re.match(r"^submenu\s+['\"]Advanced Options['\"]\s*\{", line):
            start = index
            depth = line.count('{') - line.count('}')
        continue
    depth += line.count('{') - line.count('}')
    if depth == 0:
        end = index
        break

if start is None or end is None:
    raise SystemExit('Advanced Options submenu not found')

entries = f"""
    menuentry 'Install Proxmox VE (Graphical, Surface EL2/KVM, without UFS)' --id surface-el2-kvm-without-ufs-graphical --class debian --class gnu-linux --class gnu --class os {{
        echo    'Entering Surface EL2/KVM Secure Launch without UFS ...'
        insmod  chain
        search  --no-floppy --file --set=iso_root /boot/linux26
        insmod part_gpt
        insmod fat
        insmod search_fs_uuid
        unset fat_root
        if search  --no-floppy --fs-uuid --set=fat_root $surface_fat_uuid; then
        set root=$iso_root
        terminal_output console
        if chainloader ($fat_root)/EFI/BOOT/surface-kvm-entry-without-ufs.efi; then
        boot
        else
            echo 'surface-kvm: USB EFI launcher load failed'
        fi
    else
        echo 'surface-kvm: USB EFI UUID not found; launch cancelled'
    fi
    }}

    menuentry 'Install Proxmox VE (Terminal UI, Surface EL2/KVM, without UFS)' --id surface-el2-kvm-without-ufs-terminal --class debian --class gnu-linux --class gnu --class os {{
        set background_color=black
        echo    'Entering Surface EL2/KVM console Secure Launch without UFS ...'
        insmod  chain
        search  --no-floppy --file --set=iso_root /boot/linux26
        insmod part_gpt
        insmod fat
        insmod search_fs_uuid
        unset fat_root
        if search  --no-floppy --fs-uuid --set=fat_root $surface_fat_uuid; then
        set root=$iso_root
        terminal_output console
        if chainloader ($fat_root)/EFI/BOOT/surface-kvm-entry-without-ufs-terminal.efi; then
        boot
        else
            echo 'surface-kvm: USB EFI launcher load failed'
        fi
    else
        echo 'surface-kvm: USB EFI UUID not found; launch cancelled'
    fi
    }}
"""
lines[end:end] = [entries]
path.write_text(''.join(lines), encoding='utf-8')
PY
}

append_el2_grub_entries() {
	local grub_cfg=$1
	local fat_uuid
	fat_uuid=$(blkid -s UUID -o value "$STAGE_DIR/efi.img")
	[[ "$fat_uuid" =~ ^[[:xdigit:]]{4}-[[:xdigit:]]{4}$ ]] || die "Invalid USB EFI UUID"
	# The official GRUB may enter the ISO config without sourcing FAT grub.cfg.
	# Put the USB identity in the actual menu and export it into submenus.
	sed -i "1i set surface_fat_uuid=$fat_uuid\nexport surface_fat_uuid" "$grub_cfg"
	append_el2_without_ufs_advanced_entries "$grub_cfg"

	cat >>"$grub_cfg" <<EOF

# The first-stage official GRUB records the firmware-readable FAT volume
# before it searches the ISO9660 volume.  EFI chainloader cannot load an
# application directly from ISO9660 on this firmware, so the KVM bridge is
# deliberately kept on that FAT volume.
if [ x\${fat_root} = x ]; then
    set fat_root=\$root
fi
set default=surface-el2-kvm-graphical
menuentry 'Install Proxmox VE (Graphical, Surface EL2/KVM)' --id surface-el2-kvm-graphical --class debian --class gnu-linux --class gnu --class os {
	    echo    'Entering Surface EL2/KVM Secure Launch ...'
	    insmod  chain
	    search  --no-floppy --file --set=iso_root /boot/linux26
    insmod part_gpt
    insmod fat
    insmod search_fs_uuid
    unset fat_root
    if search  --no-floppy --fs-uuid --set=fat_root \$surface_fat_uuid; then
    set root=\$iso_root
    terminal_output console
    if chainloader (\$fat_root)/EFI/BOOT/surface-kvm-entry.efi; then
	    boot
        else
            echo 'surface-kvm: USB EFI launcher load failed'
        fi
    else
        echo 'surface-kvm: USB EFI UUID not found; launch cancelled'
    fi
}

menuentry 'Install Proxmox VE (Terminal UI, Surface EL2/KVM)' --id surface-el2-kvm-terminal --class debian --class gnu-linux --class gnu --class os {
	    set background_color=black
	    echo    'Entering Surface EL2/KVM Secure Launch ...'
	    insmod  chain
	    search  --no-floppy --file --set=iso_root /boot/linux26
    insmod part_gpt
    insmod fat
    insmod search_fs_uuid
    unset fat_root
    if search  --no-floppy --fs-uuid --set=fat_root \$surface_fat_uuid; then
    set root=\$iso_root
    terminal_output console
    if chainloader (\$fat_root)/EFI/BOOT/surface-kvm-entry-terminal.efi; then
	    boot
        else
            echo 'surface-kvm: USB EFI launcher load failed'
        fi
    else
        echo 'surface-kvm: USB EFI UUID not found; launch cancelled'
    fi
}
EOF

	if [[ -f "$STAGE_DIR/EFI/BOOT/surface-kvm-shell-bridge.efi" ]]; then
		cat >>"$grub_cfg" <<EOF

menuentry 'Install Proxmox VE (Surface EL2/KVM via EFI Shell)' --id surface-el2-kvm-shell --class debian --class gnu-linux --class gnu --class os {
    echo    'Entering Surface EL2/KVM via EFI Shell ...'
    insmod  chain
    search  --no-floppy --file --set=iso_root /boot/linux26
    insmod part_gpt
    insmod fat
    insmod search_fs_uuid
    unset fat_root
    if search  --no-floppy --fs-uuid --set=fat_root \$surface_fat_uuid; then
    set root=\$iso_root
    terminal_output console
    if chainloader (\$fat_root)/EFI/BOOT/surface-kvm-shell-bridge.efi; then
    boot
        else
            echo 'surface-kvm: USB EFI launcher load failed'
        fi
    else
        echo 'surface-kvm: USB EFI UUID not found; launch cancelled'
    fi
}

menuentry 'Install Proxmox VE (Graphical, EL2/KVM after EFI Shell)' --id surface-el2-kvm-shell-graphical --class debian --class gnu-linux --class gnu --class os {
    echo    'Loading Proxmox VE Installer with EL2 DTB after EFI Shell ...'
    linux   /boot/linux26 ro ramdisk_size=16777216 rw quiet splash=silent $EL2_KERNEL_ARGS
    devicetree /boot/$EL2_DTB_NAME
    initrd  /boot/initrd.img
}

menuentry 'Install Proxmox VE (Terminal UI, EL2/KVM after EFI Shell)' --id surface-el2-kvm-shell-terminal --class debian --class gnu-linux --class gnu --class os {
    set background_color=black
    echo    'Loading Proxmox Console Installer with EL2 DTB after EFI Shell ...'
    gfxpayload=800x600x16,800x600
    linux   /boot/linux26 ro ramdisk_size=16777216 rw quiet splash=silent proxtui $EL2_KERNEL_ARGS
    devicetree /boot/$EL2_DTB_NAME
    initrd  /boot/initrd.img
}
EOF
	fi
}

patch_iso_efi_grub_cfg() {
	local efi_image=$1
	local cfg fat_uuid

	cfg=$(mktemp "$WORK_DIR/iso-efi-grub.XXXXXX")
	mcopy -i "$efi_image" ::/EFI/BOOT/grub.cfg "$cfg" >/dev/null
	fat_uuid=$(blkid -s UUID -o value "$efi_image") || true
	[[ "$fat_uuid" =~ ^[[:xdigit:]-]+$ ]] || {
		rm -f -- "$cfg"
		die "could not read the EFI FAT UUID from $efi_image"
	}
	# Preserve the firmware-readable FAT handle before the config searches for
	# /boot/linux26 on the ISO9660 volume.  EFI LoadImage cannot open an EFI
	# application from ISO9660 on the affected Surface firmware.
	sed -i '1i set fat_root=$root' "$cfg"
	sed -i "1i set surface_fat_uuid=$fat_uuid" "$cfg"
	# The source Proxmox EFI image embeds the UUID of the ISO it was built
	# from.  Rebuilding with xorriso gives the output ISO a new UUID, so the
	# original search can fail and firmware may fall through to the installed
	# PVE entry.  Locate the ISO by its installer kernel instead; that path is
	# unique to the ISO and remains valid across rebuilds and USB devices.
	sed -i -E 's|^search --fs-uuid --set=root .*$|search --no-floppy --file --set=root /boot/linux26|' "$cfg"
	grep -Fq 'search --no-floppy --file --set=root /boot/linux26' "$cfg" || {
		rm -f -- "$cfg"
		die "could not make the embedded EFI GRUB config locate the ISO"
	}
	grep -Fq 'set fat_root=$root' "$cfg" || {
		rm -f -- "$cfg"
		die "could not preserve the FAT EFI handle for KVM chainloading"
	}
	grep -Fq "set surface_fat_uuid=$fat_uuid" "$cfg" || {
		rm -f -- "$cfg"
		die "could not preserve the FAT EFI UUID for KVM chainloading"
	}
	mcopy -i "$efi_image" -o "$cfg" ::/EFI/BOOT/grub.cfg >/dev/null
	rm -f -- "$cfg"
}

remove_existing_el2_grub_entries() {
	local grub_cfg=$1
	python3 - "$grub_cfg" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
entry = re.compile(r"^\s*menuentry\b.*--id\s+['\"]?surface-el2-kvm-(?:graphical|terminal|without-ufs-(?:graphical|terminal)|shell(?:-graphical|-terminal|-linux)?)")
result = []
removed = 0
index = 0
while index < len(lines):
    if not entry.match(lines[index]):
        result.append(lines[index])
        index += 1
        continue

    depth = 0
    while index < len(lines):
        depth += lines[index].count("{") - lines[index].count("}")
        index += 1
        if depth <= 0:
            break
    removed += 1

path.write_text("".join(result), encoding="utf-8")
if removed:
    print(f"removed existing EL2/KVM entries: {removed}")
PY
}

build_standalone_kvm_grub() {
	local mode=$1
	local output=$2
	local payload_mode=${3:-iso}
	local dtb_name=${4:-$EL2_DTB_NAME}
	local kernel_args=${5:-$EL2_KERNEL_ARGS}
	local extra=
	local config="$WORK_DIR/surface-kvm-grub-$mode.cfg"
	local grub_dir=${GRUB_MODULE_DIR:-}
	local modules='efi_gop linux fdt test halt'

	if [[ -z "$grub_dir" ]]; then
		if [[ -f "$STAGE_DIR/boot/grub/arm64-efi/kernel.img" ]]; then
			grub_dir="$STAGE_DIR/boot/grub/arm64-efi"
		else
			grub_dir=/usr/lib/grub/arm64-efi
		fi
	fi
	[[ -f "$grub_dir/kernel.img" && -f "$grub_dir/modinfo.sh" ]] || die "ARM64 GRUB kernel.img not found in $grub_dir (install grub-efi-arm64-bin or set GRUB_MODULE_DIR)"

	if [[ "$mode" == terminal ]]; then
		extra=" proxtui"
	fi

	if [[ "$payload_mode" == fat ]]; then
		modules+=' part_gpt fat regexp reboot sleep'
		cat >"$config" <<EOF
set timeout=0
echo 'surface-kvm: starting USB KVM GRUB'
echo "surface-kvm: prefix=\$prefix cmdpath=\$cmdpath"
set surface_kernel="\$cmdpath/surface-kvm-linux"
set surface_dtb="\$cmdpath/surface-laptop-13-el2.dtb"
set surface_initrd="\$cmdpath/surface-kvm-initrd.img"
if regexp --set=1:surface_usb_device '^(\([^)]*\))' "\$cmdpath"; then
    echo "surface-kvm: USB device=\$surface_usb_device"
if ! [ -s "\$surface_kernel" ]; then
    echo 'surface-kvm: FAT kernel missing or empty'
    halt
fi
if ! [ -s "\$surface_dtb" ]; then
    echo 'surface-kvm: FAT EL2 DTB missing or empty'
    halt
fi
if ! [ -s "\$surface_initrd" ]; then
    echo 'surface-kvm: FAT initramfs missing or empty'
    halt
fi
linux "\$surface_kernel" ro ramdisk_size=16777216 rw quiet splash=silent $kernel_args$extra
devicetree "\$surface_dtb"
initrd "\$surface_initrd"
boot
echo 'surface-kvm: boot returned without starting Linux'
else
    echo 'surface-kvm: current boot path is not a USB FAT device'
fi
echo 'surface-kvm: KVM failed; returning to USB Ready entry in 10 seconds'
sleep 10
reboot
halt
EOF
	else
		modules+=' iso9660 search_fs_file'
		cat >"$config" <<EOF
set timeout=0
insmod iso9660
search --no-floppy --file --set=root /boot/linux26
echo 'Loading Surface EL2/KVM installer ...'
linux /boot/linux26 ro ramdisk_size=16777216 rw quiet splash=silent $kernel_args$extra
devicetree /boot/$dtb_name
initrd /boot/initrd.img
boot
EOF
	fi
	grub-script-check "$config"

	grub-mkstandalone \
		-d "$grub_dir" \
		-O arm64-efi \
		--disable-shim-lock \
		--modules="$modules" \
		-o "$output" \
		"/boot/grub/grub.cfg=$config" >/dev/null
	rm -f -- "$config"
}

build_fatboot_efi_image() {
	local source_image=$1
	local output_image=$2
	local payload_dir cfg grubenv

	payload_dir=$(mktemp -d "$WORK_DIR/fatboot-payload.XXXXXX")
	cfg="$payload_dir/grub.cfg"
	grubenv="$payload_dir/grubenv"
	grub-editenv "$grubenv" create

	# Retain shim. Build the first GRUB with its own menu below: the stock
	# Proxmox GRUB may load /boot/grub instead of the adjacent FAT grub.cfg.
	mcopy -i "$source_image" ::/EFI/BOOT/BOOTAA64.EFI "$payload_dir/BOOTAA64.EFI" >/dev/null
	mcopy -i "$source_image" ::/EFI/BOOT/shimaa64.efi "$payload_dir/shimaa64.efi" >/dev/null
	mcopy -i "$source_image" ::/EFI/BOOT/surface-kvm-entry.efi "$payload_dir/surface-kvm-entry.efi" >/dev/null
	mcopy -i "$source_image" ::/EFI/BOOT/slbounceaa64.efi "$payload_dir/slbounceaa64.efi" >/dev/null
	mcopy -i "$source_image" ::/tcblaunch.exe "$payload_dir/tcblaunch.exe" >/dev/null
	cp -- "$payload_dir/surface-kvm-entry.efi" "$payload_dir/surface-kvm-entry-terminal.efi"
	build_standalone_kvm_grub graphical "$payload_dir/surface-kvm-grubaa64.efi" fat
	build_standalone_kvm_grub terminal "$payload_dir/surface-kvm-grub-terminal.efi" fat

	cat >"$cfg" <<'EOF'
set timeout=10
set default=surface-fat-kvm-graphical
terminal_input console
terminal_output console
insmod part_gpt
insmod fat
insmod chain
insmod loadenv
insmod linux
insmod fdt
echo "surface-kvm: USB boot device cmdpath=$cmdpath"
echo 'Surface USB installer menu v5 - EL2/KVM and Ready'

# Match the installed Surface KVM trial: after handing off to Secure Launch,
# the next USB boot is Ready.  The environment is on the USB FAT volume, so
# this state cannot redirect firmware to the installed internal PVE disk.
if [ -s "$cmdpath/grubenv" ]; then
    load_env -f "$cmdpath/grubenv"
    if [ "$next_entry" = "surface-fat-ready-graphical" ]; then
        set default=surface-fat-ready-graphical
    fi
fi

menuentry 'Install Proxmox VE (Graphical, Surface EL2/KVM, direct FAT)' --id surface-fat-kvm-graphical {
    echo 'Entering Surface EL2/KVM Secure Launch from the USB FAT volume ...'
    set next_entry=surface-fat-ready-graphical
    if save_env -f "$cmdpath/grubenv" next_entry; then
        echo 'surface-kvm: USB Ready fallback armed'
    else
        echo 'surface-kvm: USB Ready fallback could not be saved; continuing'
    fi
    chainloader "$cmdpath/surface-kvm-entry.efi"
    boot
    echo 'surface-kvm: launcher returned; rebooting to USB Ready'
    reboot
}

menuentry 'Install Proxmox VE (Terminal UI, Surface EL2/KVM, direct FAT)' --id surface-fat-kvm-terminal {
    echo 'Entering Surface EL2/KVM Secure Launch from the USB FAT volume ...'
    set next_entry=surface-fat-ready-terminal
    if save_env -f "$cmdpath/grubenv" next_entry; then
        echo 'surface-kvm: USB Ready fallback armed'
    else
        echo 'surface-kvm: USB Ready fallback could not be saved; continuing'
    fi
    chainloader "$cmdpath/surface-kvm-entry-terminal.efi"
    boot
    echo 'surface-kvm: launcher returned; rebooting to USB Ready'
    reboot
}

menuentry 'Install Proxmox VE - Surface Laptop 13 (FUSE/PVE ready)' --id surface-fat-ready-graphical {
    echo 'Loading Surface PVE Ready from the USB FAT volume ...'
    linux "$cmdpath/surface-kvm-linux" ro ramdisk_size=16777216 rw quiet splash=silent
    devicetree "$cmdpath/surface-laptop-13-current.dtb"
    initrd "$cmdpath/surface-kvm-initrd.img"
    boot
}

menuentry 'Install Proxmox VE - Surface Laptop 13 (FUSE/PVE ready, terminal)' --id surface-fat-ready-terminal {
    set background_color=black
    echo 'Loading Surface PVE Ready terminal from the USB FAT volume ...'
    linux "$cmdpath/surface-kvm-linux" ro ramdisk_size=16777216 rw quiet splash=silent proxtui
    devicetree "$cmdpath/surface-laptop-13-current.dtb"
    initrd "$cmdpath/surface-kvm-initrd.img"
    boot
}
EOF
	grub-script-check "$cfg"
	local menu_grub_dir=${GRUB_MODULE_DIR:-$STAGE_DIR/boot/grub/arm64-efi}
	grub-mkstandalone -d "$menu_grub_dir" -O arm64-efi --disable-shim-lock \
		--modules='normal configfile echo test part_gpt fat chain loadenv linux fdt reboot efi_gop' \
		-o "$payload_dir/grubaa64.efi" "/boot/grub/grub.cfg=$cfg"

	log "Building search-free self-contained EFI FAT boot image"
	rm -f -- "$output_image"
	truncate -s "$FAT_BOOT_SIZE" "$output_image"
	MTOOLS_SKIP_CHECK=1 mformat -i "$output_image" -F -v SURFKVM :: >/dev/null
	mmd -i "$output_image" ::/EFI >/dev/null
	mmd -i "$output_image" ::/EFI/BOOT >/dev/null
	mcopy -i "$output_image" -o "$payload_dir/BOOTAA64.EFI" ::/EFI/BOOT/BOOTAA64.EFI >/dev/null
	mcopy -i "$output_image" -o "$payload_dir/shimaa64.efi" ::/EFI/BOOT/shimaa64.efi >/dev/null
	mcopy -i "$output_image" -o "$payload_dir/grubaa64.efi" ::/EFI/BOOT/grubaa64.efi >/dev/null
	mcopy -i "$output_image" -o "$cfg" ::/EFI/BOOT/grub.cfg >/dev/null
	mcopy -i "$output_image" -o "$grubenv" ::/EFI/BOOT/grubenv >/dev/null
	mcopy -i "$output_image" -o "$payload_dir/surface-kvm-entry.efi" ::/EFI/BOOT/surface-kvm-entry.efi >/dev/null
	mcopy -i "$output_image" -o "$payload_dir/surface-kvm-entry-terminal.efi" ::/EFI/BOOT/surface-kvm-entry-terminal.efi >/dev/null
	mcopy -i "$output_image" -o "$payload_dir/slbounceaa64.efi" ::/EFI/BOOT/slbounceaa64.efi >/dev/null
	mcopy -i "$output_image" -o "$payload_dir/surface-kvm-grubaa64.efi" ::/EFI/BOOT/surface-kvm-grubaa64.efi >/dev/null
	mcopy -i "$output_image" -o "$payload_dir/surface-kvm-grub-terminal.efi" ::/EFI/BOOT/surface-kvm-grub-terminal.efi >/dev/null
	mcopy -i "$output_image" -o "$KERNEL_IMAGE" ::/EFI/BOOT/surface-kvm-linux >/dev/null
	mcopy -i "$output_image" -o "$STAGE_DIR/boot/initrd.img" ::/EFI/BOOT/surface-kvm-initrd.img >/dev/null
	mcopy -i "$output_image" -o "$DTB_FILE" ::/EFI/BOOT/surface-laptop-13-current.dtb >/dev/null
	mcopy -i "$output_image" -o "$EL2_DTB_FILE" ::/EFI/BOOT/surface-laptop-13-el2.dtb >/dev/null
	mcopy -i "$output_image" -o "$EL2_DTB_FILE" ::/surface-laptop-13-el2.dtb >/dev/null
	mcopy -i "$output_image" -o "$payload_dir/tcblaunch.exe" ::/tcblaunch.exe >/dev/null

	rm -rf -- "$payload_dir"
}

clear_iso_kvm_bridge() {
	local bridge_dir="$STAGE_DIR/EFI/BOOT"

	rm -f -- \
		"$bridge_dir/surface-kvm-entry.efi" \
		"$bridge_dir/surface-kvm-entry-terminal.efi" \
		"$bridge_dir/surface-kvm-entry-without-ufs.efi" \
		"$bridge_dir/surface-kvm-entry-without-ufs-terminal.efi" \
		"$bridge_dir/surface-kvm-grubaa64.efi" \
		"$bridge_dir/surface-kvm-grub-terminal.efi" \
		"$bridge_dir/surface-kvm-grub-without-ufs.efi" \
		"$bridge_dir/surface-kvm-grub-without-ufs-terminal.efi" \
		"$bridge_dir/surface-kvm-shell.efi" \
		"$bridge_dir/surface-kvm-shell-bridge.efi" \
		"$bridge_dir/slbounceaa64.efi" \
		"$bridge_dir/qebspilaa64.efi" \
		"$bridge_dir/surface-laptop-13-el2.dtb" \
		"$bridge_dir/surface-laptop-13-el2-without-ufs.dtb" \
		"$STAGE_DIR/surface-laptop-13-el2.dtb" \
		"$STAGE_DIR/surface-laptop-13-el2-without-ufs.dtb" \
		"$STAGE_DIR/tcblaunch.exe" \
		"$STAGE_DIR/startup.nsh"
}

install_kvm_iso_bridge() {
	local efi_image=$1
	local bridge_dir="$STAGE_DIR/EFI/BOOT"
	local payload_dir payload_listing

	mkdir -p "$bridge_dir"
	log "Installing ISO EL2/KVM Secure Launch bridge"
	# A rebuild may use an ISO which already contains a partial KVM payload.
	# Remove those files before copying the selected payload so stale Shell or
	# DTB files cannot turn the new ISO into a second, different boot path.
	clear_iso_kvm_bridge
	# The chainloaded launcher sees the ISO filesystem as its device volume.
	# Keep every file it needs on that same filesystem rather than relying on
	# the read-only EFI system image's GRUB environment.
	mcopy -i "$efi_image" ::/EFI/BOOT/surface-kvm-entry.efi \
		"$bridge_dir/surface-kvm-entry.efi"
	if [[ -n "$EL2_DTB_WITHOUT_UFS_FILE" ]]; then
		mcopy -i "$efi_image" ::/EFI/BOOT/surface-kvm-entry-without-ufs.efi \
			"$bridge_dir/surface-kvm-entry-without-ufs.efi"
	fi
	mcopy -i "$efi_image" ::/EFI/BOOT/slbounceaa64.efi \
		"$bridge_dir/slbounceaa64.efi"
	mcopy -i "$efi_image" ::/tcblaunch.exe "$STAGE_DIR/tcblaunch.exe"
	cp --preserve=mode,timestamps "$EL2_DTB_FILE" \
		"$STAGE_DIR/surface-laptop-13-el2.dtb"
	# Keep the same DTB beside the EFI bridge too.  This is needed by
	# standalone GRUB variants that load their payload relative to $cmdpath,
	# and avoids leaving an older DTB in EFI/BOOT when an existing stage is
	# reused.
	cp --preserve=mode,timestamps "$EL2_DTB_FILE" \
		"$bridge_dir/surface-laptop-13-el2.dtb"
	if [[ -n "$EL2_DTB_WITHOUT_UFS_FILE" ]]; then
		cp --preserve=mode,timestamps "$EL2_DTB_WITHOUT_UFS_FILE" \
			"$STAGE_DIR/surface-laptop-13-el2-without-ufs.dtb"
		cp --preserve=mode,timestamps "$EL2_DTB_WITHOUT_UFS_FILE" \
			"$bridge_dir/surface-laptop-13-el2-without-ufs.dtb"
	fi

	# qebspil and its firmware are optional, but when the supplied EFI image
	# contains them the ISO bridge must carry them on the same ISO filesystem.
	# The launcher starts qebspil from that filesystem after it has installed
	# the EL2 DTB; relying on the El Torito FAT image alone does not work for
	# an application chainloaded from ISO9660.
	payload_dir=$(mktemp -d "$WORK_DIR/iso-kvm-payload.XXXXXX")
	payload_listing=$(mktemp "$WORK_DIR/iso-kvm-payload-list.XXXXXX")
	7z l -slt "$efi_image" >"$payload_listing"
	if grep -Fq 'Path = EFI/BOOT/qebspilaa64.efi' "$payload_listing"; then
		7z x -y -o"$payload_dir" "$efi_image" 'EFI/BOOT/qebspilaa64.efi' >/dev/null
		cp --preserve=mode,timestamps "$payload_dir/EFI/BOOT/qebspilaa64.efi" \
			"$bridge_dir/qebspilaa64.efi"
	fi
	if grep -Fq 'Path = firmware' "$payload_listing"; then
		7z x -y -o"$payload_dir" "$efi_image" 'firmware/*' >/dev/null
		mkdir -p "$STAGE_DIR/firmware"
		cp -a "$payload_dir/firmware/." "$STAGE_DIR/firmware/"
	fi
	if grep -Fq 'Path = EFI/BOOT/surface-kvm-shell.efi' "$payload_listing"; then
		7z x -y -o"$payload_dir" "$efi_image" 'EFI/BOOT/surface-kvm-shell.efi' >/dev/null
		cp --preserve=mode,timestamps "$payload_dir/EFI/BOOT/surface-kvm-shell.efi" \
			"$bridge_dir/surface-kvm-shell.efi"
	fi
	if grep -Fq 'Path = EFI/BOOT/surface-kvm-shell-bridge.efi' "$payload_listing"; then
		7z x -y -o"$payload_dir" "$efi_image" 'EFI/BOOT/surface-kvm-shell-bridge.efi' >/dev/null
		cp --preserve=mode,timestamps "$payload_dir/EFI/BOOT/surface-kvm-shell-bridge.efi" \
			"$bridge_dir/surface-kvm-shell-bridge.efi"
	fi
	if grep -Fq 'Path = startup.nsh' "$payload_listing"; then
		7z x -y -o"$payload_dir" "$efi_image" 'startup.nsh' >/dev/null
		cp --preserve=mode,timestamps "$payload_dir/startup.nsh" \
			"$STAGE_DIR/startup.nsh"
	fi
	rm -f -- "$payload_listing"
	rm -rf -- "$payload_dir"

	# The loader chooses the terminal image from its own chainloader filename.
	cp --preserve=mode,timestamps "$bridge_dir/surface-kvm-entry.efi" \
		"$bridge_dir/surface-kvm-entry-terminal.efi"
	if [[ -n "$EL2_DTB_WITHOUT_UFS_FILE" ]]; then
		cp --preserve=mode,timestamps "$bridge_dir/surface-kvm-entry-without-ufs.efi" \
			"$bridge_dir/surface-kvm-entry-without-ufs-terminal.efi"
	fi
	build_standalone_kvm_grub graphical \
		"$bridge_dir/surface-kvm-grubaa64.efi"
	build_standalone_kvm_grub terminal \
		"$bridge_dir/surface-kvm-grub-terminal.efi"
	if [[ -n "$EL2_DTB_WITHOUT_UFS_FILE" ]]; then
		build_standalone_kvm_grub graphical \
			"$bridge_dir/surface-kvm-grub-without-ufs.efi" iso \
			"$EL2_DTB_WITHOUT_UFS_NAME" \
			"$EL2_KERNEL_ARGS module_blacklist=ufs_qcom,phy_qcom_qmp_ufs"
		build_standalone_kvm_grub terminal \
			"$bridge_dir/surface-kvm-grub-without-ufs-terminal.efi" iso \
			"$EL2_DTB_WITHOUT_UFS_NAME" \
			"$EL2_KERNEL_ARGS module_blacklist=ufs_qcom,phy_qcom_qmp_ufs"
	fi

	# EFI LoadImage cannot open an EFI application from the ISO9660 volume on
	# the affected Surface firmware.  Keep the Secure Launch bridge and its
	# small GRUB/DTB payload on the firmware-readable El Torito FAT volume.  The
	# standalone GRUB then searches the ISO for /boot/linux26 and initrd.img,
	# while the launcher itself sees exactly one complete payload volume.
	local fat_path fat_image="$STAGE_DIR/efi.img"
	for fat_path in \
		::/EFI/BOOT/surface-kvm-entry.efi \
		::/EFI/BOOT/surface-kvm-entry-terminal.efi \
		::/EFI/BOOT/surface-kvm-entry-without-ufs.efi \
		::/EFI/BOOT/surface-kvm-entry-without-ufs-terminal.efi \
		::/EFI/PROXMOX/surface-kvm-entry.efi \
		::/EFI/PROXMOX/surface-kvm-entry-without-ufs.efi \
		::/EFI/BOOT/surface-kvm-grubaa64.efi \
		::/EFI/BOOT/surface-kvm-grub-terminal.efi \
		::/EFI/BOOT/surface-kvm-grub-without-ufs.efi \
		::/EFI/BOOT/surface-kvm-grub-without-ufs-terminal.efi \
		::/EFI/BOOT/slbounceaa64.efi \
		::/EFI/BOOT/qebspilaa64.efi \
		::/EFI/BOOT/surface-kvm-shell.efi \
		::/EFI/BOOT/surface-kvm-shell-bridge.efi \
		::/EFI/BOOT/surface-laptop-13-el2.dtb \
		::/EFI/BOOT/surface-laptop-13-el2-without-ufs.dtb \
		::/surface-laptop-13-el2.dtb \
		::/surface-laptop-13-el2-without-ufs.dtb \
		::/tcblaunch.exe \
		::/startup.nsh; do
		mdel -i "$fat_image" "$fat_path" >/dev/null 2>&1 || true
	done
	for payload in \
		'surface-kvm-entry.efi::/EFI/BOOT/surface-kvm-entry.efi' \
		'surface-kvm-entry-terminal.efi::/EFI/BOOT/surface-kvm-entry-terminal.efi' \
		'surface-kvm-grubaa64.efi::/EFI/BOOT/surface-kvm-grubaa64.efi' \
		'surface-kvm-grub-terminal.efi::/EFI/BOOT/surface-kvm-grub-terminal.efi' \
		'slbounceaa64.efi::/EFI/BOOT/slbounceaa64.efi' \
		'surface-laptop-13-el2.dtb::/surface-laptop-13-el2.dtb' \
		'surface-laptop-13-el2.dtb::/EFI/BOOT/surface-laptop-13-el2.dtb' \
		'tcblaunch.exe::/tcblaunch.exe'; do
		local source=${payload%%::*} destination=${payload#*::}
		case "$source" in
			surface-kvm-entry*) source="$bridge_dir/$source" ;;
			surface-kvm-grub*) source="$bridge_dir/$source" ;;
			surface-laptop-13-el2*) source="$bridge_dir/$source" ;;
			slbounceaa64.efi) source="$bridge_dir/$source" ;;
			tcblaunch.exe) source="$STAGE_DIR/$source" ;;
		esac
		[[ -f "$source" ]] || die "FAT KVM payload source is missing: $source"
		mcopy -i "$fat_image" -o "$source" "::$destination" >/dev/null
	done
	if [[ -n "$EL2_DTB_WITHOUT_UFS_FILE" ]]; then
		for payload in \
			'surface-kvm-entry-without-ufs.efi::/EFI/BOOT/surface-kvm-entry-without-ufs.efi' \
			'surface-kvm-entry-without-ufs-terminal.efi::/EFI/BOOT/surface-kvm-entry-without-ufs-terminal.efi' \
			'surface-kvm-grub-without-ufs.efi::/EFI/BOOT/surface-kvm-grub-without-ufs.efi' \
			'surface-kvm-grub-without-ufs-terminal.efi::/EFI/BOOT/surface-kvm-grub-without-ufs-terminal.efi' \
			'surface-laptop-13-el2-without-ufs.dtb::/surface-laptop-13-el2-without-ufs.dtb' \
			'surface-laptop-13-el2-without-ufs.dtb::/EFI/BOOT/surface-laptop-13-el2-without-ufs.dtb'; do
			local source=${payload%%::*} destination=${payload#*::}
			case "$source" in
				surface-kvm-entry*|surface-kvm-grub*|surface-laptop-13-el2*) source="$bridge_dir/$source" ;;
			esac
			[[ -f "$source" ]] || die "FAT without-UFS payload source is missing: $source"
			mcopy -i "$fat_image" -o "$source" "::$destination" >/dev/null
		done
	fi
	# Remove the duplicate ISO-side launcher payload after it has been copied
	# to FAT.  The kernel, initramfs, and installer DTBs remain under /boot on
	# ISO9660 for the standalone GRUB loaded from the FAT bridge.
	clear_iso_kvm_bridge
}

augment_initrd_with_modules() {
	local initrd="$1"
	local module_base="$WORK_DIR/modules/lib/modules"
	local module_dir release
	local base_initrd augmented manifest compressed
	shopt -s nullglob
	local module_dirs=("$module_base"/*)
	shopt -u nullglob
	(( ${#module_dirs[@]} == 1 )) || die "expected one built module release below $module_base"
	module_dir=${module_dirs[0]}
	release=$(basename "$module_dir")

	base_initrd=$(mktemp "$WORK_DIR/proxmox-initrd-base.XXXXXX.img")
	augmented=$(mktemp "$WORK_DIR/proxmox-initrd-augmented.XXXXXX.img")
	manifest=$(mktemp "$WORK_DIR/proxmox-initrd-modules.XXXXXX.manifest")
	compressed=$(mktemp "$WORK_DIR/proxmox-initrd-compressed.XXXXXX.img")
	# mktemp creates the output names; the helper intentionally opens its target
	# with O_EXCL, so remove only these task-specific temporary files first.
	rm -f -- "$base_initrd" "$augmented" "$compressed"

	log "Adding Surface kernel modules to Proxmox initrd"
	if zstd -t "$initrd" >/dev/null 2>&1; then
		zstd -q -dc "$initrd" | gzip -n -9 >"$base_initrd"
	elif gzip -t "$initrd" >/dev/null 2>&1; then
		gzip -dc "$initrd" | gzip -n -9 >"$base_initrd"
	else
		die "unsupported initrd compression: $initrd (expected zstd or gzip)"
	fi

	: >"$manifest"
	while IFS= read -r -d '' module; do
		local relative=${module#"$module_dir"/}
		printf 'lib/modules/%s/%s %s 0644\n' "$release" "$relative" "$module" >>"$manifest"
	done < <(find "$module_dir" -type f -print0 | sort -z)
	if [[ -n "$WCN7850_FIRMWARE_SOURCE" ]]; then
		local wifi_firmware wifi_relative
		while IFS= read -r -d '' wifi_firmware; do
			wifi_relative=${wifi_firmware#"$WCN7850_FIRMWARE_SOURCE"/}
			printf 'lib/firmware/ath12k/WCN7850/hw2.0/%s %s 0644\n' \
				"$wifi_relative" "$wifi_firmware" >>"$manifest"
		done < <(find "$WCN7850_FIRMWARE_SOURCE" -type f -print0 | sort -z)
	fi
	python3 "$ROOT_DIR/initramfs/scripts/augment-newc-initramfs.py" \
		"$base_initrd" "$augmented" "$manifest"
	# The augmentation helper emits gzip-compressed newc. Recompress the cpio
	# payload itself so the result has exactly one initramfs compressor.
	gzip -dc "$augmented" | zstd -q -T0 -19 -f -o "$compressed"
	mv -- "$compressed" "$initrd"
	zstd -q -dc "$initrd" | cpio -it --quiet >/dev/null
	rm -f -- "$base_initrd" "$augmented" "$manifest"
}

rebuild_iso() {
	local input_iso=$1
	local output_iso=$2
	local stage=$3
	local volume_id
	volume_id=$(xorriso -indev "$input_iso" -pvd_info 2>/dev/null |
		sed -n 's/^Volume id[[:space:]]*:[[:space:]]*//p' | head -n 1)
	[[ -n "$volume_id" ]] || volume_id=PVE

	log "Rebuilding bootable ISO"
	# Generate GPT from the new EFI image layout. Copying the input system
	# area with -G retains stale ESP LBAs and sizes when efi.img moves/grows.
	xorriso -as mkisofs \
		-V "$volume_id" \
		--protective-msdos-label \
		-partition_cyl_align off \
		-efi-boot-part --efi-boot-image \
		-c /boot/boot.cat \
		-e /efi.img \
		-no-emul-boot \
		-boot-load-size 16384 \
		-o "$output_iso" \
		"$stage"
}

verify_iso() {
	local output_iso=$1
	local dtb_path=$2
	local el2_dtb_path=${3:-}
	local el2_dtb_without_ufs_path=${4:-}
	local listing efi_image efi_listing efi_cfg boot_hash shim_hash required
	local xorriso_input=$output_iso
	[[ -s "$output_iso" ]] || die "output ISO was not created: $output_iso"
	# xorriso treats paths below /dev as possible device nodes.  The build
	# output may intentionally live in /dev/shm when the root filesystem is
	# full, so explicitly select its regular-file stdio backend.
	if [[ "$output_iso" == /dev/* ]]; then
		xorriso_input="stdio:$output_iso"
	fi
	listing=$(mktemp "$WORK_DIR/iso-list.XXXXXX")
	7z l -slt "$output_iso" >"$listing"
	grep -Fq "Path = boot/linux26" "$listing" || die "patched kernel is missing from output ISO"
	grep -Fq "Path = boot/initrd.img" "$listing" || die "installer initrd is missing from output ISO"
	grep -Fq "Path = boot/$dtb_path" "$listing" || die "Surface DTB is missing from output ISO"
	if [[ -n "$el2_dtb_path" ]]; then
		grep -Fq "Path = boot/$el2_dtb_path" "$listing" || die "EL2 DTB is missing from output ISO"
		if [[ -n "$el2_dtb_without_ufs_path" ]]; then
			grep -Fq "Path = boot/$el2_dtb_without_ufs_path" "$listing" ||
				die "UFS-disabled EL2 DTB is missing from output ISO"
		fi
		efi_image=$(mktemp "$WORK_DIR/iso-efi.XXXXXX.img")
		efi_listing=$(mktemp "$WORK_DIR/iso-efi-list.XXXXXX")
		efi_cfg=$(mktemp "$WORK_DIR/iso-efi-grub-list.XXXXXX")
		7z e -so "$output_iso" efi.img >"$efi_image" || die "cannot extract output ISO EFI image"
		python3 "$ROOT_DIR/tools/verify-iso-esp.py" "$output_iso" "$efi_image"
		7z l -slt "$efi_image" >"$efi_listing"
		7z e -so "$efi_image" EFI/BOOT/grub.cfg >"$efi_cfg" || die "output ISO EFI GRUB config is missing"
		if [[ "$FAT_BOOT" -eq 1 ]]; then
			7z e -so "$efi_image" EFI/BOOT/grubaa64.efi | python3 -c \
				'import sys; data=sys.stdin.buffer.read(); sys.exit(0 if b"Surface USB installer menu v5" in data and b"menuentry" in data and b"surface-fat-kvm-graphical" in data else 1)' ||
				die "first-stage GRUB does not embed the USB KVM menu"
			for required in \
				EFI/BOOT/surface-kvm-entry.efi \
				EFI/BOOT/surface-kvm-grubaa64.efi \
				EFI/BOOT/surface-kvm-linux \
				EFI/BOOT/surface-kvm-initrd.img \
				EFI/BOOT/surface-laptop-13-current.dtb \
				EFI/BOOT/surface-laptop-13-el2.dtb \
				EFI/BOOT/slbounceaa64.efi \
				tcblaunch.exe; do
				grep -Fqi "Path = $required" "$efi_listing" || die "search-free EFI FAT payload is missing $required"
			done
			grep -Fq 'surface-fat-kvm-graphical' "$efi_cfg" || die "search-free EFI FAT menu is missing"
			if grep -Eq '^[[:space:]]*search([[:space:]]|$)' "$efi_cfg"; then
				die "search-free EFI FAT menu still scans disks"
			fi
			if grep -Eiq '^Path = EFI/BOOT/(surface-kvm-entry|surface-kvm-grub|slbounce)' "$listing"; then
				die "search-free ISO contains a duplicate KVM payload outside efi.img"
			fi
		else
			for required in \
				EFI/BOOT/surface-kvm-entry.efi \
				EFI/BOOT/surface-kvm-entry-terminal.efi \
				EFI/BOOT/surface-kvm-grubaa64.efi \
				EFI/BOOT/surface-kvm-grub-terminal.efi \
				EFI/BOOT/slbounceaa64.efi \
				EFI/BOOT/surface-laptop-13-el2.dtb \
				surface-laptop-13-el2.dtb \
				tcblaunch.exe; do
				grep -Fqi "Path = $required" "$efi_listing" || die "EFI FAT KVM payload is missing $required"
			done
			if [[ -n "$el2_dtb_without_ufs_path" ]]; then
				grep -Fqi "Path = EFI/BOOT/surface-kvm-entry-without-ufs.efi" "$efi_listing" ||
					die "without-UFS EL2/KVM bridge launcher is missing from output ISO"
				grep -Fqi "Path = EFI/BOOT/surface-kvm-grub-without-ufs.efi" "$efi_listing" ||
					die "without-UFS EL2/KVM standalone GRUB is missing from output ISO"
				grep -Fqi "Path = EFI/BOOT/surface-kvm-entry-without-ufs-terminal.efi" "$efi_listing" ||
					die "without-UFS terminal bridge launcher is missing from output ISO"
				grep -Fqi "Path = EFI/BOOT/surface-kvm-grub-without-ufs-terminal.efi" "$efi_listing" ||
					die "without-UFS terminal standalone GRUB is missing from output ISO"
				grep -Fqi "Path = EFI/BOOT/surface-laptop-13-el2-without-ufs.dtb" "$efi_listing" ||
					die "without-UFS DTB is missing from output ISO EFI FAT image"
				grep -Fqi "Path = surface-laptop-13-el2-without-ufs.dtb" "$efi_listing" ||
					die "without-UFS root DTB is missing from output ISO EFI FAT image"
			fi
			grep -Fq 'search --no-floppy --file --set=root /boot/linux26' "$efi_cfg" ||
				die "output ISO EFI GRUB config still uses a stale filesystem UUID"
			if grep -Eiq '^Path = (EFI/(BOOT|PROXMOX)/.*(surface-kvm|slbounce|surface-laptop-13-el2)|surface-laptop-13-el2\.dtb|tcblaunch\.exe|startup\.nsh)' "$listing"; then
				die "output ISO9660 image still contains a duplicate Surface KVM payload"
			fi
		fi
		boot_hash=$(7z e -so "$efi_image" EFI/BOOT/BOOTAA64.EFI 2>/dev/null | sha256sum | cut -d ' ' -f1)
		shim_hash=$(7z e -so "$efi_image" EFI/BOOT/shimaa64.efi 2>/dev/null | sha256sum | cut -d ' ' -f1)
		[[ -n "$boot_hash" && "$boot_hash" == "$shim_hash" ]] || die "output ISO default EFI is not the normal Proxmox shim"
		rm -f -- "$efi_image" "$efi_listing" "$efi_cfg"
	fi
	xorriso -indev "$xorriso_input" -report_el_torito as_mkisofs >/dev/null
	rm -f -- "$listing"
}

main() {
	parse_args "$@"
	need xorriso
	need 7z
	need cpio
	need unsquashfs
	need python3
	need sed
	need grep
	need file
	need blkid
	need mcopy
	if [[ -n "$NETWORK_MANAGER_PACKAGE_DIR" ]]; then
		need dpkg-deb
		need mksquashfs
	fi
	if [[ "$FAT_BOOT" -eq 1 ]]; then
		need mformat
		need mmd
		need truncate
		need grub-editenv
	fi
	if [[ -n "$EL2_DTB_FILE" ]]; then
		need mdel
		need grub-mkstandalone
		need grub-script-check
		need sha256sum
	fi
	if [[ -n "$LVM_MODULE_TREE" ]]; then
		need sha256sum
	fi

	if [[ "$WORK_DIR" == "$DEFAULT_WORK_DIR" ]]; then
		WORK_DIR="$OUTPUT_DIR/.work"
	fi
	if [[ "$KERNEL_IMAGE" == "$DEFAULT_KERNEL_IMAGE" ]]; then
		KERNEL_IMAGE="$WORK_DIR/kernel/Image"
	fi
	if [[ "$DTB_FILE" == "$DEFAULT_DTB_FILE" ]]; then
		DTB_FILE="$WORK_DIR/dtb/surface-laptop-13-current.dtb"
	fi
	if [[ "$OUTPUT_ISO" == "$DEFAULT_OUTPUT_ISO" ]]; then
		OUTPUT_ISO="$OUTPUT_DIR/proxmox-ve_9.2-1-arm64-surface.iso"
	fi

	INPUT_ISO=$(absolute_path "$INPUT_ISO")
	OUTPUT_ISO=$(absolute_path "$OUTPUT_ISO")
	OUTPUT_DIR=$(absolute_path "$OUTPUT_DIR")
	WORK_DIR=$(absolute_path "$WORK_DIR")
	KERNEL_SOURCE=$(absolute_path "$KERNEL_SOURCE")
	KERNEL_IMAGE=$(absolute_path "$KERNEL_IMAGE")
	DTB_FILE=$(absolute_path "$DTB_FILE")
	if [[ -n "$GRUB_MODULE_DIR" ]]; then
		GRUB_MODULE_DIR=$(absolute_path "$GRUB_MODULE_DIR")
	fi
	if [[ -n "$INITRD_FILE" ]]; then
		INITRD_FILE=$(absolute_path "$INITRD_FILE")
	fi
	if [[ -n "$LVM_MODULE_TREE" ]]; then
		LVM_MODULE_TREE=$(absolute_path "$LVM_MODULE_TREE")
	fi
	if [[ -n "$WCN7850_FIRMWARE_SOURCE" ]]; then
		WCN7850_FIRMWARE_SOURCE=$(absolute_path "$WCN7850_FIRMWARE_SOURCE")
	fi
	if [[ -n "$NETWORK_MANAGER_PACKAGE_DIR" ]]; then
		NETWORK_MANAGER_PACKAGE_DIR=$(absolute_path "$NETWORK_MANAGER_PACKAGE_DIR")
	fi
	if [[ -n "$LVM_MODULE_TREE" ]]; then
		[[ -d "$LVM_MODULE_TREE" ]] || die "LVM module tree not found: $LVM_MODULE_TREE"
		[[ "$(basename "$LVM_MODULE_TREE")" == *surface-laptop-13* ]] ||
			die "LVM module tree release is not for Surface Laptop 13: $LVM_MODULE_TREE"
	fi
	if [[ -n "$EFI_IMAGE" ]]; then
		EFI_IMAGE=$(absolute_path "$EFI_IMAGE")
	fi
	if [[ -n "$EL2_DTB_FILE" ]]; then
		EL2_DTB_FILE=$(absolute_path "$EL2_DTB_FILE")
	fi
	if [[ -n "$EL2_DTB_WITHOUT_UFS_FILE" ]]; then
		EL2_DTB_WITHOUT_UFS_FILE=$(absolute_path "$EL2_DTB_WITHOUT_UFS_FILE")
	fi

	[[ -f "$INPUT_ISO" ]] || die "input ISO not found: $INPUT_ISO"
	[[ "$INPUT_ISO" != "$OUTPUT_ISO" ]] || die "input and output ISO must be different files"
	[[ "$DTB_NAME" != */* && "$DTB_NAME" != "" ]] || die "--dtb-name must be a file name without '/': $DTB_NAME"
	[[ "$EL2_DTB_NAME" != */* && "$EL2_DTB_NAME" != "" ]] || die "--el2-dtb-name must be a file name without '/': $EL2_DTB_NAME"
	[[ "$EL2_DTB_WITHOUT_UFS_NAME" != */* && "$EL2_DTB_WITHOUT_UFS_NAME" != "" ]] ||
		die "--el2-dtb-without-ufs-name must be a file name without '/': $EL2_DTB_WITHOUT_UFS_NAME"
	if [[ "$FAT_BOOT" -eq 1 ]]; then
		[[ -n "$EL2_DTB_FILE" && -n "$EFI_IMAGE" ]] || die "--fat-boot requires --el2-dtb and --efi-image"
		[[ "$FAT_BOOT_SIZE" =~ ^[0-9]+$ && "$FAT_BOOT_SIZE" -ge 167772160 ]] ||
			die "FAT_BOOT_SIZE must be at least 167772160 bytes"
	fi
	if [[ -n "$INITRD_FILE" ]]; then
		[[ -f "$INITRD_FILE" ]] || die "initrd not found: $INITRD_FILE"
	fi
	if [[ -n "$WCN7850_FIRMWARE_SOURCE" ]]; then
		[[ -d "$WCN7850_FIRMWARE_SOURCE" ]] || die "WCN7850 firmware directory not found: $WCN7850_FIRMWARE_SOURCE"
		for firmware in amss.bin m3.bin board-2.bin; do
			[[ -f "$WCN7850_FIRMWARE_SOURCE/$firmware" ]] ||
				die "WCN7850 firmware missing: $WCN7850_FIRMWARE_SOURCE/$firmware"
		done
	fi
	if [[ -n "$EFI_IMAGE" ]]; then
		[[ -f "$EFI_IMAGE" ]] || die "EFI image not found: $EFI_IMAGE"
	fi
	if [[ -n "$EL2_DTB_FILE" ]]; then
		[[ -f "$EL2_DTB_FILE" ]] || die "EL2 DTB not found: $EL2_DTB_FILE"
		# Reject the generic DSP-enabled tree that regressed v19 on Surface.
		for node in /soc@0/remoteproc@6800000 /soc@0/remoteproc@32300000 /sound; do
			[[ $(fdtget "$EL2_DTB_FILE" "$node" status) == disabled ]] ||
				die "Surface EL2 DTB must disable $node (DSP/SMMU boot regression)"
		done
		[[ -n "$EFI_IMAGE" ]] || die "--efi-image is required with --el2-dtb (it supplies the Secure Launch bridge)"
		verify_efi_tcb "$EFI_IMAGE"
		verify_efi_slbounce "$EFI_IMAGE"
		verify_efi_default_shim "$EFI_IMAGE"
	fi
	if [[ -n "$EL2_DTB_WITHOUT_UFS_FILE" ]]; then
		[[ -n "$EL2_DTB_FILE" ]] || die "--el2-dtb-without-ufs requires --el2-dtb"
		[[ -f "$EL2_DTB_WITHOUT_UFS_FILE" ]] ||
			die "UFS-disabled EL2 DTB not found: $EL2_DTB_WITHOUT_UFS_FILE"
	fi

	mkdir -p "$OUTPUT_DIR" "$WORK_DIR"
	build_missing_components
	[[ -f "$KERNEL_IMAGE" ]] || die "kernel image not found after build: $KERNEL_IMAGE"
	[[ -f "$DTB_FILE" ]] || die "DTB not found after build: $DTB_FILE"
	file "$KERNEL_IMAGE" | grep -Eiq 'ARM|aarch64' || die "kernel does not look like an ARM64 image: $KERNEL_IMAGE"

	STAGE_DIR=$(mktemp -d "$WORK_DIR/proxmox-iso.XXXXXX")
	log "Extracting Proxmox ISO"
	xorriso -osirrox on -indev "$INPUT_ISO" -extract / "$STAGE_DIR"
	[[ -f "$STAGE_DIR/boot/grub/grub.cfg" ]] || die "Proxmox GRUB config not found in extracted ISO"
	[[ -f "$STAGE_DIR/efi.img" ]] || die "EFI boot image not found in extracted ISO"
	# xorriso preserves ISO read-only mode bits.  The stage is disposable, so
	# make it writable before replacing boot components or GRUB configuration.
	chmod -R u+rwX -- "$STAGE_DIR"
	add_network_manager_packages
	augment_proxmox_installer_squashfs
	verify_proxmox_installer_squashfs

	log "Installing Surface kernel and DTB into ISO"
	cp --preserve=mode,timestamps "$KERNEL_IMAGE" "$STAGE_DIR/boot/linux26"
	cp --preserve=mode,timestamps "$DTB_FILE" "$STAGE_DIR/boot/$DTB_NAME"
	if [[ -n "$EL2_DTB_FILE" ]]; then
		cp --preserve=mode,timestamps "$EL2_DTB_FILE" "$STAGE_DIR/boot/$EL2_DTB_NAME"
	fi
	if [[ -n "$EL2_DTB_WITHOUT_UFS_FILE" ]]; then
		cp --preserve=mode,timestamps "$EL2_DTB_WITHOUT_UFS_FILE" \
			"$STAGE_DIR/boot/$EL2_DTB_WITHOUT_UFS_NAME"
	fi
	if [[ -n "$EFI_IMAGE" ]]; then
		cp --preserve=mode,timestamps "$EFI_IMAGE" "$STAGE_DIR/efi.img"
	fi
	if [[ "$FAT_BOOT" -eq 0 ]]; then
		patch_iso_efi_grub_cfg "$STAGE_DIR/efi.img"
	fi
	if [[ -n "$EL2_DTB_FILE" && "$FAT_BOOT" -eq 0 ]]; then
		install_kvm_iso_bridge "$EFI_IMAGE"
	fi
	if [[ -n "$INITRD_FILE" ]]; then
		cp --preserve=mode,timestamps "$INITRD_FILE" "$STAGE_DIR/boot/initrd.img"
	fi
	if [[ "$INCLUDE_MODULES" -eq 1 ]]; then
		augment_initrd_with_modules "$STAGE_DIR/boot/initrd.img"
	fi
	patch_proxmox_initrd_lvm "$STAGE_DIR/boot/initrd.img"
	verify_proxmox_installer_initrd "$STAGE_DIR/boot/initrd.img"
	patch_grub_config "$STAGE_DIR/boot/grub/grub.cfg" "$DTB_NAME"
	if [[ -n "$EL2_DTB_FILE" ]]; then
		remove_existing_el2_grub_entries "$STAGE_DIR/boot/grub/grub.cfg"
		if [[ "$FAT_BOOT" -eq 0 ]]; then
			append_el2_grub_entries "$STAGE_DIR/boot/grub/grub.cfg"
		fi
	fi
	if [[ "$FAT_BOOT" -eq 1 ]]; then
		clear_iso_kvm_bridge
		build_fatboot_efi_image "$EFI_IMAGE" "$STAGE_DIR/efi.img"
	fi

	rm -f -- "$OUTPUT_ISO"
	rebuild_iso "$INPUT_ISO" "$OUTPUT_ISO" "$STAGE_DIR"
	verify_iso "$OUTPUT_ISO" "$DTB_NAME" "${EL2_DTB_FILE:+$EL2_DTB_NAME}" \
		"${EL2_DTB_WITHOUT_UFS_FILE:+$EL2_DTB_WITHOUT_UFS_NAME}"
	printf '\nPatched ISO: %s\n' "$OUTPUT_ISO"
	file "$OUTPUT_ISO"
}

main "$@"
