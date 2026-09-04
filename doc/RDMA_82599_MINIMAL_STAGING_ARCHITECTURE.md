# RDMA 82599 最小 Staging 数据通路架构

## 1. 目标与结论

本文只依据仓库当前实现分析如何把远端 82599 数据通路从“完整帧内联 RDMA
SEND”改为“FPGA peer MR + Host B 小型共享 DMA pool”，目标是：

- Host A 不再分配未使用的 payload staging MR；
- Host A QEMU 不读取或写入 Ethernet payload；
- Host B CPU 不复制 Ethernet payload；
- Host B RDMA RNIC 与 82599 DMA 使用同一批普通主机内存；
- 保持 guest 标准 `ixgbe` 的 descriptor ownership、DD writeback 和中断语义。

总体判断是**架构可行，但当前目标机器尚不能直接端到端启用**：

- 删除 Host A 当前未使用的 staging：高可行性，改动小；
- IXGBE 使用 FPGA `peer-dmabuf` MR：代码基础已存在，但受 Host A 内核、RNIC
  provider 和 PCIe topology 约束；当前已记录的 X722/`irdma` 环境不满足条件；
- Host B 共享 DMA pool：普通 RAM 同时注册为 RDMA MR 并交给 82599 DMA 在架构上
  可行，但必须用 DPDK PMD 或经强制 zero-copy 验证的 AF_XDP 替换 `AF_PACKET`；
- RNIC 与 82599 完全绕过 Host B RAM：当前 82599 软件接口不支持，不作为目标。

目标数据面仍然经过 Host B RAM 一次，但不存在 CPU payload copy：

```text
TX:
guest TX buffer in FPGA DDR
  -> Host A RNIC peer-memory MR
  -> RDMA READ
  -> Host B shared DMA slot
  -> 82599 DMA read
  -> wire

RX:
wire
  -> 82599 DMA write
  -> Host B shared DMA slot
  -> RDMA WRITE
  -> guest RX buffer in FPGA DDR
```

这里的“最小 staging”指 Host B 只有一份由两个设备复用的有界 slot pool，不表示
物理上绕过 Host B DRAM。

## 2. 当前代码事实

### 2.1 当前 IXGBE payload 不使用 Host A staging

配置解析和 IXGBE preflight 强制 `host-staging`，但 TX/RX 数据路径不访问
`scope_remote_staging_data()`：

- `scope_ixgbe_process_tx()` 使用 `scope_guest_mem_read()` 把 guest buffer 拼进
  `x->tx_frame[2048]`；
- `scope_remote_submit_ixgbe_tx()` 把完整帧复制进 4 KiB control message；
- Host B `handle_tx()` 对 message payload 调用 `sendto(AF_PACKET)`；
- Host B RX 使用 `recvfrom()` 和 `memcpy()` 构造完整帧消息；
- Host A `scope_ixgbe_deliver_rx()` 使用 `scope_guest_mem_write()` 写入 guest buffer。

因此当前 4 MiB Host A staging MR 是握手路径的遗留要求，不是 82599 payload pool。
将其缩到配置允许的 4 KiB 可减少无效分配，但不会减少 payload copy。

### 2.2 `peer-dmabuf` 只完成了 MR 注册基础

XDMA `cdev_peer.c` 已把 BAR2 coherent alias 包装为 P2PDMA dma-buf；QEMU 已调用
`ibv_reg_dmabuf_mr()`，并把 guest IOVA、长度和 rkey 放入 HELLO。NVMe agent
已有 `IBV_WR_RDMA_READ/WRITE` 和 segment range validation，可复用其 verbs 模式。

IXGBE agent 当前没有保存 HELLO 中的 `peer_base/peer_length/peer_rkey`，也没有发出
单边 RDMA WR。当前代码禁止 IXGBE 选择 `peer-dmabuf`，是为了避免“MR 注册成功但
payload 仍然复制”的假直通状态。

### 2.3 当前 Host B `AF_PACKET` 不能复用 RDMA buffer

`sendto()` 和 `recvfrom()` 接口把 payload 交给 socket/SKB 路径。即使其用户 buffer
同时注册为 MR，也不能保证 82599 DMA 直接使用该地址，因此不能满足共享 DMA pool
目标。Host B packet I/O 层必须替换。

## 3. 可行性矩阵

