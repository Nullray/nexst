# RDMA 远端外设接入架构（当前实现）

## 1. 范围与验证状态

最后核对：2026-09-17，仓库 17 的 NexST 与 QEMU `nm37_vswitch` 分支。
本文描述现有代码，不把设计目标或可选路径写成已经完成的硬件验证。

本轮远端 NVMe 调试已修复初始化超时、PRP list 页内偏移等问题。用户在本次更新前
确认“现在代码可以正常工作”。QEMU 与 Host B agent 构建通过；PRP/CQ 测试
2581 个用例和物理 CQE 完成路径测试 12 个用例通过。该反馈不等于已完成长时压力、
写入校验、故障重连或带宽测量，本文不声明这些项目通过。

操作步骤见 [Remote NVMe 验证手册](RDMA_REMOTE_NVME_VALIDATION_RUNBOOK.md)。
现有 `RDMA_REMOTE_NIC_VALIDATION_RUNBOOK.md` 是 NIC packet 路径手册，不能将其
“保留 ixgbe 驱动”规则用于 raw NVMe 或 raw 82599 shadow 模式。

## 2. 模式与设备所有权

`type`、`transport`、`remote-device-mode` 和 `rdma-memory-mode` 是不同维度。
`remote-rdma` 目前仅支持 `nvme`、`ixgbe`，不支持 `igb`、`vortex`。

| 设备 / remote-device-mode | Host B agent | 目标设备所有权 | 执行路径 |
| --- | --- | --- | --- |
| NVMe `semantic`（默认） | `scope-remote-agent` | 保留 Linux nvme 驱动 | ioctl / O_DIRECT + RDMA |
| NVMe `shadow-queue` | `scope-remote-nvme-shadow-agent` | 解绑 nvme，不绑定 VFIO | 真实 SQ/CQ + RDMA |
| 82599 `packet`（默认） | `scope-remote-nic-agent` | 保留 Linux ixgbe 驱动 | AF_PACKET + RDMA SEND/RECV |
| 82599 `shadow-ring` | `scope-remote-ixgbe-shadow-agent` | 解绑功能驱动，不绑定 VFIO | 真实 TX/RX ring + RDMA SEND/RECV |

| 模式 | 允许的 memory mode | 示例配置 |
| --- | --- | --- |
| NVMe semantic / shadow-queue | `host-staging` 或 `peer-dmabuf` | `vswitch-backends-remote-nvme.json` / `vswitch-backends-remote-nvme-shadow.json` |
| 82599 packet | `host-staging` | `vswitch-backends-remote-82599.json` |
| 82599 shadow-ring | `inline` | `vswitch-backends-remote-82599-shadow.json` |

NVMe 不支持 inline；82599 不支持 peer-dmabuf。配置与 HELLO feature negotiation
共同阻止模式误接，旧 semantic agent 不能代替 shadow-queue agent。

“Host B 不绑定驱动”仅指目标 PCI function；agent 本身承担用户态设备管理职责，
RDMA RNIC 仍需要其内核驱动和 verbs provider。

## 3. 当前 NVMe 实验环境

| 项目 | Host A | Host B |
| --- | --- | --- |
| 主机 | `debian-qdma-dev` | `master15` |
| RDMA IPv4 | `10.128.157.132` | `10.30.19.15` |
| RDMA device / netdev | `iwo3` / `eno3` | `iwo3` / `eno3` |
| 本地 `0000:3b:00.0` | NM37 FPGA | Intel P4510 NVMe |
| 控制组件 | QEMU `scope-fpga-vswitch` | raw NVMe agent，service `7473` |

两台主机的 BDF 恰好相同，但设备完全不同，不能跨主机复用解绑命令。
Host B 物理盘是 PCI `8086:0a54`、subsystem `8086:4802`、class `010802`；
agent 明确校验这组身份。香山枚举出的 `8086:4802` 是虚拟 endpoint 身份，
不是 Host B 物理 PCI device ID。

agent 构建标识为 `nvme-shadow-cqe-order-v3`；QEMU 构建目录为
`qemu-mount/build-rdma-repo17-review`。当前配置如下：

```json
{
  "version": 1,
  "devices": [
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
  ]
}
```

