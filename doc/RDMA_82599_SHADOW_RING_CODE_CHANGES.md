# 远端 Intel 82599 影子环代码修改设计

## 1. 修改范围

本修改在不改变 FPGA packet ABI 和香山 Linux 驱动的情况下，增加一个 Host B
无功能驱动、无 VFIO 的真实 82599 shadow-ring 数据面。现有 AF_PACKET agent
保留，配置文件显式选择模式。

## 2. Wire capability

同步修改：

- `tools/scope_remote_agent/scope_remote_proto.h`
- `qemu-mount/include/hw/misc/scope_remote_proto.h`

新增 feature：

```c
SCOPE_REMOTE_FEATURE_IXGBE_SHADOW_RING = 1ULL << 5
SCOPE_REMOTE_FEATURE_IXGBE_INLINE = 1ULL << 6
```

并新增 `SCOPE_REMOTE_IXGBE_SHADOW_FEATURES`，包含 IXGBE packet、shadow-ring 和
inline bit，不包含 `PEER_MR/HOST_A_STAGING`。Phase 1 复用原有
`IXGBE_TX/TX_COMPLETE/RX/LINK` payload，不改变消息大小和 opcode，因此 protocol
major/minor 不变。

## 3. Host A QEMU 修改

### 3.1 配置解析

`ScopeBackend` 增加 `remote_ixgbe_shadow_ring`。JSON 新增：

```json
"remote-device-mode": "shadow-ring"
```

校验规则：

- 仅允许 `type=ixgbe, transport=remote-rdma`；
- `packet` 为兼容默认值；
- `shadow-ring` 要求 `rdma-memory-mode=inline`，不分配 Host A payload MR；
- 其他 backend 出现该字段时直接报错。

### 3.2 RDMA 握手

`ScopeRemoteConfig` 增加 `ixgbe_shadow_ring`。`scope_remote_handshake()` 根据该值
选择普通 packet feature set 或 shadow feature set。这样配置不能误连到另一类
agent。

### 3.3 IXGBE backend

`scope_ixgbe_backend_realize()` 将配置传给 RDMA transport，并在 ready 日志中打印
`remote_device_mode=packet|shadow-ring`。guest-visible descriptor 和 BAR 行为不变。

## 4. Host B shadow agent

新增 `tools/scope_remote_agent/scope_remote_ixgbe_shadow_agent.c`，生成二进制：

```text
scope-remote-ixgbe-shadow-agent
```

### 4.1 参数

```text
--listen ADDR
--service PORT
--rdma-device DEV
--device-id ID
--pci-bdf DDDD:BB:DD.F
--hugepage-file PATH
--allow-unsafe-identity-dma
```

### 4.2 启动检查

1. BDF 格式合法且 sysfs vendor/device 为 `8086:10fb`。
2. `/sys/bus/pci/devices/<BDF>/driver` 不存在。
3. BAR0 resource 至少 128 KiB。
4. hugepage file 所在文件系统类型为 hugetlbfs。
5. `mlock()` 成功，pagemap PFN 可见，pool 所有 4 KiB 页物理连续。
6. identity DMA 确认参数存在。
7. PCI command 的 MEMORY/BUS_MASTER 设置和 readback 成功。

### 4.3 物理队列

- queue 0，TX/RX depth 256；
- advanced TX data descriptor；
- one-buffer advanced RX descriptor；
- 每 slot 2048 B，MTU 对外固定为 1500；
- 真实中断关闭，agent 轮询 DD 和 LINKS；
- Phase 1 每个 TX request 等待对应 DD 后返回 completion，保持 request ID 精确对应。
- 启动时清读真实 `GPTC/GPRC`，退出时同时打印物理计数与 agent 软件计数。

### 4.4 RDMA session

连接和消息生命周期与 `scope_remote_nic_agent.c` 相同，但 HELLO 必须同时包含
`SCOPE_REMOTE_FEATURE_IXGBE_SHADOW_RING`。DEVICE_OPEN 返回真实 BAR 中读取的 MAC
和 link 状态。

## 5. 构建和部署

`tools/scope_remote_agent/Makefile` 将新 agent 加入 `all` 和 `clean`。

新增 `setup_remote_82599_shadow_ring.sh`：

