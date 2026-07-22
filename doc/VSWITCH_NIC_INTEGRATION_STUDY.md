# vSwitch 接入 Intel 82580 网卡的可行性与技术路线调查

## 1. 调查目标

本文分析如何把 x86 主机上的真实 Intel 82580 网卡接入仓库 14 的虚拟 PCIe switch，使香山 Linux 看到并使用一个标准 Ethernet controller，同时尽量复用当前 NVMe proxy 已验证的机制：

```text
QEMU 维护 ECAM shadow
FPGA 拦截 guest BAR MMIO
FPGA 通过 DMA32 C2H packet 通知 QEMU
QEMU 访问真实设备 BAR
coherent alias 映射香山 DDR
共享 level INTx 注入香山
```

重点回答两个问题：

1. 监测并转发 `TDT` 是否足以让真实网卡工作。
2. 若不足，TX、RX、描述符 DMA、配置空间和中断分别需要怎样代理。

本调查以本机 `87:00.0` 为第一阶段目标：

```text
87:00.0 Intel 82580 Gigabit Network Connection [8086:150e]
BAR0: 512 KiB memory register window
BAR3: 16 KiB memory window
host driver: igb
```

本机 `87:00.0` 至 `87:00.3` 是一张四口卡的四个 PCI function。第一阶段只代理一个 function，且必须由 QEMU 独占。

## 2. 结论

### 2.1 总体可行

当前框架可以接入真实 82580，但不能把它当作“多转发几个 BAR 寄存器”来实现。网卡和 NVMe 的共同点是：guest 先在内存中准备设备可读的数据结构，再通过 MMIO doorbell 把所有权交给设备。因此可以复用：

- ECAM shadow 和虚拟 BDF 拓扑。
- FPGA BAR read/write 拦截和 response mailbox。
- `BAR_WRITE_DONE` 对 guest MMIO B 通道完成的确认。
- coherent alias 对香山 DDR 的一致性访问路径。
- QEMU 中“稳定读取、修改 DMA 地址、写回、最后转发 doorbell”的顺序。
- 多 backend 路由和 aggregate INTx。

仓库14的单queue mediated backend已经完成上板验证：香山标准`igb`驱动能够绑定，物理link与carrier正常，DHCP请求/响应、租约安装和双向ping均已通过。这证明BAR代理、TX/RX descriptor地址翻译、真实82580 DMA和aggregate INTx能够组成可工作的基础网络数据面。

### 2.2 只监测 TDT 不够

`TDT[n]` 确实是 TX queue 的提交门铃。Linux 更新 `TDT` 后，82580 会获取 `TDH..TDT` 范围内的新 TX descriptor。但是 descriptor ring base 和 descriptor 内部的 `buffer_addr` 都由 guest DMA API 产生，初始值是香山 guest PA。真实主机网卡不能直接使用这些地址。

RX 还存在对称问题：Linux 把接收 buffer 地址写入 RX descriptor，再更新 `RDT[n]` 交给硬件。若不翻译 RX descriptor 内的地址，真实网卡收到报文时会向错误地址 DMA write。

所以最小完整代理必须同时处理：

```text
TX: TDBAL/TDBAH + TDT + TX descriptor buffer_addr
RX: RDBAL/RDBAH + RDT + RX descriptor pkt_addr/header_addr
可选: TDWBAL/TDWBAH head write-back address
```

### 2.3 推荐路线

推荐实现一个 **real 82580 mediated backend**：guest 继续加载标准 `igb` 驱动，真实 82580 负责 MAC/PHY、报文收发和数据 DMA；QEMU 只代理寄存器语义、翻译 descriptor 中的 DMA 地址、管理中断并约束危险操作。

第一阶段限定为：

- 一个真实 82580 function 对应一个香山 endpoint。
- 单 TX queue、单 RX queue。
- 只暴露 BAR0。
- 禁用 MSI/MSI-X，只使用现有 aggregate INTx。
- RSS固定为单队列，PTP/timestamp暂时关闭；checksum/TSO descriptor格式保持不变，避免guest驱动仍启用offload时把大包错误地当作普通帧提交。

这个范围可以先验证 ARP、ping 和单流吞吐，再逐步恢复多队列和 offload。

## 3. 已验证的设备工作方式

### 3.1 Linux igb 的 TX 初始化

仓库内 Linux `igb_configure_tx_ring()` 执行以下操作：

