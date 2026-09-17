# RDMA 远端 NVMe Shadow-Queue 验证手册

## 1. 适用范围与当前结论

本文用于仓库 17：

```text
/home/yanjiarun/nexst_proxy_17/nexst_proxy_16
```

目标是让香山通过 Host A 的 FPGA PCIe vSwitch，使用 Host B
`10.30.19.15` 上的 Intel P4510 NVMe。香山看到标准 NVMe PCIe endpoint，
并绑定 Linux `nvme` 驱动；真实命令由 Host B shadow agent 提交给物理盘。

截至本文生成时，代码检查结论如下：

- 两份 v2 patch 原始状态不能直接运行：仓库 17 的 NexST patch 原先没有实际应用，
  QEMU patch 存在缺失类型、缺失 BAR 超时函数和 `-Wshadow` 编译错误；
- Host B agent 原先把物理 PCI device ID 错写为 `8086:4802`。实际 P4510 是
  PCI `8086:0a54`、subsystem `8086:4802`；
- 上述问题已在仓库 17 修正；agent 已在 `-Werror` 下编译通过；
- QEMU 已在全新的 RDMA build 目录中完成编译和链接；
- QEMU 与 agent 的 `scope_remote_proto.h` 已用 `cmp` 确认完全一致；
- 已完成 Host B 物理盘接管、香山端枚举、Identify、I/O queue 初始化，并观察到首条
  128 KiB READ 在物理 CQE、RDMA 回传和 guest CQE 路径上成功完成；
- 持续 `dd` 曾在下一条 128 KiB 命令提交前触发 Host A PRP 解析失败。新增诊断确认
  该命令 `PSDT=0`，其 `PRP2=...3100` 指向 Linux `prp list 256` DMA pool 中的合法
  small PRP list。旧解析器错误地要求 PRP list 与 4 KiB 页对齐；现已改为允许第一张
  PRP list 带页内偏移，并按该地址到页尾计算条目数。QEMU 也会在 Identify Controller
  返回 guest 前清零尚未实现的 `sgls`，并为真正的 SQE/PRP 可见性延迟保留 100 毫秒
  有界重试。
- 2026-09-17 后续用户确认当前代码可以正常工作。该反馈与本轮源码回归/构建通过
  一并记录；未提供新的性能数字、完整测试轮次或数据哈希，不能据此声称长时压力、
  写入正确性或端到端带宽测试已经通过。可重复的验收流程仍见第 11 节。

当前实现是 Phase-1，限制如下：

- 只支持 Admin queue 0 和一组 I/O SQ/CQ（QID 1）；
- Host B 同时最多执行一个物理 NVMe 命令；
- 使用轮询读取物理 CQ，香山侧只提供 legacy INTx，不提供 MSI/MSI-X；
- 不支持 metadata buffer；AER 被虚拟完成为不支持，避免占住唯一 inflight slot；
- Host A 默认有 4 MiB staging MR，Host B 有 2 MiB hugetlbfs DMA pool；
- Host B pool 中真正用于 payload 的空间为 `0x1c0000`，即 1.75 MiB；
- 推荐测试块大小不超过 128 KiB、`iodepth=1`。

## 2. 实际拓扑与环境变量

本节默认值来自 2026-09-10 对两台机器的实际检查。

### 2.1 Host A

```text
hostname:           debian-qdma-dev
repository:         /home/yanjiarun/nexst_proxy_17/nexst_proxy_16
RDMA IP/netdev:     10.128.157.132 / eno3
RDMA verbs device:  iwo3
route to Host B:    via 10.128.157.254 dev eno3
NM37 FPGA BDF:      0000:3b:00.0
```

在 Host A 设置：

```sh
export SCOPE_REPO=/home/yanjiarun/nexst_proxy_17/nexst_proxy_16
export HOST_A_IP=10.128.157.132
export A_RDMA_DEV=iwo3
export A_RDMA_NETDEV=eno3
export A_FPGA_BDF=0000:3b:00.0
export A_XDMA_NAME=xdma0
export XDMA_USER_DEV=/dev/xdma0_user
export XDMA_CTRL_DEV=/dev/xdma0_control
export XDMA_BYPASS_DEV=/dev/xdma0_bypass
export BOOT_DIR="$SCOPE_REPO/nanhu-g/ready_for_download/proto_nm37_vu37p"

export HOST_B=10.30.19.15
export HOST_B_USER=yanjiarun
export SSH_KEY="$HOME/.ssh/id_rsa_132"

export REMOTE_NVME_SERVICE=7473
export REMOTE_NVME_ID=remote-nvme-shadow-0
export REMOTE_NVME_NSID=1
export QEMU_BUILD="$SCOPE_REPO/qemu-mount/build-rdma-repo17-review"
export QEMU_LOG=/tmp/scope-qemu-remote-nvme.log
```