| 项目 | 判断 | 前置条件或阻塞点 |
| --- | --- | --- |
| 新增 `packet-inline` 且不建 payload MR | 高 | 协议允许 IXGBE HELLO 不携带有效 peer MR |
| XDMA BAR2 导出 dma-buf | 已实现，条件运行 | `CONFIG_PCI_P2PDMA=y`，BAR 范围和 exporter 生命周期正确 |
| Host A RNIC 注册 FPGA dma-buf MR | 条件可行，最高风险 | provider 支持 dma-buf MR；RNIC 到 FPGA P2P distance、ACS、IOMMU 均通过 |
| Host B 对 FPGA MR 发起 READ/WRITE | 高 | agent 保存并严格校验 base/length/rkey；Host A MR 已实际注册成功 |
| DPDK hugepage pool 同时作为 verbs MR | 高，需 PoC | 82599 由 DPDK 独占，RDMA provider 能注册该 hugepage VA |
| AF_XDP UMEM 同时作为 verbs MR | 条件可行 | 目标内核和 `ixgbe` 必须在该 82599 上成功强制 `XDP_ZEROCOPY` |
| 保持现有 `AF_PACKET` 且消除 Host B copy | 不可行 | API 不提供该 buffer 的 82599 DMA ownership |
| RNIC 直接 DMA 到 82599 内部 packet SRAM | 不可行 | 82599 未向当前软件栈导出可注册的 peer memory |

当前机器信息已经在现有架构文档中记录：Host A 使用 X722/`irdma`，内核关闭
`CONFIG_PCI_P2PDMA`，所装 provider 没有 dma-buf MR 注册回调。因此在更换内核和
RNIC/provider 或验证新 provider 之前，只能完成 inline fallback 和 Host B pool
PoC，不能宣称 FPGA peer-MR 端到端成功。

## 4. 目标协议

### 4.1 Feature negotiation

不要继续让 `SCOPE_REMOTE_IXGBE_FEATURES` 同时隐含 `PEER_MR` 和
`HOST_A_STAGING`。建议拆成正交能力：

```text
IXGBE_PACKET          支持远端82599语义
IXGBE_INLINE_FRAME    支持现有完整帧SEND fallback
IXGBE_PEER_PAYLOAD    支持segment/credit和远端单边RDMA
IXGBE_SHARED_POOL     Host B packet I/O使用共享DMA pool
```

选择 `IXGBE_PEER_PAYLOAD` 时必须同时满足有效 `peer_base/peer_length/peer_rkey`；
选择 inline 时不创建 payload MR，HELLO 中对应字段必须为零。能力不匹配时启动失败，
禁止静默切回 inline 或 AF_XDP copy mode。

### 4.2 新消息

建议新增以下语义消息，而不是让 Host B 解析 guest 82599 descriptor：

```c
struct scope_remote_ixgbe_tx_submit {
    uint64_t request_id;
    uint32_t total_length;
    uint16_t segment_count;
    uint16_t flags;
    struct scope_remote_segment segments[SCOPE_REMOTE_MAX_SEGMENTS];
};

struct scope_remote_ixgbe_rx_credit {
    uint64_t token;
    uint64_t guest_pa;
    uint32_t capacity;
    uint32_t reserved;
};

struct scope_remote_ixgbe_rx_complete {
    uint64_t token;
    uint32_t length;
    uint32_t status;
};
```

`request_id` 应只放在公共 header 或 payload 中一个位置。结构示意保留该字段是为了
强调 completion 关联，正式 ABI 应去掉重复字段。

QEMU 继续负责解析和验证 guest descriptors。Host B 只能看见经过验证的 payload
segments 和 RX credit，不能直接操作 guest ring 或信任 guest 提供的任意地址。

## 5. TX 状态机

```text
QEMU sees TDT
  -> stable-read TX descriptors
  -> validate type/length/EOP/segment range
  -> reserve request and descriptor writeback list
  -> send TX_SUBMIT(segments, total_length)

Host B
  -> reserve FREE pool slot
  -> RDMA READ every segment into contiguous slot
  -> wait RDMA completion
  -> submit the same slot to 82599 TX
  -> wait NIC ownership return
  -> send TX_COMPLETE(request_id, status)

QEMU
  -> write descriptor DD
  -> raise queue-0 INTx
```

Host B 不得在 RDMA READ completion 前提交 82599 TX，也不得在 NIC completion 前
复用 slot。QEMU 不得把 RDMA control SEND completion 当作 guest TX completion。

首版继续限制 MTU 1500、单 queue、无 TSO。当前 QEMU 调用
`net_checksum_calculate()` 会读取并修改帧；peer payload 模式必须删除该调用。
首版要求 guest 关闭 TX checksum/TSO 等 offload，由 guest 栈生成完整帧；后续再把
offload metadata 映射到 DPDK TX descriptor 或经能力协商的 AF_XDP TX metadata。

## 6. RX 状态机

RX 不能只把 `guest_pa` 临时附在收到的 frame 上，因为 Host B 收包时可能尚未有可用
guest descriptor。必须预发布 credit：

