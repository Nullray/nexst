# 虚拟 PCIe Switch 下挂 0 至 13 个 NVMe 的实现方案

运行时寄存器、字段所有权和软件写入顺序以 `doc/VSWITCH_REGISTER_INTERFACE_SPEC.md` 为规范性接口定义。

## 1. 目标

当前系统原先依赖 FPGA 中的 DUT-facing XDMA Root Port IP，让香山 Linux 通过 `xlnx,xdma-host-3.00` PCI host bridge 枚举下游设备。这个路径和当前 proxy 状态机基本假设 XDMA RP 下只有一个被代理设备。

仓库 14 的目标是：**不再依赖真实 DUT-facing XDMA RP 硬件**，而是在香山侧实现一个由 FPGA/QEMU 共同维护的虚拟 PCIe 层次结构。下面先用只启用一个 backend 的最小拓扑解释基本机制；第 11 节描述当前 `0..13` 个 NVMe 的实现：

```text
PCI host bridge
  00:00.0 virtual Root Port / PCI bridge
    01:00.0 virtual PCIe Switch Upstream Port / PCI bridge
      02:01.0 virtual PCIe Switch Downstream Port / PCI bridge
        03:00.0 virtual NVMe endpoint
```

香山 Linux 看到的是标准 PCIe switch 拓扑；真实 NVMe 仍由 x86/QEMU 作为后端代理访问。这里实现的是 Linux 配置空间视角的虚拟 switch，不实现真实 PCIe PHY、LTSSM、TLP/DLLP 或链路训练。

## 2. 总体结论

### 2.1 不仿 Xilinx XDMA RP 私有寄存器

如果删除真实 XDMA RP IP，却继续在 device tree 中使用：

```dts
compatible = "xlnx,xdma-host-3.00";
```

就必须仿真 Xilinx XDMA host driver 期待的私有控制寄存器和配置访问协议，复杂且容易被驱动细节绑定。

### 2.2 使用pci-host-ecam-generic替代xdma rp

PCIe ECAM：Enhanced Configuration Access Mechanism，中文可理解为 PCIe 增强配置空间访问机制。它的核心作用是：让 CPU/OS 通过一段内存映射地址，访问 PCIe 设备的 Configuration Space。

pci-host-ecam-generic 是 Linux Device Tree 里的一种 PCI/PCIe Host Bridge compatible 字符串。它不是某个具体厂商 IP 的名字，而是告诉 Linux：

这个 PCIe Root Complex / Host Bridge 已经由固件或硬件初始化好了，并且它的配置空间访问方式符合标准 ECAM，Linux 可以用通用 PCI Host 驱动来枚举 PCIe 设备。

仓库 14 改为 generic ECAM host bridge：

```dts
compatible = "pci-host-ecam-generic";
reg = <0x0 0x60000000 0x0 0x01000000>;
bus-range = <0 15>;
```

Linux PCI core 使用标准 ECAM 公式访问配置空间：

```text
ecam_addr = ECAM_BASE + (bus << 20) + (device << 15) + (function << 12) + reg
```

### 2.3 QEMU 是配置空间权威

最终实现不让 FPGA 手写 PCI config 字段语义。原因是 PCI 配置空间有很多特殊规则：

```text
BAR sizing: 写 all-ones 后读 mask，再写最终 base
Command/Status: 部分 bit 可写，部分 bit 写 1 清除
Bridge bus number/window: Linux 枚举时会动态写入
Capability list: NVMe endpoint 由 QEMU PCI core 初始化
```

如果这些规则放进 FPGA，会很快变成一个不完整的 PCI config emulator。仓库 14 当前采用：

```text
QEMU 初始化并维护 28 个 function slot 的 compact ECAM shadow
FPGA ECAM read 直接读 shadow BRAM
FPGA ECAM write 发 CFG_WRITE packet 并等待 QEMU ACK
QEMU 用 bridge wmask/w1cmask helper 或 pci_default_write_config() 更新 shadow
QEMU 写回 shadow BRAM 后 ACK FPGA
```

