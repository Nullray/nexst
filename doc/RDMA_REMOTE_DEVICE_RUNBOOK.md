# SCOPE RDMA 远端外设运行手册

## 1. 适用范围

本文给出仓库 16 中通过 `remote-rdma` backend 向香山提供远端外设的端到端
操作步骤。当前代码支持三种运行模式：

| 模式 | Host B 外设 | Host B 驱动状态 | 跨主机数据形式 | Host A payload staging |
| --- | --- | --- | --- | --- |
| Remote NVMe | NVMe namespace | 保持 NVMe 驱动绑定 | RDMA + 注册 staging MR | 4 MiB `host-staging` |
| 82599 packet | Intel 82599 网口 | 保持 `ixgbe` 绑定 | 完整以太网帧 | 4 MiB `host-staging` 配置 |
| 82599 shadow-ring | Intel 82599 function | 不绑定功能驱动/VFIO | 完整帧放入 RDMA SEND | 无，使用 `inline` |

本文的主要操作对象是当前
`vswitch-backends-remote-82599-shadow.json` 对应的 shadow-ring 模式。NVMe 和
packet 模式在第 11、12 节单独说明。

当前 shadow-ring 实现不是端到端零拷贝：Host B 真实 82599 DMA 到 Host B 的
hugepage staging pool，agent 在 staging 与 RDMA message 之间复制完整帧。当前版本
也尚未启用通用真实 BAR 代理；guest-facing BAR/NVM/中断语义主要由 Host A QEMU
模型提供，真实链路状态和 descriptor 完成由 Host B 设备产生。

## 2. 默认拓扑和变量

默认值来自已检查的两台主机：

```text
Host A / FPGA host
  repository:       /home/yanjiarun/nexst_proxy_16
  RDMA verbs:       iwo3
  FPGA PCI BDF:     0000:3b:00.0
  XDMA devices:     /dev/xdma0_{user,control,bypass}

Host B / remote-device host
  address:          10.30.19.15
  user:             yanjiarun
  RDMA verbs/netdev: iwo3 / eno3
  remote 82599:     0000:5e:00.0 / ens3f0
  service:          7472

Network peer
  connected to the exported 82599 port; used for DHCP, ping and iperf3
```

在 Host A 设置运行变量。硬件枚举变化时只修改这里：

```sh
export SCOPE_REPO=/home/yanjiarun/nexst_proxy_16
export HOST_B=10.30.19.15
export HOST_B_USER=yanjiarun
export SSH_KEY="$HOME/.ssh/id_rsa_132"
export A_RDMA_DEV=iwo3
export A_FPGA_BDF=0000:3b:00.0
export B_RDMA_DEV=iwo3
export B_RDMA_NETDEV=eno3
export B_82599_BDF=0000:5e:00.0
export B_82599_NETDEV=ens3f0
export REMOTE_SERVICE=7472
```

手工执行本文中的 `ssh -i`/`scp -i` 命令前，私钥必须只有 owner 可读：

```sh
stat -c '%a %n' "$SSH_KEY"
chmod 600 "$SSH_KEY"
```

两个部署脚本会在发现权限过宽时使用一个临时 `0600` 副本，但 OpenSSH 本身会直接
拒绝 `0644`、`0664` 等权限过宽的私钥。

## 3. 安全约束

开始前必须满足：

- RDMA transport NIC 和被导出的外设是不同 PCI function；
- SSH 和 RDMA 会话不能经过即将被导出的 82599；
- 被导出的 82599 没有 Host B IP、不是 bond/bridge/VLAN 成员；
- shadow-ring 模式只能用于专用测试主机，且目标 function 必须处于 identity DMA
  环境；
- shadow-ring 模式没有 IOMMU 隔离，错误 DMA 地址可能破坏 Host B 内存；
- NVMe namespace 必须卸载并且不承载 Host B 的系统盘、swap、LVM 或活动文件系统；
- 同一 service/device ID 同时只能有一个 Host B agent；
- agent、QEMU 和香山运行期间不要重新绑定、reset 或热拔目标外设。