Host A 和 Host B 恰好都使用 `0000:3b:00.0`，但它们位于不同主机：Host A 的
该 BDF 是 NM37 FPGA，Host B 的该 BDF 是 P4510 NVMe。执行 `lspci`、驱动绑定和
设备节点检查时必须区分主机上下文，不能因为 BDF 字符串相同而把两个设备混为一谈。

私钥当前权限曾为 `0664`，OpenSSH 会拒绝使用。修正后再连接：

```sh
chmod 600 "$SSH_KEY"
ssh -i "$SSH_KEY" "$HOST_B_USER@$HOST_B" hostname
```

### 2.2 Host B

```text
hostname:                master15
RDMA IP/netdev:          10.30.19.15 / eno3
RDMA verbs device:       iwo3
physical NVMe BDF:       0000:3b:00.0
physical PCI ID:         8086:0a54
subsystem ID:            8086:4802
class:                   010802
namespace before unbind: /dev/nvme0n1
model/serial:            INTEL SSDPE2KX010T8 / BTLJ910006931P0FGN
capacity:                931.5G
```

登录 Host B 后设置：

```sh
export B_RDMA_IP=10.30.19.15
export B_RDMA_DEV=iwo3
export B_RDMA_NETDEV=eno3
export B_NVME_BDF=0000:3b:00.0
export B_NVME_DEV=/dev/nvme0n1
export B_HUGEPAGE_FILE=/dev/hugepages/scope-nvme0
export REMOTE_NVME_SERVICE=7473
export REMOTE_NVME_ID=remote-nvme-shadow-0
export REMOTE_NVME_NSID=1
export REMOTE_AGENT_DIR=/home/yanjiarun/scope_remote_nvme_agent_17
export AGENT_LOG=/tmp/scope-remote-nvme-shadow-agent.log
```

## 3. 安全约束

Host B agent 不绑定 `nvme`、`vfio-pci` 或 `uio`，而是直接 mmap sysfs BAR0，
并把 `/proc/self/pagemap` 得到的物理地址写入 NVMe PRP。必须满足：

- 目标 NVMe 是专用实验盘，不承载 rootfs、swap、LVM、mdraid 或活动文件系统；
- SSH/RDMA 使用 `iwo3/eno3`，不依赖目标 NVMe；
- 目标函数处于 identity DMA 环境；当前实现不会创建 IOMMU 映射；
- agent、QEMU 和香山运行期间，不重新绑定、reset、remove 或热拔目标盘；
- 在明确确认盘内数据可丢失前，只执行 READ 测试；
- `REMOTE_NVME_SERVICE` 和 `REMOTE_NVME_ID` 同时只供一个会话使用。

本次 Host B 检查结果是：内核命令行未启用 IOMMU，`/sys/kernel/iommu_groups`
为空，目标设备没有有效 `iommu_group`。这与 identity DMA 假设相符，但生产化实现
仍应改用 VFIO/IOMMU 映射或内核 DMA API，不能长期依赖物理地址直写。

## 4. 代码与构建基线

在 Host A：

```sh
cd "$SCOPE_REPO"

cmp tools/scope_remote_agent/scope_remote_proto.h \
    qemu-mount/include/hw/misc/scope_remote_proto.h

git diff --check
git -C qemu-mount diff --check

make -C tools/scope_remote_agent scope-remote-nvme-shadow-agent
test -x tools/scope_remote_agent/scope-remote-nvme-shadow-agent
```

`cmp` 和两个 `diff --check` 均应无输出。

不要使用从其他仓库复制来的 QEMU build 目录。检查 source path：

```sh
grep -R '/home/yanjiarun/nexst_proxy_16/qemu-mount' \
    "$SCOPE_REPO/qemu-mount/build-rdma"/build.ninja \
    "$SCOPE_REPO/qemu-mount/build-rdma"/config-host.mak 2>/dev/null || true
```

若命中旧仓库路径，不使用该目录。当前已验证的全新目录为：

