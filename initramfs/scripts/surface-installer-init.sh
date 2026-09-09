#!/surface-installer/busybox sh
# Keep the initramfs BusyBox as PID 1 across the live-root handoff. A crashing
# dynamic loader, shell or installer must not kill init and panic the kernel.
bb=/surface-installer/busybox
export PATH=/sbin:/bin:/usr/sbin:/usr/bin
# Restore the console selection used by the initramfs before switch_root.
console=/dev/tty1
for par in $("$bb" cat /proc/cmdline); do
    case "$par" in
        console=tty*) console=/dev/${par#console=}; console=${console%%,*} ;;
    esac
done
"$bb" mkdir -p /run
echo 'surface-init: starting Proxmox installer under PID 1 supervision'
# An asynchronous shell command otherwise gets /dev/null as stdin. Open the
# terminal AFTER setsid so the installer also acquires a controlling terminal.
"$bb" setsid "$bb" sh -c 'exec /sbin/unconfigured.sh <"$1" >"$1" 2>&1' sh "$console" &
installer_pid=$!
wait "$installer_pid"
status=$?
echo "surface-init: installer exited with status $status; automatic reboot suppressed"
"$bb" dmesg > /run/surface-installer-dmesg.log
echo 'surface-init: kernel log saved to /run/surface-installer-dmesg.log'
while :; do
    echo 'surface-init: recovery shell; use reboot or poweroff explicitly'
    "$bb" setsid "$bb" sh -c 'exec /surface-installer/busybox sh -i <"$1" >"$1" 2>&1' sh "$console"
    "$bb" sleep 1
done
