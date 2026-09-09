#!/bin/sh
# Start NetworkManager before waiting for WCN7850 so late devices are managed.
# The live installer has no systemd or SysV service manager.
set -u

surface_wifi_present() {
    for iface in /sys/class/net/*; do
        [ -d "$iface/wireless" ] && return 0
    done
    return 1
}

# Built-in ath12k can probe before the external initramfs firmware is unpacked.
# A failed PCI probe leaves the device unbound; udev coldplug does not retry
# a built-in driver. Retry only this device, once firmware is accessible.
surface_wifi_probe() {
    for firmware in amss.bin m3.bin board-2.bin; do
        if [ ! -s "/lib/firmware/ath12k/WCN7850/hw2.0/$firmware" ]; then
            echo "surface-wifi: missing WCN7850 firmware: $firmware" >&2
            return 1
        fi
    done
    for device in /sys/bus/pci/devices/*; do
        [ -r "$device/vendor" ] && [ -r "$device/device" ] || continue
        [ "$(cat "$device/vendor")" = 0x17cb ] || continue
        [ "$(cat "$device/device")" = 0x1107 ] || continue
        # Never detach a working driver or disturb an ongoing probe.
        [ ! -L "$device/driver" ] || continue
        echo "surface-wifi: retrying unbound WCN7850 at ${device##*/}" >&2
        if ! echo "${device##*/}" > /sys/bus/pci/drivers_probe; then
            echo "surface-wifi: WCN7850 reprobe failed; see kernel log" >&2
            return 1
        fi
    done
}

surface_wifi_present || surface_wifi_probe || true

if ! pidof dbus-daemon >/dev/null 2>&1; then
    if [ -x /etc/init.d/dbus ]; then
        /etc/init.d/dbus start >/tmp/surface-dbus.log 2>&1 || true
    else
        mkdir -p /run/dbus
        dbus-daemon --system --fork >/tmp/surface-dbus.log 2>&1 || true
    fi
fi
if ! pidof NetworkManager >/dev/null 2>&1; then
    /usr/sbin/NetworkManager --no-daemon \
        >/tmp/surface-network-manager.log 2>&1 &
fi
for wait_try in 1 2 3 4 5; do
    nmcli general status >/dev/null 2>&1 && break
    sleep 1
done
if ! nmcli general status >/dev/null 2>&1; then
    echo "surface-wifi: NetworkManager did not start; see /tmp/surface-network-manager.log" >&2
    exit 1
fi
nmcli radio wifi on >/dev/null 2>&1 || true
# Firmware/PCIe initialization can finish after userspace starts. Keep the
# manager alive even on timeout so it can pick up a device which arrives later.
wifi_wait=0
while ! surface_wifi_present && [ "$wifi_wait" -lt 30 ]; do
    sleep 1
    wifi_wait=$((wifi_wait + 1))
done
if ! surface_wifi_present; then
    mkdir -p /run/proxmox-installer
    {
        echo '=== kernel command line ==='
        cat /proc/cmdline
        echo '=== PCI devices and drivers ==='
        lspci -nnk
        echo '=== network interfaces ==='
        ip link
        iw dev
        echo '=== kernel log ==='
        dmesg
    } >/run/proxmox-installer/surface-wifi.log 2>&1
    echo "surface-wifi: no wireless interface after 30s; NetworkManager remains running" >&2
    echo "surface-wifi: diagnostics saved to /run/proxmox-installer/surface-wifi.log" >&2
    exit 1
fi
echo "surface-wifi: Wi-Fi is ready; use nmcli device wifi list/connect" >&2