不要仅通过 `/sys/kernel/iommu_groups` 为空推断 identity DMA。还需要检查启动参数、
平台 BIOS/IOMMU 设置及目标设备实际 domain。脚本会拒绝明显的
`intel_iommu=on`，但这不能代替平台确认。

## 4. 两端 RDMA 基线检查

### 4.1 Host A

```sh
cd "$SCOPE_REPO/tools/scope_remote_agent"
ibv_devices
ibv_devinfo -d "$A_RDMA_DEV" | grep -E 'hca_id|state:|link_layer'
rdma link show "$A_RDMA_DEV/1"
ip route get "$HOST_B"
```

预期 `state ACTIVE`，且 `ip route get` 使用与 `iwo3` 对应的 netdev。

当前 X722/`irdma` 环境使用普通内存或 inline 模式。通用 `host-staging` 检查：

```sh
RDMA_MEMORY_MODE=host-staging \
RDMA_DEVICE="$A_RDMA_DEV" \
REMOTE_HOST="$HOST_B" \
./scope-remote-preflight.sh
```

输出中的 `host-staging` warning 是路径说明，不是失败。不要把 `ibv_devices` 成功
解释为 `peer-dmabuf` 可用；后者还要求 RNIC provider 支持 dma-buf MR，并要求 XDMA
peer exporter 和 `CONFIG_PCI_P2PDMA=y`。

### 4.2 Host B

```sh
ssh -i "$SSH_KEY" "$HOST_B_USER@$HOST_B" "
  ibv_devices
  rdma link show
  ip -br address
  lspci -nnk -s '$B_82599_BDF'
  cat /proc/cmdline
  grep -E 'HugePages_(Total|Free)|Hugepagesize' /proc/meminfo
"
```

确认：

```text
iwo3/eno3         ACTIVE，并拥有 10.30.19.15
0000:5e:00.0      8086:10fb
ens3f0            无 Host B IP
```

当前检查曾发现 `ens3f0` 配置了 `10.30.5.162/19`。导出 82599 前，先在 Host B
确认该地址、路由和连接没有承载业务：

```sh
ip address show dev ens3f0
ip route show dev ens3f0
ss -tpn
```

确认可以释放后再执行：

```sh
sudo ip addr flush dev ens3f0
sudo ip route flush dev ens3f0
sudo ip link set dev ens3f0 down
```

SSH/RDMA 必须继续经过 `eno3/10.30.19.15`。若不能安全移除 `ens3f0` 地址，应停止
本次导出，改用另一块专用 82599 端口。

在没有 agent 占用端口时，可先执行 RDMA 连通性测试。

在 Host B 终端执行 server。提示符对应的主机应为 `master15`，不能在 Host A 上
绑定 `10.30.19.15`：

```sh
hostname
rping -s -a 10.30.19.15 -p 7472 -v
```

保持 server 运行，在 Host A 的另一个终端执行 client。Host A 当前 hostname 为
`debian-qdma-dev`，其 RDMA 地址是 `10.128.157.132`，通过路由访问 Host B：

```sh
hostname
ip route get 10.30.19.15
rping -c -a 10.30.19.15 -p 7472 -C 1000 -S 4096 -v
```

client 正常结束时双方会打印 disconnect，最终状态为 `10`，且没有 CM/CQ error。
完成后退出 Host B 的 `rping`，释放 `7472`。若 server 没有成功监听，client 的
`RDMA_CM_EVENT_REJECTED` 只是连带错误，应先修复 server。

## 5. 构建 Host A 组件

### 5.1 Host B agent

先在 Host A 做本地编译检查：

```sh
cd "$SCOPE_REPO/tools/scope_remote_agent"
make clean all
```

该命令生成：

```text
scope-remote-agent                 remote NVMe
scope-remote-nic-agent             82599 packet
scope-remote-ixgbe-shadow-agent    82599 shadow-ring
scope-peer-mr-probe                peer-dmabuf capability probe
```