```sh
cd "$SCOPE_REPO/qemu-mount"
mkdir -p "$QEMU_BUILD"
cd "$QEMU_BUILD"
test -f build.ninja || \
  ../configure --target-list=x86_64-softmmu --enable-rdma --disable-docs
ninja qemu-system-x86_64
test -x "$QEMU_BUILD/qemu-system-x86_64"
```

## 5. RDMA 基线

先不要解绑 NVMe。Host B 启动临时 server：

```sh
rping -s -a "$B_RDMA_IP" -p "$REMOTE_NVME_SERVICE" -v
```

Host A：

```sh
rdma link show "$A_RDMA_DEV/1"
ip route get "$HOST_B"
rping -c -a "$HOST_B" -p "$REMOTE_NVME_SERVICE" \
  -C 1000 -S 4096 -v
```

预期 Host A 路由从 `eno3` 发出，`iwo3/1` 为 `ACTIVE/LINK_UP`，1000 次传输
无 CQ error。完成后在 Host B 停止 `rping`，释放 7473 端口。

## 6. 部署 Host B Agent

在 Host A：

```sh
ssh -i "$SSH_KEY" "$HOST_B_USER@$HOST_B" \
  "mkdir -p /home/yanjiarun/scope_remote_nvme_agent_17"

scp -i "$SSH_KEY" \
  "$SCOPE_REPO/tools/scope_remote_agent/Makefile" \
  "$SCOPE_REPO/tools/scope_remote_agent/scope_remote_proto.h" \
  "$SCOPE_REPO/tools/scope_remote_agent/scope_remote_nvme_shadow_agent.c" \
  "$HOST_B_USER@$HOST_B:/home/yanjiarun/scope_remote_nvme_agent_17/"

ssh -i "$SSH_KEY" "$HOST_B_USER@$HOST_B" \
  "rm -f /home/yanjiarun/scope_remote_nvme_agent_17/scope-remote-nvme-shadow-agent && \
   make -C /home/yanjiarun/scope_remote_nvme_agent_17 \
   scope-remote-nvme-shadow-agent && \
   strings /home/yanjiarun/scope_remote_nvme_agent_17/scope-remote-nvme-shadow-agent | \
   grep -F nvme-shadow-cqe-order-v3"
```

预期 Host B 编译命令包含 `-Wall -Wextra -Werror`，并成功生成
`scope-remote-nvme-shadow-agent`。最后必须输出
`nvme-shadow-cqe-order-v3`；否则不要继续启动香山。

如果 Host B 缺少构建依赖，先安装：

```sh
sudo apt-get install -y build-essential rdma-core libibverbs-dev \
  librdmacm-dev pciutils nvme-cli
```

## 7. Host B 盘与 DMA 环境检查

以下命令都在 Host B 执行。

### 7.1 身份和占用检查

```sh
lspci -Dnnk -s "$B_NVME_BDF"
for f in vendor device subsystem_vendor subsystem_device class; do
  printf '%s=' "$f"
  cat "/sys/bus/pci/devices/$B_NVME_BDF/$f"
done

lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "$B_NVME_DEV"
findmnt
swapon --show
sudo fuser -vm "$B_NVME_DEV" 2>/dev/null || true
```

必须得到：

```text
vendor=0x8086
device=0x0a54
subsystem_vendor=0x8086
subsystem_device=0x4802
class=0x010802
```

如果 `lsblk` 显示挂载、swap、LVM holder 或其他活动用户，停止本流程。

### 7.2 hugepage 和 identity DMA

```sh
grep -E 'HugePages_Total|HugePages_Free|Hugepagesize' /proc/meminfo
mount | grep hugetlbfs
cat /proc/cmdline
ls -l "/sys/bus/pci/devices/$B_NVME_BDF/iommu_group" 2>/dev/null || true
find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d | head
```

当前机器已有 2 个空闲 2 MiB hugepage，且 `/dev/hugepages` 已挂载。若状态变化：

```sh
sudo mkdir -p /dev/hugepages
mountpoint -q /dev/hugepages || \
  sudo mount -t hugetlbfs -o pagesize=2M none /dev/hugepages
sudo sysctl -w vm.nr_hugepages=2
sudo rm -f "$B_HUGEPAGE_FILE"
```

如果发现目标盘处于 translated IOMMU domain，停止。不要仅凭
`--allow-unsafe-identity-dma` 强行继续。

## 8. Host B 解绑并启动 Agent