## 4. Shadow-Queue 总体架构

```text
Host A:
  XiangShan Linux nvme driver
    -> FPGA virtual PCIe CFG/BAR + guest SQ/CQ/PRP in XiangShan DDR
    -> QEMU: guest register/queue state, PRP validation, CQE/INTx
             4 MiB host-staging MR
    -> RNIC / RC RDMA connection

Host B:
  RNIC -> scope-remote-nvme-shadow-agent
            sysfs PCI config/resource0, physical controller registers
            2 MiB hugetlbfs identity-DMA pool
              physical Admin SQ/CQ, I/O SQ/CQ, PRP list, payload
            poll physical CQE -> RDMA transfer -> NVME_COMPLETE
    -> unbound physical P4510
```

这是设备语义及 DMA 地址转换的中介，不是 PCIe 总线透明延伸。guest ASQ/ACQ 和
数据地址属于香山 DDR，物理控制器只接收 Host B DMA pool 地址。

## 5. BAR 与初始化

### 5.1 初始化流程

Host B 启动时校验设备身份、无 driver symlink、hugetlbfs 和物理连续 PFN，要求
显式 `--allow-unsafe-identity-dma`。agent 映射 BAR0、启用 PCI memory/bus master，
用临时物理 Admin queue Identify namespace，再关闭控制器等待 guest。

```text
guest AQA / ASQ / ACQ writes
  -> QEMU guest state + ordered BAR_WRITE RPC -> Host B guest shadows
guest CC.EN=1
  -> confirm old physical RDY=0 -> initialize Host B queues
  -> program physical AQA / ASQ / ACQ with Host B DMA addresses -> physical CC
guest CSTS polling
  -> asynchronous physical CSTS refresh -> guest observes RDY
Identify -> Create CQ/SQ -> I/O
```

ASQ/ACQ 的 guest 数值传到 Host B 保存，但不直接写入物理 ASQ/ACQ。
Create I/O CQ/SQ 的 PRP1 也替换为 B shadow queue bus address。物理 CQ 中断关闭，
agent 轮询物理完成，QEMU 产生 guest 中断。

### 5.2 当前寄存器语义

| 操作 | QEMU | Host B shadow agent |
| --- | --- | --- |
| CAP / VS read | 使用 DEVICE_OPEN 返回值 | 启动时读取物理能力 |
| AQA / ASQ / ACQ write | 保存 guest 队列信息，异步 BAR RPC | 保存 guest shadow；启动时用 B 地址编程物理队列 |
| CC write | guest 状态及待确认请求 | 控制物理 EN/SHN，回复携带物理 CSTS |
| CSTS read | 返回最近缓存值并触发去重异步刷新 | 读取真实 CSTS |
| INTMS / INTMC | guest mask / legacy INTx | guest mask shadow，不启用物理中断 |
| SQ tail | 逐条 NVME_SUBMIT 后发送对应 BAR doorbell | stage 命令后写物理 SQ / doorbell |
| CQ head | 更新 guest CQ head / INTx / 可用空间 | 物理 CQ head 由 agent 独立推进 |
| 其他 BAR | 普通读通常为 0；非 doorbell 写进入 RPC | 部分 shadow 或拒绝，不是无条件真实 BAR 转发 |

普通 guest BAR write response 表示本地处理/排队成功，不等待物理写完成。
CSTS read 也不是每次同步往返，可能暂时返回旧值。对应 BAR RPC 回复才说明远端
处理了控制请求；NVME_COMPLETE 才表示命令完成。因此不能将 guest BAR 延迟当成
真实远端寄存器访问或端到端 I/O 延迟。

### 5.3 有序 RPC

TX FIFO 同时维护 SEND completion 与 BAR request/reply 状态；BAR 回复被消费并
补充 receive WQE 之前，不放行后续控制消息。Host B 在同步发送回复前先 post receive，
避免单 receive buffer 下连续 BAR SEND 使 iWARP 两端互等。

QEMU 校验回复 request ID、opcode、offset、size、wstrb，维护 pending BAR 和
timeout，成功回复后为排队请求更新超时预算。CC 失败恢复已确认状态并进入 failed。
日志包括 POST、SEND_CQ、RECV_CQ、DONE、TIMEOUT。