### 5.2 QEMU manager

已有 `build-rdma` 时：

```sh
cd "$SCOPE_REPO/qemu-mount"
ninja -C build-rdma qemu-system-x86_64
```

需要重新创建构建目录时：

```sh
cd "$SCOPE_REPO/qemu-mount"
mkdir -p build-rdma
cd build-rdma
../configure --target-list=x86_64-softmmu --enable-rdma \
  --disable-docs --enable-plugins
cd ..
ninja -C build-rdma qemu-system-x86_64
```

检查二进制和 XDMA 节点：

```sh
test -x "$SCOPE_REPO/qemu-mount/build-rdma/qemu-system-x86_64"
ls -l /dev/xdma0_user /dev/xdma0_control /dev/xdma0_bypass
lspci -nn -s "$A_FPGA_BDF"
```

若 XDMA 节点不存在，先加载与当前 bitstream 匹配的 XDMA 驱动。不要在 QEMU 已映射
这些节点后重新加载驱动。

构建过程本身不要使用 `sudo`。若 Meson 报 `meson-private/... Permission denied`，
先检查是否存在历史遗留的 root-owned 文件：

```sh
find build-rdma ! -user "$USER" -ls | head
```

确认该目录不是多人共享构建目录后，由管理员修正其属主，或者新建一个当前用户所有
的构建目录。只在访问 XDMA 设备和启动 QEMU manager 时使用 `sudo`。

## 6. 启动远端 82599 shadow-ring agent

仓库脚本完成拓扑检查、部署、生成 QEMU JSON、分配 hugepage、解绑 82599 和启动
agent。先只执行无状态检查：

```sh
  cd "$SCOPE_REPO"
  REMOTE_HOST="$HOST_B" \
  REMOTE_USER="$HOST_B_USER" \
  SSH_KEY="$SSH_KEY" \
  LOCAL_RDMA_DEV="$A_RDMA_DEV" \
  REMOTE_RDMA_DEV="$B_RDMA_DEV" \
  REMOTE_RDMA_NETDEV="$B_RDMA_NETDEV" \
  REMOTE_NIC_BDF="$B_82599_BDF" \
  REMOTE_NIC_NETDEV="$B_82599_NETDEV" \
  REMOTE_SERVICE="$REMOTE_SERVICE" \
  tools/scope_remote_agent/setup_remote_82599_shadow_ring.sh check
```

检查通过后才允许执行接管：

```sh
REMOTE_HOST="$HOST_B" \
REMOTE_USER="$HOST_B_USER" \
SSH_KEY="$SSH_KEY" \
LOCAL_RDMA_DEV="$A_RDMA_DEV" \
REMOTE_RDMA_DEV="$B_RDMA_DEV" \
REMOTE_RDMA_NETDEV="$B_RDMA_NETDEV" \
REMOTE_NIC_BDF="$B_82599_BDF" \
REMOTE_NIC_NETDEV="$B_82599_NETDEV" \
REMOTE_SERVICE="$REMOTE_SERVICE" \
REMOTE_ALLOW_UNSAFE_IDENTITY_DMA=1 \
tools/scope_remote_agent/setup_remote_82599_shadow_ring.sh all
```

默认通过 TTY 请求 Host B sudo 密码。只有 Host B 已配置 `sudo -n` 时，才设置：

```sh
export REMOTE_SUDO_NONINTERACTIVE=1
```

脚本成功后的必要状态：

- Host B `0000:5e:00.0` 已从 `ixgbe` 解绑；
- `scope-remote-ixgbe-shadow-agent` 以 root 运行；
- `/dev/hugepages/scope-82599-shadow` 被锁定并用于物理 ring/staging；
- Host A 已生成 `vswitch-backends-remote-82599-shadow.json`；
- agent 正在 `10.30.19.15:7472` 等待 QEMU。

检查 agent：

