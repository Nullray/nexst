# RDMA 扩展外设接入架构设计

## 1. 目标、范围与结论

本文设计如何在尽量不改变当前 `nm37_vswitch` FPGA、香山 Linux 和 QEMU
设备语义层的前提下，把位于另一台主机上的真实 PCIe 外设接入香山系统。
远端 NVMe使用块设备语义传输；远端网卡使用独立的数据包语义传输。网卡首个
实现对象为Intel 82599：香山枚举`8086:10fb`并绑定`ixgbe`，Host B的真实82599
继续由主机`ixgbe`持有。

本文直接以阶段2的“端到端 CPU 零拷贝”为唯一实现目标，不实现 Host A CPU
bounce buffer。需要新增：

- Host A QEMU 中与设备类型正交的 `remote-rdma` transport；
- Host A XDMA 驱动导出的 NM37 coherent-alias `dma-buf`；
- Host A RNIC 对该 dma-buf 建立的 peer-memory MR；
- Host B 上独占目标namespace并执行mediated NVMe命令的`scope-remote-agent`；
- Host B 上由 RDMA MR 和真实设备 DMA mapping 共享的固定 staging pool；
- 后续raw-queue优化所需的`scope_remote_dma.ko`；首版使用内核NVMe块设备
  `O_DIRECT`和admin ioctl，不要求该模块；
- 有版本、generation、范围校验和失败恢复语义的 RDMA 控制协议。

payload 路径固定为：

```text
香山 DDR
  <-> NM37 BAR2 coherent alias
Host A RNIC peer-memory MR
  <-> cross-host RDMA
Host B registered and device-DMA-mapped staging
  <-> PCIe DMA
远端真实 NVMe
```

“零拷贝”在本文中准确表示 CPU 不读取、写入或复制普通 I/O payload。Host B
staging 是 NVMe 与 RNIC 共享的同一批页，并不存在第二份buffer之间的CPU copy。
SQE、PRP list、CQE和BAR属于control path，QEMU仍可通过
`scope_guest_mem_read/write()`访问这些小型控制结构。

该模式与当前同机 `local-p2p` 并存，而不是替换它。未配置 `transport` 的现有
JSON必须继续得到完全相同的行为。目标Host A/Host B均需要支持verbs的RDMA NIC，
但`ibv_devices`非空只证明verbs可用，不等价于RNIC支持XDMA dma-buf MR。

### 1.1 仓库16首版实现状态

仓库16已实现`remote-rdma`配置解析、RC连接、版本化控制协议、guest PRP segment
验证、远端NVMe语义提交、guest CQE/aggregate INTx完成，以及XDMA P2PDMA
dma-buf exporter。Host B agent使用同一批page-aligned staging页完成`O_DIRECT`
namespace I/O和RDMA READ/WRITE，因此普通payload不经过Host B CPU复制；在
`peer-dmabuf`模式下也不经过Host A QEMU。物理控制器继续由Host B内核NVMe驱动管理；直接physical queue engine保留为
后续性能优化，而不是首版正确性的前置条件。

当前Host A的`iwo3`是active Intel X722/`irdma` verbs设备，流量经`eno3`路由到
`10.30.19.15`。不过当前内核关闭`CONFIG_PCI_P2PDMA`，且所装`irdma` provider
没有dma-buf MR注册回调。因此RDMA控制面可用，但XDMA peer-memory payload直通
尚不满足启动条件。实现保留默认且fail-closed的`peer-dmabuf`正式路径，同时提供
必须显式选择的`host-staging`兼容路径，用于在X722上完成远端功能闭环；后者通过
QEMU coherent XDMA访问在Host A staging MR与香山DDR间搬运，不能作为零拷贝或
direct-P2P性能结果。

### 1.2 远端82599数据包模式

82599不使用NVMe的peer-memory payload协议，也不把远端物理BAR或DMA地址直接
映射给香山。Host A QEMU维护最小82599 PF模型，包括BAR0、queue 0描述符、链路
状态、cause/mask和legacy INTx；它通过coherent alias访问香山TX/RX ring。完整
Ethernet frame经RDMA SEND传给Host B agent，agent使用专用82599 netdev的
`AF_PACKET`接口收发。X722仅承载RDMA控制连接。

该模式的设备语义为`type=ixgbe, transport=remote-rdma`，强制使用
`host-staging`。香山内核启用`CONFIG_IXGBE=y`，配置空间只暴露128 KiB BAR0和
INTA，隐藏MSI/MSI-X。首版固定单TX queue、单RX queue，并禁用RSS、TSO、header
split和PTP。远端82599保持绑定Host B `ixgbe`，不得与SSH/RDMA接口复用。

当前82599 backend补齐了Linux 5.16 `ixgbe` probe所需的最小虚拟硬件语义：
软件/链路reset位按真实硬件行为自清零；EEC保持EEPROM present、auto-read done
和software grant语义；FWSM返回有效firmware状态；虚拟EEPROM提供合法的firmware
pointer/version和checksum；I2CCTL对bit-bang时钟/数据线返回一致的输入电平。
这些语义仅用于满足标准`ixgbe`初始化，不转发Host B物理82599的NVM、firmware
或I2C访问。修正后香山侧不再出现FWSM firmware warning和
`pre-production adapter/LOM`提示。

远端82599首次枚举还暴露了ECAM代理的读写并发问题：Linux写BAR后立即readback时，
独立AXI读写通道可能同时访问shadow BRAM，使readback观察到旧值。当前RTL在一个
ECAM事务完成前阻止另一方向握手，并在读写同时到达时优先完成写事务。该修正不
改变配置空间内容、DMA32 packet ABI或local backend语义，但QEMU与FPGA应配套使用。

TX completion采用远端确认语义。guest写TDT后，QEMU稳定读取TX descriptor和
packet buffer并发送`IXGBE_TX`；只有Host B完成`AF_PACKET`提交并返回
`IXGBE_TX_COMPLETE(request_id)`后，QEMU才写回对应TX descriptor的DD位并产生
queue 0 legacy INTx。RDMA提交成功本身不等价于guest-visible TX completion。

