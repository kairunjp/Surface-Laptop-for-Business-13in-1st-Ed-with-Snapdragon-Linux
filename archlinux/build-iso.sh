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
GPU_FIRMWARE_SOURCE=${GPU_FIRMWARE_SOURCE:-}
GPU_FIRMWARE_URL=${GPU_FIRMWARE_URL:-}
# The main-branch EL1 DTB enables the Surface ADSP/CDSP path used by the
# Qualcomm PMIC GLINK battery service.  These device-specific files are not
# redistributed by the repository; when supplied, the Arch image uses that
# DTB and stages the files in the live root, target root, and early initramfs.
DSP_FIRMWARE_SOURCE=${DSP_FIRMWARE_SOURCE:-}
DSP_FIRMWARE_URL=${DSP_FIRMWARE_URL:-}
DSP_FIRMWARE_ENABLED=0
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(date +%s)}
DEFAULT_WCN7850_FIRMWARE_SOURCE="$ROOT_DIR/build/archlinux-reference/surface-pve-wifi-reference.tar.gz"
DEFAULT_GPU_FIRMWARE_SOURCE="$ROOT_DIR/build/archlinux-reference/surface-laptop13-gpu-reference.tar.gz"

# Arch Linux ARM currently signs packages with this key. The keyring package
# carries its historical certifications as marginal trust, so explicitly
# locally sign the verified package key after importing the official keyring.
ARCHLINUXARM_BUILD_KEY=68B3537F39A313B3E574D06777193F152BDBE6A6

ROOTFS_DIR="$BUILD_DIR/rootfs"
SHARED_DIR="$BUILD_DIR/shared"
ARCHISO_SOURCE_DIR="$SHARED_DIR/archiso-source"
PROFILE_DIR="$SHARED_DIR/profile"
ARCHISO_OUT_DIR="$SHARED_DIR/out"
KERNEL_SOURCE_DIR="$SHARED_DIR/linux"
SURFACE_OUTPUT_DIR="$SHARED_DIR/surface"
SURFACE_WORK_DIR="$SHARED_DIR/surface-work"
SURFACE_PACKAGE_DIR="$SHARED_DIR/surface-kernel-package"
SURFACE_PACKAGE_NAME=linux-surface-laptop-13
DMS_GREETER_VERSION=1.6.2
DMS_GREETER_PACKAGE_NAME=greetd-dms-greeter-bin
DMS_GREETER_PACKAGE_DIR="$SHARED_DIR/dms-greeter-package"
DMS_GREETER_ARCHIVE="$BUILD_DIR/dms-greeter-linux-arm64-${DMS_GREETER_VERSION}.gz"
DMS_GREETER_URL="https://github.com/AvengeMedia/dank-greeter/releases/download/v${DMS_GREETER_VERSION}/dms-greeter-linux-arm64.gz"
DMS_GREETER_SHA256=29b6c010360d4df09e4dadf0224c0c6d43a52a9aa1bed74bb2184d6172f407e9
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

GPU_FIRMWARE_FILES=(
	qcom/gen71500_sqe.fw
	qcom/gen71500_gmu.bin
	qcom/x1p42100/Microsoft/SurfaceLaptop13/qcdxkmsucpurwa.mbn
)