```text
TDLEN  <- descriptor ring bytes
TDBAL/H <- ring->dma
TDH    <- 0
TDT    <- 0
TXDCTL <- queue enable
```

发送时，`igb_tx_map()` 使用 DMA API 映射 skb 和 fragments，并把返回的 DMA 地址写入 advanced TX descriptor 的 `buffer_addr`。描述符准备完成后，驱动执行内存屏障并更新 `TDT`。

Intel 数据手册定义 `TDT[n]` 为 TX descriptor tail：软件通过它添加 ready descriptor，硬件处理 head 与 tail 之间的描述符。QEMU 自带的 `igb` 模型也是在 `igb_set_tdt()` 中调用 `igb_start_xmit()`，随后通过 `pci_dma_read()` 获取 descriptor 和 packet buffer。

这验证了“拦截 TDT 作为 TX 提交点”的判断，但也证明 TDT 只是提交点，不包含 packet buffer 地址翻译信息。

### 3.2 Linux igb 的 RX 初始化

`igb_configure_rx_ring()` 配置：

```text
RDBAL/H <- RX descriptor ring DMA address
RDLEN   <- descriptor ring bytes
RDH     <- 0
RDT     <- 0
RXDCTL  <- queue enable
```

`igb_alloc_rx_buffers()` 为 page 建立 DMA mapping，把 `bi->dma + page_offset` 写入 RX descriptor 的 `pkt_addr`，执行 `dma_wmb()` 后更新 `RDT`。

Intel 数据手册也明确规定：软件写 `RDT` 把新的 receive descriptor 加入硬件 free list。真实网卡接收报文后会：

1. DMA read RX descriptor。
2. DMA write packet data 到 descriptor 指定的 buffer。
3. DMA write descriptor 的 length/status/error/DD 等完成字段。

因此 RX 不能靠 TDT 路径顺带解决，必须独立代理 RDT 和 RX descriptor。

### 3.3 中断不是单纯转发一根线

82580 支持 MSI-X，并有 ICR/EICR、IMS/IMC、EIMS/EIMC 等 cause/mask 语义。ICR 包含 read-clear/W1C 行为。Linux `igb` 的中断处理会读取这些寄存器判断 RX、TX、link change 和错误原因。

当前系统没有把真实网卡的 PCIe MSI/MSI-X 直接路由到香山，所以 QEMU 必须构造 guest 可见的中断状态：

```text
真实完成/链路事件
  -> QEMU 发现 cause
  -> 更新 virtual ICR/EICR shadow
  -> 根据 virtual IMS/EIMS 判断是否 pending
  -> aggregate INTx assert
guest 读取 ICR/EICR 或完成 NAPI
  -> 按寄存器语义清 cause
  -> 无 pending cause 时 aggregate INTx deassert
```

RX 报文是外部异步事件，不会先产生 guest MMIO write。因此除了处理 TDT/RDT，系统还必须有真实完成的观测源，例如 host IRQ/eventfd 或低开销轮询。

## 4. 与现有 NVMe 机制的对应关系

| NVMe 当前机制 | 82580 对应机制 | 可否直接复用 |
|---|---|---|
| SQ doorbell | `TDT[n]` | 可复用 BAR write + done 状态机 |
| SQE | TX descriptor | 可复用 coherent alias 稳定读和地址 patch 框架 |
| PRP/PRP list | descriptor `buffer_addr` | 翻译目标类似，格式不同 |
| CQE | TX/RX descriptor write-back | 可复用完成扫描思路 |
| Admin/IO queue base | `TDBAL/H`, `RDBAL/H` | 需要新的 queue register shadow |
| CQ interrupt | ICR/EICR cause | aggregate INTx 可复用，cause model 需新增 |
| controller CC/reset | CTRL/RCTL/TCTL/queue enable | 需要设备专用生命周期状态机 |

最大的区别是：NVMe 的一个命令通常通过 PRP 指向数据页，而网卡每个 descriptor 都直接携带 packet buffer DMA 地址；RX 又由物理链路异步驱动。因此 NIC backend 的 descriptor 和中断逻辑会比当前 NVMe backend 更活跃。

## 5. 推荐架构：真实 82580 媒介化后端

### 5.1 软件分层

不建议继续把所有逻辑加入 `scope_fpga_vswitch_nvme.c`。应先把 vSwitch manager 和设备 backend 分离：