这样配置空间语义由 QEMU 维护，FPGA 只负责 fast-path read 和 write ordering。

## 3. BDF 拓扑

固定第一阶段拓扑：

```text
00:00.0 Root Port / PCI bridge                 [secondary=01, subordinate=03]
01:00.0 Switch Upstream Port / PCI bridge      [secondary=02, subordinate=03]
02:01.0 Switch Downstream Port / PCI bridge    [secondary=03, subordinate=03]
03:00.0 NVMe endpoint
```

不要把多个设备写成：

```text
01:00.0 NVMe
01:00.1 NIC
```

这表示同一个 device 的多个 function，不是 PCIe switch 下多个独立 endpoint。后续增加第二个设备时，应扩展为新的 downstream port 和新的 downstream bus：

```text
02:02.0 Switch Downstream Port 2
04:00.0 NIC endpoint
```

## 4. FPGA 硬件结构

新增模块：

```text
shell/nm37_vu37p/fpga/sources/hdl/recorder/virtual_pcie_switch_proxy.v
```

它替代 DUT-facing `xdma_rp` 的香山侧职责，但不实现真实 PCIe RP，只实现 Linux PCI core 需要看到的 ECAM 与 MMIO 行为。

### 4.1 接口

```text
S_ECAM_AXI          香山访问 0x60000000 ECAM 配置空间
M_ECAM_SHADOW_AXI   FPGA 读取 compact ECAM shadow BRAM
S_MMIO_AXI          香山访问 0x50000000 PCI memory window
S_MBX_AXI           x86/QEMU 通过 XDMA EP BAR 写 mailbox/control
M_AXIS_C2H          FPGA -> QEMU packet stream
interrupt_out       虚拟 INTx level 注入香山
```

不再需要 DUT-facing RP 相关接口：

```text
xdma_rp/S_AXI_LITE
xdma_rp/S_AXI_B
xdma_rp/M_AXI_B
pcie_rp_rx/tx
pcie_rp_ref_clk
pcie_rp_perstn
```

x86 host-facing `xdma_ep` 仍保留，用于：

```text
QEMU mailbox
C2H packet ring
ECAM shadow BRAM host write
host bypass/coherent alias
真实 NVMe 后端 DMA 地址映射
```

### 4.2 Compact ECAM Shadow BRAM

不实现完整 16MB/256MB ECAM RAM。单 backend 基线保存 4 个 function，每个 4KB：

```text
shadow offset 0x0000 -> 00:00.0 Root Port
shadow offset 0x1000 -> 01:00.0 Switch Upstream Port
shadow offset 0x2000 -> 02:01.0 Switch Downstream Port
shadow offset 0x3000 -> 03:00.0 NVMe endpoint
```

在当前多 backend 实现中，这张表扩为公式化的 28 个 slot，并使用 128KB aperture；单 backend 时前 4 个有效 slot 为：

```text
00:00.0 -> slot 0
01:00.0 -> slot 1
02:01.0 -> slot 2
03:00.0 -> slot 3
其他 BDF -> 不存在
```

### 4.3 ECAM Read 语义

FPGA 从 `S_ECAM_AXI` 解码：

```text
bus = rel_addr[27:20]
dev = rel_addr[19:15]
fn  = rel_addr[14:12]
reg = rel_addr[11:0]
```

读流程：

```text
如果 ECAM_SHADOW_READY=0
  返回 0xffffffff，AXI OKAY
如果 BDF 不在固定表中
  返回 0xffffffff，AXI OKAY
如果 BDF 在固定表中
  用 m_ecam_shadow_axi 读取 shadow BRAM 对应 dword
  把 BRAM RDATA 返回香山，AXI RRESP 透传/OKAY
```

不存在 BDF 不能返回 AXI error。Linux PCI 枚举依赖 Vendor ID/Device ID 为 all-ones 判断设备不存在；如果返回 `DECERR/SLVERR`，可能导致 host bridge 报错或 kernel fault。