先确认设备存在，再按当前绑定状态处理。`driver` 符号链接不存在表示设备已经解绑，
此时不应访问不存在的 `driver/unbind`：

```sh
export B_NVME_SYSFS="/sys/bus/pci/devices/$B_NVME_BDF"
test -d "$B_NVME_SYSFS"

if [ -L "$B_NVME_SYSFS/driver" ]; then
  B_NVME_DRIVER_PATH=$(readlink -f "$B_NVME_SYSFS/driver")
  export B_NVME_ORIGINAL_DRIVER=${B_NVME_DRIVER_PATH##*/}
  test "$B_NVME_ORIGINAL_DRIVER" = nvme
  echo "$B_NVME_BDF" | sudo tee "$B_NVME_SYSFS/driver/unbind"
else
  export B_NVME_ORIGINAL_DRIVER=nvme
  echo "$B_NVME_BDF is already unbound"
fi

test ! -L "$B_NVME_SYSFS/driver"
lspci -Dnnk -s "$B_NVME_BDF"
```

建议一次粘贴完整代码块。这里的变量名是 `$B_NVME_BDF`，不要输入
`$B\_NVME\_BDF`；Markdown 显示中的反斜杠不属于 shell 变量名。设备解绑后，
`lspci` 应只显示 `Kernel modules: nvme`，不应再显示 `Kernel driver in use`。

不要绑定 VFIO。保持当前 Host B 终端前台运行 agent：

```sh
# 先在原 agent 终端按 Ctrl-C，再确认不存在仍映射旧 inode 的进程。
pgrep -af '[s]cope-remote-nvme-shadow-agent' || true
test -z "$(pgrep -f '[s]cope-remote-nvme-shadow-agent' || true)"

cd "$REMOTE_AGENT_DIR"
strings ./scope-remote-nvme-shadow-agent | \
  grep -F nvme-shadow-cqe-order-v3
sudo ./scope-remote-nvme-shadow-agent \
  --listen "$B_RDMA_IP" \
  --service "$REMOTE_NVME_SERVICE" \
  --rdma-device "$B_RDMA_DEV" \
  --device-id "$REMOTE_NVME_ID" \
  --pci-bdf "$B_NVME_BDF" \
  --namespace-id "$REMOTE_NVME_NSID" \
  --hugepage-file "$B_HUGEPAGE_FILE" \
  --allow-unsafe-identity-dma \
  2>&1 | tee "$AGENT_LOG"
```

预期启动日志类似：

```text
NVMe 8086:0a54 0000:3b:00.0 ... nsid=1 ... lba_shift=9 ...
scope-remote-nvme-shadow-agent build=nvme-shadow-cqe-order-v3 listening on 10.30.19.15:7473 ...
```

第一行说明 agent 已完成 BAR0 映射、连续 DMA pool 建立、临时 Admin queue
初始化和 Identify Namespace，并重新关闭了 controller。若日志仍要求物理
`8086:4802`，或启动行没有 `build=nvme-shadow-cqe-order-v3`，说明 Host B
使用的是未修正的旧二进制。

## 9. Host A QEMU 配置与启动

确认配置：

```sh
cat "$SCOPE_REPO/vswitch-backends-remote-nvme-shadow.json"
```

关键内容必须是：

```json
{
  "type": "nvme",
  "transport": "remote-rdma",
  "remote-device-mode": "shadow-queue",
  "remote-host": "10.30.19.15",
  "remote-service": "7473",
  "remote-device-id": "remote-nvme-shadow-0",
  "rdma-device": "iwo3",
  "rdma-memory-mode": "host-staging",
  "rdma-staging-size": 4194304,
  "namespace-id": 1
}
```

启动前确认 FPGA/XDMA。以下检查任意一项失败都不要启动：

```sh
lspci -Dnnk -s "$A_FPGA_BDF"
test -e "$XDMA_USER_DEV"
test -e "$XDMA_CTRL_DEV"
test -e "$XDMA_BYPASS_DEV"
rdma link show "$A_RDMA_DEV/1"
```

Host B agent 已监听后，在 Host A 启动 QEMU manager：