```sh
cd "$SCOPE_REPO"
REMOTE_HOST="$HOST_B" REMOTE_USER="$HOST_B_USER" SSH_KEY="$SSH_KEY" \
tools/scope_remote_agent/setup_remote_82599_shadow_ring.sh status
```

如果 `all` 在解绑后失败，不要手工启动 Host B `ixgbe`。先查看 agent 日志，再执行
第 10 节的受控恢复。

## 7. 检查 backend JSON

```sh
cat "$SCOPE_REPO/vswitch-backends-remote-82599-shadow.json"
```

预期内容：

```json
{
  "version": 1,
  "devices": [
    {
      "type": "ixgbe",
      "transport": "remote-rdma",
      "remote-device-mode": "shadow-ring",
      "remote-host": "10.30.19.15",
      "remote-service": "7472",
      "remote-device-id": "remote-82599-shadow-0",
      "rdma-device": "iwo3",
      "rdma-memory-mode": "inline"
    }
  ]
}
```

`remote-device-id`、service 和模式必须与 Host B agent 一致。shadow-ring 必须使用
`inline`；能力协商会拒绝误连到 packet agent。

## 8. 启动 Host A QEMU manager

保持 Host B agent 运行，在 Host A 新终端执行：

```sh
cd "$SCOPE_REPO/qemu-mount"
sudo ./build-rdma/qemu-system-x86_64 \
  -machine q35 -m 128M -display none -monitor null -serial null \
  -device pcie-root-port,id=rp1,bus=pcie.0 \
  -device scope-fpga-vswitch,bus=rp1,\
backend-config="$SCOPE_REPO/vswitch-backends-remote-82599-shadow.json",\
fpga-host-bdf="$A_FPGA_BDF",xdma-user-dev=/dev/xdma0_user,\
xdma-ctrl-dev=/dev/xdma0_control,xdma-bypass-dev=/dev/xdma0_bypass,\
guest-ddr-base=0x80000000,guest-ddr-size=0x80000000,dma32-ring-size=0x10000 \
  2>&1 | tee /tmp/scope-qemu-remote-82599.log
```

不要被 `-machine q35` 混淆：此进程在这里作为 Host A vSwitch/QEMU manager 使用，
香山处理器仍运行在 FPGA 上。

在释放香山 reset 前，日志必须出现 remote session/device ready 信息，并且没有：

```text
feature mismatch
remote-rdma ... failed
invalid descriptor
backend failed
```

另一个终端检查进程和 RDMA 状态：

```sh
pgrep -af qemu-system-x86_64
rdma link show "$A_RDMA_DEV/1"
tail -n 50 /tmp/scope-qemu-remote-82599.log
```

## 9. 启动香山并验证远端网卡

准备仓库 16 对应 bitstream、`bootrom.bin` 和 `RV_BOOT.bin`。当前默认镜像位置为：

```sh
export BOOT_DIR="$SCOPE_REPO/nanhu-g/ready_for_download/proto_nm37_vu37p"
test -f "$BOOT_DIR/bootrom.bin"
test -f "$BOOT_DIR/RV_BOOT.bin"
```

确认 Host B agent 和 Host A QEMU 都 ready 后，再加载镜像并释放 reset：

```sh
cd "$SCOPE_REPO/tools/proto"
make
sudo ./load_and_run_5.sh xdma0 \
  "$BOOT_DIR/bootrom.bin" "$BOOT_DIR/RV_BOOT.bin"
```

该命令最后连接 UART。退出串口使用 `Ctrl-A`、`X`；重新连接但不复位：

```sh
sudo ./load_and_run_5.sh xdma0
```

在香山 shell 中检查：

```sh
lspci -nnk
dmesg | grep -iE 'ixgbe|pci|AER|timeout|reset'
ip -br link
cat /proc/interrupts
```

预期看到：

```text
Ethernet controller [0200]: Intel Corporation 82599ES [8086:10fb]
Kernel driver in use: ixgbe
```

记录实际接口名为 `$XS_NIC`，然后使用单队列和当前实现支持的 offload 集合：