### 4.4 ECAM Write 语义

FPGA 不在本地修改配置空间字段，也不处理 BAR sizing。写流程：

```text
如果 BDF 不在固定表中
  写返回 OKAY no-op
如果 BDF 在固定表中
  FPGA 生成 CFG_WRITE packet
  阻塞 AXI B response
  QEMU 更新对应 config shadow 并写回 BRAM
  QEMU 写 MBX_REG_ACK=seq
  FPGA 看到 ACK 后返回 AXI B OKAY
```

这个等待 ACK 的语义很关键：它保证香山一次 config write 完成后，后续 config read 能看到 QEMU 更新后的 shadow，而不是读到旧 BRAM 内容。

`virtual_pcie_switch_proxy.v` 中 ECAM write 的 AW/W 通道分别缓存，允许 AXI-Lite AW 和 W 不同周期到达。

### 4.5 Mailbox Ready Bits

`MBX_REG_PROXY_CTRL` 是全局 ready/control 寄存器：

```text
bit0 PROXY_CTRL_BAR_ROUTE_READY
  QEMU 已完成 13 项 BAR route table 的初始化，FPGA 可以进行 BAR0 MMIO hit 判断。

bit1 PROXY_CTRL_ECAM_SHADOW_READY
  QEMU 已经初始化完整 128KB compact ECAM shadow BRAM，FPGA 可以从 BRAM 响应 ECAM read。
```

两个 bit 放在同一个 control 寄存器中是可以接受的，因为它们都是 QEMU 对 FPGA 的全局路径 ready 信号；但语义不同：

```text
ECAM_SHADOW_READY 控制配置空间 read 是否有效
BAR_ROUTE_READY 控制 MMIO window 是否允许命中 NVMe BAR0
```

FPGA 必须分别判断，不应把二者混成一个“backend ready”。

### 4.6 MMIO 路由

FPGA 的 MMIO route matcher 只依赖 QEMU 写入的 13 项 BAR route table：

```text
route[i].BAR_LO / BAR_HI
route[i].BAR_SIZE
route[i].BDF
route[i].CTRL(valid / MEM-enable / backend_id)
MBX_REG_PROXY_CTRL.bit0 BAR_ROUTE_READY
```

命中后：

```text
guest_mmio_addr -> offset = guest_mmio_addr - guest_bar0_base
packet type = BAR_READ / BAR_WRITE
bdf = route[i].BDF
bar = 0
offset / size / wstrb / data
```

QEMU 按 BDF 选择 backend，并复用 NVMe proxy 的 BAR 处理逻辑，包括 `CAP/VS/CC/CSTS/AQA/ASQ/ACQ/doorbell`、Admin queue、PRP/PRP list 翻译、coherent alias 与 INTx。

### 4.7 INTx

第一阶段只使用 INTx level：

```text
QEMU 看到 CQ pending
  -> 写 mailbox INTx level=1
  -> FPGA interrupt_out 拉高
  -> 香山 PLIC 收到 PCI host interrupt
guest 写 CQ doorbell
  -> QEMU 判断 no pending
  -> 写 mailbox INTx level=0
```

Device Tree 中必须通过 `interrupt-map` 把 PCI INTA# 映射到 PLIC。单 NVMe 阶段可以把 INTA/B/C/D 都映射到同一个 PLIC interrupt，后续多设备再做 INTx swizzle 或拆分中断。

多 backend 使用一根 aggregate level INTx。QEMU 每次重新计算所有 backend 的
pending CQ，只有全部设备都没有 pending completion 时才拉低。历史上的
clear/assert retry pulse 仍可通过 `intx-retry-pulse=on` 临时启用，但默认关闭；
正常运行只使用标准 level 语义，避免一个设备的重试脉冲短暂撤销其他设备的中断。

## 5. Vivado Block Design

`shell/nm37_vu37p/fpga/scripts/xiangshan.tcl` 的核心改动：