DSP_FIRMWARE_FILES=(
	qcom/x1p42100/Microsoft/Surface12/qcadsp8380.mbn
	qcom/x1p42100/Microsoft/Surface12/adsp_dtbs.elf
	qcom/x1p42100/Microsoft/Surface12/qccdsp8380.mbn
	qcom/x1p42100/Microsoft/Surface12/cdsp_dtbs.elf
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
DSP_FIRMWARE_ARCHIVE="$BUILD_DIR/surface-dsp-firmware.tar.gz"

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
	run_chroot pacman-key --lsign-key "$ARCHLINUXARM_BUILD_KEY"
	run_chroot pacman -Sy --noconfirm archlinuxarm-keyring
	run_chroot pacman-key --populate archlinuxarm
	run_chroot pacman-key --lsign-key "$ARCHLINUXARM_BUILD_KEY"
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

download_dms_greeter() {
	local expected
	log "Downloading the pinned AArch64 DMS greeter"
	curl -fL --retry 5 --retry-delay 2 "$DMS_GREETER_URL" -o "$DMS_GREETER_ARCHIVE"
	expected="$DMS_GREETER_SHA256  $DMS_GREETER_ARCHIVE"
	printf '%s\n' "$expected" | sha256sum -c -
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
	log "Staging firmware for the built-in early Wi-Fi and GPU loaders"
	rm -rf -- "$KERNEL_BUILTIN_FIRMWARE_DIR"
	install -d "$KERNEL_BUILTIN_FIRMWARE_DIR"
	for relative in "${GPU_FIRMWARE_FILES[@]}"; do
		source="$FIRMWARE_DIR/$relative"
		[[ -s "$source" ]] || die "Surface GPU firmware is missing before kernel build: $relative"
		install -D -m 0644 "$source" "$KERNEL_BUILTIN_FIRMWARE_DIR/$relative"
	done
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
		KERNEL_EXTRA_FIRMWARE="${GPU_FIRMWARE_FILES[*]} ath12k/WCN7850/hw2.0/amss.bin ath12k/WCN7850/hw2.0/m3.bin ath12k/WCN7850/hw2.0/board.bin ath12k/WCN7850/hw2.0/board-2.bin regulatory.db regulatory.db.p7s" \
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
	local relative destination url expected wifi_source gpu_source
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
	log "Validating the Surface Laptop 13 Adreno GPU firmware reference"
	gpu_source="$GPU_FIRMWARE_SOURCE"
	if [[ -n "$GPU_FIRMWARE_URL" ]]; then
		gpu_source="$SHARED_DIR/surface-gpu-reference.tar.gz"
		curl --proto '=https' --proto-redir '=https' -fL --retry 5 --max-filesize 16777216 \
			"$GPU_FIRMWARE_URL" -o "$gpu_source"
	fi
	[[ -n "$gpu_source" ]] || die "GPU firmware reference source is not configured"
	python3 "$ROOT_DIR/archlinux/prepare-gpu-firmware.py" "$gpu_source" \
		--output "$FIRMWARE_DIR"
	if (( DSP_FIRMWARE_ENABLED )); then
		log "Staging the Surface DSP/remoteproc firmware for the battery service"
		if [[ -n "$DSP_FIRMWARE_URL" ]]; then
			curl --proto '=https' --proto-redir '=https' -fL --retry 5 \
				--max-filesize 67108864 "$DSP_FIRMWARE_URL" -o "$DSP_FIRMWARE_ARCHIVE"
			python3 "$ROOT_DIR/archlinux/prepare-dsp-firmware.py" \
				"$DSP_FIRMWARE_ARCHIVE" --output "$FIRMWARE_DIR"
		else
			python3 "$ROOT_DIR/archlinux/prepare-dsp-firmware.py" \
				"$DSP_FIRMWARE_SOURCE" --output "$FIRMWARE_DIR"
		fi
	fi
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

build_archlinux_dtbs() {
	local overlay current bluetooth
	current="$SURFACE_WORK_DIR/dtb/surface-laptop-13-current.dtb"
	bluetooth="$SURFACE_WORK_DIR/dtb/surface-laptop-13-bluetooth.dtb"
	if (( DSP_FIRMWARE_ENABLED )); then
		# build.sh already produces the full EL1 DTB used by the main branch.
		# The Arch image used to apply x1p-el2-no-dsp.dtso unconditionally, which
		# removed the ADSP/PMIC GLINK transport and left qcom_battmgr in -EAGAIN.
		log "Using the main-branch DSP-enabled DTB for battery communication"
		cp -- "$current" \
			"$SURFACE_WORK_DIR/dtb/surface-laptop-13-archlinux.dtb"
		cp -- "$bluetooth" \
			"$SURFACE_WORK_DIR/dtb/surface-laptop-13-archlinux-bluetooth.dtb"
	else
		local overlay="$BUILD_DIR/surface-no-dsp.dtbo"
		log "Applying the safe no-DSP overlay to the Arch Linux boot DTBs"
		dtc -@ -I dts -O dtb -o "$overlay" \
			"$ROOT_DIR/device-tree/overlays/experimental/x1p-el2-no-dsp.dtso"
		fdtoverlay -i "$current" \
			-o "$SURFACE_WORK_DIR/dtb/surface-laptop-13-archlinux.dtb" "$overlay"
		fdtoverlay -i "$bluetooth" \
			-o "$SURFACE_WORK_DIR/dtb/surface-laptop-13-archlinux-bluetooth.dtb" "$overlay"
	fi
	for current in \
		"$SURFACE_WORK_DIR/dtb/surface-laptop-13-archlinux.dtb" \
		"$SURFACE_WORK_DIR/dtb/surface-laptop-13-archlinux-bluetooth.dtb"; do
		if (( DSP_FIRMWARE_ENABLED )); then
			for node in /soc@0/remoteproc@6800000 /soc@0/remoteproc@32300000; do
				[[ "$(fdtget "$current" "$node" status)" == okay ]] ||
					die "DSP-enabled DTB did not enable $node: $current"
			done
		else
			for node in /soc@0/remoteproc@6800000 /soc@0/remoteproc@32300000 /sound; do
				[[ "$(fdtget "$current" "$node" status)" == disabled ]] ||
					die "no-DSP DTB did not disable $node: $current"
			done
		fi
		fdtget "$current" /soc@0/gpu@3d00000/zap-shader firmware-name >/dev/null ||
			die "Arch DTB lost the Surface GPU zap-shader firmware node: $current"
	done
}

build_surface_kernel_package() {
	local kernel_release module_tree package_root package_version package_file relative checksum
	kernel_release=$(tr -d '\n' <"$SURFACE_WORK_DIR/kernel/release")
	module_tree="$SURFACE_WORK_DIR/modules/lib/modules/$kernel_release"
	package_root="$SURFACE_PACKAGE_DIR/root"
	# Pacman package versions cannot contain the hyphens used by the kernel
	# localversion. Keep the actual release in the module directory and use a
	# reversible, package-safe version for the local package filename.
	package_version=$(printf '%s' "$kernel_release" | tr '+-' '._')
	[[ "$kernel_release" == *surface-laptop-13* ]] ||
		die "Surface kernel release is not tagged with surface-laptop-13"
	[[ -f "$SURFACE_WORK_DIR/kernel/Image" ]] || die "Surface kernel Image is missing"
	[[ -d "$module_tree" ]] || die "Surface kernel modules are missing"
	[[ -s "$FIRMWARE_DIR/ath12k/WCN7850/hw2.0/board.bin" ]] ||
		die "the Surface WCN7850 board.bin is missing"

	log "Building the linux-surface-laptop-13 target package"
	rm -rf -- "$SURFACE_PACKAGE_DIR"
	install -d \
		"$package_root/boot" \
		"$package_root/etc/kernel" \
		"$package_root/etc/mkinitcpio.d" \
		"$package_root/etc/mkinitcpio.conf.d" \
		"$package_root/usr/lib/firmware/qcom" \
		"$package_root/usr/lib/firmware/ath12k/WCN7850/hw2.0" \
		"$package_root/usr/lib/modules"
	install -m 0644 "$SURFACE_WORK_DIR/kernel/Image" \
		"$package_root/boot/vmlinuz-linux-surface-laptop-13"
	install -m 0644 "$SURFACE_WORK_DIR/dtb/surface-laptop-13-archlinux.dtb" \
		"$package_root/boot/surface-laptop-13.dtb"
	# Keep firmware out of the package itself. linux-firmware may already own
	# board.bin on newer Arch Linux ARM snapshots, which would make pacman -U
	# reject this package with a file conflict. The pacstrap wrapper installs
	# the verified Surface reference set after all repository packages finish,
	# so the hardware-specific board data wins without creating two owners.
	cp -a "$module_tree" "$package_root/usr/lib/modules/"
	local link
	for link in build source; do
		if [[ -L "$package_root/usr/lib/modules/$kernel_release/$link" ]]; then
			rm -f -- "$package_root/usr/lib/modules/$kernel_release/$link"
		fi
	done
	printf '%s\n' "$SURFACE_PACKAGE_NAME" \
		>"$package_root/usr/lib/modules/$kernel_release/pkgbase"
	rm -f -- "$package_root/usr/lib/modules/$kernel_release/vmlinuz"
	ln -s /boot/vmlinuz-linux-surface-laptop-13 \
		"$package_root/usr/lib/modules/$kernel_release/vmlinuz"

	cat >"$package_root/etc/mkinitcpio.d/$SURFACE_PACKAGE_NAME.preset" <<EOF
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-surface-laptop-13"

PRESETS=('default')

default_image="/boot/initramfs-linux-surface-laptop-13.img"
# archinstall activates this UKI entry and adjusts it for the ESP mountpoint.
# Keep the default rooted at /efi; archinstall rewrites it to /boot when
# the ESP is mounted there.
#default_uki="/efi/EFI/Linux/arch-linux-surface-laptop-13.efi"
# The DTB is placed in the UKI by ukify through this explicit config file.
#default_options="--cmdline /etc/kernel/cmdline --ukiconfig /etc/kernel/uki.conf"
EOF
	cat >"$package_root/etc/kernel/uki.conf" <<'EOF'
[UKI]
DeviceTree=/boot/surface-laptop-13.dtb
EOF
	cat >"$package_root/etc/mkinitcpio.conf.d/surface-laptop-13.conf" <<'EOF'
# Keep the Surface GPU, Wi-Fi, and Bluetooth firmware in every target initramfs.
FILES+=(
  /lib/firmware/qcom/gen71500_sqe.fw
  /lib/firmware/qcom/gen71500_gmu.bin
  /lib/firmware/qcom/x1p42100/Microsoft/SurfaceLaptop13/qcdxkmsucpurwa.mbn
  /lib/firmware/ath12k/WCN7850/hw2.0/amss.bin
  /lib/firmware/ath12k/WCN7850/hw2.0/m3.bin
  /lib/firmware/ath12k/WCN7850/hw2.0/board.bin
  /lib/firmware/ath12k/WCN7850/hw2.0/board-2.bin
  /lib/firmware/qca/hmtbtfw20.tlv
  /lib/firmware/qca/hmtnv20.b10f
  /lib/firmware/qca/hmtnv20.b112
  /lib/firmware/qca/hmtnv20.bin
  /lib/firmware/regulatory.db
  /lib/firmware/regulatory.db.p7s
)
EOF
	if (( DSP_FIRMWARE_ENABLED )); then
		{
			printf 'FILES+=(\n'
			for relative in "${DSP_FIRMWARE_FILES[@]}"; do
				printf '  /lib/firmware/%s\n' "$relative"
			done
			printf ')\n'
		} >>"$package_root/etc/mkinitcpio.conf.d/surface-laptop-13.conf"
	fi
	cat >"$SURFACE_PACKAGE_DIR/PKGBUILD" <<EOF
pkgname=$SURFACE_PACKAGE_NAME
pkgver=$package_version
pkgrel=1
pkgdesc='Surface Laptop 13 custom Linux kernel, modules, DTB, and boot preset'
arch=('aarch64')
license=('GPL-2.0-only')
depends=('mkinitcpio' 'systemd' 'systemd-ukify' 'wireless-regdb')
provides=('linux')

package() {
  cp -a /workspace/surface-kernel-package/root/. "\$pkgdir/"
}
EOF

	# modules_install creates most metadata, but regenerate it against the
	# package's /usr tree so depmod never records paths into the workspace.
	mount_chroot_filesystems
	run_chroot depmod -b /workspace/surface-kernel-package/root/usr "$kernel_release"
	if ! run_chroot id surface-builder >/dev/null 2>&1; then
		run_chroot useradd --system --user-group --create-home --home-dir /home/surface-builder \
			--shell /usr/bin/nologin surface-builder
	fi
	run_chroot chown -R surface-builder:surface-builder /workspace/surface-kernel-package
	run_chroot runuser -u surface-builder -- sh -c \
		'cd /workspace/surface-kernel-package && HOME=/home/surface-builder makepkg --nodeps --nocheck --noconfirm --cleanbuild --force'
	cleanup_mounts

	package_file=$(find "$SURFACE_PACKAGE_DIR" -maxdepth 1 -type f \
		-name "$SURFACE_PACKAGE_NAME-*.pkg.tar.*" ! -name '*.sig' -print -quit)
	[[ -n "$package_file" && -f "$package_file" ]] ||
		die "linux-surface-laptop-13 package was not created"
	printf 'target kernel package: %s\n' "${package_file##*/}"
}

build_dms_greeter_package() {
	local package_root package_file

	log "Building the standalone DMS greeter package"
	rm -rf -- "$DMS_GREETER_PACKAGE_DIR"
	package_root="$DMS_GREETER_PACKAGE_DIR/root"
	install -d \
		"$package_root/usr/bin" \
		"$package_root/usr/lib/tmpfiles.d" \
		"$package_root/usr/share/doc/$DMS_GREETER_PACKAGE_NAME"

	# DankMaterialShell's current greeter is a single statically linked binary.
	# Keep the package local to the ISO so target installation does not depend
	# on the AUR or on a second download from the installer.
	gzip -dc "$DMS_GREETER_ARCHIVE" >"$package_root/usr/bin/dms-greeter"
	chmod 0755 "$package_root/usr/bin/dms-greeter"
	cat >"$package_root/usr/lib/tmpfiles.d/dms-greeter.conf" <<'EOF'
#  Path                   Mode User    Group   Age Argument
d /var/cache/dms-greeter  0750 greeter greeter -
d /var/lib/greeter       0755 greeter greeter -
EOF
	cat >"$DMS_GREETER_PACKAGE_DIR/PKGBUILD" <<EOF
pkgname=$DMS_GREETER_PACKAGE_NAME
pkgver=$DMS_GREETER_VERSION
pkgrel=1
pkgdesc='Greetd login screen with the Dank Material aesthetic (AArch64 binary)'
arch=('aarch64')
license=('MIT')
depends=('greetd' 'quickshell' 'qt6-declarative')
optdepends=('niri: Niri compositor support')
provides=('greetd-dms-greeter' 'dms-greeter=$DMS_GREETER_VERSION')
conflicts=('greetd-dms-greeter' 'greetd-dms-greeter-git' 'dms-greeter')

package() {
  cp -a /workspace/dms-greeter-package/root/. "\$pkgdir/"
}
EOF

	mount_chroot_filesystems
	if ! run_chroot id surface-builder >/dev/null 2>&1; then
		run_chroot useradd --system --user-group --create-home --home-dir /home/surface-builder \
			--shell /usr/bin/nologin surface-builder
	fi
	run_chroot chown -R surface-builder:surface-builder /workspace/dms-greeter-package
	run_chroot runuser -u surface-builder -- sh -c \
		'cd /workspace/dms-greeter-package && HOME=/home/surface-builder makepkg --nodeps --nocheck --noconfirm --cleanbuild --force'
	cleanup_mounts

	package_file=$(find "$DMS_GREETER_PACKAGE_DIR" -maxdepth 1 -type f \
		-name "$DMS_GREETER_PACKAGE_NAME-*.pkg.tar.*" ! -name '*.sig' -print -quit)
	[[ -n "$package_file" && -f "$package_file" ]] ||
		die "DMS greeter package was not created"
	printf 'target DMS greeter package: %s\n' "${package_file##*/}"
}

stage_profile() {
	local kernel_release module_tree profile_pacman_conf relative surface_package dms_greeter_package checksum
	kernel_release=$(tr -d '\n' <"$SURFACE_WORK_DIR/kernel/release")
	module_tree="$SURFACE_WORK_DIR/modules/lib/modules/$kernel_release"
	[[ -f "$SURFACE_WORK_DIR/kernel/Image" ]] || die "Surface kernel Image is missing"
	[[ -d "$module_tree" ]] || die "Surface kernel modules are missing"
	surface_package=$(find "$SURFACE_PACKAGE_DIR" -maxdepth 1 -type f \
		-name "$SURFACE_PACKAGE_NAME-*.pkg.tar.*" ! -name '*.sig' -print -quit)
	[[ -n "$surface_package" && -f "$surface_package" ]] ||
		die "Surface target kernel package is missing"
	dms_greeter_package=$(find "$DMS_GREETER_PACKAGE_DIR" -maxdepth 1 -type f \
		-name "$DMS_GREETER_PACKAGE_NAME-*.pkg.tar.*" ! -name '*.sig' -print -quit)
	[[ -n "$dms_greeter_package" && -f "$dms_greeter_package" ]] ||
		die "DMS greeter package is missing"

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
		"$PROFILE_DIR/airootfs/usr/lib/firmware/qcom" \
		"$PROFILE_DIR/airootfs/usr/lib/firmware/qca" \
		"$PROFILE_DIR/airootfs/usr/lib/firmware/ath12k/WCN7850/hw2.0" \
		"$PROFILE_DIR/grub"
	cp "$SURFACE_WORK_DIR/kernel/Image" \
		"$PROFILE_DIR/airootfs/usr/lib/surface-laptop-13/Image"
	install -m 0644 "$surface_package" \
		"$PROFILE_DIR/airootfs/usr/lib/surface-laptop-13/$(basename "$surface_package")"
	install -m 0644 "$dms_greeter_package" \
		"$PROFILE_DIR/airootfs/usr/lib/surface-laptop-13/$(basename "$dms_greeter_package")"
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
	for relative in "${GPU_FIRMWARE_FILES[@]}"; do
		install -D -m 0644 "$FIRMWARE_DIR/$relative" \
			"$PROFILE_DIR/airootfs/usr/lib/firmware/$relative"
		[[ -s "$PROFILE_DIR/airootfs/usr/lib/firmware/$relative" ]] ||
			die "staged GPU firmware is empty: $relative"
	done
	if (( DSP_FIRMWARE_ENABLED )); then
		: >"$PROFILE_DIR/airootfs/usr/lib/surface-laptop-13/dsp-firmware.list"
		for relative in "${DSP_FIRMWARE_FILES[@]}"; do
			install -D -m 0644 "$FIRMWARE_DIR/$relative" \
				"$PROFILE_DIR/airootfs/usr/lib/firmware/$relative"
			[[ -s "$PROFILE_DIR/airootfs/usr/lib/firmware/$relative" ]] ||
				die "staged DSP firmware is empty: $relative"
			checksum=$(sha256sum "$FIRMWARE_DIR/$relative" | awk '{print $1}')
			printf '%s  %s\n' "$checksum" "$relative" \
				>>"$PROFILE_DIR/airootfs/usr/lib/surface-laptop-13/dsp-firmware.list"
		done
	else
		rm -f -- "$PROFILE_DIR/airootfs/usr/lib/surface-laptop-13/dsp-firmware.list"
	fi
	python3 "$ROOT_DIR/archlinux/prepare-wifi-firmware.py" \
		"$FIRMWARE_DIR/ath12k/WCN7850/hw2.0" \
		--output "$PROFILE_DIR/airootfs/usr/lib/firmware/ath12k/WCN7850/hw2.0" \
		>"$PROFILE_DIR/airootfs/usr/lib/surface-laptop-13/wifi-sha256sums"
	cp "$SURFACE_WORK_DIR/dtb/surface-laptop-13-archlinux.dtb" \
		"$PROFILE_DIR/grub/surface-laptop-13-archlinux.dtb"
	cp "$SURFACE_WORK_DIR/dtb/surface-laptop-13-archlinux-bluetooth.dtb" \
		"$PROFILE_DIR/grub/surface-laptop-13-archlinux-bluetooth.dtb"
	if (( DSP_FIRMWARE_ENABLED )); then
		sed -i 's|Surface Laptop 13 (safe, DSP disabled)|Surface Laptop 13 (battery communication, DSP enabled)|' \
			"$PROFILE_DIR/grub/grub.cfg"
	fi
}

trim_build_inputs() {
	log "Removing intermediate kernel and firmware inputs"
	# stage_profile has copied everything mkarchiso needs into PROFILE_DIR. Keep
	# only the bootstrap chroot, archiso source, profile, and archiso work/output
	# directories for the final image build; GitHub's ARM runner has limited disk.
	rm -rf -- "$KERNEL_SOURCE_DIR" "$SURFACE_OUTPUT_DIR" "$SURFACE_WORK_DIR" \
		"$SURFACE_PACKAGE_DIR" "$FIRMWARE_DIR"
	rm -f -- "$BUILD_DIR"/linux-*.tar.gz "$BUILD_DIR/surface-no-dsp.dtbo" \
		"$DSP_FIRMWARE_ARCHIVE" \
		"$ROOTFS_ARCHIVE" "$ROOTFS_MD5_FILE" "$DMS_GREETER_ARCHIVE"
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
	if [[ -z "$GPU_FIRMWARE_SOURCE" && -z "$GPU_FIRMWARE_URL" ]]; then
		[[ -f "$DEFAULT_GPU_FIRMWARE_SOURCE" ]] ||
			die "bundled GPU firmware reference is missing: $DEFAULT_GPU_FIRMWARE_SOURCE"
		GPU_FIRMWARE_SOURCE="$DEFAULT_GPU_FIRMWARE_SOURCE"
	fi
	if [[ -n "$GPU_FIRMWARE_SOURCE" && -z "$GPU_FIRMWARE_URL" ]]; then
		GPU_FIRMWARE_SOURCE=$(absolute_path "$GPU_FIRMWARE_SOURCE")
		case "$GPU_FIRMWARE_SOURCE/" in
			"$BUILD_DIR/"*) die "GPU firmware reference must be outside the disposable scratch directory" ;;
		esac
		python3 "$ROOT_DIR/archlinux/prepare-gpu-firmware.py" "$GPU_FIRMWARE_SOURCE"
	fi
	if [[ -n "$DSP_FIRMWARE_SOURCE" && -n "$DSP_FIRMWARE_URL" ]]; then
		die "set only one of DSP_FIRMWARE_SOURCE and DSP_FIRMWARE_URL"
	fi
	if [[ -n "$DSP_FIRMWARE_SOURCE" ]]; then
		DSP_FIRMWARE_SOURCE=$(absolute_path "$DSP_FIRMWARE_SOURCE")
		case "$DSP_FIRMWARE_SOURCE/" in
			"$BUILD_DIR/"*) die "DSP firmware must be outside the disposable scratch directory" ;;
		esac
		[[ -d "$DSP_FIRMWARE_SOURCE" ]] ||
			die "Surface DSP firmware tree not found: $DSP_FIRMWARE_SOURCE"
		for relative in "${DSP_FIRMWARE_FILES[@]}"; do
			[[ -s "$DSP_FIRMWARE_SOURCE/$relative" ]] ||
				die "Surface DSP firmware is missing: $DSP_FIRMWARE_SOURCE/$relative"
		done
		DSP_FIRMWARE_ENABLED=1
	elif [[ -n "$DSP_FIRMWARE_URL" ]]; then
		[[ "$DSP_FIRMWARE_URL" == https://* ]] ||
			die "DSP_FIRMWARE_URL must use HTTPS"
		DSP_FIRMWARE_ENABLED=1
	fi
	[[ "$(uname -m)" == aarch64 ]] || die "Arch Linux ARM ISO builds must run on an AArch64 host"
	[[ "$(id -u)" -eq 0 ]] || die "run this builder as root (for example: sudo ./archlinux/build-iso.sh)"
	for host_command in awk bsdtar chroot curl dtc fdtoverlay fdtget findmnt git gzip make md5sum mount python3 sha256sum stat tar umount; do
		need "$host_command"
	done
	reset_scratch
	download_firmware
	download_dms_greeter
	download_rootfs
	prepare_rootfs_network
	mount_chroot_filesystems
	install_archiso_build_dependencies
	cleanup_mounts
	download_archiso
	download_kernel
	build_surface_kernel_and_dtb
	build_archlinux_dtbs
	build_surface_kernel_package
	build_dms_greeter_package
	stage_profile
	trim_build_inputs
	build_iso
	copy_and_hash_output
}

main "$@"
