#!/usr/bin/env bash
set -euo pipefail

# Host A orchestrator for exporting one Host B Intel 82599 to XiangShan.
# Environment variables below may be overridden before invoking the script.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)

REMOTE_HOST=${REMOTE_HOST:-10.30.19.15}
REMOTE_USER=${REMOTE_USER:-yanjiarun}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_rsa_132}
REMOTE_RDMA_DEV=${REMOTE_RDMA_DEV:-iwo3}
REMOTE_RDMA_NETDEV=${REMOTE_RDMA_NETDEV:-eno3}
REMOTE_NIC_NETDEV=${REMOTE_NIC_NETDEV:-ens3f0}
REMOTE_DEVICE_ID=${REMOTE_DEVICE_ID:-remote-82599-0}
REMOTE_SERVICE=${REMOTE_SERVICE:-7472}
REMOTE_DIR=${REMOTE_DIR:-/home/$REMOTE_USER/scope_remote_agent_16}
LOCAL_RDMA_DEV=${LOCAL_RDMA_DEV:-iwo3}
CONFIG_OUT=${CONFIG_OUT:-$REPO_ROOT/vswitch-backends-remote-82599.json}

ACTIVE_KEY=
TEMP_KEY=
SSH=()
SCP=()

die()
{
    printf 'error: %s\n' "$*" >&2
    exit 1
}

cleanup()
{
    if [[ -n "$TEMP_KEY" ]]; then
        rm -f -- "$TEMP_KEY"
    fi
}
trap cleanup EXIT

