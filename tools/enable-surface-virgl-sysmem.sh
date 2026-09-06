#!/usr/bin/env bash
# Keep virtio-gpu-gl on the Surface while avoiding the Adreno GMEM path that
# currently causes a GPU ring fault under virgl. Run as root on the host.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root' >&2; exit 1; }
[[ $(dpkg --print-architecture) == arm64 ]] || {
    echo 'This wrapper is only for the ARM64 Surface host' >&2; exit 1;
}

real=/usr/bin/kvm.pve-real
wrapper=/usr/bin/kvm
backup=/root/surface-virgl-backup
mkdir -p "$backup"

# Keep the package-managed QEMU path under a diversion. This survives a PVE
# package upgrade and gives the wrapper a stable target.
if ! dpkg-divert --list "$wrapper" | grep -Fq "diverted by surface-virgl"; then
    dpkg-divert --add --local --rename \
        --divert "$real" \
        --package surface-virgl \
        "$wrapper"
fi
[[ -x $real ]] || { echo "missing diverted QEMU binary: $real" >&2; exit 1; }

if [[ -e $wrapper && ! -L $wrapper ]]; then
    cp -a "$wrapper" "$backup/kvm-wrapper.before.$(date +%Y%m%d%H%M%S)"
fi
cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *virtio-gpu-gl*)
        case ",${FD_MESA_DEBUG-}," in
            *,sysmem,*) ;;
            *) export FD_MESA_DEBUG="${FD_MESA_DEBUG:+$FD_MESA_DEBUG,}sysmem" ;;
        esac
        ;;
esac
# QEMU uses argv[0] to select the KVM personality. Preserve the original
# /usr/bin/kvm name even though dpkg-divert moved the real symlink.
exec -a /usr/bin/kvm /usr/bin/kvm.pve-real "$@"
EOF
chmod 0755 "$wrapper"

echo "virgl wrapper installed: $wrapper -> $real"
echo 'virtio-gpu-gl QEMU processes will use FD_MESA_DEBUG=sysmem.'
echo 'Restart affected VMs through PVE to load the wrapper.'