```text
scope_fpga_vswitch.c
  ECAM shadow、DMA32 ring、FPGA mailbox、route table、aggregate INTx

scope_fpga_vswitch_nvme_backend.c
  当前 NVMe BAR、queue、PRP、CQ 逻辑

scope_fpga_vswitch_igb_backend.c
  82580 BAR、TX/RX ring、descriptor、cause/mask、reset/link 逻辑
```

backend 公共接口可定义为：

```text
realize / unrealize
config_write
bar_read / bar_write
poll_completion
reset
has_pending_interrupt
```

JSON 配置增加设备类型，例如：

```json
{
  "version": 1,
  "devices": [
    { "type": "nvme", "real-host-bdf": "0000:af:00.0" },
    { "type": "igb",  "real-host-bdf": "0000:87:00.0" }
  ]
}
```

硬件 route `backend_id` 仍只标识 endpoint；QEMU 根据 backend type 调用对应处理函数。

### 5.2 TX 数据路径

推荐顺序如下：

```text
1. guest igb 把 packet buffer guest PA 写入 TX descriptors。
2. guest 写 TDT[n]。
3. FPGA 拦截 BAR_WRITE，QEMU early response 并请求 BAR_WRITE_DONE。
4. guest AXI B handshake 后 FPGA 发 BAR_WRITE_DONE。
5. QEMU 从 old_tail 到 new_tail，通过 coherent alias 稳定读取 descriptors。
6. 对 data descriptor 的 buffer_addr 执行 guest PA -> real coherent alias DMA 翻译。
7. context descriptor 不按 data descriptor 误改；保留 TSO/checksum上下文格式。
8. QEMU 把 patched descriptors 写回 coherent alias，并做 readback fence。
9. QEMU 最后把 new_tail 写到真实 82580 TDT[n]。
10. 真实 82580 DMA read descriptor 和 packet data，发送报文并写回 DD/status。
11. QEMU 观察完成并生成 guest 可见 TX cause/INTx。
```

关键不变量是：**在 descriptor 地址全部翻译完成以前，绝不能把新的 TDT 转发给真实网卡。** 数据手册说明硬件不会获取 tail 之后的 descriptor，这正好给 QEMU 提供安全 patch 窗口。

### 5.3 RX 数据路径

推荐顺序如下：

```text
1. guest igb 把 receive page guest PA 写入 RX descriptors。
2. guest 写 RDT[n] 交付 descriptors。
3. FPGA/QEMU等待 BAR_WRITE_DONE。
4. QEMU读取 old_tail 到 new_tail 的 RX descriptors。
5. 根据 `SRRCTL.DESCTYPE` 解析 descriptor。`ADV_ONEBUF` 只翻译
   `pkt_addr`；`HDR_SPLIT/HDR_SPLIT_ALWAYS` 还要翻译非零
   `hdr_addr`。
6. QEMU写回 patched descriptors并做readback。
7. QEMU最后写真实 82580 RDT[n]。
8. 真实网卡收到帧后，通过 coherent alias DMA write packet和descriptor status。
9. QEMU通过真实IRQ或descriptor轮询发现 DD，设置virtual RX cause并拉高INTx。
10. guest igb读取descriptor和packet，随后补充buffer并再次写RDT。
```

RX descriptor write-back 会复用 descriptor 空间。特别是在 Linux 当前使用的
`ADV_ONEBUF` 模式中，refill 只重新写第一个 qword 的 `pkt_addr`；第二个 qword
可能继续保留上一轮 write-back 的 `status_error/length/VLAN`。因此 QEMU 不能
把任意非零第二个 qword 当成 `hdr_addr`，也不能假设完成后的 descriptor 仍保存
原始 address；需要依靠 `SRRCTL.DESCTYPE` 和自身 queue shadow 判断字段所有权。

### 5.4 Ring base 与其他 DMA 地址寄存器

guest 写入的 `TDBAL/H` 和 `RDBAL/H` 也是香山 guest PA。QEMU 应保存两套值：

```text
guest_ring_base: 用于从 coherent alias 定位 guest descriptor ring
real_ring_base:  guest_ring_base 翻译后的真实 82580 DMA 地址
```

向真实 BAR 转发时写 `real_ring_base`，向 guest 读回时返回 `guest_ring_base`，避免 Linux 看到被翻译后的主机地址。

若 guest 启用 TX head write-back，还必须翻译 `TDWBAL/H`。第一阶段可在虚拟能力和寄存器行为中禁用该功能，减少一个异步 DMA 地址入口。

### 5.5 BAR 寄存器分类

不应对所有 BAR write 采用同一种“直接写真实设备”策略。建议建立明确分类：

