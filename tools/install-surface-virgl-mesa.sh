#!/usr/bin/env bash
# Run as root on the installed Debian trixie ARM64 Surface host.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root' >&2; exit 1; }
source /etc/os-release
[[ ${VERSION_CODENAME:-} == trixie && $(dpkg --print-architecture) == arm64 ]] || {
    echo 'This installer requires Debian trixie arm64' >&2; exit 1;
}
backup=$(mktemp -d /var/backups/surface-virgl.XXXXXXXX)
dpkg-query -W > "$backup/packages-before.txt"
source_file=/etc/apt/sources.list.d/surface-backports.sources
if [[ ! -e $source_file ]]; then
    cat > "$source_file" <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
fi
apt-get update
# Select only Mesa from backports, without changing the global default release.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libgl1-mesa-dri/trixie-backports libegl-mesa0/trixie-backports \
    libgbm1/trixie-backports libglx-mesa0/trixie-backports \
    mesa-libgallium/trixie-backports mesa-utils-bin
timeout 30 /usr/bin/eglinfo.aarch64-linux-gnu -B -p gbm | tee "$backup/eglinfo.txt"
grep -q 'renderer: Adreno X1-45' "$backup/eglinfo.txt" || {
    echo 'Adreno X1-45 hardware rendering was not verified' >&2; exit 1;
}
echo "Hardware EGL verified; package inventory: $backup"
echo 'Restart affected QEMU processes to load the new Mesa libraries.'
