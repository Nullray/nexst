#!/bin/sh

set -u

rdma_device=${RDMA_DEVICE:-iwo3}
peer_device=${PEER_MEMORY_DEVICE:-/dev/xdma0_peer}
remote_host=${REMOTE_HOST:-10.30.19.15}
memory_mode=${RDMA_MEMORY_MODE:-peer-dmabuf}
probe=${PEER_MR_PROBE:-./scope-peer-mr-probe}
failed=0

check()
{
    label=$1
    shift
    if "$@"; then
        printf '[PASS] %s\n' "$label"
    else
        printf '[FAIL] %s\n' "$label" >&2
        failed=1
    fi
}

printf 'Scope remote-RDMA preflight\n'
printf '  RDMA device: %s\n  memory mode: %s\n  remote host: %s\n' \
       "$rdma_device" "$memory_mode" "$remote_host"

check "verbs device exists" sh -c \
    "ibv_devices 2>/dev/null | awk 'NR > 2 {print \$1}' | grep -Fx '$rdma_device' >/dev/null"
check "verbs port is active" sh -c \
    "ibv_devinfo -d '$rdma_device' 2>/dev/null | grep -Eq 'state:[[:space:]]+PORT_ACTIVE'"
check "kernel route selects an interface" ip route get "$remote_host"
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
route_netdev=$(ip route get "$remote_host" 2>/dev/null |
    awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
if [ -n "$rdma_netdev" ] && [ "$rdma_netdev" = "$route_netdev" ]; then
    printf '[PASS] route uses RDMA netdev %s\n' "$rdma_netdev"
else
    printf '[FAIL] RDMA netdev (%s) and route netdev (%s) differ\n' \
           "${rdma_netdev:-unknown}" "${route_netdev:-unknown}" >&2
    failed=1
fi

if [ "$memory_mode" = host-staging ]; then
    printf '%s\n' \
        '[WARN] host-staging is compatible with irdma but adds QEMU/XDMA payload copies'
    exit "$failed"
fi
if [ "$memory_mode" != peer-dmabuf ]; then
    printf '[FAIL] unsupported RDMA_MEMORY_MODE=%s\n' "$memory_mode" >&2
    exit 1
fi

printf '  peer memory: %s\n' "$peer_device"

kernel_release=$(uname -r)
kernel_config=/boot/config-$kernel_release
if [ -r "$kernel_config" ]; then
    check "CONFIG_PCI_P2PDMA enabled" grep -q '^CONFIG_PCI_P2PDMA=y$' "$kernel_config"
else
    printf '[WARN] cannot read %s; verify CONFIG_PCI_P2PDMA manually\n' \
           "$kernel_config"
fi

check "XDMA peer exporter exists" test -c "$peer_device"
if [ -x "$probe" ] && [ -c "$peer_device" ]; then
    printf '%s\n' '[INFO] probing provider dma-buf MR registration'
    if "$probe" --rdma-device "$rdma_device" \
                --peer-memory-device "$peer_device"; then
        printf '%s\n' '[PASS] XDMA dma-buf registered as an RNIC MR'
    else
        printf '%s\n' \
            '[FAIL] verbs exists, but this provider/kernel cannot register the XDMA dma-buf MR' >&2
        failed=1
    fi
else
    printf '[WARN] build %s and load the XDMA peer exporter before the MR probe\n' \
           "$probe"
fi

exit "$failed"