| 类别 | 例子 | 处理方式 |
|---|---|---|
| DMA address | TDBAL/H、RDBAL/H、TDWBAL/H | guest shadow + 地址翻译后写真实 BAR |
| Doorbell/tail | TDT、RDT | 等 BAR_WRITE_DONE 和 descriptor patch 后再转发 |
| Interrupt cause/mask | ICR/EICR、IMS/IMC、EIMS/EIMC | virtual shadow，按 RC/W1C/set/clear 语义维护 |
| Device control | CTRL、CTRL_EXT、RCTL、TCTL | 受控转发；reset/enable 进入生命周期状态机 |
| Link/PHY/NVM | STATUS、MDIC、EERD、RAL/RAH | 初期可独占直通读取，副作用写入需要白名单 |
| Statistics | GPRC/GPTC 等 | 可读真实值，但需注意 clear-on-read 和跨次测试状态 |

QEMU 自带 `igb_core.c` 已实现大量 register mask、self-clear、RC/W1C、descriptor 和 interrupt 语义，可作为语义参考；但它的 DMA 面向 QEMU `AddressSpace`，报文面向 QEMU net backend，不能原样替换成“真实 82580 BAR passthrough”。适合复用定义和状态机思路，不适合直接调用整个 core。

### 5.6 中断实现选择

#### 方案 A：轮询 descriptor/真实 cause，第一阶段推荐

QEMU 周期性检查：

- TX descriptor DD/write-back。
- RX descriptor DD。
- 必要时读取真实 ICR/EICR 获取 link/error cause。

优点是无需新增 host 内核驱动接口；缺点是空闲轮询开销和中断延迟较大，而且读取真实 ICR 可能清 cause，必须立即转存到 virtual shadow。

#### 方案 B：VFIO eventfd，长期推荐

把真实 NIC function 绑定 `vfio-pci`，通过 VFIO device fd 映射 BAR，并为真实 MSI/MSI-X/INTx 注册 eventfd。QEMU 收到 eventfd 后读取/保存 cause，再驱动香山 virtual INTx。

VFIO 提供设备所有权和中断通知，但不能自动解决本项目的 DMA 地址问题。真实 NIC 要访问 FPGA coherent alias 地址，仍需处理 IOMMU/peer DMA 映射和 descriptor 地址翻译。

#### 方案 C：直接复用 host igb 中断，不推荐

让 host `igb` 继续绑定同时由 QEMU 写 BAR，会产生两个控制平面竞争 ring、interrupt mask、reset 和 PHY，不具备正确性。真实 function 必须只属于一个 owner。

## 6. FPGA 侧需要的修改

### 6.1 可以保留的部分

`virtual_pcie_switch_proxy.v` 已经具备：

- 多 BDF ECAM shadow。
- BAR MMIO request/response。
- packet 中的 BDF、backend ID、offset、size、WSTRB。
- `BAR_WRITE_DONE`。
- route collision 诊断。
- aggregate INTx output。

这些逻辑不依赖 NVMe 寄存器格式，原则上可以服务 NIC。

### 6.2 当前限制

当前 route table 是 13 项、每个 backend 一项，事实上对应每个 endpoint 的一个 BAR window。generic manager 已使用 `ScopeBackend`/`ScopeBackendOps`，RTL 上限也已改名为 `MAX_BACKENDS`。第一阶段仍有以下边界：

1. 第一阶段保留“每 backend 一条 BAR0 route”；后续支持BAR3时再把route entry与endpoint数量解耦。
2. route entry 增加 BAR index，并使 packet flags 返回匹配的 BAR number。
3. route entry 数量与 endpoint 数量解耦，例如 32 个 route 支持 13 endpoint 的多 BAR。
4. queue 0 寄存器必须按 Linux `igb` 使用的低地址 alias 代理：RX 位于 `0x028xx`，TX 位于 `0x038xx`。QEMU `igb_regs.h` 同时定义了 `0x0c0xx/0x0e0xx` 主地址，不能用后者匹配 guest 的 queue-0 MMIO。

本仓库 Linux `igb_probe()` 当前只 `pci_iomap(pdev, 0, 0)`，因此第一阶段可以只暴露 512 KiB BAR0，暂时隐藏 16 KiB BAR3。这样可在不改 route ABI 的情况下先完成单 NIC 原型；正式通用框架仍应支持多 BAR。

Intel 82580 数据手册进一步说明了这两个 memory region 的职责：