- 验证 X722/RDMA transport 和目标 82599 是不同设备；
- 检查目标 netdev 没有 IP；
- 可先由 ixgbe bring-up，再 unbind；
- 部署源码并在 Host B 编译；
- 用 root 启动 shadow agent；
- 生成带 `remote-device-mode=shadow-ring` 的 QEMU JSON；
- stop 后清理 agent，并可执行 drivers_probe 重新绑定 ixgbe。

脚本要求显式设置 `REMOTE_ALLOW_UNSAFE_IDENTITY_DMA=1`，避免无意关闭隔离。
agent 捕获 `SIGINT/SIGTERM` 并走统一硬件 cleanup；脚本在重新绑定 `ixgbe` 前验证
agent 已退出，若 5 秒内未退出则拒绝 re-probe。远端 `sudo` 默认分配 TTY 交互输入
密码，CI 可设置 `REMOTE_SUDO_NONINTERACTIVE=1` 使用 `sudo -n`。

## 6. 不在本次代码中实现的 Phase 2

以下接口留作后续修改，不在 Phase 1 wire ABI 中占用半成品 opcode：

- TX scatter segment request；
- RX guest buffer credit；
- Host B `IBV_WR_RDMA_READ/WRITE` payload work request；
- Host A peer-dmabuf 模式下不再把 payload 放入 RDMA SEND message；
- 多队列、RSS、TSO、VLAN offload 和真实 MSI-X forwarding。

原因是当前 X722 provider 和 XDMA P2PDMA 条件尚未验证通过。先引入不可运行的
one-sided 数据面会把硬件能力问题混入 shadow-ring 正确性验证。

## 7. 测试计划

### 7.1 静态和单机检查

- 两份 protocol header `cmp` 一致；
- `make -C tools/scope_remote_agent clean all`；
- QEMU 相关对象或完整 RDMA build 编译；
- shell script 通过 `bash -n`；
- packet 配置和 shadow 配置 parser 正反例。

### 7.2 Host B 硬件检查

- 已绑定 `ixgbe` 时启动失败；
- unbind 后 BAR/MAC/LINKS 读取正确；
- TX descriptor DD、GPTC/GOTC 增长；
- RX descriptor DD、GPRC/GORC 增长；
- stop 后 PCI command BUS_MASTER 为 0。

### 7.3 端到端检查

- 香山 `lspci -nn` 显示 `8086:10fb`，`ixgbe` probe 成功；
- `ip link set`、ARP、ping、iperf3 正常；
- 拔线/插线能触发 guest link state 变化；
- agent kill 后 guest link down，不错误完成在途 TX；
- 与 AF_PACKET 模式分别记录带宽、CPU、延迟和丢包，论文中不能混为一种路径。

## 8. 回滚

设置 `remote-device-mode=packet` 并启动原 `scope-remote-nic-agent` 即可回到当前
路径。新功能不改变 packet 模式 wire message，也不修改 FPGA bitstream。

## 9. 2026-09-03 实施与验收状态

已完成：

- 两份 wire header 完全一致；
- Host A 上全部 remote agent 以 `-Wall -Wextra -Werror` 构建通过；
- 新 agent 部署到 `10.30.19.15:/home/yanjiarun/scope_remote_agent_16`，并在 Host B
  构建通过；
- QEMU 全新 `build-rdma-shadow` 配置和 `qemu-system-x86_64` 链接通过；
- 部署脚本通过 `bash -n` 和 `shellcheck`；
- Host B 检查到 RDMA 为 `iwo3/eno3`，目标 82599 为
  `0000:5e:00.0/ens3f0`，两者相互独立；
- Host B 的 `/sys/kernel/iommu_groups` 为空；
- 目标仍绑定 `ixgbe` 时，shadow agent 按设计以 `EBUSY` fail closed，计数为
  `tx=0 rx=0`。

尚未完成的是真实设备正向验收。Host B 的 `sudo -n` 返回“需要密码”，当前会话不能
安全地分配 hugepage、unbind `ixgbe` 或修改 PCI command。因此尚未声称下列项目
通过：真实 TX/RX descriptor DD、ping/iperf、链路变化，以及 agent 退出后的
BUS_MASTER readback。操作者在可交互终端执行以下命令后，应按第 7 节完成这些测试：

```sh
cd /home/yanjiarun/nexst_proxy_16
REMOTE_ALLOW_UNSAFE_IDENTITY_DMA=1 \
  tools/scope_remote_agent/setup_remote_82599_shadow_ring.sh all
```
