# 虚拟 PCIe Switch 下挂单 NVMe 的实现方案

## 1. 目标

当前系统原先依赖 FPGA 中的 DUT-facing XDMA Root Port IP，让香山 Linux 通过 `xlnx,xdma-host-3.00` PCI host bridge 枚举下游设备。这个路径和当前 proxy 状态机基本假设 XDMA RP 下只有一个被代理设备。

仓库 13 的新目标是：**不再依赖真实 DUT-facing XDMA RP 硬件**，而是在香山侧实现一个由 FPGA/QEMU 共同维护的虚拟 PCIe 层次结构。第一阶段只模拟一个 switch 下挂一个 NVMe：

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

仓库 13 改为 generic ECAM host bridge：

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

如果这些规则放进 FPGA，会很快变成一个不完整的 PCI config emulator。仓库 13 当前采用：

```text
QEMU 初始化并维护 4 个 BDF 的 16KB compact ECAM shadow
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

不实现完整 16MB/256MB ECAM RAM。第一阶段只保存 4 个 function，每个 4KB：

```text
shadow offset 0x0000 -> 00:00.0 Root Port
shadow offset 0x1000 -> 01:00.0 Switch Upstream Port
shadow offset 0x2000 -> 02:01.0 Switch Downstream Port
shadow offset 0x3000 -> 03:00.0 NVMe endpoint
```

因此 BRAM 只需要 16KB。FPGA 的 BDF 映射逻辑是固定表：

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
  QEMU 已经写入 GUEST_BAR0_LO/HI/SIZE/CTRL，FPGA 可以进行 NVMe BAR0 MMIO hit 判断。

bit1 PROXY_CTRL_ECAM_SHADOW_READY
  QEMU 已经初始化完整 16KB compact ECAM shadow BRAM，FPGA 可以从 BRAM 响应 ECAM read。
```

两个 bit 放在同一个 control 寄存器中是可以接受的，因为它们都是 QEMU 对 FPGA 的全局路径 ready 信号；但语义不同：

```text
ECAM_SHADOW_READY 控制配置空间 read 是否有效
BAR_ROUTE_READY 控制 MMIO window 是否允许命中 NVMe BAR0
```

FPGA 必须分别判断，不应把二者混成一个“backend ready”。

### 4.6 MMIO 路由

FPGA 的 `nvme_bar_hit()` 只依赖 QEMU 写入的 mailbox BAR route：

```text
MBX_REG_GUEST_BAR0_LO
MBX_REG_GUEST_BAR0_HI
MBX_REG_GUEST_BAR0_SIZE
MBX_REG_GUEST_BAR0_CTRL
MBX_REG_PROXY_CTRL.bit0 BAR_ROUTE_READY
```

命中后：

```text
guest_mmio_addr -> offset = guest_mmio_addr - guest_bar0_base
packet type = BAR_READ / BAR_WRITE
bdf = 03:00.0
bar = 0
offset / size / wstrb / data
```