```text
BAR0, 512 KiB: Memory CSR + optional FLASH window
BAR3,  16 KiB: MSI-X table + Pending Bit Array (PBA)
```

因此 BAR3 是否必需，取决于虚拟 endpoint 暴露的中断能力，而不是取决于 TX/RX 数据寄存器：

- 第一阶段若从虚拟配置空间中移除 MSI/MSI-X capability，让 guest `igb` 只使用现有 aggregate INTx，则 BAR3 应同时隐藏，可以只实现 BAR0。
- 如果虚拟配置空间保留 MSI-X capability，并且 capability 的 BIR 指向 BAR3，那么 BAR3 必须完成 BAR sizing、地址分配、MMIO route、table/PBA 语义和 vector 状态维护；缺少任一部分都可能使 `igb` 选择 MSI-X 后无法收到中断。
- BAR3 不应简单写穿到真实 MSI-X table。guest 写入的是面向虚拟拓扑的 message address/data，真实 host NIC 的 interrupt target 不等于香山。长期实现应由 QEMU 保存 virtual MSI-X table，并把真实 VFIO/eventfd vector 映射到香山侧虚拟 vector 或 aggregate interrupt。

Expansion ROM 是另一个可选窗口，主要用于 PXE/boot ROM，不属于正常 Linux 网络收发必需路径，第一阶段应在虚拟配置空间中禁用。

### 6.3 无需恢复 SQE monitor

NIC descriptor 与 NVMe SQE 一样可以通过 coherent alias 读取。TDT/RDT 的 `BAR_WRITE_DONE` 加上两次稳定读，可以建立：

```text
guest descriptor write visible
  -> QEMU patch
  -> real tail write
```

因此不需要为 NIC 新建类似 `sqe_write_done_monitor` 的 AW/B 监视器。若稳定读失败，应保持 tail pending 并重试，不能提前把真实 TDT/RDT 写出去。

## 7. 配置空间与设备发现

QEMU 为 NIC endpoint 建立独立的 PCI config template：

```text
Vendor/Device: 8086:150e
Class:         020000 Ethernet controller
Header:        Type 0
BAR0:          512 KiB memory BAR
Interrupt Pin: INTA
MSI/MSI-X:     第一阶段隐藏
```

配置空间继续由 QEMU 权威维护并同步 ECAM shadow。不能直接复制真实 function 的全部 config space，因为真实 capability 中的 MSI-X table、PCIe link、AER 和 power-management 状态未必能在虚拟拓扑中正确兑现。

BAR sizing、Command.MEM、Command.BME 和 PM state 仍由 QEMU mask/W1C 规则处理。只有 guest MEM enable 且 route 完整提交后，FPGA 才允许 MMIO hit。

## 8. 真实设备生命周期与隔离

启动前必须将目标 function 从 host `igb` unbind。建议第一阶段使用独立网口，并保证它不承担主机 SSH、管理网或存储网络。

82580 是多 function、多端口控制器，部分 reset、NVM、PHY 和全局资源可能跨 function 产生影响。因此：

- 禁止在未审计前直接转发所有 global/device reset bit。
- 记录并恢复原 PCI Command 和关键控制寄存器。
- 退出时先停 RX/TX queue，等待 DMA quiesce，再解除 BAR/DMA 映射。
- 若同卡其他 function 仍由 host 使用，必须单独验证 reset scope；初期最稳妥的是整张卡四个 function 全部从 host driver 解绑。

82580 支持 VMDq，但 Intel 数据手册明确说明该型号移除了 SR-IOV/VF 配置空间。因此不能像支持 SR-IOV 的 I350/82576 那样直接创建 VF 作为多个独立真实 endpoint。VMDq 可用于后续把流量分配到 queue pool，但不会自动生成可直通的 PCI function。

## 9. 可选技术路线比较

