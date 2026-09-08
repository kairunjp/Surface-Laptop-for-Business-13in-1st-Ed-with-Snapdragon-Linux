#!/surface-installer/busybox sh
# Keep the initramfs BusyBox as PID 1 across the live-root handoff. A crashing
# dynamic loader, shell or installer must not kill init and panic the kernel.
bb=/surface-installer/busybox
export PATH=/sbin:/bin:/usr/sbin:/usr/bin
"$bb" mkdir -p /run
echo 'surface-init: starting Proxmox installer under PID 1 supervision'
"$bb" setsid /sbin/unconfigured.sh &
installer_pid=$!
wait "$installer_pid"
status=$?
echo "surface-init: installer exited with status $status; automatic reboot suppressed"
"$bb" dmesg > /run/surface-installer-dmesg.log
echo 'surface-init: kernel log saved to /run/surface-installer-dmesg.log'
while :; do
    echo 'surface-init: recovery shell; use reboot or poweroff explicitly'
    "$bb" setsid "$bb" sh -i
    "$bb" sleep 1
done