TDT/RDT属于packet-mediated 82599的普通doorbell，不再请求额外
`BAR_WRITE_DONE`。Linux `ixgbe`在发布descriptor前已有内存屏障，QEMU侧又对
descriptor执行稳定双读，因此BAR write response后即可把tail放入backend pending
queue，由`poll()`在ring配置和descriptor可见后推进。该修改避免了
`ip link set eth0 up`期间TDT/RDT初始化写被错误等待5 ms后产生
`BAR_DONE_INFERRED`，同时不削弱descriptor可见性检查。

默认情况下，guest-visible link状态继续严格跟随Host B真实82599 carrier。为便于
在物理网线未连接时单独验证香山Linux→标准`ixgbe`→TX descriptor→QEMU→RDMA的
发送路径，可显式设置`SCOPE_IXGBE_FORCE_LINK_UP=1`。该开关只改变香山看到的
虚拟`LINKS`状态，不改变Host B物理82599的真实carrier，正常实验不得默认启用。

相关现有设计见：

- [PROJECT_ARCHITECTURE.md](PROJECT_ARCHITECTURE.md)
- [VIRTUAL_PCIE_SWITCH_NVME_DESIGN.md](VIRTUAL_PCIE_SWITCH_NVME_DESIGN.md)
- [VSWITCH_NIC_INTEGRATION_STUDY.md](VSWITCH_NIC_INTEGRATION_STUDY.md)
- [VORTEX_NVME_GDS_DESIGN.md](VORTEX_NVME_GDS_DESIGN.md)

## 2. 当前架构与可复用边界

当前主线仍是三层结构：

```text
香山 Linux 标准驱动
  -> FPGA virtual_pcie_switch_proxy
  -> DMA32 ring / mailbox
  -> QEMU scope-fpga-vswitch
  -> NVMe / IGB / Vortex backend
```

`ScopeBackendOps` 已把设备语义拆成 `realize`、`cleanup`、BAR packet 处理和
非阻塞 `poll`。但 `ScopeBackend` 中的 `real_host_bdf`、`real_bar0_map` 和
`scope_real_bar_*()` 仍默认真实设备与 QEMU 位于同一主机。

本地 NVMe 的关键路径是：

```text
guest SQE/PRP
  -> scope_guest_mem_read()
  -> scope_translate_guest_pa_for_real_dma()
  -> NM37 BAR coherent-alias PCIe address
  -> patch guest SQE/PRP
  -> real NVMe doorbell
  -> NVMe P2P DMA XiangShan DDR
```

远端 PCIe fabric 无法路由 Host A NM37 BAR 地址，因此
`scope_translate_guest_pa_for_real_dma()` 必须明确变为 `local-p2p` 专用函数。
远端模式不能把任何 Host A PCIe bus address 写进 Host B 设备 descriptor。

以下部分可以原样保留：

- 香山 PCI host bridge、标准 `nvme`/`igb` 驱动和 guest DMA address；
- FPGA ECAM shadow、BAR route、DMA32 ring、early BAR response 和 aggregate INTx；
- QEMU 的 backend/BDF 路由、guest queue shadow、SQE 可见性检查；
- `scope_guest_mem_read/write()` 对SQE、PRP list和CQE等控制结构的受控访问；
- local-P2P 的真实 BAR、PRP/descriptor patch 和 completion 路径；
- 现有 Vortex direct-P2P 和一跳 GDS 路径。

## 3. 对附件方案的必要修正

### 3.1 正式直通路径必须导出 NM37 peer-memory MR

`scope_guest_mem_read/write()` 的实现是 XDMA bypass `mmap()` 加 `memcpy()`，不能
用于阶段2 payload。Host A 应让 NM37 XDMA PCI function 成为 P2PDMA memory
provider，把 BAR2 中映射香山 DDR coherent alias 的范围导出成 `dma-buf`，再由
支持该能力的 RNIC 调用：

```c
ibv_reg_dmabuf_mr(pd, dmabuf_offset, length, guest_ddr_base,
                  dmabuf_fd,
                  IBV_ACCESS_LOCAL_WRITE |
                  IBV_ACCESS_REMOTE_READ |
                  IBV_ACCESS_REMOTE_WRITE);
```

MR的RDMA IOVA建议设置为`guest_ddr_base`，这样QEMU验证后的guest PA可直接成为
RDMA address；RNIC内部PCIe目标仍由dma-buf attachment返回的SG决定。不能把
`/dev/xdma0_bypass`的普通MMIO mmap地址传给`ibv_reg_mr()`，因为PCI BAR不是
可以用`pin_user_pages()`注册的普通RAM。

仓库内XDMA char driver当前只有bypass mmap，没有dma-buf/P2PDMA exporter。
阶段2必须扩展该驱动，并在目标Host A上选择同时满足以下条件的RNIC：

- provider实现`ibv_reg_dmabuf_mr()`；
- RNIC与NM37 BAR2之间的PCI P2P topology允许双向事务；
- ACS/IOMMU不会把peer request阻断或错误重定向；
- importer能够映射XDMA exporter提供的P2PDMA pages。

任一条件不满足时`peer-dmabuf`直接拒绝启动，禁止静默回退。为了支持当前X722，
`host-staging`可作为显式兼容模式运行，但其额外XDMA/QEMU搬运必须在日志和实验中
单独标注。

### 3.2 PIN/UNPIN 两个 ioctl 不足以构造 PRP

`dma_map_sg()` 返回的 DMA segment 数量可能少于原始 page 数量，也不能假设整个
256 MiB pool 得到一个连续 IOVA。Agent 必须获得每段 `{dma_addr, dma_len}`，再按
NVMe controller page size 切分成 PRP1、PRP2 或 PRP list。

因此最小正确 UAPI 至少需要：

```text
PIN_POOL
GET_SG
SYNC
UNPIN_POOL
```

若坚持只用 PIN/UNPIN，则 PIN 必须接收一个受长度约束的输出数组并一次性返回
完整 SG；对 256 MiB/4 KiB 页这会产生过大的可变长 ioctl，不推荐。

### 3.3 运行期 BAR 不能同步阻塞 RX 线程

当前 FPGA MMIO 状态机同一时间只有一个等待 QEMU 的 BAR transaction，这简化了
远端实现，但不意味着 QEMU 可以在 DMA32 RX 线程中同步等待网络。推荐规则是：