```text
QEMU sees RDT
  -> read and validate newly guest-owned RX descriptors
  -> send RX_CREDIT(token, guest_pa, capacity)

Host B
  -> put FREE pool slots into NIC RX ownership
  -> 82599 DMA receives frame into slot
  -> pair frame with one RX credit; no credit means bounded drop/recycle
  -> RDMA WRITE slot payload to credit.guest_pa
  -> wait RDMA completion
  -> send RX_COMPLETE(token, length, status)

QEMU
  -> verify token is outstanding
  -> write RX descriptor length/status/DD/EOP
  -> raise queue-0 INTx
```

RDMA WRITE completion必须发生在 QEMU 写 descriptor DD 之前。这样 guest 观察到 DD
时 payload 已经可见。断链时所有未完成 credit 由 generation 失效，不能在新 session
中复用。

## 7. Host B 共享 Pool

### 7.1 Slot ownership

每个 slot 必须且只能处于以下状态之一：

```text
FREE
RDMA_TX_FILL -> NIC_TX_OWNED -> FREE
NIC_RX_OWNED -> RDMA_RX_DRAIN -> FREE
```

任何时刻都不能让 RDMA RNIC 写一个仍由 82599 TX/RX 持有的 slot。状态迁移由 CQ、
NIC completion ring 和 generation 共同驱动；控制线程不得依靠固定 sleep 推测完成。

### 7.2 大小

标准 MTU 下 slot 可先使用 2 KiB；若使用 AF_XDP，其 chunk 大小也应按实际内核接口
选择 2 KiB 或 4 KiB。容量公式是：

```text
pool_bytes = (tx_slots + rx_slots) * slot_size
```

64 个总 slot、每 slot 2 KiB 时是 128 KiB，但全双工容易互相挤占。建议首版固定
`tx_slots=64, rx_slots=64, slot_size=2048`，payload pool 约 256 KiB，另加 ring、
alignment 和 metadata。后续根据 CQ 深度和 backpressure 测量缩减，不应直接把
4 MiB 数字搬到 Host B。

### 7.3 DPDK 与 AF_XDP 选择

首选 DPDK 作为性能基线：82599 有成熟 PMD，hugepage pool ownership 和 TX/RX
completion 明确，容易证明 payload 没有 CPU copy。代价是将专用 82599 从内核
`ixgbe` 解绑到用户态驱动，agent 必须独占该 port，现有 setup/runbook 要同步修改。

AF_XDP 可作为保留内核 `ixgbe` 的方案，但启动必须显式请求 `XDP_ZEROCOPY` 并检查
结果；如果 bind 失败就终止。copy mode、generic XDP 或普通 `AF_PACKET` 结果不能
计入零拷贝验收。还必须用目标内核和目标 82599 实测 UMEM 同时注册 verbs MR、
长时间双向 DMA、reset 和关闭顺序。

## 8. 代码修改范围

### Host A QEMU

- `scope_fpga_vswitch.c`：允许 IXGBE 选择 `packet-inline` 或
  `peer-dmabuf`，移除“IXGBE 必须 host-staging”的硬编码；
- `scope_fpga_vswitch_rdma.c`：按 feature 决定是否建立 payload MR；新增 TX segment、
  RX credit/completion API；
- `scope_fpga_vswitch_ixgbe_backend.c`：TX 不再拼 `tx_frame`，改为收集已验证 segment；
  RDT 发布 RX credit；completion 后保持现有 DD/INTx 顺序；
- `scope_remote_proto.h`：新增 feature 和 versioned message；保留旧 inline opcode 用于
  明确配置的兼容模式。

### Host B agent

- `scope_remote_nic_agent.c`：保存 peer MR metadata，增加 RDMA READ/WRITE WR、slot
  状态机、credit queue、范围检查和 CQ 驱动；
- 把 `AF_PACKET` packet I/O 抽象成 backend ops；新增 DPDK backend，AF_XDP backend
  作为条件实现；
- setup 脚本增加 port ownership、hugepage/UMEM、queue 数量和 zero-copy preflight。

### XDMA 与运行环境

- 保留 `cdev_peer.c` exporter，但补齐 dma-buf revoke/move-notify 与设备移除期间的
  importer 同步审计；
- Host A preflight 必须实际执行小范围 peer-MR RDMA READ/WRITE，不能只检查设备节点；
- 检查 `CONFIG_PCI_P2PDMA`、provider dma-buf MR ops、PCIe distance、ACS 和 IOMMU。

## 9. 分阶段实施

### Phase 0：消除无效 Host A staging

- 新增 `packet-inline` 模式；
- IXGBE inline HELLO 不要求 peer MR；
- 保持现有完整帧消息路径不变；
- 验证行为与旧 `host-staging` 完全一致。

该阶段几乎确定可成功，但只减少内存，不减少 payload copy。

### Phase 1：协议和 descriptor/credit 正确性

- 实现 TX segment、RX credit、token/generation 和错误恢复；
- 用普通 host RAM MR 模拟 peer window 做单元/集成测试；
- 保留 inline fallback 做结果对照。