validate_settings()
{
    [[ "$REMOTE_HOST" =~ ^[0-9A-Fa-f:.]+$ ]] || die "invalid REMOTE_HOST"
    [[ "$REMOTE_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die "invalid REMOTE_USER"
    [[ "$REMOTE_RDMA_DEV" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid REMOTE_RDMA_DEV"
    [[ "$REMOTE_RDMA_NETDEV" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid REMOTE_RDMA_NETDEV"
    [[ "$REMOTE_NIC_NETDEV" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid REMOTE_NIC_NETDEV"
    [[ "$LOCAL_RDMA_DEV" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid LOCAL_RDMA_DEV"
    [[ "$REMOTE_DEVICE_ID" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid REMOTE_DEVICE_ID"
    [[ "$REMOTE_SERVICE" =~ ^[0-9]+$ ]] || die "invalid REMOTE_SERVICE"
    [[ "$REMOTE_DIR" =~ ^/[A-Za-z0-9_./-]+$ ]] || die "invalid REMOTE_DIR"
}

prepare_ssh()
{
    local mode

    [[ -f "$SSH_KEY" ]] || die "SSH key not found: $SSH_KEY"
    mode=$(stat -c '%a' "$SSH_KEY")
    if (( (8#$mode & 077) != 0 )); then
        TEMP_KEY=$(mktemp /tmp/scope-id-rsa-132.XXXXXX)
        cp -- "$SSH_KEY" "$TEMP_KEY"
        chmod 600 "$TEMP_KEY"
        ACTIVE_KEY=$TEMP_KEY
    else
        ACTIVE_KEY=$SSH_KEY
    fi
    SSH=(ssh -i "$ACTIVE_KEY" -o BatchMode=yes -o ConnectTimeout=10
         -o StrictHostKeyChecking=accept-new "$REMOTE_USER@$REMOTE_HOST")
    SCP=(scp -i "$ACTIVE_KEY" -o BatchMode=yes -o ConnectTimeout=10
         -o StrictHostKeyChecking=accept-new)
}

remote()
{
    "${SSH[@]}" "$@"
}

remote_tty()
{
    ssh -tt -i "$ACTIVE_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new "$REMOTE_USER@$REMOTE_HOST" "$@"
}

check_local()
{
    local route

    command -v rdma >/dev/null || die "Host A is missing the rdma utility"
    command -v scp >/dev/null || die "Host A is missing scp"
    route=$(ip route get "$REMOTE_HOST")
    printf 'Host A route: %s\n' "$route"
    rdma link show "$LOCAL_RDMA_DEV/1" 2>/dev/null |
        grep -q 'state ACTIVE' ||
        die "Host A $LOCAL_RDMA_DEV is not ACTIVE"
}

check_remote_topology()
{
    local cmd

    printf -v cmd '%s' "set -eu; \
test \"\$(cat /sys/class/net/$REMOTE_RDMA_NETDEV/device/vendor)\" = 0x8086; \
test \"\$(cat /sys/class/net/$REMOTE_RDMA_NETDEV/device/device)\" = 0x37d1; \
test \"\$(basename \"\$(readlink -f /sys/class/net/$REMOTE_RDMA_NETDEV/device/driver)\")\" = i40e; \
test \"\$(cat /sys/class/net/$REMOTE_NIC_NETDEV/device/vendor)\" = 0x8086; \
test \"\$(cat /sys/class/net/$REMOTE_NIC_NETDEV/device/device)\" = 0x10fb; \
test \"\$(basename \"\$(readlink -f /sys/class/net/$REMOTE_NIC_NETDEV/device/driver)\")\" = ixgbe; \
ip -o -4 address show dev $REMOTE_RDMA_NETDEV | grep -q ' $REMOTE_HOST/'; \
rdma link show $REMOTE_RDMA_DEV/1 | grep -q 'state ACTIVE'; \
if ip -o address show dev $REMOTE_NIC_NETDEV scope global | grep -q .; then \
  echo '$REMOTE_NIC_NETDEV has a Host B IP address; refusing to repurpose it' >&2; exit 1; \
fi; \
echo 'Host B topology OK: $REMOTE_RDMA_DEV/$REMOTE_RDMA_NETDEV transports RDMA; $REMOTE_NIC_NETDEV exports 8086:10fb'; \
ip -br link show dev $REMOTE_RDMA_NETDEV; \
ip -br link show dev $REMOTE_NIC_NETDEV; \
cat /sys/class/net/$REMOTE_NIC_NETDEV/carrier 2>/dev/null || true"
    remote "$cmd"
}

report_remote_dependencies()
{
    remote "for p in librdmacm1 librdmacm-dev libibverbs-dev rdma-core ibverbs-utils; do dpkg-query -W -f='\${Status}' \"\$p\" 2>/dev/null | grep -q 'install ok installed' || echo missing:\$p; done"
}

install_remote_dependencies()
{
    printf '%s\n' 'Remote sudo requires the Host B password.'
    remote_tty "sudo apt-get update && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential pkg-config librdmacm-dev libibverbs-dev rdma-core ibverbs-utils iproute2 ethtool"
}

deploy_and_build()
{
    remote "mkdir -p '$REMOTE_DIR'"
    "${SCP[@]}" \
        "$SCRIPT_DIR/Makefile" \
        "$SCRIPT_DIR/scope_remote_proto.h" \
        "$SCRIPT_DIR/scope_remote_nic_agent.c" \
        "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"
    remote "make -C '$REMOTE_DIR' scope-remote-nic-agent"
}

write_qemu_config()
{
    local tmp

    tmp=$(mktemp "${CONFIG_OUT}.XXXXXX")
    cat >"$tmp" <<EOF
{
  "version": 1,
  "devices": [
    {
      "type": "ixgbe",
      "transport": "remote-rdma",
      "remote-host": "$REMOTE_HOST",
      "remote-service": "$REMOTE_SERVICE",
      "remote-device-id": "$REMOTE_DEVICE_ID",
      "rdma-device": "$LOCAL_RDMA_DEV",
      "rdma-memory-mode": "host-staging",
      "rdma-staging-size": 4194304
    }
  ]
}
EOF
    mv -- "$tmp" "$CONFIG_OUT"
    printf 'Wrote QEMU backend config: %s\n' "$CONFIG_OUT"
}

start_remote_agent()
{
    local inner cmd

    inner="set -eu; ip link set dev $REMOTE_NIC_NETDEV up; \
if test -f '$REMOTE_DIR/scope-remote-nic-agent.pid'; then \
  oldpid=\$(cat '$REMOTE_DIR/scope-remote-nic-agent.pid'); \
  kill \"\$oldpid\" 2>/dev/null || true; \
fi; \
cd '$REMOTE_DIR'; \
nohup ./scope-remote-nic-agent \
  --listen $REMOTE_HOST --service $REMOTE_SERVICE \
  --rdma-device $REMOTE_RDMA_DEV \
  --device-id $REMOTE_DEVICE_ID \
  --netdev $REMOTE_NIC_NETDEV \
  >scope-remote-nic-agent.log 2>&1 & \
echo \$! >scope-remote-nic-agent.pid"
    printf -v cmd 'sudo sh -c %q' "$inner"
    printf '%s\n' 'Remote sudo requires the Host B password.'
    remote_tty "$cmd"
    sleep 1
    status_remote_agent
}

stop_remote_agent()
{
    local inner cmd

    inner="if test -f '$REMOTE_DIR/scope-remote-nic-agent.pid'; then \
pid=\$(cat '$REMOTE_DIR/scope-remote-nic-agent.pid'); \
kill \"\$pid\" 2>/dev/null || true; \
rm -f '$REMOTE_DIR/scope-remote-nic-agent.pid'; fi"
    printf -v cmd 'sudo sh -c %q' "$inner"
    remote_tty "$cmd"
}

status_remote_agent()
{
    remote "set -eu; test -s '$REMOTE_DIR/scope-remote-nic-agent.pid'; pid=\$(cat '$REMOTE_DIR/scope-remote-nic-agent.pid'); test -d \"/proc/\$pid\"; tr '\\000' ' ' <\"/proc/\$pid/cmdline\" | grep -q scope-remote-nic-agent; echo agent_pid=\$pid; tail -n 20 '$REMOTE_DIR/scope-remote-nic-agent.log'; carrier=\$(cat /sys/class/net/$REMOTE_NIC_NETDEV/carrier 2>/dev/null || echo unknown); echo 82599_carrier=\$carrier; if test \"\$carrier\" != 1; then echo 'warning: connect the 82599 SFP+/cable before XiangShan DHCP or ping' >&2; fi"
}

show_qemu_command()
{
    cat <<EOF

Start the repository-16 RDMA QEMU build with:

sudo $REPO_ROOT/qemu-mount/build-rdma/qemu-system-x86_64 \\
  -machine q35 -m 128M -display none -monitor null -serial null \\
  -device pcie-root-port,id=rp1,bus=pcie.0 \\
  -device scope-fpga-vswitch,bus=rp1,backend-config=$CONFIG_OUT,\\
fpga-host-bdf=0000:3b:00.0,xdma-user-dev=/dev/xdma0_user,\\
xdma-ctrl-dev=/dev/xdma0_control,xdma-bypass-dev=/dev/xdma0_bypass,\\
guest-ddr-base=0x80000000,guest-ddr-size=0x80000000,dma32-ring-size=0x10000
EOF
}

usage()
{
    cat <<EOF
Usage: $(basename "$0") ACTION

Actions:
  check       Verify Host A/Host B topology and list missing remote packages
  install     Install Host B RDMA build/runtime packages (interactive sudo)
  deploy      Copy and build scope-remote-nic-agent on Host B
  configure   Generate the Host A QEMU backend JSON
  start       Bring up the dedicated 82599 and start the Host B agent
  status      Show Host B agent log, PID and 82599 carrier
  stop        Stop the Host B agent
  all         Check, install, deploy, configure and start

Defaults match the inspected machines. Override with environment variables,
for example REMOTE_NIC_NETDEV=ens3f1 or LOCAL_RDMA_DEV=iwo3.
EOF
}

main()
{
    local action=${1:-check}

    validate_settings
    prepare_ssh
    case "$action" in
    check)
        check_local
        check_remote_topology
        report_remote_dependencies
        ;;
    install)
        install_remote_dependencies
        ;;
    deploy)
        check_remote_topology
        deploy_and_build
        ;;
    configure)
        check_local
        write_qemu_config
        show_qemu_command
        ;;
    start)
        check_local
        check_remote_topology
        start_remote_agent
        show_qemu_command
        ;;
    status)
        status_remote_agent
        ;;
    stop)
        stop_remote_agent
        ;;
    all)
        check_local
        check_remote_topology
        install_remote_dependencies
        deploy_and_build
        write_qemu_config
        start_remote_agent
        show_qemu_command
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
    esac
}

main "$@"