## 6. NVMe 数据和完成路径

### 6.1 SQE / PRP

QEMU 根据 SQ tail 稳定读取 Admin SQE，I/O SQE 双读比对；计算长度、解析 PRP、
检查 guest DDR 范围、合并连续段，最多编码 64 segment。当前支持 PRP 而非 SGL；
Identify Controller 返回 guest 前清零 `sgls`。

- PRP1 可以带页内偏移，首段长度受剩余页空间限制。
- PRP2 直接指向第二个数据页时要求 controller-page 对齐。
- PRP2 指向首张 PRP list 时要求 8 字节对齐，允许页内偏移。
- list 中的数据页及后续 list 页地址要求 controller-page 对齐。
- 首 list 位于页尾、只容纳一个链指针时也能解析；不跨页读取 list。

原故障中的 `PRP1=0x8297c000`、`PRP2=0x84ea3100`、131072 字节请求是合法
small PRP list，不能因 PRP2 低 12 位非零拒绝。现在按首 list 到页尾的实际空间
解析并加入复现用例。解析失败或不稳定 SQE 有 100 微秒间隔、100 毫秒上限的重试，
提供 WAIT/READY/ERR 日志；重试不代替格式修正。

每提交一条命令即推进 SQ cursor，避免重试重发。达到 inflight 上限或 CQ 空间不足时
保留目标 tail 并延后恢复；CQ admission 计入未返回的 inflight completion，
避免 guest 暂未消费 CQ 被误判为控制器故障。

### 6.2 Host B 物理执行

2 MiB DMA pool 布局：

| 偏移 | 用途 | 预留大小 |
| --- | --- | --- |
| `0x00000` | Admin SQ | `0x10000` |
| `0x10000` | Admin CQ | `0x04000` |
| `0x14000` | I/O SQ | `0x10000` |
| `0x24000` | I/O CQ | `0x04000` |
| `0x28000` | 物理 PRP list | `0x01000` |
| `0x40000` | payload | `0x1c0000`，1792 KiB |

agent 暂存 NVME_SUBMIT；WRITE 先从 A staging RDMA READ。后续 SQ doorbell RPC
将命令复制到物理 SQ，重建指向 B payload 的 PRP，通过屏障发布命令，再写物理 tail。
物理 NVMe DMA B 内存，不访问 guest PA。

Phase-1 限定 Admin QID 0、一组 I/O SQ/CQ（QID 1）、单物理 inflight、最大队列
深度 1024、controller page size 4 KiB。Number of Queues 限制为一组；Create/Delete
CQ/SQ 在物理控制器执行，成功后更新 agent 状态。AER 立即虚拟完成为 INVALID_OPCODE，
避免占住唯一 inflight；metadata 不支持。不能描述为任意 Admin、多 namespace、
多队列的完整透明 passthrough。

### 6.3 Host-Staging

```text
WRITE:
XiangShan DDR -> QEMU copy -> A staging MR
  -> B initiated RDMA READ -> B DMA payload -> physical NVMe DMA read

READ:
physical NVMe DMA write -> B DMA payload
  -> B initiated RDMA WRITE -> A staging MR -> QEMU copy -> XiangShan DDR
```

两端各有 staging。B 的同一 payload 同时用于物理 NVMe DMA 和 RNIC 传输，
不再经过 Linux pread/pwrite；A 每个方向仍有一次 CPU payload copy。A MR 为 4 MiB，
单次传输仍受 B payload 上限限制。

### 6.4 完成顺序

```text
physical CQE phase visible
  -> barrier -> read remaining CQE fields -> validate SQID/CID
  -> READ payload RDMA WRITE completes (if applicable)
  -> NVME_COMPLETE SEND
  -> QEMU matches request ID / SQID / CID
  -> copy READ data to guest / sanitize Identify
  -> publish guest CQE -> advance tail/phase -> legacy INTx
```

先检查 phase 再读取其余字段，避免提前复制旧 CQE。物理失败 status 不伪装成成功，
RDMA payload 回传失败转换为数据传输错误完成。QEMU 发布 CQE 前先完成数据发布。
物理 CQ head 与 guest CQ head 分别推进。

## 7. 可选 Peer-Dmabuf 和旧 Semantic 路径

