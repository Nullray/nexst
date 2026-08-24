#!/bin/sh

set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "Usage: $0 RDMA_DEVICE /dev/nvmeX /dev/nvmeXnY [DEVICE_ID]" >&2
    exit 2
fi

rdma_device=$1
controller=$2
namespace=$3
device_id=${4:-remote-nvme0}
listen_addr=10.30.19.15
service=${SCOPE_REMOTE_SERVICE:-7471}
staging_size=${SCOPE_REMOTE_STAGING_SIZE:-4194304}
agent=${SCOPE_REMOTE_AGENT:-./scope-remote-agent}

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root so O_DIRECT and NVMe admin ioctls are available." >&2
    exit 1
fi
test -x "$agent"
test -c "$controller"
test -b "$namespace"
ibv_devices 2>/dev/null | awk 'NR > 2 {print $1}' |
    grep -Fx "$rdma_device" >/dev/null
ibv_devinfo -d "$rdma_device" 2>/dev/null |
    grep -Eq 'state:[[:space:]]+PORT_ACTIVE'
rdma_netdev=
if command -v ibdev2netdev >/dev/null 2>&1; then
    rdma_netdev=$(ibdev2netdev 2>/dev/null |
        awk -v dev="$rdma_device" '$1 == dev {print $5; exit}')
else
    for net_path in /sys/class/infiniband/"$rdma_device"/device/net/*; do
        if [ -e "$net_path" ]; then
            rdma_netdev=${net_path##*/}
            break
        fi
    done
fi
if [ -z "$rdma_netdev" ]; then
    echo "Cannot map $rdma_device to a network interface." >&2
    exit 1
fi
ip -o addr show dev "$rdma_netdev" | grep -F " $listen_addr/" >/dev/null
if findmnt -rn -S "$namespace" >/dev/null 2>&1; then
    echo "$namespace is mounted; refusing to expose an active filesystem." >&2
    exit 1
fi

echo "Starting Scope remote NVMe agent on $listen_addr:$service"
echo "  RDMA device: $rdma_device"
echo "  namespace:   $namespace (must remain reserved for this agent)"
exec "$agent" \
    --listen "$listen_addr" --service "$service" \
    --rdma-device "$rdma_device" --device-id "$device_id" \
    --controller "$controller" --namespace "$namespace" \
    --namespace-id 1 --staging-size "$staging_size"
