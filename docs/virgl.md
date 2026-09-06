# Surface Snapdragon virgl

The installed Debian trixie Mesa 25.0.7 rejected this machine's GPU ID
`0xe943030c00`. Updating the Mesa stack to Debian trixie-backports
`26.1.2-1~bpo13+1` enables Freedreno recognition of Adreno X1-45. Keep the
existing working EL2 kernel, DTB and firmware for this userspace change.

Run `tools/install-surface-virgl-mesa.sh` as root on the installed ARM64 host.
The script adds the signed official backports source if absent, selects only
the Mesa packages from that suite, records the previous package inventory,
installs the ARM64 Pixman fix, and checks hardware EGL. Then run
`tools/enable-surface-virgl-sysmem.sh` once. It diverts the package-managed
`/usr/bin/kvm` symlink and applies `FD_MESA_DEBUG=sysmem` only when the QEMU
command contains `virtio-gpu-gl`. Stop/start affected VMs through PVE to load
the new libraries and wrapper.

For a VM using `vga: virtio-gl`, PVE generates `virtio-gpu-gl` and
`egl-headless,gl=core`. Leave `kvm: 1` enabled. No software renderer override
or GPU-ID spoofing is required.

## Deployment evidence

On surface-pve, the updated stack reports:

```text
OpenGL core profile vendor: freedreno
OpenGL core profile renderer: Adreno X1-45
OpenGL core profile version: 4.6 (Core Profile) Mesa 26.1.2-1~bpo13+1
OpenGL ES profile version: OpenGL ES 3.2 Mesa 26.1.2-1~bpo13+1
```

VM 100 loads the updated libgallium, opens `/dev/dri/renderD128`, and its
DRM fdinfo reports `drm-driver: msm` with nonzero GPU execution time and
cycles. The previous unsupported-GPU message is absent. Existing
virglrenderer 1.1.0 and PVE QEMU 11.0.3 are retained.

The first post-upgrade runs exposed a separate host crash. QEMU was killed by
SIGSEGV in the `SPICE Worker`, at `libpixman-1.so.0` from Debian trixie's
0.44.0-3 package. There was no host OOM, kernel GPU fault, or QMP shutdown
event. This matches Debian bug #1059145: the ARM64 NEON advanced prefetcher
could read past the end of an image buffer when the stride was negative. The
fix is in Pixman 0.46.0 and later. The host now uses Debian's
`libpixman-1-0` 0.46.4-1+b2 package; the previous 0.44.0-3 package is kept in
the remote rollback directory.

Pixman alone stops the QEMU SIGSEGV, but the unmodified Freedreno GMEM path
then produced one Adreno `gpu fault ring 2`/`hangcheck recover` event after
about 17 minutes. QEMU stayed alive, but this is not acceptable for a host
that is expected to run VMs continuously. With `FD_MESA_DEBUG=sysmem`, the
same Mesa 26.1.2, virglrenderer 1.1.0, `virtio-gpu-gl`, and KVM stack stayed
running for 1140 seconds without another GPU fault, QEMU SIGSEGV, Pixman
error, or OOM event. The QEMU process still opens `/dev/dri/renderD128` and
uses the `msm` DRM driver, so this is hardware virgl rendering with a lower
performance sysmem rendering path rather than a software renderer fallback.
The installed wrapper was then exercised through a normal `qm start` and
remained running for a further 600-second watch with the same clean result.

The wrapper preserves `/usr/bin/kvm` as QEMU's `argv[0]`; without that, QEMU
rejects `-cpu host` on ARM64. The dpkg diversion keeps the wrapper across PVE
package updates. To remove the workaround after a future Freedreno fix, stop
the affected VMs, remove `/usr/bin/kvm`, run
`dpkg-divert --remove --rename --divert /usr/bin/kvm.pve-real --package surface-virgl /usr/bin/kvm`,
and start the VMs again.

The installer also verifies Pixman >= 0.46.0. It adds the signed Debian
unstable source only for that package transaction and removes the source on
exit; unstable is not left as a system-wide apt source. Initial deployment
records, VM config backup and installation logs are in
`/root/surface-virgl-backup/` on the host. The host's log clock was
2026-09-07 JST during these tests. No boot artifacts changed.
