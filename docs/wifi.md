# Wi-Fi 7 and `nmcli`

The Qualcomm WCN7850 is exposed by the kernel as `wlan0` through the
`ath12k_wifi7_pci` driver. It can be present while its link state is `DOWN`;
that is normal until a network manager activates it. The installer and the
installed Proxmox system use NetworkManager for `wlan*` and leave Proxmox
bridges under ifupdown2.

After installation, check the device and turn Wi-Fi on with:

```sh
systemctl enable --now NetworkManager
nmcli radio wifi on
nmcli device status
nmcli device wifi list ifname wlan0
nmcli device wifi connect 'SSID' password 'PASSWORD' ifname wlan0
```

The password is stored in NetworkManager's connection profile. Use
`nmcli connection show` to list profiles and `nmcli connection delete ID` to
remove one. Do not put credentials in the kernel command line or in the ISO.

The live installer includes the same tools and starts NetworkManager after
udev and D-Bus are ready. From its shell, use `nmcli` directly:

```sh
nmcli device status
nmcli device wifi list ifname wlan0
nmcli device wifi connect 'SSID' password 'PASSWORD' ifname wlan0
```

`/usr/local/sbin/surface-wifi-start` starts NetworkManager before waiting up to
30 seconds for the wireless interface. The manager stays running on timeout
so later devices can still be managed. Built-in ath12k can request firmware
before the external initramfs is unpacked, leaving WCN7850 unbound with
`amss.bin` error `-2` followed by MHI error `-110`. After the live firmware
is available, the helper retries only unbound PCI devices with ID
`17cb:1107`. It never detaches a bound driver. On timeout, PCI device/driver
information, network interfaces, and the kernel log are saved in
`/run/proxmox-installer/surface-wifi.log` for diagnosis.

The ISO builder takes the ARM64 Debian packages from an external directory so
binary packages are not committed to this repository:

```sh
./build-proxmox-iso.sh \
  --network-manager-packages /path/to/arm64-network-manager-debs
```

The directory must contain `network-manager`, `libnm0`, `wpasupplicant`, `iw`,
`rfkill`, `wireless-regdb`, and their ARM64 dependencies. The builder copies
them into the ISO package pool, installs them during Proxmox installation, and
verifies the resulting initramfs and installer module.

If `wlan0` is absent, inspect the hardware and firmware path before changing
NetworkManager configuration:

```sh
lspci -nnk
iw dev
dmesg | grep -Ei 'ath12k|firmware|wlan'
```

The WCN7850 firmware must be present under
`/lib/firmware/ath12k/WCN7850/hw2.0`; the Proxmox builder accepts that directory
with `--wcn7850-firmware`. The Arch builder requires the working boot firmware
reference described in [archlinux.md](archlinux.md), including its original
`board.bin`. Both the live root and early initramfs need the same set.
