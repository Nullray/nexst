# Scope Remote Device Agents

This Host B process exposes one allowlisted NVMe namespace to a repository-16
vSwitch `remote-rdma` backend. Payload moves through a registered, page-aligned
staging pool shared by `O_DIRECT` NVMe I/O and RNIC RDMA.

The namespace must be unmounted and reserved for this process. Start one agent
per remote backend:

```sh
sudo ./scope-remote-agent \
  --listen 10.30.19.15 --service 7471 \
  --rdma-device <host-b-verbs-device> \
  --device-id remote-nvme0 \
  --controller /dev/nvme0 --namespace /dev/nvme0n1 \
  --namespace-id 1 --staging-size 4194304
```

## Remote Intel 82599 packet backend

`scope-remote-nic-agent` exports a dedicated Host B 82599 interface as an
`8086:10fb` endpoint.  XiangShan binds its standard `ixgbe` driver; Host A
QEMU implements the 82599 BAR0, queue-0 descriptors and legacy INTx, while
the agent moves complete Ethernet frames over the existing RDMA connection.

The physical 82599 stays bound to Host B's `ixgbe` driver.  The selected port
must be up, have MTU 1500 or less, and must not carry a Host B IP address or
the RDMA/control session.  Start the agent as root for `AF_PACKET` access:

```sh
sudo ip link set dev <82599-netdev> up
sudo ip addr flush dev <82599-netdev>
sudo ./scope-remote-nic-agent \
  --listen 10.30.19.15 --service 7472 \
  --rdma-device <x722-verbs-device> \
  --device-id remote-82599-0 --netdev <82599-netdev>
```

This first implementation exposes one TX and one RX queue, BAR0 only, and
aggregate INTx.  RSS, TSO, header split, PTP, MSI and MSI-X are intentionally
not exposed.  The 82599 interface is the payload NIC; the X722 is the RDMA
transport NIC.

On the target Host B (`10.30.19.15`), the guarded wrapper checks the verbs
port, local address, device nodes, and that the namespace is not mounted:

```sh
sudo ./run-agent-10.30.19.15.sh <host-b-verbs-device> \
  /dev/nvme0 /dev/nvme0n1 remote-nvme0
```

The first implementation supports NVM read, write and flush; Identify and Get
Log Page; and virtual queue create/delete. Number of Queues, Interrupt
Coalescing, Interrupt Vector Configuration, and Asynchronous Event
Configuration are maintained as virtual endpoint features and are never
forwarded to the Host B controller. Unsupported commands return NVMe Invalid
Opcode. The wire contract is `scope_remote_proto.h`.

## Host A preflight

An entry in `ibv_devices` proves that verbs is available, but it does not prove
that the RNIC provider can register XDMA peer memory. Run the two-level check:

```sh
make
sudo env RDMA_DEVICE=iwo3 \
  PEER_MEMORY_DEVICE=/dev/xdma0_peer \
  REMOTE_HOST=10.30.19.15 \
  ./scope-remote-preflight.sh
```

The final `scope-peer-mr-probe` result is authoritative for `peer-dmabuf`. On the current Host A,
`iwo3` is an active Intel X722/`irdma` device, but the installed `irdma`
provider does not implement dma-buf MR registration. In addition,
`CONFIG_PCI_P2PDMA` must be enabled for the XDMA exporter. The direct-peer
transport therefore fails closed until both requirements are met.

For the current X722/`irdma` host, select the explicit compatibility mode:

```sh
RDMA_MEMORY_MODE=host-staging RDMA_DEVICE=iwo3 \
  REMOTE_HOST=10.30.19.15 ./scope-remote-preflight.sh
```

In `host-staging`, the RNIC registers ordinary Host A RAM. QEMU copies each
request between that MR and XiangShan DDR through the existing coherent XDMA
mapping. This mode runs on `irdma`, but it is not direct peer-memory or
zero-copy and is always identified as such in the startup log. `peer-dmabuf`
remains the default mode and never falls back automatically.

## QEMU configuration

Use `vswitch-backends-remote-nvme.json` from the repository root. It selects
the X722-compatible `host-staging` mode and connects to `10.30.19.15:7471`
through `iwo3`. Start QEMU with the normal vSwitch command and replace the
local backend JSON with this file. To test direct peer memory later, change
`rdma-memory-mode` to `peer-dmabuf` and add `peer-memory-device`.

```sh
cd /home/yanjiarun/nexst_proxy_16/qemu-mount
sudo ./build-rdma/qemu-system-x86_64 \
  -machine q35 -m 128M -display none -monitor null -serial null \
  -device pcie-root-port,id=rp1,bus=pcie.0 \
  -device scope-fpga-vswitch,bus=rp1,\
backend-config=/home/yanjiarun/nexst_proxy_16/vswitch-backends-remote-nvme.json,\
fpga-host-bdf=0000:3b:00.0,xdma-user-dev=/dev/xdma0_user,\
xdma-ctrl-dev=/dev/xdma0_control,xdma-bypass-dev=/dev/xdma0_bypass,\
guest-ddr-base=0x80000000,guest-ddr-size=0x80000000,dma32-ring-size=0x10000
```

Start Host B first. A successful Host A startup prints
`memory=host-staging(extra-qemu-copy)` and then the remote session and device
limits. Only after that should the FPGA reset be released and XiangShan booted.