| 路线 | guest 驱动 | 数据面 | 优点 | 主要代价 | 建议 |
|---|---|---|---|---|---|
| 真实 82580 mediated backend | 标准 igb | 真实 NIC DMA 到 coherent alias | 保真度高，保持真实 MAC/PHY/P2P DMA | descriptor、interrupt、reset 代理复杂 | 推荐主线 |
| QEMU igb + TAP/AF_XDP | 标准 igb | QEMU 软件收发并拷贝 | 可复用成熟 QEMU igb 模型，最快 bring-up | 不是主机外设直接 P2P，性能含软件栈 | 推荐作为对照/早期验证 |
| virtio-net backend | virtio_net | virtqueue + host net backend | 软件路径成熟、协议简单 | 不再验证真实 igb 驱动和真实寄存器 | 只适合功能基线 |
| VFIO + eventfd + mediated DMA | 标准 igb | 真实 NIC DMA | 中断和设备 ownership 更规范 | IOMMU/P2P 映射仍需解决 | 长期增强 |
| SR-IOV VF passthrough | VF 驱动 | 硬件 VF DMA | 隔离和多实例天然 | 82580 不支持 SR-IOV | 换 I350/82576 后考虑 |
| 全 RTL 网卡模型 | 自定义/igb | FPGA 模拟 MAC 寄存器 | QEMU 依赖小 | 工作量极大，重复成熟模型 | 不推荐 |

## 10. 分阶段实施计划

### Phase 0：只完成枚举和 BAR 基础访问

- 新增 `igb` backend type 和 endpoint config template。
- 只暴露 BAR0，隐藏 MSI/MSI-X。
- 独占 mmap 真实 82580 BAR0。
- 受控转发 STATUS、MDIC、NVM、MAC address 等 probe 读取。
- 让香山 `lspci -vv` 正确识别 8086:150e，并观察 `igb` probe 到哪一步。

验收：驱动完成 probe 或至少明确停在 queue/interrupt 初始化，而不是 ECAM/BAR routing。

### Phase 1：单队列 TX

- shadow TDBAL/H、TDLEN、TDH、TDT、TXDCTL。
- 翻译 ring base 和 advanced TX data descriptor buffer address。
- TDT 使用 `BAR_WRITE_DONE -> stable read -> patch -> readback -> real TDT`。
- 轮询 TX DD，建立 virtual TXDW cause 和 INTx。
- RSS固定为单队列；TX路径必须正确区分context/data descriptor并保持checksum/TSO上下文。若后续需要严格禁用offload，应通过专用subsystem ID配合guest `igb` feature quirk实现，不能只在QEMU中清descriptor位。

验收：香山发出的 ARP request 能从真实网口抓到，TX descriptor 正常回收。

### Phase 2：单队列 RX

- shadow RDBAL/H、RDLEN、RDH、RDT、RXDCTL、SRRCTL。
- 按 `SRRCTL.DESCTYPE` 翻译 RX descriptor：`ADV_ONEBUF` 只翻译
  `pkt_addr`；仅 `HDR_SPLIT/HDR_SPLIT_ALWAYS` 翻译非零 `hdr_addr`。
- 轮询 RX DD 或接入 VFIO eventfd。
- 建立 virtual RX cause、ICR read-clear 和 INTx deassert。

验收：香山收到 ARP reply，`ping` 双向工作，RX buffer 内容与抓包一致。

### Phase 3：稳定性和完整生命周期

- reset、link change、MDIC/NVM、promiscuous/filter 行为。
- 多 backend aggregate INTx 正确性。
- timeout、device removal、QEMU退出时 DMA quiesce。
- 长时间 ping、iperf、接口 up/down 和重复启动。

### Phase 4：性能特性

- 多 TX/RX queue。
- 多队列RSS、VLAN、jumbo frame和更完整的offload验收。
- MSI-X 虚拟化或真实 eventfd 到虚拟 vector 的映射。
- route table 多 BAR 化和 PTP/flash BAR 支持。

## 11. 关键风险与检查点

### 11.1 Descriptor 类型不能误判

advanced TX ring 中既有 context descriptor，也有 data descriptor。地址翻译必须先解析 descriptor type；把 context dword 当成 `buffer_addr` 修改会直接破坏 TSO/checksum状态。

advanced RX descriptor 同样必须按 `SRRCTL.DESCTYPE` 解释。`ADV_ONEBUF` 的
第二个 qword 是设备 write-back 区，可能包含非零的
`status_error/length/VLAN`；只有 header-split 模式才能把该 qword 作为
`hdr_addr`。遇到未支持的 descriptor type 时，QEMU应设置virtual `RXO`
cause、丢弃该次pending RDT且不得写真实RDT，避免永久重试错误配置。

### 11.2 Tail 回绕与批量提交

TDT/RDT 都是 ring index，不是字节地址。QEMU 必须使用配置的 ring length 计算：

```text
[old_tail, new_tail) with wrap-around
```

并拒绝超出 ring depth、未对齐或 queue 尚未 enable 的提交。

### 11.3 不能在共享 RX 线程中长时间 sleep