```sh
export XS_NIC=eth0
ip link set dev "$XS_NIC" up
ethtool -L "$XS_NIC" combined 1 2>/dev/null || true
ethtool -K "$XS_NIC" tso off gso off gro off lro off rxhash off \
  2>/dev/null || true
udhcpc -i "$XS_NIC" -f -q
ip address show dev "$XS_NIC"
ip route
ping -c 20 <gateway-or-network-peer>
```

如果网络没有 DHCP，配置专用测试地址：

```sh
ip address add <xiangshan-address/prefix> dev "$XS_NIC"
ip link set dev "$XS_NIC" up
ping -c 20 <network-peer-address>
```

功能验收标准：

- `8086:10fb` 成功绑定香山 `ixgbe`；
- 物理 82599 link up 后，香山 carrier/operstate 变为 up；
- ARP、双向 ping 正常；
- TX/RX descriptor 持续完成，没有永久 queue stall；
- QEMU 没有 guest DDR 越界、RDMA protocol failure 或 backend failed；
- Host B agent 的物理 TX/RX 计数增长。

## 10. 性能测试、监控和关闭

### 10.1 网络性能

在 82599 对端主机启动：

```sh
iperf3 -s
```

香山发送和接收分别测试：

```sh
iperf3 -c <network-peer-address> -t 30 -P 1
iperf3 -c <network-peer-address> -t 30 -P 1 -R
ping -c 1000 -i 0.01 <network-peer-address>
```

当前只有 queue 0，基线应先使用 `-P 1`。论文测试应同时记录 packet size、方向、
MTU、CPU 利用率、丢包、重传、QEMU CPU、agent CPU 和 RDMA 端口计数。

Host A 监控：

```sh
pidstat -p "$(pgrep -n qemu-system-x86_64)" 1
rdma statistic show 2>/dev/null || true
tail -f /tmp/scope-qemu-remote-82599.log
```

Host B 监控：

```sh
ssh -i "$SSH_KEY" "$HOST_B_USER@$HOST_B" \
  "tail -f /home/$HOST_B_USER/scope_remote_agent_16/scope-remote-ixgbe-shadow-agent.log"
```

### 10.2 正常关闭顺序

必须按以下顺序关闭：

1. 停止香山中的 ping、iperf3、DHCP 和其他网络业务；
2. 在香山执行 `ip link set dev "$XS_NIC" down`；
3. assert 香山 reset，或确保它不再产生 BAR/DMA 请求；
4. 正常终止 Host A QEMU，等待进程完全退出；
5. 停止 Host B shadow agent；
6. 脚本确认队列停止和 bus master 清除后，才重新 probe `ixgbe`。

Host B 恢复命令：

```sh
cd "$SCOPE_REPO"
REMOTE_HOST="$HOST_B" \
REMOTE_USER="$HOST_B_USER" \
SSH_KEY="$SSH_KEY" \
REMOTE_NIC_BDF="$B_82599_BDF" \
REMOTE_NIC_NETDEV="$B_82599_NETDEV" \
tools/scope_remote_agent/setup_remote_82599_shadow_ring.sh stop
```

确认恢复：

```sh
ssh -i "$SSH_KEY" "$HOST_B_USER@$HOST_B" \
  "lspci -nnk -s '$B_82599_BDF'; ip -br link show '$B_82599_NETDEV'"
```

若 agent 在 5 秒内没有退出，脚本会拒绝 re-probe。此时不要强制绑定驱动；先保存
日志，确认 agent PID 和设备 bus master/queue 状态。

## 11. 82599 packet 模式

packet 模式风险较低，适合先验证香山 `ixgbe`、RDMA 消息和网络功能。Host B 的
82599 保持绑定 `ixgbe`，agent 使用 `AF_PACKET`。

一键部署和启动：