该阶段不依赖 FPGA P2P，可先证明状态机和 ordering。

### Phase 2：Host B 共享 DMA pool

- 先实现 DPDK backend；
- 在普通 host RAM MR 上验证 RDMA RNIC 与 82599 共用同一 slot；
- 用计数器证明 agent 没有 payload `memcpy()`，验证 pool starvation 和全双工。

### Phase 3：Host A FPGA peer MR

- 升级/更换满足条件的内核和 RNIC/provider；
- 运行 dma-buf MR 与 P2P 小范围破坏性受控测试；
- 通过后才允许 `IXGBE_PEER_PAYLOAD` feature；
- 合并 Phase 2，完成 FPGA DDR 到 82599 的端到端路径。

### Phase 4：性能和可选 AF_XDP

- 批量 post WR、CQ moderation、multi-SGE、queue 深度调优；
- 在目标 `ixgbe` 上单独验证 AF_XDP forced zero-copy，再决定是否替代 DPDK；
- 根据测量缩减 slot 数，不能牺牲 backpressure 正确性。

## 10. 验收标准

功能验收：

- guest 标准 `ixgbe` probe、link、DHCP、ARP、ICMP 和双向 TCP 正常；
- TX DD 只在 NIC completion 后写回；RX DD 只在 RDMA WRITE completion 后写回；
- 断链、agent 重启、QEMU 重启后旧 token/generation 全部失效；
- pool 满、无 RX credit、CQ error 均有有界 drop/fail，不发生越界或死锁。

零拷贝验收：

- peer 模式下 QEMU 不对 descriptor 指向的 packet payload 调用
  `scope_guest_mem_read/write()`；读取 descriptor、写 DD/length 等控制结构仍然允许；
- agent packet path 不对 payload 调用 `memcpy()`；
- AF_XDP 方案必须报告 zero-copy enabled，DPDK 方案必须确认 mbuf data 位于注册 MR；
- verbs counters、82599 counters 和协议字节计数一致；
- 使用递增字节、随机种子和边界长度 packet pattern 做端到端校验；Ethernet 首版
  单帧仍限制 2048 字节。

性能验收至少记录吞吐、P50/P99 RTT、CPU cycles/packet、PCIe/RDMA bytes、pool
high-watermark 和 drop 原因。不能只用吞吐提升推断零拷贝成立。

## 11. 主要风险与最终建议

最高风险不在 82599，而在 Host A RNIC 能否把 XDMA BAR2 dma-buf 注册为可远端访问
的 MR。当前 X722/`irdma` 环境已知不满足，必须先把它当作硬件/内核选型门槛。

Host B 建议先走 DPDK，因为它对 82599 buffer ownership 最明确；AF_XDP 只有在目标
组合强制 zero-copy 成功后才进入候选。实现顺序应是 Phase 0、Phase 1、Phase 2，
并行解决 Host A peer-MR 环境，最后在 Phase 3 合流。这样每一步都能单独验收，且
不会把协议错误、82599 queue 错误和 PCIe P2P 环境错误混在一次调试中。

## 12. 代码与接口依据

仓库代码定位：

- `qemu-mount/hw/misc/scope_fpga_vswitch.c:1093`：当前配置层强制 IXGBE
  `host-staging`；
- `qemu-mount/hw/misc/scope_fpga_vswitch_ixgbe_backend.c:430`：当前 TX descriptor
  解析、payload 读取和 completion ownership；
- `qemu-mount/hw/misc/scope_fpga_vswitch_ixgbe_backend.c:527`：当前 RX payload、DD
  writeback 和中断顺序；
- `qemu-mount/hw/misc/scope_fpga_vswitch_rdma.c:230`：host MR 与 peer dma-buf MR
  注册；
- `tools/scope_remote_agent/scope_remote_nic_agent.c:340`：当前 `AF_PACKET` TX/RX；
- `tools/scope_remote_agent/scope_remote_agent.c:232`：NVMe agent 已有可复用的单边
  RDMA READ/WRITE 和 peer range validation；
- `shell/software/xdma_drv/XDMA/linux-kernel/xdma/cdev_peer.c:50`：XDMA P2PDMA
  dma-buf attach/map/export。

外部接口约束参考：

- Linux kernel `AF_XDP` 文档：UMEM、slot ownership、`XDP_ZEROCOPY` 和 completion
  ring，<https://docs.kernel.org/networking/af_xdp.html>；
- Linux kernel PCI P2PDMA 文档：topology、dma-buf importer/exporter 和生命周期，
  <https://docs.kernel.org/driver-api/pci/p2pdma.html>；
- DPDK IXGBE PMD 文档：82599 支持范围，
  <https://doc.dpdk.org/guides/nics/ixgbe.html>。
