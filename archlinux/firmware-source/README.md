# Surface Laptop 13 AudioReach topology

`X1P42100-Microsoft-Surface-Laptop-13.m4` is an experimental derivative of
the published X1P42100 Surface Pro 12in topology. It retains the two WSA884x
speaker and VA DMIC backends and adds WCD9385 RX/TX backends for the 3.5 mm
headset codec.

The checked-in production binary remains the redistributable Surface Pro 12in
topology under the model-specific Surface Laptop filename. Do not replace it
with this experimental variant until its WCD links and PCM routing have passed
a complete headset, speaker, and microphone test. With the
`audioreach-topology` source checked out as `TOPOLOGY_SRC` and `alsatplg` on
`PATH`, the experiment can be generated with:

```sh
mkdir -p build
m4 -I build -I "$TOPOLOGY_SRC" \
  X1P42100-Microsoft-Surface-Laptop-13.m4 > build/surface.conf
alsatplg -c build/surface.conf \
  -o build/X1P42100-Microsoft-Surface-Laptop-13-tplg.bin
```

`drivers/firmware-manifest.json` records the production binary, not the experimental
output. CI rejects a replacement unless the production baseline is deliberately
reviewed. See [the offline audio audit](../../docs/audio-audit.md).