```sh
cd "$SCOPE_REPO"
REMOTE_HOST="$HOST_B" \
REMOTE_USER="$HOST_B_USER" \
SSH_KEY="$SSH_KEY" \
LOCAL_RDMA_DEV="$A_RDMA_DEV" \
REMOTE_RDMA_DEV="$B_RDMA_DEV" \
REMOTE_RDMA_NETDEV="$B_RDMA_NETDEV" \
REMOTE_NIC_NETDEV="$B_82599_NETDEV" \
REMOTE_SERVICE="$REMOTE_SERVICE" \
tools/scope_remote_agent/setup_remote_82599_rdma.sh all
```

该脚本生成 `vswitch-backends-remote-82599.json`。启动 QEMU 时只把第 8 节的
`backend-config` 换为该文件，香山侧操作不变。

停止 packet agent：

```sh
tools/scope_remote_agent/setup_remote_82599_rdma.sh stop
```

不要让 packet agent 和 shadow agent 同时使用同一 82599 或同一 RDMA service。

## 12. Remote NVMe 模式

### 12.1 Host B 准备

记录远端 controller 和专用 namespace：

```sh
export B_NVME_CTRL=/dev/nvme0
export B_NVME_NS=/dev/nvme0n1
```

在 Host B 确认 namespace 未使用：

```sh
lsblk -f "$B_NVME_NS"
findmnt -S "$B_NVME_NS"
swapon --show
pvs 2>/dev/null || true
```

从 Host A 部署 agent 源码和启动脚本：

```sh
ssh -i "$SSH_KEY" "$HOST_B_USER@$HOST_B" \
  "mkdir -p /home/$HOST_B_USER/scope_remote_agent_16"
scp -i "$SSH_KEY" \
  "$SCOPE_REPO/tools/scope_remote_agent/Makefile" \
  "$SCOPE_REPO/tools/scope_remote_agent/scope_remote_proto.h" \
  "$SCOPE_REPO/tools/scope_remote_agent/scope_remote_agent.c" \
  "$SCOPE_REPO/tools/scope_remote_agent/run-agent-10.30.19.15.sh" \
  "$HOST_B_USER@$HOST_B:/home/$HOST_B_USER/scope_remote_agent_16/"
ssh -i "$SSH_KEY" "$HOST_B_USER@$HOST_B" \
  "make -C /home/$HOST_B_USER/scope_remote_agent_16 scope-remote-agent"
```

然后在 Host B 前台启动，以便观察 I/O 和协议错误：

```sh
cd /home/yanjiarun/scope_remote_agent_16
make scope-remote-agent
sudo ./run-agent-10.30.19.15.sh \
  iwo3 /dev/nvme0 /dev/nvme0n1 remote-nvme0
```

NVMe 默认使用 service `7471`。保持 agent 前台运行以便观察错误。

### 12.2 Host A QEMU

检查 `vswitch-backends-remote-nvme.json`：

```sh
cat "$SCOPE_REPO/vswitch-backends-remote-nvme.json"
```

使用第 8 节 QEMU 命令，只替换：

```text
backend-config=/home/yanjiarun/nexst_proxy_16/vswitch-backends-remote-nvme.json
```

香山启动后：

```sh
lspci -nnk
lsblk
nvme list 2>/dev/null || true
dmesg | grep -iE 'nvme|timeout|reset|I/O error'
```

只读冒烟测试：

```sh
dd if=/dev/nvme0n1 of=/dev/null bs=1M count=256 iflag=direct
```

仅对可销毁的专用 namespace 执行写测试：

```sh
fio --name=remote-nvme \
  --filename=/dev/nvme0n1 --direct=1 --ioengine=libaio \
  --rw=randrw --rwmixread=70 --bs=4k --iodepth=1 \
  --runtime=60 --time_based=1 --group_reporting=1
```

当前远端协议的 `max_inflight` 和实现路径应先从 `iodepth=1` 验证，再根据运行日志
逐步提高。停止顺序为香山 I/O、香山 reset、QEMU、Host B agent。

## 13. 常见故障

