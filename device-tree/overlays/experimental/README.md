# Experimental overlays

`audio-jack.dtso` is not selected by the default build. It adds the WCD9385
codec, its RX/TX SoundWire children, and the corresponding sound-card links.
The current link configuration prevents the base ALSA card from registering
on this machine and needs separate hardware validation.

Do not deploy a resulting DTB without keeping a known-good recovery DTB
available.