- 初始化阶段的 `CAP/VS/CC/CSTS` RPC 可以同步执行，但必须有 deadline；
- guest BAR read/write 进入 per-backend pending request，由 RDMA CQ/event 驱动；
- remote completion 到达后再调用现有 `scope_write_bar_response()`；
- doorbell 不作为普通 BAR write 转发，而转换为语义化 `NVME_SUBMIT`；
- 超时返回 guest `SLVERR`，并把 backend 标为 failed，禁止永久占住 FPGA MMIO。

### 3.4 Kernel module 必须绑定设备生命周期

仅用 `pci_get_domain_bus_and_slot()` 临时取得 `struct pci_dev` 并执行
`dma_map_sg()`，无法阻止 host `nvme` 驱动并发 bind/reset/remove。可靠版本中，
`scope_remote_dma` 应通过 `driver_override` 绑定目标 function，负责：

- `pci_enable_device_mem()`、64-bit DMA mask 和 `pci_set_master()`；
- 在 fd/session 生命周期内持有目标 `pci_dev`；
- reset/remove/close 时先停 bus master，再撤销 DMA mapping 和长期 pin；
- 阻止第二个 owner 和 host `nvme` 驱动同时控制设备。

它仍不实现 NVMe opcode、queue、BAR 寄存器或 RDMA 协议；这些设备语义留在
agent。该少量生命周期职责是安全使用 Linux DMA API 的前提，不应留给任意
userspace config write。

## 4. 可行性分析

| 维度 | 判断 | 说明 |
| --- | --- | --- |
| FPGA/RTL | 可行，最小修正 | 数据面和CFG/BAR packet ABI不变；ECAM代理必须串行化配置读写，保证BAR写回后的readback不会与在途写冲突 |
| 香山 Linux | 可行，首版不改 | 继续绑定标准NVMe driver，使用普通guest PRP |
| QEMU设备模型 | 可行，改动中等 | queue shadow可复用；payload只生成RDMA segment，不执行copy |
| Host A peer MR | 条件可行、关键风险最高 | XDMA需导出P2PDMA dma-buf，RNIC需支持dma-buf MR及当前拓扑 |
| Host B真实NVMe | 可行，工作量较大 | agent必须实现最小用户态controller/queue engine |
| Host B staging mapping | 可行 | 长期pin页同时注册RDMA MR并映射到NVMe DMA domain |
| 性能 | 理论上无payload CPU copy | 仍有RDMA RTT、Host B memory落点及控制通路CPU开销 |
| 一致性 | 有现有coherent alias基础 | 仍须单独验证RNIC requester下的读写可见性和ordering |
| 故障恢复 | 可实现但不能透明重试 | 断线时physical WRITE状态可能不确定，必须reset/fail guest |
| 安全性 | 可控但需信任agent | full-DDR rkey权限大，必须认证、短生命周期和严格PRP allowlist |

### 4.1 目标服务器前提

目标Host A和Host B至少满足：

- 两端安装支持RC QP的InfiniBand或RoCE RNIC及对应verbs provider；
- Host A RNIC额外支持`ibv_reg_dmabuf_mr()`与PCI peer memory；
- Host A RNIC到NM37 BAR2的P2P distance/topology检查通过；
- XDMA能把`BAR2 + coherent alias + guest DDR`导出为RNIC可attach的dma-buf；
- Host A到Host B的RDMA route已验证；RoCE环境正确配置MTU、PFC/ECN；
- Host B目标NVMe可从host `nvme` driver安全解绑；
- Host B IOMMU/DMA API可为该device映射长期pin pages；
- `RLIMIT_MEMLOCK`覆盖Host B staging MR；
- 首版固定x86 coherent Host B、4 KiB system/NVMe page和64-bit DMA；
- 单agent独占一个真实controller，不与SPDK、VFIO或host driver共用。

部署脚本必须探测实际RNIC名称、BDF、GID/port、link layer和dma-buf MR支持，不能
硬编码开发服务器设备。`ibv_devices`为空、测试dma-buf MR注册失败或P2P距离不安全
都属于启动硬失败。

### 4.2 VFIO与Host B模块边界

VFIO已提供PCI function独占、BAR mmap、IOMMU DMA map和中断eventfd，是Host B
最终通用实现的备选。如果目标Host B的VFIO/IOMMU配置稳定，可用VFIO替代
`scope_remote_dma.ko`。这不影响Host A的XDMA dma-buf exporter；Host A peer MR
是阶段2不可省略的独立工作。

## 5. 最终分层架构

```text
                            Host A
┌──────────────────────────────────────────────────────────────┐
│ XiangShan Linux standard nvme driver                         │
│             │ guest CFG/BAR + guest PRP                      │
│ NM37 virtual_pcie_switch_proxy / XiangShan DDR               │
│             │                                                │
│             ├─ DMA32 control ABI -> QEMU                     │
│             │                                                │
│             └─ BAR2 coherent alias                           │
│                    ▲ PCIe P2P                                 │
│ Host A RDMA RNIC ──┘                                         │
│   └─ ibv_reg_dmabuf_mr(XDMA-exported peer dma-buf)           │
│                                                              │
│ QEMU scope-fpga-vswitch                                     │
│   ├─ NVMe semantics / PRP validation / virtual INTx           │
│   ├─ local-p2p transport (unchanged)                         │
│   └─ remote-rdma control; payload_cpu_bytes=0                │
└───────────────────────┬──────────────────────────────────────┘
                        │ RC QP(s)
========================│=======================================
                        │
┌───────────────────────▼──────────────────────────────────────┐
│                            Host B                            │
│ scope-remote-agent                                          │
│   ├─ allowlisted device/session owner                        │
│   ├─ BAR/config and physical NVMe SQ/CQ                      │
│   ├─ RNIC directly RDMA READ/WRITE XiangShan DDR             │
│   └─ fixed staging pool: RDMA MR + NVMe DMA SG               │
│                 │ ioctl                                      │
│ scope_remote_dma.ko                                         │
│   ├─ PCI bind/lifetime                                      │
│   ├─ pin_user_pages(FOLL_LONGTERM)                           │
│   ├─ dma_map_sgtable / sync                                  │
│   └─ opaque handle + bounded SG query                        │
│                 │ physical PRP                               │
│ Real NVMe controller                                        │
└──────────────────────────────────────────────────────────────┘
```

设备语义和传输维度保持正交：

