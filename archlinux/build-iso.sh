#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# The scratch directory is deliberately outside the repository by default.
# A full Arch Linux ARM rootfs, the kernel build, and archiso's work tree are
# all several GiB larger than the checked-in source.
BUILD_DIR=${ARCHLINUX_BUILD_DIR:-${RUNNER_TEMP:-/tmp}/surface-laptop-13-archlinux}
OUTPUT_DIR=${ARCHLINUX_OUTPUT_DIR:-$ROOT_DIR/build/archlinux}
ARCHLINUX_ROOTFS_URL=${ARCHLINUX_ROOTFS_URL:-https://ca.us.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}
ARCHLINUX_MIRROR=${ARCHLINUX_MIRROR:-'https://ca.us.mirror.archlinuxarm.org/$arch'}
ARCHISO_REF=${ARCHISO_REF:-v90}
LINUX_FIRMWARE_REVISION=${LINUX_FIRMWARE_REVISION:-e981caea6ed33c48d25b7dbf473327dbd01df163}
LINUX_FIRMWARE_BASE_URL=${LINUX_FIRMWARE_BASE_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain}
WCN7850_FIRMWARE_SOURCE=${WCN7850_FIRMWARE_SOURCE:-}
WCN7850_FIRMWARE_URL=${WCN7850_FIRMWARE_URL:-}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(date +%s)}
DEFAULT_WCN7850_FIRMWARE_SOURCE="$ROOT_DIR/build/archlinux-reference/surface-pve-wifi-reference.tar.gz"

ROOTFS_DIR="$BUILD_DIR/rootfs"
SHARED_DIR="$BUILD_DIR/shared"
ARCHISO_SOURCE_DIR="$SHARED_DIR/archiso-source"
PROFILE_DIR="$SHARED_DIR/profile"
ARCHISO_OUT_DIR="$SHARED_DIR/out"
KERNEL_SOURCE_DIR="$SHARED_DIR/linux"
SURFACE_OUTPUT_DIR="$SHARED_DIR/surface"
SURFACE_WORK_DIR="$SHARED_DIR/surface-work"
ROOTFS_ARCHIVE="$BUILD_DIR/ArchLinuxARM-aarch64-latest.tar.gz"
ROOTFS_MD5_FILE="$BUILD_DIR/ArchLinuxARM-aarch64-latest.tar.gz.md5"
FIRMWARE_DIR="$SHARED_DIR/firmware"
KERNEL_BUILTIN_FIRMWARE_DIR="$SHARED_DIR/kernel-firmware"

DEFAULT_LINUX_FIRMWARE_REVISION=e981caea6ed33c48d25b7dbf473327dbd01df163
declare -A FIRMWARE_SHA256=(
	["qca/hmtbtfw20.tlv"]=f1c00f4640a5c4e5dc36a2574d3d1d0afcfd1ab58a84f217dce4b1bb73cba981
	["qca/hmtnv20.b10f"]=f8d027c5f0ea54456d23b903c55e1a87b06df97ff26b83e3fd02ac6b265b5264
	["qca/hmtnv20.b112"]=f8d027c5f0ea54456d23b903c55e1a87b06df97ff26b83e3fd02ac6b265b5264
	["qca/hmtnv20.bin"]=c26b340bbc8b617304610c774627ac4879194705eea7a7c7b13e3593903befd9
)

MOUNTS=()

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

BUILD_DIR=$(absolute_path "$BUILD_DIR")
OUTPUT_DIR=$(absolute_path "$OUTPUT_DIR")

