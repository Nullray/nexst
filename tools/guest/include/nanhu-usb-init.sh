#!/bin/sh
export PATH=/sbin:/bin:/usr/sbin:/usr/bin
/bin/mount -t devtmpfs devtmpfs /dev || exit 1
exec </dev/hvc0 >/dev/hvc0 2>&1
printf '[nanhu-init] hvc0 console connected\n'
/bin/mount -t proc proc /proc || exit 1
/bin/mount -t sysfs sysfs /sys || exit 1
/bin/mount -t tmpfs tmpfs /tmp || exit 1
printf '[nanhu-init] starting console shell via BusyBox init\n'
exec /bin/busybox init
