# Surface Snapdragon virgl

The installed Debian trixie Mesa 25.0.7 rejected this machine's GPU ID
`0xe943030c00`. Updating the Mesa stack to Debian trixie-backports
`26.1.2-1~bpo13+1` enables Freedreno recognition of Adreno X1-45. Keep the
existing working EL2 kernel, DTB and firmware for this userspace change.

Run `tools/install-surface-virgl-mesa.sh` as root on the installed ARM64 host.
The script adds the signed official backports source if absent, selects only
the Mesa packages from that suite, records the previous package inventory,
and checks hardware EGL. It does not change VM configurations or restart VMs.
Stop/start affected VMs through PVE to load the new libraries.

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

Hardware rendering support and VM stability are separate checks. The first
post-upgrade VM run still stopped after approximately 32 seconds without a
kernel fault. That exit is not yet explained; the earlier claim that the
unsupported-GPU message probably caused the exits was not proven.
QMP event capture and an exit-only strace were added for a second run.
The second run remained running for more than 100 seconds, with GPU time
increasing from 227 ms to 307 ms and resident GPU memory reaching 145744 KiB.
No GPU fault or unsupported-GPU message appeared. QMP recorded an RTC update;
no shutdown event was observed during capture. Guest desktop rendering and
sustained stability still need verification.

Initial deployment records, VM config backup and installation log are in
`/root/surface-virgl-backup/` on the host. The host's log clock was
2026-09-07 JST during these tests. Package inventories permit selecting the
previous versions for rollback; review an apt downgrade simulation for all
five Mesa packages together before applying it. No boot artifacts changed.
