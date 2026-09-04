#!/usr/bin/env bash
set -euo pipefail

# Host A orchestrator for the unbound physical 82599 shadow-ring mode.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)

REMOTE_HOST=${REMOTE_HOST:-10.30.19.15}
REMOTE_USER=${REMOTE_USER:-yanjiarun}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_rsa_132}
REMOTE_RDMA_DEV=${REMOTE_RDMA_DEV:-iwo3}
REMOTE_RDMA_NETDEV=${REMOTE_RDMA_NETDEV:-eno3}
REMOTE_NIC_BDF=${REMOTE_NIC_BDF:-0000:5e:00.0}
REMOTE_NIC_NETDEV=${REMOTE_NIC_NETDEV:-ens3f0}
REMOTE_DEVICE_ID=${REMOTE_DEVICE_ID:-remote-82599-shadow-0}
REMOTE_SERVICE=${REMOTE_SERVICE:-7472}
REMOTE_DIR=${REMOTE_DIR:-/home/$REMOTE_USER/scope_remote_agent_16}
REMOTE_HUGEPAGE_FILE=${REMOTE_HUGEPAGE_FILE:-/dev/hugepages/scope-82599-shadow}
REMOTE_ALLOW_UNSAFE_IDENTITY_DMA=${REMOTE_ALLOW_UNSAFE_IDENTITY_DMA:-0}
REMOTE_RESTORE_SFP_TX_LASER=${REMOTE_RESTORE_SFP_TX_LASER:-1}
REMOTE_REQUIRE_LINK_UP=${REMOTE_REQUIRE_LINK_UP:-1}
REMOTE_SUDO_NONINTERACTIVE=${REMOTE_SUDO_NONINTERACTIVE:-0}
LOCAL_RDMA_DEV=${LOCAL_RDMA_DEV:-iwo3}
CONFIG_OUT=${CONFIG_OUT:-$REPO_ROOT/vswitch-backends-remote-82599-shadow.json}

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
    [[ "$REMOTE_NIC_BDF" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] ||
        die "invalid REMOTE_NIC_BDF"
    [[ "$REMOTE_NIC_NETDEV" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid REMOTE_NIC_NETDEV"
    [[ "$LOCAL_RDMA_DEV" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid LOCAL_RDMA_DEV"
    [[ "$REMOTE_DEVICE_ID" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid REMOTE_DEVICE_ID"
    [[ "$REMOTE_SERVICE" =~ ^[0-9]+$ ]] || die "invalid REMOTE_SERVICE"
    [[ "$REMOTE_DIR" =~ ^/[A-Za-z0-9_./-]+$ ]] || die "invalid REMOTE_DIR"
    [[ "$REMOTE_HUGEPAGE_FILE" =~ ^/[A-Za-z0-9_./-]+$ ]] ||
        die "invalid REMOTE_HUGEPAGE_FILE"
    [[ "$REMOTE_SUDO_NONINTERACTIVE" == 0 ||
       "$REMOTE_SUDO_NONINTERACTIVE" == 1 ]] ||
        die "REMOTE_SUDO_NONINTERACTIVE must be 0 or 1"
    [[ "$REMOTE_RESTORE_SFP_TX_LASER" == 0 ||
       "$REMOTE_RESTORE_SFP_TX_LASER" == 1 ]] ||
        die "REMOTE_RESTORE_SFP_TX_LASER must be 0 or 1"
    [[ "$REMOTE_REQUIRE_LINK_UP" == 0 ||
       "$REMOTE_REQUIRE_LINK_UP" == 1 ]] ||
        die "REMOTE_REQUIRE_LINK_UP must be 0 or 1"
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

remote_root()
{
    local command=$1 quoted

    if [[ "$REMOTE_SUDO_NONINTERACTIVE" == 1 ]]; then
        printf -v quoted 'sudo -n sh -c %q' "$command"
        remote "$quoted"
    else
        printf -v quoted 'sudo sh -c %q' "$command"
        ssh -tt -i "$ACTIVE_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new \
            "$REMOTE_USER@$REMOTE_HOST" "$quoted"
    fi
}

check_local()
{
    command -v rdma >/dev/null || die "Host A is missing the rdma utility"
    command -v scp >/dev/null || die "Host A is missing scp"
    printf 'Host A route: %s\n' "$(ip route get "$REMOTE_HOST")"
    rdma link show "$LOCAL_RDMA_DEV/1" 2>/dev/null | grep -q 'state ACTIVE' ||
        die "Host A $LOCAL_RDMA_DEV is not ACTIVE"
}

check_remote_topology()
{
    local cmd

    printf -v cmd '%s' "set -eu; \
test \"\$(cat /sys/class/net/$REMOTE_RDMA_NETDEV/device/vendor)\" = 0x8086; \
test \"\$(basename \"\$(readlink -f /sys/class/net/$REMOTE_RDMA_NETDEV/device/driver)\")\" = i40e; \
test \"\$(cat /sys/bus/pci/devices/$REMOTE_NIC_BDF/vendor)\" = 0x8086; \
test \"\$(cat /sys/bus/pci/devices/$REMOTE_NIC_BDF/device)\" = 0x10fb; \
ip -o -4 address show dev $REMOTE_RDMA_NETDEV | grep -q ' $REMOTE_HOST/'; \
rdma link show $REMOTE_RDMA_DEV/1 | grep -q 'state ACTIVE'; \
if test -e /sys/class/net/$REMOTE_NIC_NETDEV; then \
  test \"\$(basename \"\$(readlink -f /sys/class/net/$REMOTE_NIC_NETDEV/device)\")\" = $REMOTE_NIC_BDF; \
  if ip -o address show dev $REMOTE_NIC_NETDEV scope global | grep -q .; then \
    echo '$REMOTE_NIC_NETDEV has a Host B IP address' >&2; exit 1; fi; \
elif test -e /sys/bus/pci/devices/$REMOTE_NIC_BDF/driver; then \
  echo 'target is bound but $REMOTE_NIC_NETDEV is missing' >&2; exit 1; fi; \
case \"\$(cat /proc/cmdline)\" in *intel_iommu=on*) \
  echo 'intel_iommu=on is incompatible unless the target is demonstrably in an identity domain' >&2; exit 1;; esac; \
echo 'Host B topology OK'; \
echo rdma=$REMOTE_RDMA_DEV/$REMOTE_RDMA_NETDEV target=$REMOTE_NIC_BDF/$REMOTE_NIC_NETDEV; \
grep -E 'HugePages_(Total|Free)|Hugepagesize' /proc/meminfo"
    remote "$cmd"
}

deploy_and_build()
{
    remote "mkdir -p '$REMOTE_DIR'"
    "${SCP[@]}" \
        "$SCRIPT_DIR/Makefile" \
        "$SCRIPT_DIR/scope_remote_proto.h" \
        "$SCRIPT_DIR/scope_remote_ixgbe_shadow_agent.c" \
        "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"
    remote "make -C '$REMOTE_DIR' scope-remote-ixgbe-shadow-agent"
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
      "remote-device-mode": "shadow-ring",
      "remote-host": "$REMOTE_HOST",
      "remote-service": "$REMOTE_SERVICE",
      "remote-device-id": "$REMOTE_DEVICE_ID",
      "rdma-device": "$LOCAL_RDMA_DEV",
      "rdma-memory-mode": "inline"
    }
  ]
}
EOF
    mv -- "$tmp" "$CONFIG_OUT"
    printf 'Wrote QEMU backend config: %s\n' "$CONFIG_OUT"
}

start_remote_agent()
{
    local inner laser_arg= require_link_arg=

    if [[ "$REMOTE_RESTORE_SFP_TX_LASER" == 1 ]]; then
        laser_arg=--restore-sfp-tx-laser
    fi
    if [[ "$REMOTE_REQUIRE_LINK_UP" == 1 ]]; then
        require_link_arg=--require-link-up
    fi

    inner="set -eu
test ! -e /sys/bus/pci/devices/$REMOTE_NIC_BDF/driver || {
  ip link set dev $REMOTE_NIC_NETDEV up
  sleep 2
  echo $REMOTE_NIC_BDF > /sys/bus/pci/drivers/ixgbe/unbind
}
test ! -e /sys/bus/pci/devices/$REMOTE_NIC_BDF/driver
free=\$(awk '/HugePages_Free:/ { print \$2 }' /proc/meminfo)
if test \"\$free\" -lt 1; then
  total=\$(awk '/HugePages_Total:/ { print \$2 }' /proc/meminfo)
  echo \$((total + 1)) > /proc/sys/vm/nr_hugepages
fi
free=\$(awk '/HugePages_Free:/ { print \$2 }' /proc/meminfo)
test \"\$free\" -ge 1
if test -f '$REMOTE_DIR/scope-remote-ixgbe-shadow-agent.pid'; then
  oldpid=\$(cat '$REMOTE_DIR/scope-remote-ixgbe-shadow-agent.pid')
  if test -d /proc/\$oldpid; then
    tr '\\000' ' ' < /proc/\$oldpid/cmdline | grep -q scope-remote-ixgbe-shadow-agent || {
      echo 'refusing to signal a reused shadow-agent PID' >&2; exit 1; }
    kill \"\$oldpid\"
    for i in 1 2 3 4 5; do test ! -d /proc/\$oldpid && break; sleep 1; done
    test ! -d /proc/\$oldpid || {
      echo 'old shadow agent did not stop; target remains unbound' >&2; exit 1; }
  fi
  rm -f '$REMOTE_DIR/scope-remote-ixgbe-shadow-agent.pid'
fi
cd '$REMOTE_DIR'
rm -f '$REMOTE_HUGEPAGE_FILE'
nohup ./scope-remote-ixgbe-shadow-agent \\
  --listen $REMOTE_HOST --service $REMOTE_SERVICE \\
  --rdma-device $REMOTE_RDMA_DEV --device-id $REMOTE_DEVICE_ID \\
  --pci-bdf $REMOTE_NIC_BDF --hugepage-file $REMOTE_HUGEPAGE_FILE \\
  --allow-unsafe-identity-dma \\
  $laser_arg $require_link_arg \\
  >scope-remote-ixgbe-shadow-agent.log 2>&1 &
echo \$! >scope-remote-ixgbe-shadow-agent.pid"
    remote_root "$inner"
    for _ in {1..8}; do
        if remote "grep -q 'listening .* link=up' \
            '$REMOTE_DIR/scope-remote-ixgbe-shadow-agent.log' 2>/dev/null"; then
            break
        fi
        sleep 1
    done
    status_remote_agent
}

stop_remote_agent()
{
    local inner

    inner="set -eu
if test -f '$REMOTE_DIR/scope-remote-ixgbe-shadow-agent.pid'; then
  pid=\$(cat '$REMOTE_DIR/scope-remote-ixgbe-shadow-agent.pid')
  if test -d /proc/\$pid; then
    tr '\\000' ' ' < /proc/\$pid/cmdline | grep -q scope-remote-ixgbe-shadow-agent || {
      echo 'refusing to signal a reused shadow-agent PID' >&2; exit 1; }
    kill \"\$pid\"
    for i in 1 2 3 4 5; do test ! -d /proc/\$pid && break; sleep 1; done
    test ! -d /proc/\$pid || {
      echo 'shadow agent did not stop; refusing to reprobe ixgbe' >&2; exit 1; }
  fi
  rm -f '$REMOTE_DIR/scope-remote-ixgbe-shadow-agent.pid'
fi
if test ! -e /sys/bus/pci/devices/$REMOTE_NIC_BDF/driver; then
  echo $REMOTE_NIC_BDF > /sys/bus/pci/drivers_probe
fi"
    remote_root "$inner"
}

status_remote_agent()
{
    remote "set -u
log='$REMOTE_DIR/scope-remote-ixgbe-shadow-agent.log'
test -s '$REMOTE_DIR/scope-remote-ixgbe-shadow-agent.pid' || {
  echo 'error: shadow agent PID file is missing' >&2; test ! -f \"\$log\" || tail -n 30 \"\$log\"; exit 1; }
pid=\$(cat '$REMOTE_DIR/scope-remote-ixgbe-shadow-agent.pid')
if test ! -d /proc/\$pid ||
   ! tr '\\000' ' ' < /proc/\$pid/cmdline | grep -q scope-remote-ixgbe-shadow-agent; then
  echo 'error: shadow agent is not running' >&2
  test ! -f \"\$log\" || tail -n 30 \"\$log\"
  exit 1
fi
echo agent_pid=\$pid
tail -n 30 \"\$log\"
grep -q 'listening .* link=up' \"\$log\" || {
  echo 'error: shadow agent is not ready with physical link up' >&2; exit 1; }
if test -e /sys/bus/pci/devices/$REMOTE_NIC_BDF/driver; then
  echo 'error: target unexpectedly rebound to a driver' >&2; exit 1; fi"
}

usage()
{
    cat <<EOF
Usage: $(basename "$0") ACTION

Actions:
  check       Verify the two-NIC topology and identity-DMA prerequisites
  deploy      Copy and build the shadow-ring agent on Host B
  configure   Generate the Host A QEMU backend JSON
  start       Unbind the dedicated 82599 and start the root agent
  status      Show Host B agent status and log
  stop        Stop the agent and reprobe ixgbe
  all         Check, deploy, configure and start

This mode has no IOMMU isolation. Set REMOTE_ALLOW_UNSAFE_IDENTITY_DMA=1 only
on a dedicated Host B after checking its boot/IOMMU configuration.
The inspected SFP+ setup restores the TX laser after ixgbe unbind and requires
physical link by default. Set REMOTE_RESTORE_SFP_TX_LASER=0 only for a non-SFP
target; set REMOTE_REQUIRE_LINK_UP=0 only while diagnosing an unplugged link.
Remote sudo prompts on a terminal by default. Set REMOTE_SUDO_NONINTERACTIVE=1
only when Host B has passwordless or cached sudo credentials.
EOF
}

main()
{
    local action=${1:-check}

    validate_settings
    prepare_ssh
    case "$action" in
    check) check_local; check_remote_topology ;;
    deploy) check_remote_topology; deploy_and_build ;;
    configure) check_local; write_qemu_config ;;
    start)
        [[ "$REMOTE_ALLOW_UNSAFE_IDENTITY_DMA" == 1 ]] ||
            die "set REMOTE_ALLOW_UNSAFE_IDENTITY_DMA=1 after verifying Host B uses identity DMA"
        check_local
        check_remote_topology
        start_remote_agent
        ;;
    status) status_remote_agent ;;
    stop) stop_remote_agent ;;
    all)
        [[ "$REMOTE_ALLOW_UNSAFE_IDENTITY_DMA" == 1 ]] ||
            die "set REMOTE_ALLOW_UNSAFE_IDENTITY_DMA=1 after verifying Host B uses identity DMA"
        check_local
        check_remote_topology
        deploy_and_build
        write_qemu_config
        start_remote_agent
        ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
    esac
}

main "$@"