descriptor 暂不可见时应保存 pending tail 和 retry deadline，由主循环分批重试。
TDT和RDT分别进入独立的64项有序pending FIFO：每个方向内部保持tail顺序，poll
每轮最多处理一个TX头和一个RX头。这样RX等待BAR done、内存可见性或地址修复时，
不会形成head-of-line blocking阻止TX tail转发；一个NIC queue的问题也不能阻塞
其他NVMe/NIC backend的BAR、CFG和中断事件。

### 11.4 地址范围必须严格校验

每个 descriptor address 翻译前都要验证：

- 地址落在 guest DDR window。
- `address + length` 不溢出。
- packet fragment 不越界。
- 翻译结果落在 FPGA coherent alias aperture。

出现错误时不得写真实 tail，否则真实 NIC 可能 DMA 到任意 host/PCIe 地址。

### 11.5 物理 descriptor write-back 与 guest shadow

直接原地 patch 会让 guest memory 中短暂出现 translated address。Linux `igb` 通常用软件 `tx_buffer_info/rx_buffer_info` 保存 DMA mapping，并通过 descriptor status 判断完成，但仍需逐项验证清理路径不会依赖 descriptor 中的原 guest address。

若原地 patch 产生兼容性问题，备用方案是为真实 NIC 建立独立 descriptor shadow ring：QEMU复制并翻译 guest descriptor到shadow ring，完成后再把write-back字段同步回guest ring。该方案隔离更好，但多一次copy并增加ring一致性复杂度。

## 12. 建议的最终选择

建议按以下顺序推进：

1. 先用 QEMU 自带 `igb` 模型接 TAP，验证虚拟 ECAM/BAR/INTx 能让香山标准 `igb` 驱动完整工作，作为软件语义基线。
2. 再实现单队列真实 82580 mediated backend，优先打通 TX，然后 RX。
3. 第一版使用 descriptor/ICR 轮询；功能稳定后改用 VFIO eventfd 降低空闲开销和中断延迟。
4. 保持 coherent alias 和 `BAR_WRITE_DONE`，不恢复 SQE monitor。
5. 如果目标是快速获得多实例和强隔离，硬件平台应优先换成支持 SR-IOV 的 I350/82576；82580 的 VMDq 只能作为 queue/pool 分流辅助，不能替代 PCI VF。

因此，用户提出的“监测 TDT，有变化就启动 DMA”方向是正确的 TX 切入点，但完整表述应为：

```text
监测 TDT/RDT
  -> 等 guest MMIO completion
  -> 读取对应增量 descriptor
  -> 翻译 descriptor ring 和 packet buffer DMA 地址
  -> 写回并确认可见
  -> 最后更新真实 TDT/RDT
  -> 观察 write-back/cause 并生成 guest interrupt
```

## 13. 仓库 14 当前实现

调研结论已在新的 generic QOM 中实现，旧 NVMe-only QOM保持不变：

```text
scope-fpga-vswitch             mixed backend主线
scope-fpga-vswitch-nvme        原NVMe-only回退路径
```

新 manager 使用 `ScopeBackendOps` 对 `realize/cleanup/process_bar_packet/poll` 做设备分派。JSON `type` 支持 `nvme` 和 `igb`，缺省仍为 `nvme`。IGB endpoint模板为 `8086:150e`、class `020000`、512KB 32-bit BAR0和INTA；不提供MSI/MSI-X capability与BAR3，因此guest `igb`自动降为一个legacy queue pair。

82580 backend当前完成：

- 在打开BAR前校验目标为`8086:150e`，并检查目标卡四个sibling function均未绑定host driver；
- 打开MEM/BUS_MASTER，同时禁止真实PCI INTx；
- 屏蔽真实interrupt、停止RX/TX并执行受控reset；
- shadow queue 0的TDBA/TDLEN/RDBA/RDLEN/TXDCTL/RXDCTL/SRRCTL；
- 按Linux `igb`实际使用的`0x028xx/0x038xx` queue-0 alias匹配并转发上述寄存器；
- 在queue enable时一次性提交翻译后的完整ring base；
- 将TDT/RDT作为early-response write，等待`BAR_WRITE_DONE`后处理；
- 对增量descriptor做两次稳定读、guest PA范围检查、coherent alias地址翻译、写回和readback验证；
- 区分advanced TX context/data descriptor，保留checksum/TSO上下文，禁用per-packet TX timestamp；
- 根据`SRRCTL.DESCTYPE`处理RX descriptor：Linux默认的`ADV_ONEBUF`只翻译
  `pkt_addr`并原样保留第二个qword；`HDR_SPLIT/HDR_SPLIT_ALWAYS`才翻译非零
  `hdr_addr`；未支持类型设置virtual `RXO`且不转发真实RDT；