NVMe 两种 device mode 都有 peer-dmabuf 代码路径：XDMA 用 PCI P2PDMA 导出 BAR2
coherent alias 的 dma-buf，QEMU 调用 `ibv_reg_dmabuf_mr()`。成功时 B 直接 RDMA
香山 DDR 对应 MR，省去 A staging/copy；B payload 仍存在，物理 NVMe 仍只 DMA B
内存。

这需要 `/dev/xdmaN_peer`、正确 BAR/guest IOVA 范围、P2PDMA 拓扑及 RNIC provider
支持。普通 BAR mmap 不能代替 DMA-BUF 注册，失败不会自动 fallback。
当前实测 host-staging 不能作为 peer-dmabuf 已通过的证据。

旧 NVMe semantic 模式继续使用 `scope-remote-agent`：内核 nvme 驱动管理物理设备，
允许的 Admin 用 ioctl，READ/WRITE 用 pread/pwrite(O_DIRECT)，FLUSH 用 fsync；
guest queue 创建由模型处理，不创建 raw shadow SQ/CQ，BAR 主要由 QEMU 合成。

## 8. 82599 两种路径

QEMU 维护 guest 82599 BAR0、单 TX/RX queue、descriptor 和 legacy INTx。
本轮 NVMe BAR 代理没有为 82599 增加透明 BAR 转发；guest ring 地址不能直接写到
真实 NIC。MAC/link 和完成按所选 agent 返回。

| 路径 | packet | shadow-ring |
| --- | --- | --- |
| A payload MR | host-staging 会分配，但 frame 走控制消息 | inline 不分配独立 payload MR |
| TX | 拼帧 -> RDMA SEND -> AF_PACKET sendto | 拼帧 -> RDMA SEND -> B DMA buffer -> 物理 TX descriptor |
| TX_COMPLETE | sendto 接受完整帧，不保证物理发送完成 | 物理 TX descriptor DD 后返回 |
| RX | AF_PACKET recvfrom -> RDMA SEND -> guest buffer/descriptor | 物理 RX buffer -> RDMA SEND -> guest buffer/descriptor |
| B payload | socket / SEND/RECV buffers | 真实 ring 和 DMA buffer pool |
| 目标驱动 | ixgbe | 无功能驱动，由 agent 管理 |

inline 是帧内嵌 SEND/RECV 消息，不是零拷贝，也不是 one-sided RDMA guest packet
buffer。两种路径均非所有 BAR 原样转发；guest/physical ring 与中断分别管理。
frame 上限 2048 字节，通常 MTU 1500，单 TX/RX queue，不提供完整 TSO/RSS/MSI-X。

详见 [82599 Shadow-Ring 架构](RDMA_82599_SHADOW_RING_ARCHITECTURE.md)。

## 9. 协议与安全边界

librdmacm/libibverbs 建立 RC QP，检查实际 verbs device，HELLO 后 DEVICE_OPEN，
再进入 polling。wire 字段 little-endian，版本 `major=1, minor=2`，消息最大
4096 字节，NVMe 最多 64 segment；两份 `scope_remote_proto.h` 必须完全一致。

新增 feature bits 为 NVME_SHADOW_QUEUE、NVME_BAR_PROXY，与 STAGING 或
ZERO_COPY/PEER_MR 组合协商。inline NIC 单独协商，不要求无用的 payload MR。

raw NVMe agent 处理 HELLO、DEVICE_OPEN、NVME_SUBMIT、BAR_READ/WRITE、RESET、
KEEPALIVE、CLOSE。NVME_ENABLE/DISABLE 虽有 opcode 定义，但启停路径实际使用 CC
BAR RPC。不同 agent 不一定实现同样的 opcode。

保护包括 session/generation/request ID、消息长度、MR 和 guest PRP 范围、
segment 总长度、pending 请求及回复检查。不能把 semantic agent 的 LBA/opcode
校验全部归于 raw agent。

限制与风险：