```sh
cd "$SCOPE_REPO/qemu-mount"
sudo "$QEMU_BUILD/qemu-system-x86_64" \
  -machine q35 -m 128M -display none -monitor null -serial null \
  -device pcie-root-port,id=rp1,bus=pcie.0 \
  -device scope-fpga-vswitch,bus=rp1,\
backend-config="$SCOPE_REPO/vswitch-backends-remote-nvme-shadow.json",\
fpga-host-bdf="$A_FPGA_BDF",xdma-user-dev="$XDMA_USER_DEV",\
xdma-ctrl-dev="$XDMA_CTRL_DEV",xdma-bypass-dev="$XDMA_BYPASS_DEV",\
guest-ddr-base=0x80000000,guest-ddr-size=0x80000000,dma32-ring-size=0x10000 \
  2>&1 | tee "$QEMU_LOG"
```

预期出现 `[SCOPE REMOTE][READY]`，并包含：

```text
memory=host-staging(extra-qemu-copy)
lba_shift=9
max_inflight=1
```

这也说明当前路径不是零拷贝：WRITE 会执行 guest DDR 到 Host A staging 的
QEMU copy；READ 完成时执行反向 copy。

## 10. 启动香山并完成 NVMe 枚举

保持 Host B agent 和 Host A QEMU manager 前台运行。在 Host A 新开一个终端，先检查
启动工具和镜像：

```sh
cd "$SCOPE_REPO/tools/proto"
make
test -x ./load_and_run_5.sh
test -c "/dev/${A_XDMA_NAME}_user"
test -c "/dev/${A_XDMA_NAME}_bypass"
test -f "$BOOT_DIR/bootrom.bin"
test -f "$BOOT_DIR/RV_BOOT.bin"
```

所有检查通过后，加载 bootrom 和 Linux 镜像、释放香山 reset，并连接 UART：

```sh
cd "$SCOPE_REPO/tools/proto"
sudo ./load_and_run_5.sh "$A_XDMA_NAME" \
  "$BOOT_DIR/bootrom.bin" \
  "$BOOT_DIR/RV_BOOT.bin"
```

启动顺序必须是：Host B agent ready、Host A QEMU 出现
`[SCOPE REMOTE][READY]`、最后执行 `load_and_run_5.sh`。不要同时打开 minicom，否则
会与脚本争用 UART。退出串口使用 `Ctrl-\`；不复位、不重新加载镜像，仅重新连接
UART 时执行：

```sh
cd "$SCOPE_REPO/tools/proto"
sudo ./load_and_run_5.sh "$A_XDMA_NAME"
```

进入香山 Linux shell 后检查：

```sh
lspci -nnk
dmesg | grep -iE 'nvme|pci|pcie'
ls -l /sys/class/nvme
lsblk
```

虚拟 endpoint 的设备 ID 由 QEMU 固定为 `8086:4802`，这与 Host B 物理 PCI
device ID `8086:0a54` 不同，是当前虚拟 ABI 的设计，不是识别错误。预期：

```text
Non-Volatile memory controller [0108]: ... [8086:4802]
Kernel driver in use: nvme
```

初始化成功必须依次经过：

```text
guest AQA/ASQ/ACQ write
  -> Host A guest queue shadow
  -> ordered remote BAR_WRITE metadata
  -> agent translates physical ASQ/ACQ to Host B shadow queue addresses
  -> guest CC.EN
  -> remote BAR_WRITE(CC)
  -> agent writes physical AQA/ASQ/ACQ/CC
  -> physical CSTS.RDY=1
  -> Identify Controller（QEMU 向 guest 屏蔽未实现的 SGL capability）
  -> Identify Namespace
  -> Set Features Number of Queues = 1
  -> Create CQ 1
  -> Create SQ 1
```

Host A 观察：

```sh
grep -E 'SCOPE REMOTE.*(READY|IDENTIFY|SUBMIT|COMPLETE)|BAR|CSTS|timeout|failed' \
  "$QEMU_LOG"