```text
Device semantics: NVMe / IGB / IXGBE / Vortex
Transport:        local-p2p / remote-rdma
```

配置解析允许`nvme + remote-rdma`和`ixgbe + remote-rdma`，仍拒绝
`igb + remote-rdma`和`vortex + remote-rdma`。NVMe Host A payload
不经过QEMU buffer；QEMU只把验证后的guest PRP转换为
`{rdma_addr=guest_pa, length}` segment列表。Host B RNIC对这些segment直接执行
RDMA READ/WRITE。

## 6. 配置与启动模型

现有配置缺省仍为`local-p2p`：

```json
{
  "type": "nvme",
  "real-host-bdf": "0000:e1:00.0"
}
```

阶段2远端配置：

```json
{
  "type": "nvme",
  "transport": "remote-rdma",
  "remote-host": "10.30.19.15",
  "remote-service": "7471",
  "remote-device-id": "remote-nvme0",
  "rdma-device": "iwo3",
  "rdma-memory-mode": "host-staging",
  "rdma-staging-size": 4194304
}
```

Host B agent配置：

```json
{
  "listen": "10.30.19.15:7471",
  "staging-bytes": 268435456,
  "devices": [
    {
      "id": "lab-nvme0",
      "type": "nvme",
      "bdf": "0000:e1:00.0",
      "namespace": 1
    }
  ]
}
```

解析和启动规则：

- `transport`缺省`local-p2p`；
- local要求`real-host-bdf`并禁止remote/peer-memory字段；
- remote禁止`real-host-bdf`，要求host/service/device-id/RNIC；
- remote允许`type=nvme`或`type=ixgbe`；`ixgbe`只允许`host-staging`，禁止
  namespace和peer-memory字段；
- 远端`ixgbe`默认镜像Host B物理82599 link状态；仅无网线TX自测时可在启动
  QEMU前显式设置`SCOPE_IXGBE_FORCE_LINK_UP=1`，正常实验不得默认启用；
- `rdma-memory-mode`缺省`peer-dmabuf`；该模式要求peer-memory device，QEMU先从
  XDMA取得dma-buf fd，再对所选RNIC执行`ibv_reg_dmabuf_mr()`；
- `host-staging`禁止peer-memory device，注册普通Host A RAM MR，并把每个请求的
  guest segment紧凑映射到单请求staging窗口；每backend限制一个in-flight；
- `peer-dmabuf` MR范围必须严格等于配置的guest DDR窗口；`host-staging` MR范围
  等于配置的staging窗口；两者都验证RDMA地址边界；
- agent只能打开本地allowlist中的不透明device ID；
- 同一remote device ID同时只允许一个session owner；
- 任一MR、RDMA或agent能力不匹配均启动失败，不自动切换memory mode或TCP payload。

## 7. RDMA 会话与协议

### 7.1 连接和 MR 交换

使用`librdmacm + libibverbs`建立RC QP。QEMU先完成所选Host A payload MR注册，
agent先完成Host B staging的NVMe DMA map和RDMA MR注册，然后交换：

- protocol major/minor、feature bits、endianness；
- session ID、device generation和最大in-flight；
- Host A payload MR的RDMA base、length、session rkey和memory-mode feature；
- Host B slot size/count、alignment和max payload；
- remote device identity、BAR0 size、NVMe CAP/VS和controller page size；
- keepalive和各阶段timeout。

`peer-dmabuf`下QEMU发送已验证的guest PA segment；`host-staging`下QEMU将其改写
为本次请求在Host A staging MR内的紧凑segment。agent只消费HELLO给出的MR范围；
验证每段都位于peer MR范围内。禁止交换kernel pointer、`struct ibv_*`地址或PCIe
bus address。

### 7.2 控制消息

控制消息固定 little-endian，并使用定长 header：

```c
struct scope_remote_hdr {
    uint32_t magic;          /* "SRDM" */
    uint16_t major;
    uint16_t minor;
    uint16_t opcode;
    uint16_t flags;
    uint32_t payload_len;
    uint64_t session_id;
    uint64_t request_id;
    uint64_t generation;
    int32_t  status;
    uint32_t reserved;
};
```

首版 opcode：

```text
HELLO / HELLO_RSP
DEVICE_OPEN / DEVICE_OPEN_RSP
BAR_READ / BAR_READ_RSP
BAR_WRITE / BAR_WRITE_RSP
NVME_ENABLE / NVME_DISABLE
NVME_SUBMIT / NVME_COMPLETE
RESET / RESET_RSP
KEEPALIVE / ERROR / CLOSE
```

每个消息验证 magic、版本、长度、session、generation 和 request ID。未知 opcode、
非零 reserved 或越界 slot 立即使 session fail-closed。

### 7.3 Host B Slot与Host A segment状态

固定slot只存在于Host B：

```text
FREE
 -> RDMA_FILLING       (WRITE: RNIC RDMA READ XiangShan DDR)
 -> DEVICE_OWNED       (NVMe reads/writes slot)
 -> RDMA_DRAINING      (READ: RNIC RDMA WRITE XiangShan DDR)
 -> FREE

任意阶段 -> FAILED
```

Host A不分配payload slot，只为每个request保存经过范围验证的PRP segment列表。
Host B slot复用前必须满足device completion和对应RDMA WR都已退休，且
request/session/slot generation仍匹配。

### 7.4 顺序保证

NVMe WRITE必须遵守：

```text
QEMU验证guest PRP segments
 -> agent对Host A peer MR执行RDMA READ
 -> RDMA READ CQ completion
 -> Host B DMA sync for device
 -> physical SQE visible
 -> physical SQ doorbell
```

NVMe READ必须遵守：

```text
physical NVMe CQE success
 -> Host B DMA sync for RNIC
 -> agent对Host A peer MR执行RDMA WRITE
 -> RDMA WRITE CQ completion
 -> completion SEND
 -> QEMU验证request/generation
 -> guest CQE visible
 -> virtual INTx
```

QEMU不在completion前后读取payload。v1不启用`IBV_ACCESS_RELAXED_ORDERING`；
agent在发送后继控制消息前等待对应RDMA WR的本地CQ completion。若data/control
使用不同QP，必须以显式request状态建立跨QP屏障。

## 8. Host A QEMU 修改设计