- 协议无应用层认证/加密，限定可信隔离实验网络。
- raw 模式依赖显式允许的 identity-DMA；没有 VFIO/IOMMU DMA 隔离，不适合不可信 guest。
- pagemap 物理地址不能在任意 IOMMU 配置下直接用作设备 DMA 地址。
- 解绑前确认盘未挂载、无 swap/LVM/其他使用者；未知数据盘禁止破坏性测试。
- 物理 CAP/Identify 能力未全部收敛为完整代理能力模型，枚举成功不等于支持所有命令。
- 未实现自动重连、不确定 WRITE 恢复、多 session 仲裁及透明 failed-state 恢复。

## 10. 生命周期

按 agent -> QEMU -> 香山顺序启动。agent 只服务一个连接，退出后需要重启。
功能驱动所有权按第 2 节区分，不能让内核与 raw agent 同时管理目标 function。

CC.EN 从 1 变 0 时 agent 发起物理关闭，立即停用软件 pending/queue，但不立即清空
可能仍被 DMA 使用的队列。下一次 start 确认 RDY=0 后才重建队列。enable 后不在 BAR
handler 内等待新 RDY=1，由 guest CSTS polling 观察。

PRP 失败、RPC 超时、CQ 错误或错误回复可使 QEMU backend failed，并暴露 CSTS.CFS。
此时按 runbook 停止两端并恢复，不声称支持透明在线恢复。FPGA 重烧/XDMA 重载前
也必须先停止 I/O 和 QEMU，避免失效 BAR/MR 映射。

## 11. 代码与验证入口

| 文件 | 职责 |
| --- | --- |
| `qemu-mount/hw/misc/scope_fpga_vswitch.c` | 配置、guest memory、PRP、目标 SQ tail、CQ admission、BAR pending、completion/INTx |
| `qemu-mount/hw/misc/scope_fpga_vswitch_nvme_backend.c` | BAR packet/RPC 桥接，区分 SQ/CQ doorbell |
| `qemu-mount/hw/misc/scope_fpga_vswitch_rdma.c` | RC/MR、feature 协商、FIFO、有序 BAR RPC、CQ polling |
| `qemu-mount/hw/misc/scope_fpga_vswitch_ixgbe_backend.c` | guest NIC 模型及 frame 收发 |
| `qemu-mount/include/hw/misc/scope_remote_proto.h` | QEMU wire ABI |
| `tools/scope_remote_agent/scope_remote_proto.h` | agent wire ABI |
| `tools/scope_remote_agent/scope_remote_nvme_shadow_agent.c` | raw P4510、SQ/CQ、DMA pool、物理 PRP、RDMA completion |
| `tools/scope_remote_agent/scope_remote_agent.c` | 兼容 semantic NVMe agent |
| `tools/scope_remote_agent/scope_remote_nic_agent.c` | AF_PACKET NIC agent |
| `tools/scope_remote_agent/scope_remote_ixgbe_shadow_agent.c` | raw 82599 shadow ring agent |
| `shell/software/xdma_drv/XDMA/linux-kernel/xdma/cdev_peer.c` | 可选 P2PDMA dma-buf exporter |

在 NexST 根目录执行：

```sh
cmp tools/scope_remote_agent/scope_remote_proto.h \
    qemu-mount/include/hw/misc/scope_remote_proto.h
bash qemu-mount/tests/unit/run-scope-remote-nvme.sh
bash tools/scope_remote_agent/tests/run-nvme-completion.sh
make -C tools/scope_remote_agent scope-remote-nvme-shadow-agent
ninja -C qemu-mount/build-rdma-repo17-review qemu-system-x86_64
```

测试直接编译生产函数，默认 ASan/UBSan，模拟 guest memory 和 DMA/RDMA，不替代实际
FPGA coherence、网络、INTx 或存储介质测试。临时恢复旧 PRP 页对齐条件会使原日志
用例失败，恢复旧 CQE 预读取顺序会使 DMA 可见性用例失败。

实机按 runbook 验证枚举、Identify、队列初始化、小范围 READ，再重复原始只读
`dd if=/dev/nvme0n1 of=/dev/null bs=1M count=256 iflag=direct`。数据正确性需对同一
未变更 LBA 比较哈希；性能另记 fio 配置、块大小、队列深度、CPU 占用、staging 模式和
实际带宽。局部 BAR 响应、单个 SEND 完成或单次 READ 成功不能代替完整性能/可靠性结论。
