# Experimental overlays

`audio-jack.dtso` is currently selected by the default build while the
Surface Laptop 13 headset path is being validated on real hardware. It adds
the WCD9385 codec, its RX/TX SoundWire children, and the corresponding sound
card links; a reboot and a physical plug/unplug test are still required.

Do not deploy a resulting DTB without keeping a known-good recovery DTB
available.