### 8.1 数据结构

在 `scope_fpga_vswitch.c` 增加：

```c
typedef enum ScopeTransportKind {
    SCOPE_TRANSPORT_LOCAL_P2P = 0,
    SCOPE_TRANSPORT_REMOTE_RDMA,
} ScopeTransportKind;

typedef struct ScopeRemoteState ScopeRemoteState;

struct ScopeBackend {
    /* existing fields */
    ScopeTransportKind transport;
    ScopeRemoteState *remote;
};
```

建议新增传输接口：

```c
struct ScopePhysicalOps {
    bool (*connect)(ScopeProxyState *, ScopeBackend *, Error **);
    void (*disconnect)(ScopeProxyState *, ScopeBackend *);
    bool (*bar_submit)(ScopeProxyState *, ScopeBackend *,
                       const ScopePhysBarReq *);
    bool (*poll)(ScopeProxyState *, ScopeBackend *, int64_t now_us);
};
```

local implementation 直接包装现有 `scope_real_bar_*()`；remote implementation
只排队，不在 `bar_submit()` 内等待网络。

### 8.2 JSON 和 realization

修改 `scope_parse_backend_object()`：

- 解析 `transport/remote-host/remote-service/remote-device-id`；
- 保持严格重复字段和未知字段检查；
- 按上述 local/remote 互斥规则验证；
- `requires_real_pci` 不能再单独决定 QEMU 本机 sysfs preflight；
- local 执行现有 real PCI open/map，remote 执行 RDMA connect 和 `DEVICE_OPEN`；
- remote 返回的 PCI ID、class、BAR size、CAP/VS 用于初始化同样的虚拟 config。

### 8.3 BAR 抽象

现有调用点逐步从：

```text
scope_real_bar_read/write
scope_real_bar_read32/write32
```

迁移到：

```text
scope_phys_bar_read/write
scope_phys_bar_read32/write32
```

但 remote runtime 不能伪装成同步函数。具体分两类：

1. `realize/reset` 中允许调用带 timeout 的同步 helper；
2. `process_bar_packet` 中创建 `ScopeRemoteBarPending`，在 `poll()` 收到 response 后
   调用 `scope_write_bar_response()`。

NVMe `CAP/VS/CC/CSTS/AQA/ASQ/ACQ` 尽量由 QEMU shadow 响应。doorbell 进入远端
NVMe submit 状态机，不发送普通 `BAR_WRITE` RPC。

### 8.4 Admin queue 分离

remote 模式不执行以下 local-only 操作：

- `scope_translate_guest_pa_for_real_dma()`；
- 把 translated ASQ/ACQ 写入真实 controller；
- patch guest SQE/PRP 后写回 guest queue；
- 从 guest CQ memory 扫描由真实设备 DMA 写入的 CQE。

QEMU 只保存 guest ASQ/ACQ、depth、head/tail/phase。Agent 从自己的 staging pool
划出 physical ASQ/ACQ/IOSQ/IOCQ 并取得 device IOVA。guest Admin doorbell 到达后：

1. QEMU 用现有稳定读取检查取得 guest SQE；
2. 校验 opcode、qid/cid 和 guest buffer range；
3. 把Admin data PRP转换为peer MR segment，不读取payload；
4. 发送语义化`NVME_SUBMIT`，由agent直接RDMA READ/WRITE这些segment；
5. agent 重建 physical command，所有 queue/data pointer 使用 Host B IOVA；
6. completion 后 QEMU 将 result/status 合成 guest CQE并驱动原有 INTx。

Linux NVMe probe 不只需要普通 4 KiB READ/WRITE。v1 必须覆盖最小 Admin 集合：

- Identify Controller/Namespace/Active Namespace List；
- Set Features Number of Queues；
- Create/Delete I/O CQ 和 SQ；
- Linux probe 实际触发的 Get/Set Features 与 Get Log Page；
- controller enable/disable 和 reset。

Firmware Download/Commit、Format、Sanitize、Namespace Management 等破坏性 Admin
命令默认返回 invalid opcode，除非 agent 配置显式授权。

### 8.5 NVMe WRITE：Host B RNIC直接读取香山DDR

新增`scope_remote_nvme_submit_write()`：

1. 根据namespace LBA shift计算payload长度；
2. 解析guest PRP/PRP list，但不修改它们；
3. 把每个guest range转换为peer MR内的`{guest_pa, length}`；
4. 将segment列表和Host B slot授权放入`NVME_SUBMIT`；
5. agent为每段提交RDMA READ，目标为同一Host B slot的连续offset；
6. 所有RDMA READ完成后，agent执行DMA sync并生成physical PRP；
7. agent提交真实NVMe WRITE；
8. physical completion返回后QEMU合成guest CQE。

该路径中QEMU不得调用`scope_guest_mem_read()`读取payload，也不存在Host A
`memcpy`或Host A staging MR。

### 8.6 NVMe READ：Host B RNIC直接写入香山DDR

新增`scope_remote_nvme_submit_read()`和completion handler：

1. QEMU验证guest PRP目标并生成peer MR segment列表；
2. agent让NVMe把数据DMA到Host B slot；
3. physical CQE成功并完成DMA ownership sync；
4. agent按segment列表把slot内容直接RDMA WRITE到香山DDR；
5. 全部RDMA WRITE取得CQ completion后发送`NVME_COMPLETE`；
6. QEMU验证request/session/generation后直接写guest CQE并assert INTx。

QEMU不得把连续slot scatter到CPU buffer，也不得调用`scope_guest_mem_write()`写
payload。PRP scatter由多条RDMA WRITE SGE/WR完成。

### 8.7 非阻塞推进

`scope_nvme_backend_poll()` 需要同时推进：

- 原有 local pending SQ doorbell；
- remote RDMA CM/CQ event；
- pending BAR request；
- remote NVMe request/completion；
- keepalive、阶段 deadline 和 failure cleanup。

任何一次 poll 都必须有工作预算，不能因一个远端 backend 阻塞其他 NVMe、IGB、
Vortex backend。

### 8.8 Host A XDMA/RNIC peer-memory层

当前可扩展源码位于：

```text
shell/software/xdma_drv/XDMA/linux-kernel/xdma/
  xdma_mod.c
  xdma_mod.h
  xdma_cdev.c
  libxdma.c
```