1. 移除 DUT-facing `xdma_rp` 实例、GT/refclk/reset/interrupt 连接。
2. `u_role/m_axi_io` 分配两个虚拟 PCIe window：

```text
0x60000000/16MB -> virtual_pcie_switch_proxy_0/s_ecam_axi
0x50000000/16MB -> virtual_pcie_switch_proxy_0/s_mmio_axi
```

3. 复用原 `vconf_bram` 作为 ECAM shadow BRAM：

```text
vconf_bram_ctrl_a/S_AXI <- virtual_pcie_switch_proxy_0/m_ecam_shadow_axi
vconf_bram_ctrl_b/S_AXI <- host/QEMU via xdma_ep/M_AXI_LITE
```

4. host/QEMU 侧地址段：

```text
HOST_MBX_REG                    0x11000000, range 0x1000
RETIRED_SQE_MONITOR_RESERVED    0x11001000, range 0x1000, unmapped
HOST_ECAM_SHADOW_BRAM           0x11010000, range 0x20000
```

5. role DDR 和 proxy C2H 使用直接链路：

```text
u_role/m_axi_mem
  -> axi_ic_ddr_mem_reg_slice_S01
  -> axi_ic_ddr_mem/S01_AXI

virtual_pcie_switch_proxy_0/m_axis_c2h
  -> axis_rs_active_proxy_c2h
  -> axis_cc_proxy_c2h1
  -> axis_rs_proxy_c2h_out
  -> xdma_ep/S_AXIS_C2H_1
```

vSwitch 不再例化 SQE write-done monitor，也不再使用 C2H 2-to-1 合流器。

BAR route 冲突诊断位于 proxy mailbox：

```text
0x060 ROUTE_ERROR_STATUS
      bit0    sticky，写 1 清除
      bits2:1 最近一次命中的 route 数量
0x064 ROUTE_ERROR_COUNT
0x068 ROUTE_ERROR_ADDR_LO
0x06c ROUTE_ERROR_ADDR_HI
```

当同一个 MMIO 地址同时命中多个有效 route 时，FPGA 返回 `SLVERR`，同时记录
冲突次数和最后地址。未命中仍保持 read 返回全 1、write no-op 的既有语义。

## 6. QEMU 软件结构

新增设备文件：

```text
qemu-mount/hw/misc/scope_fpga_vswitch_nvme.c
```

QOM type：

```text
scope-fpga-vswitch-nvme
```

它是独立实验路径，不修改旧 `scope_fpga_proxy.c`。

### 6.1 28 个 Virtual Config Slot

QEMU 维护：

```c
struct ScopeVswitchConfigFn {
    uint16_t bdf;
    uint8_t config[4096];
    uint8_t wmask[4096];
    uint8_t w1cmask[4096];
};
```

slot 映射为：

```text
slot 0: 00:00.0 Root Port
slot 1: 01:00.0 Switch Upstream Port
slot 2+2*i: 02:(i+1).0 Switch Downstream Port i
slot 3+2*i: (03+i):00.0 NVMe endpoint i
i = 0..12
```

Bridge slot 使用 QEMU-side helper 初始化 Type 1 header，并用 `wmask/w1cmask` 处理可写字段和 W1C 字段：

```text
command/status
primary/secondary/subordinate bus
memory base/limit
prefetchable memory base/limit
interrupt line
bridge control
secondary status
```

NVMe endpoint slot 使用 QEMU `PCIDevice`：

```text
pci_config_set_vendor_id()
pci_config_set_device_id()
pci_config_set_class()
pcie_endpoint_cap_init()
pci_register_bar()
pci_default_write_config()
```

因此 NVMe BAR sizing、Command bit、PCIe capability 等语义尽量沿用 QEMU PCI core。

### 6.2 启动初始化流程

QEMU realize 阶段：

