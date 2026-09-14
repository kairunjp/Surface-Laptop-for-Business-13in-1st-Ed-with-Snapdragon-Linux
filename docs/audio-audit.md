# Audio audit: archlinux after 0eebace

Status: offline correction and build validation, **not a hardware audio fix confirmed
by testing**. No SSH connection, mixer operation, regulator operation or reboot on
the laptop was performed. Quiet speakers, silent capture and headset support remain
open issues. In particular, 0eebace is not a known-good microphone configuration.

## Commit comparison

| Commit | Production topology | Stream gain | DEC0 / DEC1 inputs |
| --- | --- | --- | --- |
| 823c04a | 11320 bytes, SHA256 below | 65535 | DMIC0 / DMIC1 |
| 7695652 | identical | 8192 | DMIC2 / DMIC2 |
| 0eebace | identical | 65535 | DMIC0 / DMIC1 |

Between 823c04a and 7695652, the base DT gained DMIC2/3 supply routes,
the experimental WCD9385 m4 source was added, and build guards excluded its
headset DT node. 0eebace only reverted gain/input selections and comments; it did
not establish working capture. All three production binaries have SHA256
`89b731f3f98fc2b84699bca39a56e390925a44a26d5aea80382cf617e00c08d8`.
The experimental m4 is **not** the source of that production binary.

## Playback and clipping

Decoding the production binary with alsatplg establishes:

- PCM 0: MultiMedia1, S16_LE, 48000 Hz, stereo → stream volume/converter/MFC →
  WSA_CODEC_DMA_RX_0 (105 / 0x69) → WSA macro AIF1_PB RX0/RX1 →
  WSA_SPK1/2 → SpkrLeft/SpkrRight WSA884x SoundWire amplifiers.
- PCM 1: MultiMedia2 capture, S16_LE, 48000 Hz, 1–2 channels ←
  VA_CODEC_DMA_TX_0 (110 / 0x6e).
- The two graph routing switches have one channel in topology. They are not
  left/right DMA gates. The previous `on,on` explanation was incorrect.