- TDT和RDT分别进入64项TX/RX pending FIFO，`BAR_WRITE_DONE`按全局sequence在
  两个FIFO中匹配；poll每轮分别尝试一个TX和RX队首，消除跨方向队头阻塞；
- 轮询真实ICR和link状态，按virtual ICR read-clear与IMS/IMC set/clear语义驱动aggregate INTx；
- guest `CTRL.RST`进入backend受控reset路径，并清除该backend的ring/tail/cause shadow。

FPGA packet和mailbox ABI未增加NIC专用字段；已有BDF、BAR index、backend route与`BAR_WRITE_DONE`足以复用。RTL内部上限已从`MAX_NVME`更名为`MAX_BACKENDS`。香山内核defconfig已启用`CONFIG_IGB=y`，PTP保持关闭。

当前已完成以下上板功能验证：

- 香山PCI枚举识别`8086:150e`并由标准`igb`驱动绑定；
- `eth0`进入`UP/LOWER_UP`，物理`carrier=1`；
- TX/RX descriptor翻译后能够完成DHCP Discover/Offer/Request/ACK交换；
- rootfs `udhcpc` hook能够安装IPv4地址、默认路由和DNS；
- 香山通过真实82580完成双向ping。

这些结果验证了单queue TX/RX、真实DMA和共享INTx的基本闭环。长时间ping、单流iperf、接口反复down/up、adapter reset和异常恢复仍需要继续验收。

### 13.1 RX低地址误翻译故障与修复

上板时曾持续出现`guest_pa=0x1073 len=256`。该值不是香山分配的DMA地址：
`0x1073`来自已完成RX descriptor第二个qword中的write-back状态，`256`来自
`SRRCTL.BSIZEHDR`。旧实现看到第二个qword非零便按`hdr_addr`翻译，导致RDT
pending永久进行100 us可见性重试；当TDT/RDT共用一个pending FIFO时，该RX项又
阻塞后续TDT，最终触发Linux `Detected Tx Unit Hang`/`NETDEV WATCHDOG`。

当前实现按descriptor type决定字段含义，并拆分TX/RX pending FIFO。临时的
descriptor不可见仍保留在本方向队首重试；不支持的descriptor type作为永久配置
错误一次性上报`RXO`并移出pending队列，但不会转发真实RDT。ring base/length
重配置、queue disable、guest `CTRL.RST`和backend清理都会清除对应pending状态
与tail基线。

## 14. 参考资料

1. [Intel 82580EB/82580DB Gigabit Ethernet Controller Datasheet](https://www.intel.de/content/dam/doc/datasheet/82580-eb-db-gbe-controller-datasheet.pdf)：TX/RX ring、TDT/RDT、descriptor、interrupt 和 reset 语义。
2. [Intel Ethernet Controllers and PHYs brochure](https://www.intel.com/content/dam/www/public/us/en/documents/brochures/ethernet-controllers-phys-brochure.pdf)：82580 的 8 TX/8 RX queue、VMDq、MSI-X 能力，以及与支持 SR-IOV 型号的区别。
3. [Linux igb driver: igb_main.c](https://github.com/torvalds/linux/blob/master/drivers/net/ethernet/intel/igb/igb_main.c)：ring 初始化、DMA mapping、descriptor 填充、TDT/RDT 和中断处理。
4. [Linux igb register definitions: e1000_regs.h](https://github.com/torvalds/linux/blob/master/drivers/net/ethernet/intel/igb/e1000_regs.h)：TDBA/RDBA、TDT/RDT、ICR/EICR 等寄存器地址。
5. [QEMU igb_core.c](https://gitlab.com/qemu-project/qemu/-/blob/master/hw/net/igb_core.c)：完整软件设备模型中的 TDT 触发、descriptor DMA、RX write-back 和 interrupt cause 状态机。
6. [Linux VFIO documentation](https://docs.kernel.org/driver-api/vfio.html)：真实 PCI function 的用户态所有权、BAR 访问、DMA ownership 和中断接口。
7. [Linux virtio documentation](https://docs.kernel.org/driver-api/virtio/virtio.html)：共享 descriptor ring 软件网络路径，可作为非直通基线方案。
