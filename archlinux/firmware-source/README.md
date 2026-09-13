# Surface Laptop 13 AudioReach topology

`X1P42100-Microsoft-Surface-Laptop-13.m4` is derived from the published
X1P42100 Surface Pro 12in topology. It retains the two WSA884x speaker and VA
DMIC backends and adds the WCD9385 RX/TX backends required by the 3.5 mm
headset codec.

The checked-in binary is generated with the `audioreach-topology` source at
commit `e7b20b2b16cdda18eb8ae143c8d95c4815c0288e` and `alsatplg` from
`alsa-utils` 1.2.8. With that source checked out as `TOPOLOGY_SRC` and
`alsatplg` on `PATH`:

```sh
mkdir -p build
m4 -I build -I "$TOPOLOGY_SRC" \
  X1P42100-Microsoft-Surface-Laptop-13.m4 > build/surface.conf
alsatplg -c build/surface.conf \
  -o ../firmware-tree/qcom/x1e80100/X1P42100-Microsoft-Surface-Laptop-13-tplg.bin
```

The resulting size and SHA-256 are recorded in `drivers/firmware-manifest.json`.