[AudioReach soft_vol_api.h](https://github.com/AudioReach/audioreach-engine/blob/faa820567ad17b6c4168de390f184bb352fd6784/modules/processing/volume_control/capi/soft_vol/api/soft_vol_api.h)
defines PARAM_ID_VOL_CTRL_MASTER_GAIN 0x08001035 as unsigned Q13 with default
0x2000. Therefore 8192 = 1.0 = 0 dB; 65535 = 7.99988 = +18.0617 dB.
A signal above approximately -18.06 dBFS can exceed full scale under that gain.
This explains a concrete clipping mechanism consistent with the reported distortion;
it does not prove that every observed distortion originates there.

The pinned kernel
[topology.c](https://github.com/torvalds/linux/blob/075b74841bd0065a3bda3440873c747938e69b68/sound/soc/qcom/qdsp6/topology.c)
initializes `mod->gain` from VOL_CTRL_DEFAULT_GAIN and its put callback only caches
the raw value. `audioreach_gain_event` sends it on DAPM POST_PMU;
[audioreach.c](https://github.com/torvalds/linux/blob/075b74841bd0065a3bda3440873c747938e69b68/sound/soc/qcom/qdsp6/audioreach.c)
sends it unchanged to master_gain. Changing the mixer during an active graph is
not evidence that the DSP applied the new gain. The topology's generic linear
dB TLV is not an accurate Q13 gain conversion; use raw values for this control.

Both service and UCM now request 8192. WSA digital volume 81 is -3 dB by the
kernel's -84 dB + 1 dB/step TLV; PA 6 is 0 dB by the WSA884x -9 dB + 1.5 dB/step
TLV. These baseline values are retained. Raising DSP gain cannot establish correct
amplifier calibration, boost operation or speaker efficiency. Actual low acoustic
volume cannot be uniquely diagnosed from the repository. No speculative amplifier,
voltage or kernel driver changes are made.

## Capture investigation

The pinned
[lpass-va-macro.c](https://github.com/torvalds/linux/blob/075b74841bd0065a3bda3440873c747938e69b68/sound/soc/codecs/lpass-va-macro.c)
provides VA DEC muxes, VA DMIC muxes, DEC0/1 AIF1 capture switches, channel masks,
48 kHz decimation and a DAPM `vdd-micb` regulator supply. The intended logical
path is DMIC pin → VA DMIC → VA DMIC MUX0/1 → VA DEC0/1 MUX (VA_DMIC) →
VA_AIF1_CAP Mixer DEC0/1 → VA capture DAI → VA_CODEC_DMA_TX_0 → MultiMedia2.
VA_DEC0/1 value 84 is 0 dB. The new Mic DisableSequence releases DEC routes and
the frontend graph switch so that DAPM can power down the capture path.

The VA driver groups DMIC0/1 on one clock and DMIC2/3 on another. Selecting
DMIC2 for both decoders duplicates one selection; it is not proof of a stereo pair.
The SM8550 LPASS LPI pinctrl driver used by X1E supports GPIO6=dmic1_clk,
GPIO7=dmic1_data, GPIO8=dmic2_clk, GPIO9=dmic2_data. This validates pin functions,
not the laptop PCB's wiring. Neither 0/1 nor 2/3 can be declared correct from
these SoC definitions. The preexisting 0/1 selection is retained as an explicitly
unverified comparison baseline, not introduced as a new inferred fix.

The DT's `qcom,dmic-sample-rate=2400000` describes the PDM clock, not PCM sample
rate. The VA driver uses a 9.6 MHz MCLK / 4; 4.8 MHz is also a supported divisor,
so source alone cannot prove the board requires 2.4 MHz. The machine driver's
[x1e80100_be_hw_params_fixup](https://github.com/torvalds/linux/blob/075b74841bd0065a3bda3440873c747938e69b68/sound/soc/qcom/x1e80100.c)
fixes the PCM backend to 48 kHz, matching topology. The DT connects micb to
PM8550-B LDO1 at 1.8 V and its parent to SMPS4. Existing DAPM supply routes cover
DMIC0–3. CI checks the actual phandles and properties; it cannot measure rail
voltage, clock presence, capture samples or DMA activity. No regulator-always-on
is added. Previously asserted board-specific clock/wiring claims were removed.

## Headset and service

The normal DT has WSA and VA DAI links only. The normal topology has no WCD9385
RX/TX backend or headset PCM. Consequently 3.5 mm audio is not implemented in
this baseline. The experimental m4/overlay remains isolated; restoring it could
again prevent the base ALSA card from probing. No claim of headset repair is made.

The initialization helper now returns failure when mixer operations fail rather
than reporting success with "optional" errors. It keeps the existing card wait,
SoundWire wait and simple mixer interface. UCM remains responsible for normal
session activation. Static validation cannot confirm control existence or execution
order against hardware. The kernel package contains the service; the existing
pacstrap wrapper installs the model-specific UCM files from the live image.

## CI evidence and limits

`archlinux/verify-audio.py` runs before build intermediates are deleted. It checks
approved topology size/hash and decoded paths, parses UCM and its includes using
libasound without opening a card, checks helper shell syntax, validates compiled
DTB pinctrl/micb/DAPM/DMA properties and rejects headset nodes/links. The builder
also runs systemd-analyze verify against the build rootfs.

The verifier resolves the firmware table in the built vmlinux, follows the
registered topology's name/data pointers, and compares every payload byte and
size. It checks that the same bytes are present in the boot Image. This is stronger
than finding the filename in strings. The separate audio-validation artifact
contains the kernel package, Image, DTB, topology, extracted embedded topology,
kernel config, UCM, service, reports and SHA256SUMS. The usual ISO remains a
separate artifact. Passing CI proves build consistency, **not** acoustic performance
or successful card probing on the laptop.