建议新增：

```text
  cdev_peer.c
  cdev_peer.h
  xdma_peer_uapi.h
```

具体修改：

- `libxdma.c`确认bypass BAR index、BAR2长度和目标alias范围；
- `xdma_mod.h`保存P2PDMA provider、dma-buf、owner和generation；
- `xdma_cdev.c`创建`/dev/xdmaN_peer`，权限默认仅root；
- probe时用`pci_p2pdma_add_resource()`登记BAR2中目标范围；
- exporter为该范围建立P2PDMA pages/SG并实现`dma_buf_ops.attach`、
  `map_dma_buf`、`unmap_dma_buf`、`release`；
- attach时用importer `attachment->dev`校验RNIC拓扑和allowlist；
- ioctl只返回dma-buf fd、guest DDR base/size、alias offset和generation；
- FPGA reset、PCI remove、最后owner关闭前先撤销MR/attachment，再释放provider资源。

当前固定地址模型为guest DDR `[0x80000000, 0x100000000)`，coherent alias offset
为`0x100000000`，因此BAR2目标范围为
`[0x180000000, 0x200000000)`。实现必须从QEMU/XDMA配置读取并校验这些值；地址
计算使用防溢出检查，不能仅凭固定常量导出整个16 GiB BAR2。

QEMU启动时：

```text
open /dev/xdma0_peer
 -> ioctl EXPORT_DMABUF
 -> ibv_reg_dmabuf_mr(..., iova=guest_ddr_base)
 -> 小范围RDMA READ/WRITE自检
 -> 通过后才连接remote agent并发布rkey
```