| 现象 | 首要检查 | 处理 |
| --- | --- | --- |
| `feature mismatch` | agent 类型和 JSON 模式 | packet/shadow JSON 与对应 agent 成对使用 |
| `Connection refused` | Host B agent、service、防火墙 | 先启动 agent；确认 `7471/7472` 和 RDMA route |
| RDMA port 非 ACTIVE | verbs/netdev/link | 修复 X722 网络，不要改目标 82599 |
| shadow agent 拒绝 bound device | `lspci -nnk -s BDF` | 使用受控脚本解绑，不要同时运行 Host B `ixgbe` |
| hugepage/PFN 检查失败 | hugepage、pagemap、IOMMU | 停止测试并修复前置条件，禁止换成普通匿名内存 |
| 香山 `ixgbe` probe timeout | QEMU 日志、bitstream BAR ordering | 确认 QEMU 先 ready，使用仓库 16 对应 bitstream/kernel |
| agent 报 `link remained down after SFP TX laser restore` | 光模块/线缆/对端，或并非使用 SDP3 控制 laser | 先用绑定状态下的 `ethtool` 验证链路；不要继续启动香山 |
| 香山 link down | agent 启动行、QEMU `READY`、物理 `LINKS` | 三处都必须是 `link=up`；否则 DHCP 不会发送 Discover |
| QEMU `READY link=up` 但香山仍为 `NO-CARRIER` | guest ixgbe 的 SFP cage 判定 | 确认 QEMU 模型 reset 后 `ESDP.SDP2=1`，再检查香山 `dmesg` |
| TX 有而 RX 无 | guest RDT、Host B RX DD、对端 MAC/ARP | 查看 QEMU 和 agent 两侧计数，关闭未支持 offload |
| queue stall | descriptor 地址/长度、RDMA completion | 立即停止负载，保存双端日志，按关闭顺序恢复 |
| agent 退出后不能 rebind | agent 未停或 bus master 未清 | 不强绑驱动；使用 `stop` 并检查 PID/日志 |
| Meson `Permission denied` | 构建目录含 root-owned 文件 | 不用 `sudo ninja`；修正属主或创建新的用户构建目录 |

最小故障信息集合：

```sh
# Host A
date
uname -a
lspci -nnk -s "$A_FPGA_BDF"
rdma link show
ip route get "$HOST_B"
tail -n 200 /tmp/scope-qemu-remote-82599.log

# Host B
ssh -i "$SSH_KEY" "$HOST_B_USER@$HOST_B" "
  date
  uname -a
  lspci -nnk -s '$B_82599_BDF'
  rdma link show
  grep -E 'HugePages_(Total|Free)|Hugepagesize' /proc/meminfo
  tail -n 200 /home/$HOST_B_USER/scope_remote_agent_16/scope-remote-ixgbe-shadow-agent.log
"

# XiangShan
lspci -nnk
ip -s link show
cat /proc/interrupts
dmesg | tail -n 300
```

## 14. 每次实验检查表

启动前：

- [ ] RDMA transport link ACTIVE，路由经过正确 netdev；
- [ ] 远端外设身份、BDF、驱动归属符合所选模式；
- [ ] 远端 payload 端口/namespace 没有 Host B 业务；
- [ ] Host B agent 类型、service、device ID 与 JSON 一致；
- [ ] Host A QEMU 和当前 FPGA bitstream/软件来自同一仓库版本；
- [ ] 上一次实验的 QEMU、agent 和测试进程已经退出。

启动后：

- [ ] agent ready；
- [ ] QEMU remote backend ready；
- [ ] 香山枚举出预期 PCI ID 并绑定原生驱动；
- [ ] 冒烟测试通过后才开始压力测试；
- [ ] 双端日志、CPU、RDMA/设备计数同步采集。

结束后：

- [ ] 先停 guest I/O，再停 QEMU，最后停 agent；
- [ ] shadow-ring 模式确认 82599 已安全 re-probe；
- [ ] NVMe namespace 在 agent 退出前没有被 Host B 重新挂载；
- [ ] 保存配置、commit、内核/bitstream 标识和原始测试结果。