```text
打开 XDMA user/control/bypass
初始化真实 NVMe BAR 和能力缓存
初始化 QEMU PCIDevice 的 NVMe config
初始化两个公共 bridge slot、active downstream/endpoint slot和inactive全1 slot
写完整 28 x 4KB ECAM shadow到128KB BRAM aperture
readback fence 确认 shadow 写入已到 FPGA
写 PROXY_CTRL_ECAM_SHADOW_READY
同步 NVMe BAR0 route mailbox
写 PROXY_CTRL_BAR_ROUTE_READY
启动 DMA32 RX thread
```

这样香山开始枚举时，ECAM read 可以直接从 FPGA BRAM 返回 QEMU 准备好的配置空间。
vSwitch 不再注册 `/dev/xdma*_events_0` 的旧配置回调：该 user IRQ 在当前
Block Design 中来自 `host_uart/interrupt`，并不是 ECAM 配置事件。ECAM write
唯一的权威控制路径是 `CFG_WRITE DMA32 packet -> QEMU 更新 shadow -> ACK seq`。
`xdma-event-dev` 属性仅为兼容已有启动命令而保留，当前不会打开或消费该节点。

### 6.3 CFG_WRITE 处理流程

FPGA 发来的 `CFG_WRITE` packet 带：

```text
bdf
bar = BAR_TAG_CFG
offset
size/wstrb
data
seq
```

QEMU 处理：

```text
解析 bdf/offset/wstrb/data
如果 bdf 不在固定表中
  ACK seq
如果 bdf 是 bridge
  使用 wmask/w1cmask 更新 bridge shadow
  写回对应 4KB slot 的变更 dword 到 ECAM shadow BRAM
  readback fence
  ACK seq
如果 bdf 是 active NVMe endpoint
  调用 pci_default_write_config()
  复制 pci_dev->config 到 NVMe shadow slot
  写回 ECAM shadow BRAM
  同步 BAR0 route mailbox
  readback fence
  ACK seq
```

这个顺序保证 FPGA ECAM write 返回 B response 时，shadow BRAM 和 BAR route 已经更新完成。

### 6.4 NVMe 后端复用

active endpoint BAR0 的访问按BDF选择backend后进入NVMe proxy状态机：

```text
CAP/VS/CSTS/CC/AQA/ASQ/ACQ
SQ/CQ doorbell
Admin CQ shadow scan
PRP/PRP list 翻译
coherent alias
INTx level
```

相对仓库 11 的核心不同点是：配置空间不再由单设备 `vconf` 或 FPGA 本地模型维护，而是 QEMU 维护多 BDF compact ECAM shadow。

## 7. Packet ABI

仓库 14 的 vSwitch packet 使用32B DMA32 packet，`flags`中显式携带BDF/BAR/size/wstrb：

```text
flags[15:0]  = bdf = (bus << 8) | (dev << 3) | fn
flags[18:16] = bar index, CFG_WRITE 使用 BAR_TAG_CFG
flags[23:20] = size bytes
flags[31:24] = write strobe
bar_offset   = config offset 或 BAR offset
data         = low 32-bit payload
guest_addr_lo= high 32-bit payload for 64-bit BAR lane
```

当前有效packet类型只有`CFG_WRITE`、`BAR_WRITE`、`BAR_READ`和`BAR_WRITE_DONE`。vSwitch不定义或消费`SQE_WRITE_DONE`。BDF字段用于在多个endpoint之间选择backend。

## 8. Device Tree 和地址规划

新增 DTS：

```text
nanhu-g/software/dt/XSTop_vpcie.dts
```

核心节点：

```dts
pcie_virtual: pcie@60000000 {
    compatible = "pci-host-ecam-generic";
    device_type = "pci";
    reg = <0x0 0x60000000 0x0 0x01000000>;
    #address-cells = <3>;
    #size-cells = <2>;
    bus-range = <0 15>;
    ranges = <0x02000000 0x00000000 0x50000000
              0x0 0x50000000
              0x00000000 0x01000000>;
    #interrupt-cells = <1>;
    interrupt-map-mask = <0 0 0 7>;
    interrupt-map = <0 0 0 1 &L4 2>,
                    <0 0 0 2 &L4 2>,
                    <0 0 0 3 &L4 2>,
                    <0 0 0 4 &L4 2>;
};
```