dma-buf MR可用flags以RNIC provider实际支持为准；v1要求LOCAL_WRITE、
REMOTE_READ和REMOTE_WRITE，不使用REMOTE_ATOMIC或RELAXED_ORDERING。参考
[PCI Peer-to-Peer DMA Support](https://docs.kernel.org/driver-api/pci/p2pdma.html)和
[ibv_reg_dmabuf_mr](https://github.com/linux-rdma/rdma-core/blob/master/libibverbs/man/ibv_reg_mr.3)。

## 9. Host B scope-remote-agent

建议目录：

```text
tools/scope_remote_agent/
  main.c
  scope_remote_proto.h
  scope_remote_rdma.c
  scope_remote_pci.c
  scope_remote_nvme.c
  scope_remote_pool.c
  tests/
  Makefile
```

职责边界：

- `scope_remote_rdma.c`：CM、QP/CQ/MR、control SEND/RECV、RDMA payload；
- `scope_remote_pci.c`：打开已由模块绑定的 allowlisted device、BAR访问；
- `scope_remote_pool.c`：slot、SG/IOVA、generation 和 ownership；
- `scope_remote_nvme.c`：CAP/MPS/DSTRD、controller reset、physical SQ/CQ、PRP、CQ poll；
- `main.c`：配置、单 owner、signal shutdown 和有序清理。

### 9.1 启动顺序

```text
校验 agent 配置和 allowlist
 -> 确认目标未挂载/未被 host nvme 使用
 -> driver_override 绑定 scope_remote_dma
 -> 打开 /dev/scope_remote_dmaN
 -> 分配并 mlock staging pool
 -> PIN_POOL + GET_SG
 -> ibv_reg_mr 同一批 userspace pages
 -> 划分 queue/data slots
 -> reset 并初始化真实 NVMe controller
 -> 监听 RDMA connection
```

首版 physical NVMe 使用 CQ polling，不依赖 MSI/MSI-X。最终版本若需要 event-driven
中断，应优先评估 VFIO eventfd，而不是在最小模块里重新实现完整中断框架。

### 9.2 Physical NVMe engine

Agent 必须实现：

- 读取 CAP，选择支持的 MPS，计算 doorbell stride；
- 在 DMA pool 中建立 ASQ/ACQ，program AQA/ASQ/ACQ 和 CC；
- 等待 CSTS.RDY，并维护 controller generation；
- Admin CID 与 I/O CID 分配、SQ tail、CQ head/phase；
- 根据 SG/IOVA 构造 PRP1、PRP2 和 PRP list；
- 在 SQE 可见后才写 doorbell；
- 按 CQ phase polling physical completion，并把状态映射成 guest NVMe status；
- reset、timeout 或 session generation 变化时让全部未决 CID 确定失败；
- 在 slot 回到 `FREE` 前完成 device/RNIC ownership sync；
- 拒绝 agent allowlist 之外的 Admin opcode、namespace 和 LBA 范围。

首版只需实现 Linux probe 和普通 I/O 所需的最小命令集。physical command 的
PRP始终指向Host B staging SG；它不会包含Host A guest PA、NM37 BAR地址或RDMA
virtual address。

## 10. Host B `scope_remote_dma.ko` 设计

模块只提供“页面生命周期 + 目标设备DMA映射”，不承载NVMe语义。建议UAPI：

```c
struct scope_remote_pin_req {
    __u64 user_addr;
    __u64 length;
    __u32 direction;
    __u32 flags;
};

struct scope_remote_pin_rsp {
    __u64 handle;
    __u32 nents;
    __u32 generation;
};

struct scope_remote_sg_entry {
    __u64 dma_addr;
    __u64 dma_len;
};
```

ioctl为`PIN_POOL`、`GET_SG`、`SYNC_FOR_DEVICE`、`SYNC_FOR_CPU`和`UNPIN_POOL`。
`PIN_POOL`采用`pin_user_pages(FOLL_LONGTERM | FOLL_WRITE)`，建立`sg_table`后调用
`dma_map_sgtable()`；`GET_SG`分页返回DMA API合并后的segment。所有handle都绑定
owner fd和device generation，禁止跨session复用。

清理顺序固定为：

```text
停止接收新请求
 -> 等待/取消physical queue
 -> 清除PCI bus master
 -> 注销Host B RDMA MR
 -> dma_unmap_sgtable
 -> unpin_user_pages
 -> 释放staging
 -> 释放device owner
```

如果选择VFIO实现同等能力，应保留相同的agent上层接口和状态机，避免把IOMMU
细节泄漏到NVMe backend。

## 11. 82580/IGB 后续扩展

IGB远端接入复用同一个`remote-rdma` transport和Host A peer MR，但不放进首版
验收。数据路径仍必须是直接RDMA：

```text
TX: guest packet buffer -> Host A RNIC RDMA READ -> Host B staging -> 82580 DMA
RX: 82580 DMA -> Host B staging -> Host A RNIC RDMA WRITE -> guest packet buffer
```

QEMU只读取guest descriptor和写回descriptor status/虚拟中断，不经CPU读取或写入
packet payload。Agent维护physical descriptor ring，并在以下时点保持顺序：

- TX：所有RDMA READ完成后才把physical descriptor交给82580；
- RX：82580写完slot且RDMA WRITE完成后才写回guest DD/EOP状态；
- reset：停止MAC DMA，再撤销slot和peer-MR request。

与NVMe相比，IGB需要处理小包率、checksum/VLAN offload、多descriptor packet和
持续补充RX buffer，控制消息频率可能成为瓶颈。建议后续使用批量descriptor消息，
但不改变Host A无payload CPU搬运的约束。

## 12. 一致性、错误恢复与安全

### 12.1 DMA所有权与可见性

Host A侧不是普通RAM cache一致性问题，而是RNIC对NM37 BAR2 coherent alias的PCIe
访问。必须在板级验证：

- RNIC PCIe MRd能读取香山DDR最新内容；
- RNIC PCIe MWr对香山核和NM37侧随后访问可见；
- RDMA WRITE CQ completion之后再写guest CQE时，payload已经达到目标；
- 4 KiB边界、64-byte窄传输和backpressure下不丢beat；
- PCIe ACS、IOMMU和root-port路由没有把peer流量送入Host A系统RAM。

Host B侧严格使用Linux DMA API的`SYNC_FOR_DEVICE/CPU`语义。首版不得把
`IBV_ACCESS_RELAXED_ORDERING`作为性能优化开启。

### 12.2 失败语义

以下事件使session fail-closed：

- RDMA disconnect、CQ error、rkey/generation不匹配；
- Host A XDMA reset/remove或peer dma-buf失效；
- Host B NVMe timeout、fatal CSTS、PCI remove/reset；
- 不合法PRP、越界LBA、重复CID或协议长度错误；
- 任一请求超过阶段deadline。

失败时QEMU停止新doorbell、取消虚拟INTx、推进或终止未决BAR transaction，并把
controller置为需要guest reset的failed状态。不得因不确定physical WRITE状态而
自动重放命令，也不得静默改走`scope_guest_mem_read/write()`或TCP payload。

### 12.3 权限边界

Host A peer MR覆盖guest DDR，rkey权限很大。首版安全模型是受信实验网络和受信
agent，同时必须具备：

- RC连接双向认证或在受隔离管理网内使用；
- rkey只在单个session内有效，断连立即dereg MR并递增generation；
- QEMU只发布已验证PRP segment，agent再次验证base/length/溢出；
- 禁止remote atomic，禁止访问BAR2中guest DDR alias之外的范围；
- Agent设备、namespace和LBA allowlist；
- Host B真实SSD未挂载且无其他driver owner；
- 日志不打印rkey、内存内容或完整认证材料。

后续若provider支持memory window/UMR，可按request绑定更小的远端权限，但不作为
首版正确性的依赖。

## 13. 代码修改清单

| 位置 | 修改内容 |
| --- | --- |
| `qemu-mount/hw/misc/scope_fpga_vswitch.c` | 增加transport配置、physical ops抽象、remote生命周期和统一poll；保留local路径 |
| `qemu-mount/hw/misc/scope_fpga_vswitch_nvme.c` | guest queue shadow、PRP验证、remote Admin/I/O submit、CQE/INTx合成；禁止payload helper |
| `qemu-mount/hw/misc/scope_fpga_vswitch_ixgbe_backend.c` | 82599最小BAR/NVM/I2C/reset语义、单队列TX/RX、远端TX completion写回DD/INTx、TDT/RDT pending推进及无网线force-link测试开关 |
| `qemu-mount/hw/misc/scope_fpga_vswitch_rdma.c`（新增） | RDMA CM/QP/CQ、XDMA dma-buf MR注册、peer segment、request/generation和deadline状态机 |
| `qemu-mount/hw/misc/scope_remote_proto.h`（新增） | wire ABI、opcode、feature bits、固定宽度字段和版本校验 |
| `qemu-mount/hw/misc/meson.build` | 增加librdmacm/libibverbs可选依赖；未启用remote时不影响现有build |
| `shell/software/xdma_drv/XDMA/linux-kernel/xdma/libxdma.c` | 定位和校验BAR2 coherent-alias P2PDMA resource |
| `shell/software/xdma_drv/XDMA/linux-kernel/xdma/xdma_mod.[ch]` | peer exporter生命周期、owner和generation |
| `shell/software/xdma_drv/XDMA/linux-kernel/xdma/xdma_cdev.c` | 注册受控`xdmaN_peer` cdev |
| `shell/software/xdma_drv/XDMA/linux-kernel/xdma/cdev_peer.[ch]`（新增） | P2PDMA dma-buf export/attach/map/unmap UAPI |
| `tools/scope_remote_agent/`（新增） | Host B RDMA、PCI、pool和minimal NVMe engine |
| `work_farm/software/linux/drivers/misc/scope_remote_dma.c`（新增） | Host B设备独占、long-term pin和DMA SG lifecycle |
| `tools/prepare_rdma_remote.sh`（新增） | 分Host A/Host B角色探测、绑定检查、memlock和启动参数生成 |

由于当前QEMU的backend子文件是被`scope_fpga_vswitch.c`直接`#include`的，第一版
应沿用现有构建形态，减少重构风险；待remote路径稳定后再拆成独立编译单元。

代码审查中应设置明确禁区：remote NVMe payload路径不得调用
`scope_guest_mem_read()`、`scope_guest_mem_write()`、`memcpy()`，不得分配Host A
payload bounce buffer。允许这些helper处理SQE、PRP list、CQE等控制元数据。

## 14. 直接阶段2实施顺序

这里的编号是开发里程碑，不再包含“Host A CPU搬运”过渡实现；每一步都必须保持
最终数据路径方向。

### 14.1 目标服务器硬件门槛

- Host A/Host B完成RNIC link、RC ping-pong和带宽测试；
- 记录RNIC/NM37/NVMe BDF、NUMA和`lspci -tv`拓扑；
- 验证Host A RNIC provider支持dma-buf MR；
- 检查ACS/IOMMU/P2P距离，确认RNIC到NM37 BAR2可双向访问；
- 若这些门槛失败，先更换slot/server/provider，不开发CPU fallback。

### 14.2 Host A peer memory最小闭环

- 实现XDMA BAR2 alias P2PDMA dma-buf exporter；
- 用目标RNIC注册dma-buf MR；
- Host B执行64 B到1 MiB的RDMA READ/WRITE，Host A CPU不触碰payload；
- 通过香山侧校验程序和NM37 ILA确认内容、方向、地址及burst；
- 重复注册/注销、断连、XDMA reset，确认generation和资源释放。

### 14.3 Host B共享staging闭环

- 实现`scope_remote_dma.ko`或VFIO等价层；
- 同一批页同时建立RDMA MR和NVMe DMA SG；
- 验证RDMA填充后NVMe可读、NVMe写入后RNIC可RDMA发送；
- 验证不存在slot间CPU copy，完成ownership sync和异常清理。

### 14.4 最小远端NVMe

- 接通HELLO、DEVICE_OPEN、BAR初始化和controller reset；
- 支持Identify、Set Features、Create Queue等Linux probe Admin命令；
- 支持4 KiB、QD=1、PRP1普通READ/WRITE；
- QEMU完成guest CQE/INTx，payload只走RNIC↔NM37和RNIC↔Host B staging。

### 14.5 完整原型

- 支持PRP2/PRP list、64 B边缘、4 KiB到当前上限的多segment I/O；
- 提升queue depth和并发slot，加入batch control message；
- 完成disconnect、timeout、NVMe reset和XDMA reset注入；
- 性能稳定后再扩展IGB，不改变transport ABI。

## 15. 目标服务器实验计划与验收

### 15.1 部署前记录

在新服务器上分别保存以下信息，脚本应生成一份machine-readable report：

```text
Host A: NM37 BDF/BAR2、RNIC BDF/device/port/GID、NUMA、IOMMU、ACS路径
Host B: RNIC BDF/device/port/GID、NVMe BDF/namespace、NUMA、IOMMU
Network: InfiniBand/RoCE、MTU、link rate、route、PFC/ECN（RoCE）
Software: kernel、rdma-core/provider、XDMA模块、firmware版本
```

先用普通host RAM完成RC verbs基线，这只验证网络；它不是最终数据路径验收。随后
必须改用XDMA导出的peer dma-buf MR完成同样测试。

### 15.2 分层测试

1. Host A RNIC直接RDMA READ NM37 guest DDR，Host B比较内容；
2. Host B直接RDMA WRITE NM37 guest DDR，香山侧比较内容；
3. 覆盖64 B、4 KiB、64 KiB、1 MiB及DDR首尾/非法边界；
4. ILA确认请求来自RNIC requester，并命中BAR2 coherent alias；
5. Host B staging分别完成RDMA和NVMe DMA方向测试；
6. Linux NVMe枚举、Identify和4 KiB顺序READ/WRITE；
7. `fio`校验模式覆盖QD=1/4/16、read/write/randread/randwrite；
8. 注入RDMA断线、错误rkey、agent kill、NVMe reset、XDMA reset和非法PRP。

### 15.3 可观测性

每个请求至少记录：

```text
request_id/session/generation/opcode/lba/bytes
guest_segment_count/host_b_slot/physical_cid
rdma_direction/rdma_bytes/rdma_latency_us
device_latency_us/total_latency_us/status
payload_cpu_bytes=0
host_a_staging_bytes=0
```

QEMU增加remote专用计数器：`payload_guest_read_calls`、
`payload_guest_write_calls`、`payload_memcpy_bytes`，三者必须始终为0。控制元数据访问
单独统计，避免把SQE/CQE访问误报为payload copy。

### 15.4 验收标准

- 所有数据校验正确，重复运行和多request并发无残留状态；
- `rdma_bytes`等于NVMe payload bytes，Host A payload CPU计数恒为0；
- Host A没有payload staging MR，也没有TCP/socket payload消息；
- NM37 ILA观察到RNIC发起的MRd/MWr，XDMA H2C/C2H不参与payload；
- Host B slot在RNIC和NVMe之间共享，没有第二份payload buffer或CPU copy；
- guest只在RDMA和physical NVMe都完成后收到CQE/INTx；
- 非法地址、断线和reset均在deadline内失败，香山不永久卡住；
- 无新增PCIe AER、IOMMU fault、MR泄漏、pinned-page泄漏或设备owner冲突；
- local-p2p NVMe、IGB、Vortex现有回归全部继续通过。

性能报告至少对比：本地NVMe、远端普通CPU-copy基线（仅作为测量对照，不纳入
产品路径）和remote-rdma direct三者的IOPS、带宽、P50/P99延迟及Host A/Host B
CPU占用。

## 16. 首版边界与结论

首个可交付版本固定为：一个remote NVMe controller、一个namespace、4 KiB MPS、
标准PRP、有限queue depth、Host B固定staging pool、RC QP、physical CQ polling和
guest INTx。Host A对整个合法guest DDR coherent-alias建立session级peer MR；
QEMU只处理控制结构、地址验证、请求状态和guest completion。

这里的“端到端零拷贝”不是“没有CPU参与”。Host A和Host B CPU仍建立连接、解析
SQE/PRP、提交命令并处理CQE；关键约束是CPU从不搬运普通payload。实际payload为：

```text
NVMe WRITE: XiangShan DDR --Host A RNIC/RDMA--> Host B shared pages --NVMe DMA--> SSD
NVMe READ:  SSD --NVMe DMA--> Host B shared pages --RDMA/Host A RNIC--> XiangShan DDR
```

因此Host A不存在payload bounce、payload staging或QEMU `memcpy`。真正决定该方案
能否在另一台服务器落地的不是QEMU协议，而是目标RNIC能否把XDMA导出的BAR2
P2PDMA dma-buf注册成可读写MR，以及实际PCIe拓扑/ACS/IOMMU是否允许该peer
traffic。部署时应先完成14.1和14.2；通过后，其余工作可以保持现有FPGA/QEMU
架构并逐层实现。