```

控制器初始化阶段应看到 `BAR][SUBMIT` 的 `off=0x0024`、`off=0x0028`、
`off=0x0030` 和 `off=0x0014`，并分别收到 `BAR][DONE` 或 `NVME][CC`。
Identify Controller 成功后还必须看到：

```text
[SCOPE REMOTE][NVME][IDENTIFY] ... masked_sgls=1
```

`ASQ/ACQ` 请求传递的是 guest 寄存器元数据；agent 保存它们用于初始化校验，但不会
把 FPGA 地址原样写给真实 P4510。物理控制器最终使用 Host B hugepage pool 中的
shadow SQ/CQ 地址。SQE 内容在 guest doorbell 后通过 `NVME_SUBMIT` 发送，不能与
ASQ/ACQ 寄存器值混为一谈。

Host B 观察：

```sh
grep -E 'NVMe BAR (RX|TX|CC)|CSTS|RDMA completion failed' "$AGENT_LOG"
```

每个请求应依次出现带 `op=read/write` 的 `NVMe BAR RX`、
`NVMe BAR TX ... begin` 和
`NVMe BAR TX ... done`。若只有 `begin` 而没有 `done`，故障位于 RDMA SEND
完成路径；若 Host A 有 `SUBMIT` 而 Host B 没有对应 `RX`，则检查 QP 和请求发送路径。

QEMU transport 还会为每个 BAR RPC 输出：

```text
[SCOPE RDMA][BAR][POST]
[SCOPE RDMA][BAR][SEND_CQ]
[SCOPE RDMA][BAR][RECV_CQ]
```

Host B agent 会在发送上一条 response 前预先 post 下一条 receive WQE。若
`POST` 和 `SEND_CQ` 都存在但 Host B 没有 `NVMe BAR RX`，检查 iWARP QP；若 Host B
已有 `TX ... done` 而 Host A 没有 `RECV_CQ`，检查 Host A receive CQ。CSTS 对应
`off=0x001c, op=read`，它必须与初始化寄存器写一样完成 request/response 闭环。

注意：BAR write 是异步转发。QEMU 会先完成香山侧 MMIO transaction，再等待
Host B response；远端拒绝或超时会将 backend 标为 failed。只有 `CSTS` 会周期性
远端读取并缓存在 Host A，CAP/VS/AQA/ASQ/ACQ 等读取来自 QEMU/本地 shadow。

若香山 rootfs 包含 `nvme-cli`，继续验证 Admin 命令和 Identify payload：

```sh
nvme list
nvme id-ctrl /dev/nvme0
nvme id-ns /dev/nvme0n1
```

当前 shadow transport 只实现 PRP，因此 `nvme id-ctrl` 中的 `sgls` 必须是 `0`。
这是虚拟设备有意收窄能力，不改变物理 P4510 本身的寄存器或固件能力。

若没有 `nvme-cli`，至少读取 sysfs 中由 Identify 建立的属性：

```sh
cat /sys/class/nvme/nvme0/model
cat /sys/class/nvme/nvme0/serial
cat /sys/class/nvme/nvme0/firmware_rev
cat /sys/block/nvme0n1/size
cat /sys/block/nvme0n1/queue/logical_block_size
```

## 11. 先做非破坏性 READ

在香山确认设备名：

```sh
lsblk
export GUEST_NVME=/dev/nvme0n1
```

小块读取：

```sh
dd if="$GUEST_NVME" of=/dev/null bs=4K count=256
```

再测试 128 KiB：

```sh
dd if="$GUEST_NVME" of=/dev/null bs=128K count=128
```

最后再执行与论文带宽测试相同的 direct I/O；Linux 可能按控制器限制把每个 1 MiB
请求拆成多条 128 KiB NVMe 命令，因此 QEMU 中出现 `bytes=131072` 是正常现象：

```sh
dd if="$GUEST_NVME" of=/dev/null bs=1M count=256 iflag=direct
```

有 `fio` 时：

```sh
fio --name=remote-nvme-read \
    --filename="$GUEST_NVME" \
    --direct=1 --rw=read --bs=4k --iodepth=1 --numjobs=1 \
    --size=64m --runtime=30 --time_based=1 --group_reporting
```

对每个成功请求，Host A 应看到一对同 request ID 的 `SUBMIT`/`COMPLETE`。
READ 的正确顺序是：

```text
physical CQE
  -> Host B RDMA WRITE 到 Host A staging
  -> NVME_COMPLETE
  -> QEMU copy 到 guest DDR
  -> guest CQE
  -> legacy INTx
```

测试时在 Host A 另开终端观察 PRP 解析和 I/O 生命周期：

```sh
tail -n 0 -F "$QEMU_LOG" | grep --line-buffered -E \
  '\[SCOPE REMOTE\]\[(PRP|NVME)\]'
```

若发生短暂可见性等待，正常恢复序列应为 `PRP][WAIT`、`PRP][READY`、
`NVME][SUBMIT`、`NVME][COMPLETE`，且 guest 不应进入 controller reset。

### 11.1 PRP/CQE 修复的专项回归（2026-09-17）

Host A 执行下列无硬件单元测试。脚本从当前源码提取生产函数编译，模拟 guest
内存及 DMA/RDMA；它们不测试 FPGA cache coherence、实际 RDMA 或中断传递：

```sh
cd /home/yanjiarun/nexst_proxy_17/nexst_proxy_16
bash qemu-mount/tests/unit/run-scope-remote-nvme.sh
bash tools/scope_remote_agent/tests/run-nvme-completion.sh
```

默认开启 AddressSanitizer/UndefinedBehaviorSanitizer。预期分别通过 2581 和 12
个用例，覆盖日志中的 `PRP1=0x8297c000, PRP2=0x84ea3100, length=131072`、
所有 8 字节对齐的首 list 页内偏移、仅含链指针的页尾、非法地址、64 segment
上限、CQ 空间预留，以及先观察物理 CQE phase 再读取其余字段、先完成数据回传
再通知 QEMU、phase 翻转和 RDMA 错误完成。

本次还修复了 CC.EN 清零后过早清空物理队列内存的竞态。agent 立即停用软件
队列状态，但仅在再次启动、确认物理 RDY=0 后重建 DMA 队列。这个硬件时序尚需
实机验证，不能用上述模拟测试代替。

重新编译并按第 6/8/9 节部署、重启两端后，在香山上重复原始只读测试：

```sh
for n in 1 2 3; do
  echo "remote NVMe read round=$n"
  dd if=/dev/nvme0n1 of=/dev/null bs=1M count=256 iflag=direct || break
done
dmesg | tail -n 80
```

必须三轮全部完成、各读取 256 MiB，且两端无 `PRP][ERR`、BAR/request timeout、
CQE mismatch、`controller is down` 或 namespace removal，才能判定原始持续读取
故障的实机回归通过。`dd` 成功不等同于数据正确性验证；需进一步与 Host B 对同一
未变更 LBA 范围计算的哈希比较。长时随机读与 reset/reconnect 仍需单独测试。

自动检查时两端均未运行测试进程，Host B 非交互 sudo 需要密码，因此当时没有由
自动检查重新执行实机持续读取。之后用户确认当前版本可以正常工作；这是用户实测
反馈，不补记不存在的自动测试日志或测试轮次。failed controller 仍采用停止两端并
按第 15 节恢复的流程，不声称支持透明故障重连。

## 12. 可选破坏性 WRITE

仅当已经确认整块 P4510 可擦除时执行。不要在未知数据盘上运行：

```sh
fio --name=remote-nvme-write \
    --filename="$GUEST_NVME" \
    --direct=1 --rw=write --bs=4k --iodepth=1 --numjobs=1 \
    --offset=1g --size=64m --runtime=30 --time_based=1 \
    --group_reporting
```

随后可在同一范围做校验型测试：

```sh
fio --name=remote-nvme-verify \
    --filename="$GUEST_NVME" \
    --direct=1 --rw=write --bs=4k --iodepth=1 --numjobs=1 \
    --offset=1g --size=64m --verify=crc32c --do_verify=1 \
    --group_reporting
```

## 13. 性能记录

Phase-1 强制 `iodepth=1`，结果主要反映完整远端控制/数据往返延迟，不代表盘的
原生并发能力。建议记录：

```sh
fio --name=seq-read-128k --filename="$GUEST_NVME" --direct=1 \
    --rw=read --bs=128k --iodepth=1 --numjobs=1 \
    --runtime=60 --time_based=1 --group_reporting

fio --name=rand-read-4k --filename="$GUEST_NVME" --direct=1 \
    --rw=randread --bs=4k --iodepth=1 --numjobs=1 \
    --runtime=60 --time_based=1 --group_reporting
```

同时保存 QEMU 日志中的 `latency_us`，并记录 Host A QEMU CPU 占用和 Host B
agent CPU 占用。论文比较时至少包含：本地 NVMe、远端 NVMe、4K/128K、顺序/随机、
IOPS、带宽、平均及 P99 延迟。

## 14. 故障定位

### 14.1 Agent 报设备身份不符

```sh
for f in vendor device subsystem_vendor subsystem_device class; do
  cat "/sys/bus/pci/devices/$B_NVME_BDF/$f"
done
```

当前 agent 只接受本机这块 P4510：PCI `8086:0a54`、subsystem `8086:4802`。

### 14.2 `prepare raw NVMe: Device or resource busy`

目标仍绑定 `nvme`，或 BAR 正被使用。重新执行第 7、8 节占用检查，不要强行 mmap。

### 14.3 pagemap 返回 `Operation not permitted`

必须以 root 启动 agent；同时确认 hugepage 文件位于 hugetlbfs。不要用普通 tmpfs
或 ext4 文件替代。

### 14.4 `CSTS.RDY` 超时或 `CSTS.CFS=1`

检查 QEMU 中 AQA/ASQ/ACQ/CC BAR response 是否成功；检查 Host B agent 是否仍在；
停止两端并按第 15 节恢复，不要在 failed controller 上继续发 I/O。

### 14.5 `[SCOPE REMOTE][PRP][WAIT/READY/ERR]`

Host A 通过 XDMA coherent alias 读取 guest SQE 和 PRP list。短暂读到未完全可见的
内容时会输出一次 `PRP][WAIT`，每 100 微秒重读，最多等待 100 毫秒；随后出现
`PRP][READY` 和 `NVME][SUBMIT` 表示已恢复，不需要重启。

对于大于一个后续数据页的请求，`PRP2` 表示 PRP list 地址。Linux 对 4 KiB 到
128 KiB 范围内需要 list 且条目不超过 32 的请求可使用 256 字节 small PRP pool。
协议要求首个 list 地址 8 字节对齐，而不要求 4 KiB 页对齐，因此类似
`PRP2=...3100` 是合法格式。只有当 `PRP2` 直接表示第二个数据页
时才必须按 controller page 对齐。修复后的解析器遵循该区别；不要重新加入统一的
`PRP2 & page_mask` 检查。

如果最终出现 `PRP][ERR`，日志中的 `reason`、`entry`、`addr`、`prp1`、`prp2`
和 `psdt` 可区分零项、未对齐、越界、读取失败以及非 PRP 命令。该错误发生在 Host A，
命令尚未发送给 Host B。
随后看到的 guest `CSTS=0x3` 是 QEMU failed 状态下的 `RDY|CFS`，不能单独证明
物理 NVMe 先发生 CFS。

若 `reason=unsupported-psdt` 或 `psdt` 非 0，先确认 QEMU 初始化日志出现
`masked_sgls=1`。缺少该日志通常表示仍在运行旧 QEMU 二进制；即使已经替换二进制，
也必须停止旧 QEMU、重新启动 agent/QEMU 并重新启动香山，让 Linux 重新读取 Identify
Controller，不能只在已启动的 guest 中重跑 `dd`。

### 14.6 有 SUBMIT，没有 COMPLETE

同时检查：

```sh
# Host A
grep -E 'SUBMIT|COMPLETE|BAR.*timeout|remote-rdma.*failed' "$QEMU_LOG"

# Host B
grep -E 'unexpected NVMe CQE|RDMA completion failed|bootstrap|prepare' \
  "$AGENT_LOG"
```

重点排查 identity DMA 不成立、物理 doorbell 未生效、CQ phase/CID 不匹配、RDMA
连接中断。5 秒请求超时后 QEMU 会标记 backend failed，需要完整重启会话。

### 14.7 QEMU 启动即报 XDMA 文件不存在

在 Host A 确认 NM37 `0000:3b:00.0` 已绑定项目要求的 XDMA 驱动，并按项目既有
流程加载 XDMA，直到三个 `/dev/xdma0_*` 节点存在。Host B 上同名的
`0000:3b:00.0` 是另一台机器上的 NVMe，不会与 Host A 的 NM37 冲突。

## 15. 停止与恢复 Host B

顺序必须是：先停止香山 I/O，再停止 Host A QEMU，最后 `Ctrl-C` 停止 Host B
agent。agent cleanup 会关闭 controller、恢复 PCI command，并删除自己创建的
hugepage 文件。

Host B 重新绑定内核 NVMe 驱动：

```sh
sudo rm -f "$B_HUGEPAGE_FILE"
if [ ! -L "/sys/bus/pci/devices/$B_NVME_BDF/driver" ]; then
  echo "$B_NVME_BDF" | sudo tee /sys/bus/pci/drivers/nvme/bind
fi
lspci -Dnnk -s "$B_NVME_BDF"
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
dmesg | tail -n 100
```

验收标准：`Kernel driver in use: nvme` 恢复，`/dev/nvme0n1` 重新出现，且内核
没有持续 reset、I/O timeout 或 controller fatal status。
