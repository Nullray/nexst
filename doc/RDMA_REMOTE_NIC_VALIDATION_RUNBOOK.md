# Remote 82599 Validation Runbook

## Scope

This procedure exports one dedicated Intel 82599 port on Host B
(`10.30.19.15`) as an `8086:10fb` endpoint behind the XiangShan virtual
switch. XiangShan uses the upstream Linux `ixgbe` driver. The X722 carries
the Host A--Host B RDMA connection; the 82599 carries guest Ethernet frames.

The implementation is packet-mediated. Host B keeps the physical 82599 bound
to `ixgbe`; Host A QEMU models BAR0, queue-0 descriptors and legacy INTx.
Physical 82599 registers and DMA addresses are not forwarded across hosts.

## Automated Setup For The Inspected Hosts

Repository 16 includes a Host A orchestration script whose defaults match the
inspected machines: Host A `iwo3`, Host B `irdma0/eno3@10.30.19.15`, and the
dedicated Host B 82599 `ens3f0` (`0000:5e:00.0`). Run:

```sh
cd /home/yanjiarun/nexst_proxy_16
./tools/scope_remote_agent/setup_remote_82599_rdma.sh check
./tools/scope_remote_agent/setup_remote_82599_rdma.sh all
./tools/scope_remote_agent/setup_remote_82599_rdma.sh start
```

`all` interactively requests the Host B sudo password, installs missing RDMA
development/runtime packages, deploys and starts the packet agent, and writes
`vswitch-backends-remote-82599.json`. Use the individual `install`, `deploy`,
`configure`, `start`, `status`, and `stop` actions when repeating only part of
the procedure. The script refuses to repurpose a non-82599 netdev or an 82599
port carrying a Host B IP address.

## 1. Identify Separate Transport And Payload Ports

On Host B:

```sh
ip -br address
rdma link show
ibdev2netdev 2>/dev/null || true
for n in /sys/class/net/*; do
    [ -e "$n/device" ] || continue
    printf '%s -> %s\n' "$(basename "$n")" "$(readlink -f "$n/device")"
done
```

Record:

```sh
B_RDMA_DEV=<verbs device backed by an X722 1a:00.x function>
B_RDMA_NETDEV=<X722 netdev carrying 10.30.19.15>
B_82599_NETDEV=<dedicated netdev backed by 5e:00.0 or 5e:00.1>
```

Safety requirements:

- `B_RDMA_NETDEV` and `B_82599_NETDEV` are different ports.
- SSH and the RDMA route to Host A use only `B_RDMA_NETDEV`.
- `B_82599_NETDEV` is not a bond/VLAN member and has no Host B IP address.
- The selected 82599 remains bound to `ixgbe`; do not unbind, FLR or rescan it.
- Connect the 82599 port to the network on which XiangShan will obtain an IP.

## 2. Establish The RDMA Baseline

Before involving QEMU, validate the X722 route with `rping`.

Host B:

```sh
rping -s -a 10.30.19.15 -p 7472 -v
```

Host A:

```sh
rping -c -a 10.30.19.15 -p 7472 -C 1000 -S 4096 -v
```

The run must finish without CQ errors, reconnects or `irdma` resets.

## 3. Build And Start The Host B Agent

```sh
cd /home/yanjiarun/nexst_proxy_16/tools/scope_remote_agent
make scope-remote-nic-agent

sudo ip link set dev "$B_82599_NETDEV" up
sudo ip addr flush dev "$B_82599_NETDEV"
ethtool -i "$B_82599_NETDEV"       # driver must be ixgbe
cat "/sys/class/net/$B_82599_NETDEV/carrier"

sudo ./scope-remote-nic-agent \
  --listen 10.30.19.15 --service 7472 \
  --rdma-device "$B_RDMA_DEV" \
  --device-id remote-82599-0 \
  --netdev "$B_82599_NETDEV"
```

The process needs root or `CAP_NET_RAW`. It must print the selected netdev,
MAC address, and `8086:10fb` identity. The agent also verifies the selected
netdev's sysfs PCI identity and refuses to start unless it is `8086:10fb`;
this prevents accidentally exporting the X722 RDMA transport port.

## 4. Build And Start Host A QEMU

The backend entry is:

```json
{
  "type": "ixgbe",
  "transport": "remote-rdma",
  "remote-host": "10.30.19.15",
  "remote-service": "7472",
  "remote-device-id": "remote-82599-0",
  "rdma-device": "iwo3",
  "rdma-memory-mode": "host-staging",
  "rdma-staging-size": 4194304
}
```

Use `vswitch-backends-remote-82599.json`, adjusting only Host A's verbs device
when necessary:

```sh
cd /home/yanjiarun/nexst_proxy_16/qemu-mount
ninja -C build-rdma qemu-system-x86_64

sudo ./build-rdma/qemu-system-x86_64 \
  -machine q35 -m 128M -display none -monitor null -serial null \
  -device pcie-root-port,id=rp1,bus=pcie.0 \
  -device scope-fpga-vswitch,bus=rp1,\
backend-config=/home/yanjiarun/nexst_proxy_16/vswitch-backends-remote-82599.json,\
fpga-host-bdf=0000:3b:00.0,xdma-user-dev=/dev/xdma0_user,\
xdma-ctrl-dev=/dev/xdma0_control,xdma-bypass-dev=/dev/xdma0_bypass,\
guest-ddr-base=0x80000000,guest-ddr-size=0x80000000,dma32-ring-size=0x10000
```

Success is indicated by `[SCOPE REMOTE][IXGBE][READY]` with device
`8086:10fb`, the physical 82599 MAC, MTU, and link state.

## 5. Build The XiangShan Kernel Image

`riscv_serve_defconfig` enables `CONFIG_IXGBE=y`. Rebuild the kernel payload
and OpenSBI image with the normal repository-16 flow. Use a repository-16
bitstream containing the ECAM read/write serialization fix. The packet ABI,
BAR routes and aggregate INTx remain unchanged, but an older bitstream can
return stale BAR readback data while a configuration write is still in flight.

## 6. XiangShan Enumeration And Network Test

After QEMU is ready, load and boot XiangShan. In its shell:

```sh
lspci -nnk
ip link
```

Expected endpoint:

```text
Ethernet controller [0200]: Intel Corporation 82599ES [8086:10fb]
Kernel driver in use: ixgbe
```

Bring up the interface and disable unsupported offloads when `ethtool` is
available:

```sh
ip link set dev eth0 up
ethtool -L eth0 combined 1 2>/dev/null || true
ethtool -K eth0 tso off gso off gro off lro off rxhash off 2>/dev/null || true
udhcpc -i eth0 -f -q
ip address show dev eth0
ping -c 100 <gateway-or-peer>
```

Acceptance criteria:

- `8086:10fb` binds to `ixgbe`, not `igb`.
- `carrier=1` and `operstate=up` after the physical 82599 link is active.
- DHCP, ARP and bidirectional ping succeed.
- `/proc/interrupts` increases on the shared PCI INTx line.
- QEMU reports no descriptor address outside guest DDR, queue stall, RDMA
  protocol failure or permanently asserted aggregate INTx.

### DHCP reports a lease but does not return

`udhcpc` prints `lease ... obtained` before it synchronously runs
`/usr/share/udhcpc/default.script`.  First separate the DHCP data path from the
guest address/route hook:

```sh
udhcpc -i eth0 -f -q -s /bin/true
```

If this always returns, DHCP TX/RX is complete and the hang is in the guest
hook. Trace each hook command on the next run:

```sh
printf '%s\n' '#!/bin/sh' \
  'exec sh -x /usr/share/udhcpc/default.script "$@"' >/tmp/udhcpc-trace.sh
chmod +x /tmp/udhcpc-trace.sh
udhcpc -i eth0 -f -q -s /tmp/udhcpc-trace.sh
```

At the same time, inspect `/tmp/scope-qemu-remote-82599.log` on Host A.
`TX_COMPLETE ... intx=1` confirms TX completion publication. `RX_DELIVER`
confirms delivery into a guest RX descriptor. Repeated `RX_DROP` indicates a
full or disabled guest RX ring and must be investigated before retrying DHCP.

## 7. Recovery

Stop XiangShan traffic, then QEMU, then the Host B agent. Restore Host B's
82599 IP configuration only if it had one before this test. The agent never
unbinds or resets the physical function.