cleanup_mounts() {
	local index
	set +e
	for ((index=${#MOUNTS[@]}-1; index>=0; index--)); do
		umount -R "${MOUNTS[index]}" >/dev/null 2>&1 || true
	done
	MOUNTS=()
}

cleanup() {
	cleanup_mounts
}
trap cleanup EXIT

run_chroot() {
	chroot "$ROOTFS_DIR" /usr/bin/env -i \
		HOME=/root \
		LANG=C \
		LC_ALL=C \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin \
		TERM=dumb \
		"$@"
}

bind_mount() {
	local source=$1 target=$2
	install -d "$target"
	mount --bind "$source" "$target"
	MOUNTS+=("$target")
}

mount_chroot_filesystems() {
	local filesystem
	for filesystem in dev proc sys run; do
		install -d "$ROOTFS_DIR/$filesystem"
		mount --rbind "/$filesystem" "$ROOTFS_DIR/$filesystem"
		mount --make-rslave "$ROOTFS_DIR/$filesystem"
		MOUNTS+=("$ROOTFS_DIR/$filesystem")
	done
	bind_mount "$SHARED_DIR" "$ROOTFS_DIR/workspace"
}

reset_scratch() {
	[[ -n "$BUILD_DIR" && "$BUILD_DIR" != / && "$BUILD_DIR" != "$ROOT_DIR" ]] ||
		die "refusing unsafe scratch directory: $BUILD_DIR"
	install -d "$BUILD_DIR"
	if [[ -n "$(findmnt -R -n -o TARGET "$ROOTFS_DIR" 2>/dev/null)" ]]; then
		die "scratch rootfs contains an active mount: $ROOTFS_DIR"
	fi
	# These paths are created only below BUILD_DIR and are safe to recreate.
	for directory in "$ROOTFS_DIR" "$SHARED_DIR"; do
		if [[ -e "$directory" ]]; then
			rm -rf -- "$directory"
		fi
	done
	install -d "$ROOTFS_DIR" "$SHARED_DIR" "$OUTPUT_DIR"
}

download_rootfs() {
	local expected actual
	log "Downloading Arch Linux ARM AArch64 root filesystem"
	curl -fL --retry 5 --retry-delay 2 "$ARCHLINUX_ROOTFS_URL" -o "$ROOTFS_ARCHIVE"
	curl -fL --retry 5 --retry-delay 2 "${ARCHLINUX_ROOTFS_URL}.md5" -o "$ROOTFS_MD5_FILE"
	expected=$(awk 'NF {print $1; exit}' "$ROOTFS_MD5_FILE")
	[[ "$expected" =~ ^[[:xdigit:]]{32}$ ]] || die "invalid Arch Linux ARM MD5 file"
	actual=$(md5sum "$ROOTFS_ARCHIVE" | awk '{print $1}')
	[[ "$actual" == "$expected" ]] || die "Arch Linux ARM rootfs MD5 mismatch"
	log "Unpacking Arch Linux ARM root filesystem"
	bsdtar -xpf "$ROOTFS_ARCHIVE" -C "$ROOTFS_DIR"
}

prepare_rootfs_network() {
	local root_pacman_conf="$ROOTFS_DIR/etc/pacman.conf"
	install -d "$ROOTFS_DIR/etc/pacman.d"
	# Use the same Arch Linux ARM repository set for the bootstrap rootfs and
	# the final ISO.  The repository name is expanded by pacman from $repo.
	printf 'Server = %s/$repo\n' "$ARCHLINUX_MIRROR" >"$ROOTFS_DIR/etc/pacman.d/mirrorlist"
	sed "s|%ARCHLINUX_MIRROR%|$ARCHLINUX_MIRROR|g" \
		"$ROOT_DIR/archlinux/profile/pacman.conf" >"$root_pacman_conf"
	# The generic rootfs normally ships resolv.conf as a symlink into a systemd
	# runtime directory.  Replace it in this disposable chroot with the runner's
	# resolver so pacman can bootstrap before systemd is running.
	rm -f -- "$ROOTFS_DIR/etc/resolv.conf"
	cp -L /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"
}

install_archiso_build_dependencies() {
	log "Installing Arch Linux ARM build dependencies"
	run_chroot pacman-key --init
	# The Arch Linux ARM package key has legacy SHA-1 certifications. Newer
	# GnuPG versions reject those while importing the vendor keyring, leaving
	# the key at unknown trust and even rejecting archlinuxarm-keyring itself.
	# Permit the legacy key certification only during this bootstrap; package
	# signature checking remains Required in pacman.conf.
	run_chroot sh -c \
		'printf "%s\\n" allow-weak-key-signatures >> /etc/pacman.d/gnupg/gpg.conf'
	run_chroot pacman-key --populate archlinuxarm
	run_chroot pacman -Sy --noconfirm archlinuxarm-keyring
	run_chroot pacman-key --populate archlinuxarm
	run_chroot pacman -Syu --noconfirm
	run_chroot pacman -S --needed --noconfirm \
		arch-install-scripts \
		base-devel \
		cpio \
		dosfstools \
		e2fsprogs \
		erofs-utils \
		grub \
		libarchive \
		libisoburn \
		mkinitcpio \
		mkinitcpio-archiso \
		mtools \
		openssl \
		pacman \
		rsync \
		squashfs-tools \
		wireless-regdb \
		xz \
		zstd
	# The bootstrap rootfs is only the build host.  Its package cache is not
	# copied into the ISO and can consume a meaningful part of the runner disk.
	run_chroot pacman -Scc --noconfirm
}

download_archiso() {
	local mkarchiso
	log "Fetching archiso ${ARCHISO_REF}"
	git clone --depth=1 --branch "$ARCHISO_REF" \
		https://github.com/archlinux/archiso.git "$ARCHISO_SOURCE_DIR"
	[[ -x "$ARCHISO_SOURCE_DIR/archiso/mkarchiso" ]] || die "mkarchiso was not found"

	# archiso's generic UEFI module list targets the x86_64 GRUB package.  The
	# Arch Linux ARM arm64-efi package intentionally does not ship the AT
	# keyboard and USB-serial modules.  It also does not include fdt in the
	# generic list, although this profile uses GRUB's devicetree command.
	mkarchiso="$ARCHISO_SOURCE_DIR/archiso/mkarchiso"
	sed -i \
		-e 's/at_keyboard //' \
		-e 's/keylayouts //' \
		-e 's/usb //' \
		-e 's/usbserial_common //' \
		-e 's/usbserial_ftdi //' \
		-e 's/usbserial_pl2303 //' \
		-e 's/usbserial_usbdebug //' \
		-e 's/ fat font / fat font fdt /' \
		"$mkarchiso"
	grep -Fq 'font fdt' "$mkarchiso" || die "failed to add the AArch64 GRUB fdt module"
	grep -Fq 'at_keyboard' "$mkarchiso" && die "AArch64 GRUB module list still contains at_keyboard"
}

download_kernel() {
	local revision short_revision archive kernel_url
	revision=$(awk -F= '$1 ~ /^revision[[:space:]]*$/ {gsub(/[[:space:]]/,"",$2); print $2}' "$ROOT_DIR/kernel/source.lock")
	[[ "$revision" =~ ^[[:xdigit:]]{40}$ ]] || die "invalid kernel revision in kernel/source.lock"
	short_revision=${revision:0:12}
	archive="$BUILD_DIR/linux-$short_revision.tar.gz"
	kernel_url="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/snapshot/linux-$short_revision.tar.gz"
	log "Downloading Linux source at ${revision}"
	curl -fL --retry 5 --retry-delay 2 "$kernel_url" -o "$archive"
	install -d "$KERNEL_SOURCE_DIR"
	tar -xzf "$archive" --strip-components=1 -C "$KERNEL_SOURCE_DIR"
	[[ -f "$KERNEL_SOURCE_DIR/Makefile" ]] || die "Linux source archive is incomplete"
}

build_surface_kernel_and_dtb() {
	local relative source
	log "Staging firmware for the built-in early Wi-Fi loader"
	rm -rf -- "$KERNEL_BUILTIN_FIRMWARE_DIR"
	install -d "$KERNEL_BUILTIN_FIRMWARE_DIR"
	for relative in \
		ath12k/WCN7850/hw2.0/amss.bin \
		ath12k/WCN7850/hw2.0/m3.bin \
		ath12k/WCN7850/hw2.0/board.bin \
		ath12k/WCN7850/hw2.0/board-2.bin; do
		source="$FIRMWARE_DIR/$relative"
		[[ -s "$source" ]] || die "WCN7850 firmware is missing before kernel build: $relative"
		install -D -m 0644 "$source" "$KERNEL_BUILTIN_FIRMWARE_DIR/$relative"
	done
	for relative in regulatory.db regulatory.db.p7s; do
		source="$ROOTFS_DIR/usr/lib/firmware/$relative"
		[[ -s "$source" ]] || die "regulatory firmware is missing before kernel build: $relative"
		install -D -m 0644 "$source" "$KERNEL_BUILTIN_FIRMWARE_DIR/$relative"
	done

	log "Building the Surface ARM64 kernel"
	env \
		KERNEL_SOURCE="$KERNEL_SOURCE_DIR" \
		KERNEL_CROSS_COMPILE= \
		KERNEL_APPLY_PATCHES=1 \
		KERNEL_EXTRA_FIRMWARE='ath12k/WCN7850/hw2.0/amss.bin ath12k/WCN7850/hw2.0/m3.bin ath12k/WCN7850/hw2.0/board.bin ath12k/WCN7850/hw2.0/board-2.bin regulatory.db regulatory.db.p7s' \
		KERNEL_EXTRA_FIRMWARE_DIR="$KERNEL_BUILTIN_FIRMWARE_DIR" \
		SURFACE_OUTPUT_DIR="$SURFACE_OUTPUT_DIR" \
		SURFACE_WORK_DIR="$SURFACE_WORK_DIR" \
		SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
		"$ROOT_DIR/build.sh" kernel

	log "Building Surface device trees"
	env \
		KERNEL_SOURCE="$KERNEL_SOURCE_DIR" \
		KERNEL_CROSS_COMPILE= \
		SURFACE_OUTPUT_DIR="$SURFACE_OUTPUT_DIR" \
		SURFACE_WORK_DIR="$SURFACE_WORK_DIR" \
		SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
		"$ROOT_DIR/build.sh" dtb
}

download_firmware() {
	local relative destination url expected wifi_source
	log "Validating the surface-pve boot Wi-Fi firmware reference"
	wifi_source="$WCN7850_FIRMWARE_SOURCE"
	if [[ -n "$WCN7850_FIRMWARE_URL" ]]; then
		wifi_source="$SHARED_DIR/surface-wifi-reference.tar.gz"
		curl --proto '=https' --proto-redir '=https' -fL --retry 5 --max-filesize 16777216 \
			"$WCN7850_FIRMWARE_URL" -o "$wifi_source"
	fi
	[[ -n "$wifi_source" ]] || die "Wi-Fi reference source is not configured"
	python3 "$ROOT_DIR/archlinux/prepare-wifi-firmware.py" "$wifi_source" \
		--output "$FIRMWARE_DIR/ath12k/WCN7850/hw2.0"
	log "Downloading pinned Bluetooth firmware"
	for relative in "${!FIRMWARE_SHA256[@]}"; do
		destination="$FIRMWARE_DIR/$relative"
		install -d "$(dirname "$destination")"
		url="${LINUX_FIRMWARE_BASE_URL%/}/$relative?id=$LINUX_FIRMWARE_REVISION"
		curl -fL --retry 5 --retry-delay 2 "$url" -o "$destination"
		if [[ "$LINUX_FIRMWARE_REVISION" == "$DEFAULT_LINUX_FIRMWARE_REVISION" ]]; then
			expected="${FIRMWARE_SHA256[$relative]}  $destination"
			printf '%s\n' "$expected" | sha256sum -c -
		fi
	done
}

build_no_dsp_dtbs() {
	local overlay current bluetooth
	overlay="$BUILD_DIR/surface-no-dsp.dtbo"
	current="$SURFACE_WORK_DIR/dtb/surface-laptop-13-current.dtb"
	bluetooth="$SURFACE_WORK_DIR/dtb/surface-laptop-13-bluetooth.dtb"
	log "Applying the safe no-DSP overlay to the Arch Linux boot DTBs"
	dtc -@ -I dts -O dtb -o "$overlay" \
		"$ROOT_DIR/device-tree/overlays/experimental/x1p-el2-no-dsp.dtso"
	fdtoverlay -i "$current" \
		-o "$SURFACE_WORK_DIR/dtb/surface-laptop-13-archlinux.dtb" "$overlay"
	fdtoverlay -i "$bluetooth" \
		-o "$SURFACE_WORK_DIR/dtb/surface-laptop-13-archlinux-bluetooth.dtb" "$overlay"
	for current in \
		"$SURFACE_WORK_DIR/dtb/surface-laptop-13-archlinux.dtb" \
		"$SURFACE_WORK_DIR/dtb/surface-laptop-13-archlinux-bluetooth.dtb"; do
		for node in /soc@0/remoteproc@6800000 /soc@0/remoteproc@32300000 /sound; do
			[[ "$(fdtget "$current" "$node" status)" == disabled ]] ||
				die "no-DSP DTB did not disable $node: $current"
		done
	done
}

stage_profile() {
	local kernel_release module_tree profile_pacman_conf relative
	kernel_release=$(tr -d '\n' <"$SURFACE_WORK_DIR/kernel/release")
	module_tree="$SURFACE_WORK_DIR/modules/lib/modules/$kernel_release"
	[[ -f "$SURFACE_WORK_DIR/kernel/Image" ]] || die "Surface kernel Image is missing"
	[[ -d "$module_tree" ]] || die "Surface kernel modules are missing"

	log "Assembling the AArch64 archiso profile"
	install -d "$PROFILE_DIR" "$ARCHISO_OUT_DIR"
	cp -a "$ARCHISO_SOURCE_DIR/configs/baseline/." "$PROFILE_DIR/"
	cp -a "$ROOT_DIR/archlinux/profile/." "$PROFILE_DIR/"
	# The baseline profile's generic Linux preset runs during package
	# installation, before customize_airootfs.sh stages the Surface kernel.
	# Remove it because this image uses the kernel built above instead.
	rm -f -- "$PROFILE_DIR/airootfs/etc/mkinitcpio.d/linux.preset"
	profile_pacman_conf="$PROFILE_DIR/pacman.conf"
	sed -i "s|%ARCHLINUX_MIRROR%|$ARCHLINUX_MIRROR|g" "$profile_pacman_conf"
	# mkarchiso uses profile_pacman_conf while assembling the image, but the
	# resulting live root otherwise keeps Arch Linux ARM's geo-selected
	# mirrorlist.  Keep archinstall/pacstrap on the same validated mirror used
	# for the build so one slow regional mirror cannot abort installation.
	install -D -m 0644 "$profile_pacman_conf" \
		"$PROFILE_DIR/airootfs/etc/pacman.conf"

	install -d \
		"$PROFILE_DIR/airootfs/usr/lib/surface-laptop-13" \
		"$PROFILE_DIR/airootfs/usr/lib/modules" \
		"$PROFILE_DIR/airootfs/usr/lib/firmware/qca" \
		"$PROFILE_DIR/airootfs/usr/lib/firmware/ath12k/WCN7850/hw2.0" \
		"$PROFILE_DIR/grub"
	cp "$SURFACE_WORK_DIR/kernel/Image" \
		"$PROFILE_DIR/airootfs/usr/lib/surface-laptop-13/Image"
	cp -a "$module_tree" "$PROFILE_DIR/airootfs/usr/lib/modules/"
	for link in build source; do
		if [[ -L "$PROFILE_DIR/airootfs/usr/lib/modules/$kernel_release/$link" ]]; then
			rm -f -- "$PROFILE_DIR/airootfs/usr/lib/modules/$kernel_release/$link"
		fi
	done
	for relative in "${!FIRMWARE_SHA256[@]}"; do
		install -D -m 0644 "$FIRMWARE_DIR/$relative" \
			"$PROFILE_DIR/airootfs/usr/lib/firmware/$relative"
		[[ -s "$PROFILE_DIR/airootfs/usr/lib/firmware/$relative" ]] ||
			die "staged firmware is empty: $relative"
	done
	python3 "$ROOT_DIR/archlinux/prepare-wifi-firmware.py" \
		"$FIRMWARE_DIR/ath12k/WCN7850/hw2.0" \
		--output "$PROFILE_DIR/airootfs/usr/lib/firmware/ath12k/WCN7850/hw2.0" \
		>"$PROFILE_DIR/airootfs/usr/lib/surface-laptop-13/wifi-sha256sums"
	cp "$SURFACE_WORK_DIR/dtb/surface-laptop-13-archlinux.dtb" \
		"$PROFILE_DIR/grub/surface-laptop-13-archlinux.dtb"
	cp "$SURFACE_WORK_DIR/dtb/surface-laptop-13-archlinux-bluetooth.dtb" \
		"$PROFILE_DIR/grub/surface-laptop-13-archlinux-bluetooth.dtb"
}

trim_build_inputs() {
	log "Removing intermediate kernel and firmware inputs"
	# stage_profile has copied everything mkarchiso needs into PROFILE_DIR. Keep
	# only the bootstrap chroot, archiso source, profile, and archiso work/output
	# directories for the final image build; GitHub's ARM runner has limited disk.
	rm -rf -- "$KERNEL_SOURCE_DIR" "$SURFACE_OUTPUT_DIR" "$SURFACE_WORK_DIR" "$FIRMWARE_DIR"
	rm -f -- "$BUILD_DIR"/linux-*.tar.gz "$BUILD_DIR/surface-no-dsp.dtbo" \
		"$ROOTFS_ARCHIVE" "$ROOTFS_MD5_FILE"
}

build_iso() {
	log "Building the Arch Linux ARM64 ISO"
	mount_chroot_filesystems
	run_chroot env SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
		/workspace/archiso-source/archiso/mkarchiso \
		-v -r \
		-w /workspace/archiso-work \
		-o /workspace/out \
		/workspace/profile
	cleanup_mounts
}

copy_and_hash_output() {
	local iso
	mapfile -t iso_files < <(find "$ARCHISO_OUT_DIR" -maxdepth 1 -type f -name '*.iso' -print | sort)
	(( ${#iso_files[@]} == 1 )) || die "expected one ISO in $ARCHISO_OUT_DIR"
	iso=${iso_files[0]}
	install -d "$OUTPUT_DIR"
	cp "$iso" "$OUTPUT_DIR/"
	(
		cd "$OUTPUT_DIR"
		sha256sum "$(basename "$iso")" >SHA256SUMS
	)
	log "ISO written to $OUTPUT_DIR/$(basename "$iso")"
	cat "$OUTPUT_DIR/SHA256SUMS"
}

main() {
	local host_command
	if [[ -z "$WCN7850_FIRMWARE_SOURCE" && -z "$WCN7850_FIRMWARE_URL" ]]; then
		[[ -f "$DEFAULT_WCN7850_FIRMWARE_SOURCE" ]] ||
			die "bundled Wi-Fi reference is missing: $DEFAULT_WCN7850_FIRMWARE_SOURCE"
		WCN7850_FIRMWARE_SOURCE="$DEFAULT_WCN7850_FIRMWARE_SOURCE"
	fi
	if [[ -n "$WCN7850_FIRMWARE_SOURCE" && -z "$WCN7850_FIRMWARE_URL" ]]; then
		WCN7850_FIRMWARE_SOURCE=$(absolute_path "$WCN7850_FIRMWARE_SOURCE")
		case "$WCN7850_FIRMWARE_SOURCE/" in
			"$BUILD_DIR/"*) die "Wi-Fi reference must be outside the disposable scratch directory" ;;
		esac
		python3 "$ROOT_DIR/archlinux/prepare-wifi-firmware.py" "$WCN7850_FIRMWARE_SOURCE"
	fi
	[[ "$(uname -m)" == aarch64 ]] || die "Arch Linux ARM ISO builds must run on an AArch64 host"
	[[ "$(id -u)" -eq 0 ]] || die "run this builder as root (for example: sudo ./archlinux/build-iso.sh)"
	for host_command in awk bsdtar chroot curl dtc fdtoverlay fdtget findmnt git make md5sum mount python3 sha256sum stat tar umount; do
		need "$host_command"
	done
	reset_scratch
	download_firmware
	download_rootfs
	prepare_rootfs_network
	mount_chroot_filesystems
	install_archiso_build_dependencies
	cleanup_mounts
	download_archiso
	download_kernel
	build_surface_kernel_and_dtb
	build_no_dsp_dtbs
	stage_profile
	trim_build_inputs
	build_iso
	copy_and_hash_output
}

main "$@"