地址规划：

```text
香山侧 ECAM window: 0x60000000, 16MB
香山侧 PCI MEM:     0x50000000, 16MB
host mailbox:       0x11000000, 4KB
reserved hole:      0x11001000, 4KB, unmapped
host ECAM shadow:   0x11010000, 128KB
```

## 9. 分阶段验证

### Phase 0: generic ECAM 基础

确认内核启用：

```text
CONFIG_PCI_HOST_GENERIC
CONFIG_PCI_ECAM
```

确认 `DT_TARGET=XSTop_vpcie` 能生成并被 OpenSBI/内核使用。

### Phase 1: ECAM shadow 可见

host 侧读 shadow BRAM：

```sh
pcie-util /dev/xdma0_user read 0x01010000  # 00:00.0 vendor/device
pcie-util /dev/xdma0_user read 0x01013000  # 03:00.0 NVMe vendor/device
```

香山侧读 ECAM：

```sh
devmem 0x60000000 32  # 00:00.0
devmem 0x60300000 32  # 03:00.0
```

未定义 BDF 应返回 `0xffffffff` 且不触发 AXI fault。

### Phase 2: 枚举拓扑

目标：

```sh
lspci -tv
```

看到类似：

```text
-[0000:00]-
 \-00.0-[01-03]--
    \-00.0-[02-03]--
       \-01.0-[03]--
          \-00.0  Non-Volatile memory controller
```

### Phase 3: BAR sizing 和 MMIO

目标：

```sh
lspci -vv -s 03:00.0
```

看到 NVMe class `010802`、64-bit BAR0，以及 BAR0 被分配在 `0x50000000` PCI MEM window 内。

QEMU 日志应看到 `03:00.0 BAR0` 的 `CAP/VS/CSTS/CC/AQA/ASQ/ACQ/doorbell`。

### Phase 4: NVMe 数据路径

目标：

```sh
/dev/nvme0n1 存在
dd if=/dev/nvme0n1 of=/dev/null bs=512 count=1
```

QEMU 路径应继续使用 coherent alias稳定读取、PRP/PRP list翻译和INTx level。Admin SQ doorbell的门控事件为`BAR_WRITE_DONE`，不再等待SQE monitor packet。

## 10. 风险点

1. **ECAM write 必须等 QEMU ACK**
   如果 FPGA 提前返回 B response，后续 config read 可能读到旧 shadow，Linux 枚举会出现随机错误。

2. **Bridge config helper 仍是最小模型**
   当前 bridge slot 只覆盖第一阶段枚举需要的 Type 1 header 字段。后续支持更多 capability、热插拔或 AER 时，需要扩展 QEMU-side shadow helper。

3. **NVMe endpoint 依赖 QEMU PCI core**
   NVMe slot 应继续调用 `pci_default_write_config()`，不要在 FPGA 或手写 shadow 中单独重做 BAR sizing 语义。

4. **不存在 BDF 不能返回 AXI error**
   必须返回 `0xffffffff + OKAY`。

5. **INTx 必须依赖 interrupt-map**
   只写 host bridge 自身 `interrupts` 不一定能让 endpoint INTA# 映射到 NVMe driver IRQ。

6. **MSI/MSI-X 暂缓**
   第一阶段隐藏或不暴露 MSI/MSI-X capability，只走 INTx，避免同时实现 MSI write 捕获和中断重映射。

7. **QEMU 与 FPGA ready bit 要分开理解**
   `ECAM_SHADOW_READY` 只说明配置空间 shadow 可读；`BAR_ROUTE_READY` 只说明 MMIO BAR route 可用。枚举期可以先只有 ECAM ready，BAR route 随 NVMe BAR 写入变化。

## 11. 当前实现边界

当前仓库 14 实现的是启动时可配置的 `0..13` NVMe vSwitch：