QEMU 对 `03:00.0 BAR0` 继续复用当前 NVMe proxy 的 BAR 处理逻辑，包括 `CAP/VS/CC/CSTS/AQA/ASQ/ACQ/doorbell`、Admin queue、PRP/PRP list 翻译、coherent alias 与 INTx。

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
HOST_MBX_REG          0x11000000, range 0x1000
HOST_SQE_MONITOR_CFG  0x11001000, range 0x1000
HOST_ECAM_SHADOW_BRAM 0x11010000, range 0x4000
```

5. `virtual_pcie_switch_proxy_0/m_axis_c2h` 接入原 C2H 合流路径，继续和 `sqe_write_done_monitor` 共用 DMA32 packet ring。

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

### 6.1 4 个 Virtual Config Slot

QEMU 维护：

```c
struct ScopeVswitchConfigFn {
    uint16_t bdf;
    uint8_t config[4096];
    uint8_t wmask[4096];
    uint8_t w1cmask[4096];
};
```

4 个 slot 对应：

```text
slot 0: 00:00.0 Root Port
slot 1: 01:00.0 Switch Upstream Port
slot 2: 02:01.0 Switch Downstream Port
slot 3: 03:00.0 NVMe endpoint
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
打开 XDMA user/control/event/bypass
初始化真实 NVMe BAR 和能力缓存
初始化 QEMU PCIDevice 的 NVMe config
初始化 3 个 bridge shadow slot + 1 个 NVMe shadow slot
写完整 16KB ECAM shadow BRAM
readback fence 确认 shadow 写入已到 FPGA
写 PROXY_CTRL_ECAM_SHADOW_READY
同步 NVMe BAR0 route mailbox
写 PROXY_CTRL_BAR_ROUTE_READY
启动 DMA32 RX thread 和 event handler
```

这样香山开始枚举时，ECAM read 可以直接从 FPGA BRAM 返回 QEMU 准备好的配置空间。

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
如果 bdf 是 03:00.0 NVMe
  调用 pci_default_write_config()
  复制 pci_dev->config 到 NVMe shadow slot
  写回 ECAM shadow BRAM
  同步 BAR0 route mailbox
  readback fence
  ACK seq
```

这个顺序保证 FPGA ECAM write 返回 B response 时，shadow BRAM 和 BAR route 已经更新完成。

### 6.4 NVMe 后端复用

`03:00.0 BAR0` 的访问进入现有 NVMe proxy 状态机：

```text
CAP/VS/CSTS/CC/AQA/ASQ/ACQ
SQ/CQ doorbell
SQE_WRITE_DONE
Admin CQ shadow scan
PRP/PRP list 翻译
coherent alias
INTx level
```

相对仓库 11 的核心不同点是：配置空间不再由单设备 `vconf` 或 FPGA 本地模型维护，而是 QEMU 维护多 BDF compact ECAM shadow。

## 7. Packet ABI

仓库 13 的 vSwitch packet 继续使用 32B DMA32 packet，但 `flags` 中显式携带 BDF/BAR/size/wstrb：

```text
flags[15:0]  = bdf = (bus << 8) | (dev << 3) | fn
flags[18:16] = bar index, CFG_WRITE 使用 BAR_TAG_CFG
flags[23:20] = size bytes
flags[31:24] = write strobe
bar_offset   = config offset 或 BAR offset
data         = low 32-bit payload
guest_addr_lo= high 32-bit payload for 64-bit BAR lane
```

第一阶段只有 `03:00.0 BAR0` 进入 NVMe 后端；保留 BDF/BAR 字段是为了后续扩展 NIC 或多个 downstream endpoint。

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
host SQE monitor:   0x11001000, 4KB
host ECAM shadow:   0x11010000, 16KB
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

QEMU 路径应继续使用 coherent alias、PRP/PRP list 翻译、SQE monitor 和 INTx level。

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

当前仓库 13 实现的是：

```text
generic ECAM host bridge
固定 4 BDF 虚拟 switch 拓扑
QEMU 维护 16KB compact ECAM shadow
FPGA ECAM read 读 BRAM
FPGA ECAM write 发 CFG_WRITE 并等 QEMU ACK
单 NVMe endpoint BAR0 后端复用现有 NVMe proxy
INTx level 中断
```

当前不实现：

```text
真实 PCIe 链路训练 / TLP / DLLP
完整 switch capability / AER / hotplug
MSI/MSI-X
动态增加 downstream port
完整 16MB ECAM RAM
多个 endpoint 同时转发
```

这条路线比“仿 Xilinx XDMA RP 控制寄存器”更干净，也比“自己实现真实 PCIe RP/TLP/链路层”可控得多；后续增加 NIC 或多设备时，应继续扩展 QEMU config shadow 表和 packet BDF/BAR 路由，而不是把 PCI 配置语义重新搬回 FPGA。
