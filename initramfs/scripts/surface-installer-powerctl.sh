#!/bin/sh
# The Proxmox installer uses its startup script as PID 1.  systemctl-based
# power commands cannot talk to it, so use the BusyBox reboot syscall applet.

action=${0##*/}
case "$action" in
    reboot)
        busybox_action=reboot
        sysrq_action=b
        ;;
    poweroff|halt)
        busybox_action=poweroff
        sysrq_action=o
        ;;
    *)
        echo "unsupported power action: $action" >&2
        exit 2
        ;;
esac

sync
if [ -x /usr/bin/busybox ]; then
    /usr/bin/busybox "$busybox_action" -f && exit 0
fi
if [ -x /bin/busybox ]; then
    /bin/busybox "$busybox_action" -f && exit 0
fi

echo "$sysrq_action" > /proc/sysrq-trigger
sleep 100
exit 1