```text
generic ECAM host bridge
00:00.0 Root Port
01:00.0 Switch Upstream Port
02:(1+i).0 Downstream Port -> (03+i):00.0 NVMe i, i=0..12
QEMU 维护 28 x 4KB compact ECAM shadow，BRAM aperture 为 128KB
FPGA ECAM read 读 BRAM
FPGA ECAM write 发 CFG_WRITE 并等 QEMU ACK
每个 endpoint 独立 BAR0 route、NVMe register/queue/PRP/CQ 状态
Admin SQE通过coherent alias稳定读取，不使用SQE monitor
所有 endpoint 共用一根 aggregate INTx level 中断
```

QEMU 使用 `backend-config=/path/to/vswitch-nvme.json` 指定真实设备。数组顺序
就是 `backend_id` 和虚拟端口顺序；空数组是合法的 switch-only 模式。兼容的
单设备入口仍为 `real-host-bdf=0000:xx:yy.z`，但不能和 `backend-config` 同时使用。

```json
{
  "version": 1,
  "devices": [
    { "real-host-bdf": "0000:af:00.0" },
    { "real-host-bdf": "0000:b0:00.0" }
  ]
}
```

DMA32 ring 默认扩为 64KB，可通过 `dma32-ring-size` 覆盖。消费者保存物理 slot
的 `type + seq` 和扫描 cursor，每轮只扫描固定数量 slot，避免 ring 扩大后高频
全表轮询。manager 统一拥有 XDMA、shadow BRAM 和共享 INTx；真实 BAR、NVMe
寄存器、namespace LBA shift、SQ/CQ、pending doorbell 和 CID 状态均属于各自
backend，处理BAR packet时必须先按BDF选择backend。

### 11.1 多设备可靠性约束

当前实现对多 backend 的共享软件路径增加以下约束：

1. 每个 backend 保存 `admin_outstanding_count`。Admin CID bitmap 仍用于校验具体
   CQE，但高频 CQ 轮询通过计数器 O(1) 判断是否存在命令，不再每轮扫描 65536 个 CID。
2. Admin SQE 可见性检查执行两次立即 coherent-alias 读取。两次内容不一致、全零
   或仍等于 seed 时返回 `WAIT`，由 RX 线程按 deadline 重新调度；读取函数内部不
   sleep，因此单个设备不会阻塞其他设备的 DMA32 packet 消费。
3. FPGA完成guest doorbell的AXI B handshake后发送`BAR_WRITE_DONE`。QEMU收到该
   packet后才开始SQE稳定读取；如果one-shot packet未被cursor及时消费，超时恢复
   会精确搜索ring并推断BAR completion，但SQE稳定读取仍是转发真实doorbell的门槛。
4. QEMU 退出或部分 backend 初始化失败时恢复各真实设备原来的 PCI Command。
   控制器保持 disabled，因为恢复旧 `CC.EN` 会重新引用可能已经失效的 queue
   地址；后续归还 host 驱动仍应走正常 reset/probe 流程。
5. 单个 backend 执行 `CC.EN=0`、INT mask 或 CQ doorbell 更新时不能直接清共享
   INTx。QEMU 先更新该 backend 状态，再重新 OR 全部 backend 的 pending 状态，
   只有 aggregate pending 为零时才向 FPGA 写 level 0。

当前不实现：

```text
真实 PCIe 链路训练 / TLP / DLLP
完整 switch capability / AER / hotplug
MSI/MSI-X
完整 16MB ECAM RAM
运行时热插拔或改变 backend 数量
每个 endpoint 独立 MSI/MSI-X
```

这条路线比“仿 Xilinx XDMA RP 控制寄存器”更干净，也比“自己实现真实 PCIe RP/TLP/链路层”可控得多；后续增加 NIC 或多设备时，应继续扩展 QEMU config shadow 表和 packet BDF/BAR 路由，而不是把 PCI 配置语义重新搬回 FPGA。
