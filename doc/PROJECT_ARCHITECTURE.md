# 跨软硬件协同虚拟 PCIe/外设系统架构

本项目在 FPGA 原型平台上把香山 Linux 的 PCIe 配置访问、BAR MMIO 和真实设备 DMA 与 x86/QEMU 协同起来。当前仓库 14 的主线不再依赖 DUT-facing XDMA Root Port，而是由 FPGA 和 QEMU 实现一个 Linux 配置空间视角的虚拟 PCIe switch，并把主机侧真实 NVMe、Intel 82580 Ethernet function 或 U280 上的 Vortex GPGPU 作为 mediated backend 映射给香山。

核心控制链路为：

```text
香山 PCI config/BAR access
-> FPGA virtual_pcie_switch_proxy
-> XDMA C2H DMA32 packet
-> x86/QEMU manager
-> 配置空间更新或所选真实 backend BAR access
-> FPGA mailbox response/ACK
-> 香山 AXI transaction 完成
```

核心数据链路为：

```text
主机侧真实 NVMe/82580 PCIe DMA
-> FPGA XDMA EP bypass coherent alias
-> u_role/s_axi_dma coherency 入口
-> 香山 guest memory
```

QEMU 负责控制面、地址翻译和状态机推进，不复制普通 NVMe IO 或 Ethernet packet data。真实 NVMe/82580 到 FPGA endpoint 的数据传输仍是 host PCIe fabric 上的 P2P DMA。Vortex 第一阶段使用独立 U280 XRT host-memory BO，QEMU 在香山 coherent alias 与该 BO 之间搬运命令的数据操作数，因此它是 mediated copy path，不宣称为设备到设备 P2P。

## 1. 虚拟 PCIe 拓扑

### 1.1 固定层次结构

系统支持在 QEMU 启动时选择 `0..13` 个 backend。每项可以是 NVMe、82580 或 Vortex，设备按配置文件顺序映射为：

```text
00:00.0  virtual Root Port
  `-01:00.0  virtual Switch Upstream Port
      |-02:01.0  Downstream Port 0 -> 03:00.0 backend 0
      |-02:02.0  Downstream Port 1 -> 04:00.0 backend 1
      | ...
      `-02:13.0  Downstream Port 12 -> 0f:00.0 NVMe backend 12
```

第 `i` 个 backend 的映射公式为：

```text
backend_id       = i, i = 0..12
downstream BDF   = 02:(i + 1).0
endpoint BDF     = (03 + i):00.0
```

未启用的 downstream port 和 endpoint 配置空间填充为全 `0xff`，Linux 枚举时会自然忽略。空设备列表是合法的 switch-only 模式。

### 1.2 这里的 switch 是什么

该设计实现的是 Linux PCI core 可见的配置空间层次和 BAR 路由，不实现真实 PCIe PHY、LTSSM、DLLP/TLP 或链路训练。香山使用 `pci-host-ecam-generic` 访问标准 ECAM，因此不需要仿真 Xilinx XDMA RP 私有寄存器。

当前 13 个 endpoint 是工程实现上由 bus range、ECAM slot 和 BAR route table 共同确定的上限，不是 PCIe 协议本身的极限。

## 2. 地址空间规划

### 2.1 香山侧地址

| 地址范围 | 作用 |
| --- | --- |
| `0x60000000-0x60ffffff` | 16MB generic ECAM window，Linux 用于枚举和配置 PCI function |
| `0x50000000-0x50ffffff` | 16MB PCI memory window，Linux 分配各 endpoint BAR0 和 bridge memory window |

ECAM 地址遵循标准公式：

```text
ECAM_BASE + (bus << 20) + (device << 15) + (function << 12) + register
```

ECAM 和 PCI memory window 是两类独立事务。前者访问 PCI configuration space；后者在枚举和 BAR 分配完成后访问设备运行时寄存器。

### 2.2 x86/FPGA host 控制窗口

| XDMA user offset | 作用 |
| --- | --- |
| `0x01000000/4KB` | proxy mailbox、BAR response、共享 INTx 和 13 项 BAR route table |
| `0x01001000/4KB` | 已退役的 SQE monitor 窗口；当前保留且不映射 |
| `0x01010000/128KB` | compact ECAM shadow BRAM |

ECAM shadow 实际保存 28 个 4KB function slot，共 112KB，BRAM aperture 向上取整为 128KB：2 个公共 bridge slot，加上 13 组 downstream port/endpoint slot。

### 2.3 XDMA EP bypass 窗口

| Bypass 地址 | FPGA 内部路径 |
| --- | --- |
| `0x000000000-0x0ffffffff` | raw DDR bypass，保留用于诊断 |
| `0x100000000-0x1ffffffff` | coherent alias，经 role DMA/coherency 入口访问 guest memory |

`axi_alias_attr_bridge.v` 对 alias 地址减去 `0x100000000`，并把 `AWCACHE/ARCACHE` 设置为 `4'hf`，随后将事务送入 `u_role/s_axi_dma`。QEMU 对 SQE/CQE 的访问以及 patch 给真实 NVMe 的 queue/data DMA 地址默认均使用 coherent alias。

## 3. QEMU Manager 与 Backend

### 3.1 软件入口

当前混合设备主线为：

```text
qemu-mount/hw/misc/scope_fpga_vswitch.c
QOM type: scope-fpga-vswitch
```

`scope-fpga-vswitch-nvme` 及其原文件继续保留为 NVMe-only 稳定回退入口。generic manager 通过统一 `ScopeBackendOps` 调用 backend 的 `realize`、`cleanup`、BAR packet 处理和非阻塞 poll：

```text
scope_fpga_vswitch.c                 ECAM、DMA32 ring、mailbox、route、aggregate INTx
scope_fpga_vswitch_nvme_backend.c    NVMe BAR/doorbell 的 backend 调度入口
scope_fpga_vswitch_igb_backend.c     82580 queue、descriptor、cause/mask、reset/link
scope_fpga_vswitch_vortex_backend.c  Vortex CP BAR、命令ring翻译和U280 bridge worker
```

QEMU manager 统一拥有：

- XDMA user/control/bypass fd；
- DMA32 cyclic ring 及其消费者状态；
- 128KB ECAM shadow 映射；
- FPGA mailbox 和全局锁；
- 一根 aggregate INTx 的软件 level；
- 启动时确定的 backend 数组。

每个 `ScopeBackend` 保存设备类型、ops、虚拟 BDF 和设备私有状态。NVMe/IGB backend 还保存真实 BDF 与真实 BAR0 映射；Vortex backend 保存 Unix socket 和虚拟/物理 CP queue 状态。NVMe 私有状态包含 namespace LBA shift、SQ/CQ、pending doorbell 和 Admin CID；IGB 私有状态包含 queue 0 的 guest/translated ring、相互独立的 TX/RX pending tail FIFO、virtual ICR/IMS 和 descriptor 统计。处理 BAR packet 时先按 BDF 选择 backend，再经 ops 分派，禁止跨设备复用状态。

### 3.2 Backend 配置

多设备使用严格 JSON 配置：

```json
{
  "version": 1,
  "devices": [
    { "type": "nvme", "real-host-bdf": "0000:af:00.0" },
    { "type": "igb",  "real-host-bdf": "0000:87:00.0" },
    { "type": "vortex", "bridge-socket": "/run/scope-vortex0.sock" }
  ]
}
```

`type` 缺省为 `nvme`，以兼容原配置。NVMe/IGB 使用 `real-host-bdf`；Vortex 必须使用绝对路径 `bridge-socket`，并禁止填写真实 BDF。启动属性为 `backend-config=/path/to/vswitch-backends.json`。兼容单 NVMe 入口 `real-host-bdf=0000:xx:yy.z` 仍保留，但不能和 `backend-config` 同时使用。设备数量和顺序只在启动时确定，不支持运行时热插拔。

所有真实 function 必须由 QEMU 独占。NVMe 初始化时开启 MEM/BUS_MASTER、映射 BAR0、写 `CC.EN=0` 并等待 `CSTS.RDY=0`。82580 在打开BAR前校验真实PCI ID必须为`8086:150e`，并要求同卡 `87:00.0..3` 全部从 host `igb` 解绑，随后屏蔽真实中断、停止 RX/TX 并执行受控 reset；guest 侧只暴露 BAR0 和 legacy INTA，不暴露 MSI/MSI-X/BAR3。任一 active backend 初始化失败会终止 manager 初始化，并清理已经打开的资源。

### 3.3 QEMU 是配置空间权威

QEMU 初始化固定的 28 个 compact ECAM slot：

- Root Port、Switch Upstream Port 和 active Downstream Port 使用 Type 1 config shadow；
- active NVMe endpoint 使用 QEMU PCI core 初始化 Type 0 config、PCIe capability 和 64-bit BAR0；
- active IGB endpoint 使用 `8086:150e`、class `020000`、32-bit 512KB BAR0 和 INTA 模板，隐藏 MSI/MSI-X 与 BAR3；
- active Vortex endpoint 使用 `1b36:1310`、class `120000` 和 32-bit 4KB BAR0；它没有真实 PCI config，配置由QEMU合成；
- inactive slot 保持全 `0xff`。

FPGA 不自行实现 PCI Command、Status W1C、BAR sizing、bus number 或 bridge window 规则。对于香山发来的 `CFG_WRITE`：

1. bridge function 按 QEMU 侧 `wmask/w1cmask` 更新；
2. endpoint 调用 `pci_default_write_config()`；
3. QEMU 把变化写回 ECAM shadow BRAM；
4. 如 BAR/Command 变化，QEMU先更新对应 BAR route；
5. 最后写 ACK，允许 FPGA 向香山返回 AXI B response。

这个顺序保证 config write 完成后，后续 ECAM read 能看到新配置和一致的 MMIO route。

### 3.4 DMA32 Ring

FPGA 的 `CFG_WRITE`、`BAR_READ`、`BAR_WRITE` 和 `BAR_WRITE_DONE` 使用固定 32B packet，经 XDMA C2H cyclic DMA 写入 host ring。vSwitch ABI 不再定义或消费 `SQE_WRITE_DONE`。

ring 默认大小为 64KB，可通过 `dma32-ring-size` 调整。消费者保存每个物理 slot 的 `type + seq`，并维护扫描 cursor，每轮只扫描有限 slot，避免多设备场景下高频全表轮询。需要恢复特定 one-shot 事件时，QEMU 可以按 `type + backend/BDF + seq + offset` 对整个 ring 做精确搜索。

## 4. FPGA 虚拟 PCIe 前端

### 4.1 `virtual_pcie_switch_proxy.v`

该模块替代仓库 11 中 DUT-facing XDMA RP 和单设备 `axilite_active_proxy` 的当前职责，主要接口为：

| 接口 | 作用 |
| --- | --- |
| `S_ECAM_AXI` | 接收香山对 `0x60000000` ECAM window 的访问 |
| `M_ECAM_SHADOW_AXI` | 从 dual-port BRAM 读取 compact ECAM shadow |
| `S_MMIO_AXI` | 接收香山对 `0x50000000` PCI memory window 的访问 |
| `S_MBX_AXI` | 接收 QEMU 的 ACK、BAR response、route 和 INTx 控制 |
| `M_AXIS_C2H` | 向 XDMA/QEMU发送 32B 事件 packet |
| `interrupt_out` | 向香山输出共享 level INTx |

ECAM read 命中支持的 BDF 时直接读取 shadow BRAM；未启用或未定义 BDF 返回 `0xffffffff` 和 AXI `OKAY`。ECAM write 缓存可独立到达的 AW/W，生成 `CFG_WRITE` packet，并在 QEMU 写回 shadow、返回相同 seq 的 ACK 后完成。

### 4.2 BAR Route Table

mailbox 从 `0x100` 开始保存 13 项 route，stride 为 `0x20`。每项包含：

```text
BAR base low/high
BAR size
virtual BDF
backend_id
valid / MEM-enable / 64-bit control
```

QEMU 更新 route 时先清 valid，再写各字段，最后置 valid，避免 FPGA 命中半更新状态。FPGA 对 13 项并行匹配：唯一命中时生成带 BDF/backend 信息的 BAR packet；无命中时 read 返回全 `1`、write no-op；多重命中返回 `SLVERR` 并记录 sticky route error。

当前 MMIO 状态机一次只允许一个 BAR transaction 等待 QEMU response，因此所有 backend 共用 seq/response mailbox，不需要复制 13 套 mailbox。

### 4.3 SQE 可见性

vSwitch 不再在 role DDR AXI 路径中插入 SQE monitor。QEMU 通过 coherent alias 对 Admin SQE 连续读取两次，只有两次内容一致并通过非零、旧 seed 和字段合理性检查后才 patch SQE 和转发真实 doorbell。暂不可见时按 100us deadline 重试，shared RX thread 不执行长时间 sleep。

旧 `scope-fpga-proxy` 仍保留其 `SQE_WRITE_DONE` ABI 和 monitor 兼容逻辑，用于旧 bitstream 回归；该兼容实现不属于当前 vSwitch 数据路径。

### 4.4 Intel 82580 Mediated Backend

82580 第一阶段固定为一个真实 function 对应一个虚拟 endpoint、单 TX queue、单 RX queue和BAR0-only。虚拟 config 不包含 MSI/MSI-X，因此仓库内 Linux `igb` 会进入 legacy fallback，并把 `rss_queues/num_tx_queues/num_rx_queues` 全部降为 1。

QEMU 对 queue 0 的 `TDBAL/H、TDLEN、RDBAL/H、RDLEN` 保存 guest shadow；这些寄存器按 Linux `igb` 实际使用的低地址 alias 匹配，即 RX `0x028xx`、TX `0x038xx`，不能混用 82580 另一个 `0x0c0xx/0x0e0xx` 队列窗口。ring base或length变化时会清除上一轮tail基线，避免接口reopen把`TDT/RDT=0`误判为旧ring回绕。guest 写 queue enable 后，才把完整 ring base 翻译为真实 coherent-alias DMA 地址并写入物理 82580。`TDT/RDT` 使用与 NVMe doorbell 相同的 early response：

```text
guest TDT/RDT
-> BAR_WRITE + request DONE
-> BAR_WRITE_DONE
-> coherent alias 两次稳定读取增量 descriptor
-> 按 descriptor type 翻译有效 buffer address
-> coherent alias 写回并 readback 验证
-> 最后更新真实 TDT/RDT
```

advanced TX context descriptor保持原样，data descriptor 的 `buffer_addr` 被翻译，因此 checksum/TSO 上下文格式不会被误改；TX timestamp request 被清除。RX 按 `SRRCTL.DESCTYPE` 解释 descriptor：Linux 默认的 `ADV_ONEBUF` 只翻译 `pkt_addr` 并保留第二个 write-back qword，只有 `HDR_SPLIT/HDR_SPLIT_ALWAYS` 才翻译非零 `hdr_addr`。未支持的类型设置 virtual `RXO`，且不向真实设备提交 RDT。

TDT和RDT分别进入独立的64项有序pending FIFO。每个方向内部保持tail顺序，manager poll每轮分别尝试一个TX队首和一个RX队首；一个方向等待`BAR_WRITE_DONE`或descriptor可见性时，不阻塞另一个方向。ring重配置、queue disable和受控reset只清理相应backend/方向的pending与tail基线。RSS 被强制为单队列，PTP 寄存器暂不参与正式接口。

真实 82580 的 PCI INTx 被禁用并保持 IMC mask；QEMU轮询真实 ICR和link状态，把 cause保存到virtual ICR/IMS。guest读取ICR按read-clear语义消费cause，各backend的pending做OR后驱动同一根aggregate INTx。guest写`CTRL.RST`不会无条件穿透：backend先停DMA并mask中断，等待真实reset完成，再清空自己的ring、tail和interrupt shadow。

### 4.5 Vortex U280 Mediated Backend

Vortex endpoint 暴露 4KB Command Processor BAR0。香山 `scope_vortex` PCI driver 通过 ioctl 提供32-bit CP寄存器访问，并用`dma_alloc_coherent()`建立guest command ring和host staging buffer。rootfs中的RISC-V静态程序把Vortex common runtime与vSwitch callback transport直接链接在同一个ELF中，因此原生`vecadd`主程序不需要理解QEMU协议，也不依赖guest中的`libvortex*.so`或动态C++运行库。

guest提交tail后，QEMU在worker线程中完成：

```text
读取coherent alias中的64B command line
-> 对MEM_WRITE/MEM_READ中的guest DMA PA建立U280 XRT host-only BO
-> 上传或记录下载目标，并把命令地址patch成U280 CP可见地址
-> 通过Unix socket RPC写物理CP ring并提交tail
-> 等待物理Q_SEQNUM完成
-> 对MEM_READ把BO内容写回guest coherent alias
-> 更新虚拟Q_SEQNUM/Q_ERROR
```

主机进程`scope-vortex-bridge`动态加载`libvortex-xrt.so`，负责U280 xclbin加载、CP寄存器访问和XRT host-memory BO生命周期。QEMU的共享RX线程不等待GPU执行；每个Vortex backend由独立worker处理长命令。第一阶段支持vecadd所需的memory、DCR、launch、fence和flush命令，不支持device event/profile命令，也不生成INTx。

### 4.6 Block Design

`shell/nm37_vu37p/fpga/scripts/xiangshan.tcl` 完成以下连接：

- `u_role/m_axi_io` 分别映射到 vSwitch ECAM 和 MMIO slave；
- dual-port BRAM 一端供 FPGA ECAM fast-path read，另一端供 QEMU host write；
- vSwitch C2H stream 经 register slice 和 clock converter 直接接到 `xdma_ep/S_AXIS_C2H_1`；
- `u_role/m_axi_mem` 经 DDR register slice 直接接入 DDR interconnect；
- vSwitch `interrupt_out` 接 `role_intr_concat/In1`；
- XDMA EP bypass 分成 raw DDR 和 coherent alias 两个分支；
- DUT-facing `xdma_rp` 不再属于当前 vSwitch bitstream。

## 5. 配置与 MMIO 控制流程

### 5.1 ECAM Read

```text
Linux pci-host-ecam-generic 发起 ECAM read
-> FPGA 解码 BDF 和 compact slot
-> M_ECAM_SHADOW_AXI 读取 BRAM dword
-> FPGA 直接返回 AXI R response
```

只有 `ECAM_SHADOW_READY=1` 后 FPGA 才开放 shadow read。该路径不经过 QEMU，因此 Linux 枚举期间的大量 config read 不需要 C2H 往返。

### 5.2 ECAM Write

```text
Linux ECAM write
-> FPGA CFG_WRITE packet
-> QEMU 按 PCI mask/W1C/BAR 语义更新 config
-> QEMU 写回 shadow 和 BAR route
-> QEMU ACK seq
-> FPGA 返回 AXI B response
```

### 5.3 BAR Read/Write

```text
Linux 访问 endpoint BAR0
-> FPGA 13 项 route table 唯一命中
-> BAR_READ/BAR_WRITE packet 携带 virtual BDF、BAR、offset、size、wstrb
-> QEMU 选择 backend 并处理 NVMe register/doorbell
-> QEMU 写 BAR response mailbox
-> FPGA 返回 AXI R/B response
```

`BAR_ROUTE_READY` 和 `ECAM_SHADOW_READY` 是两个独立 ready bit：前者表示 MMIO route table 可用，后者只表示配置空间 shadow 可读。

## 6. NVMe Queue 与数据路径

### 6.1 Admin Doorbell

1. 香山 NVMe 驱动把 SQE 写入 guest queue memory。
2. 香山写 endpoint SQ0 doorbell。
3. FPGA发送 `BAR_WRITE`；QEMU返回 early OK 并要求 `BAR_WRITE_DONE`。
4. FPGA向香山完成 AXI B handshake，并发送 `BAR_WRITE_DONE`。
5. QEMU通过 coherent alias 对新 SQE做两次立即稳定读取；若内容不一致、全零、仍是旧 seed 或字段不合理，则每 100us 按 deadline 重新检查，不阻塞其他 backend。
6. QEMU patch SQE/PRP，通过 coherent alias 写回并读回验证，然后把真实 SQ doorbell写入对应真实 NVMe BAR0。

多 backend 共享 ring 时，one-shot `BAR_WRITE_DONE` 可能已经落入未被常规 cursor 及时消费的物理 slot。pending doorbell 超过 `bar-done-timeout-us`（默认 5000us）后，QEMU先精确搜索整个 ring，再把 BAR completion 标记为 inferred。推断成立的依据是 early BAR response 已经写给 FPGA；真正写真实 NVMe doorbell之前仍必须通过 coherent-alias SQE 稳定读取。之后到达的同 seq/offset late DONE 会被忽略，避免污染下一条 pending doorbell。

### 6.2 PRP/PRP List 翻译

香山 SQE 中的 `metadata/PRP1/PRP2` 是 guest physical address，真实 NVMe不能直接使用。QEMU 在转发命令前：

1. 按 Admin opcode 或 `nsid + nlb + namespace LBA shift` 计算数据长度；
2. 把直接 `PRP1/PRP2` 翻译为 XDMA EP coherent alias DMA 地址；
3. 当 `PRP2` 指向 PRP list 时，通过 coherent alias 读取 list page；
4. 逐项翻译 data page entry 和 next-list pointer，并写回 list page；
5. 把 patch 后的 SQE 写回，再通知真实 NVMe。

QEMU 在 Identify Namespace 完成后解析 namespace 数据并记录实际 LBA shift，不固定假设 512B sector。该机制支持跨页 IO、文件系统格式化和 mount，同时不搬运用户数据。

### 6.3 CQE 与共享 INTx

真实 NVMe 把 CQE DMA 到 coherent alias，事务经 `u_role/s_axi_dma` 进入 guest CQ memory。QEMU 通过同一 alias 扫描 CQE，校验 phase、SQID、SQ head 和 outstanding CID，然后推进该 backend 的 CQ shadow tail。

每个 backend 独立计算 CQ pending 和 INT mask，manager 对所有 backend 做 OR：

```text
aggregate_intx = OR(backend[i].intx_pending)
```

任一 backend 仍有未消费 CQE 时，共享 `interrupt_out` 保持高电平。某个 endpoint 的 CQ doorbell、INTMS 或 `CC.EN=0` 只能更新自己的状态；只有 aggregate pending 变为零时，QEMU 才向 FPGA 写 INTx level 0。`intx-retry-pulse` 是默认关闭的调试属性，不属于正常中断语义。

## 7. Linux 与 Rootfs

### 7.1 Device Tree

`nanhu-g/software/dt/XSTop_vpcie.dts` 使用：

```text
compatible = "pci-host-ecam-generic"
ECAM reg    = 0x60000000 / 16MB
bus-range  = 0..15
PCI memory = 0x50000000 / 16MB
INTA-D     -> PLIC interrupt 2
```

Linux 使用标准 PCI core、NVMe driver 和内建 `igb` driver，不需要了解 QEMU backend BDF 或 coherent alias host 地址。Vortex endpoint由`drivers/misc/scope_vortex.c`绑定并生成`/dev/scope-vortexN`。仓库14的 RISC-V defconfig 已启用`CONFIG_IGB=y`和`CONFIG_SCOPE_VORTEX=y`，PTP clock仍关闭。

### 7.2 PCI 工具

rootfs 集成完整 pciutils `lspci` 和 `pci.ids`，安装为 `/usr/bin/lspci`，覆盖 BusyBox 同名简化 applet。常用检查包括：

```text
lspci -tv
lspci -nnvv
lspci -s 03:00.0 -vvxxx
lspci -k
```

使用`VORTEX_ENABLE=1`构建rootfs时，会安装`/bin/vortex-vecadd`、静态`/bin/vx-vecadd`、静态`/bin/scope-vortex-check`、`kernel.vxbin`和`/usr/lib/vortex/build-info`。非默认硬件配置通过`VORTEX_CONFIGS`传入，并必须与U280 xclbin使用的Vortex配置一致；wrapper先比较物理U280 capability和编译配置，再启动vecadd。该功能默认关闭，避免没有Vortex RV32工具链的普通rootfs构建被可选组件阻塞。

### 7.3 网络配置

rootfs 安装 BusyBox `udhcpc` 的默认事件脚本到`/usr/share/udhcpc/default.script`。脚本在`bound/renew`事件中配置IPv4地址、默认路由和DNS，在`deconfig`事件中移除旧IPv4地址并保持接口up。该脚本是DHCP控制面的必要组成部分；DHCP协议交换成功本身不会自动修改Linux接口地址。

标准启动顺序为：

```text
ip link set eth0 up
udhcpc -i eth0 -f -q
```

## 8. XDMA Host 驱动

`shell/software/xdma_drv/XDMA/linux-kernel/xdma` 为 QEMU manager 提供：

- XDMA user aperture，用于 mailbox 和 ECAM shadow；
- `XDMA_IOC_DMA32_DB_ALLOC` 等 ioctl，用于分配连续 DMA32 ring；
- C2H cyclic DMA 启停和 stale transfer 清理；
- bypass BAR 映射，用于 QEMU访问 coherent alias guest memory。

QEMU 异常退出、重新烧 bitstream 或 PCIe link 重建后，应确保旧 cyclic transfer 被停止，避免新 manager 继承失效 ring 状态。

## 9. 当前实现边界

当前静态实现支持：

- 启动时配置 `0..13` 个NVMe、82580或Vortex backend；
- generic ECAM 虚拟 switch 拓扑；
- QEMU 权威维护多 BDF config shadow；
- 每 endpoint 独立 BAR0 和设备私有状态；
- NVMe queue、PRP/PRP list、CQ 和 namespace LBA shift；
- 82580 queue 0 TX/RX ring、descriptor-type-aware DMA地址翻译、独立TX/RX pending、virtual ICR/IMS和受控reset；
- Vortex 4KB CP BAR、guest/physical command ring转换、U280 XRT bridge和vecadd rootfs入口；
- coherent alias P2P DMA；
- 共享 level INTx；
- PRP list 和 namespace LBA shift；
- BAR_DONE timeout recovery。

当前不实现：

- 真实 PCIe link training、TLP/DLLP；
- MSI/MSI-X、AER、hotplug 和完整 switch capability；
- 运行时增加/删除 backend；
- BAR0 之外的 endpoint BAR；
- 82580多队列、MSI/MSI-X、BAR3、VFIO eventfd和PTP；
- Vortex device event/profile命令、GPU fault interrupt和零拷贝guest-to-U280数据路径；
- 把一个真实 NVMe 控制器虚拟成多个隔离 controller；
- 完整 16MB ECAM RAM。

真实设备必须由 QEMU 独占。NVMe必须能够干净进入 `CSTS.RDY=0`；如果出现 `RDY=1/CFS=1`，应先恢复真实控制器状态。82580必须整卡四个function均从host驱动解绑。当前单队列路径已完成标准`igb`绑定、link/carrier、DHCP租约、IPv4配置和双向ping验证；长时间收发、吞吐、接口反复up/down及reset压力仍属于后续验收范围。

## 10. 关键文件

| 文件 | 作用 |
| --- | --- |
| `qemu-mount/hw/misc/scope_fpga_vswitch.c` | generic manager、ECAM、DMA32 ring、route和aggregate INTx |
| `qemu-mount/hw/misc/scope_fpga_vswitch_nvme_backend.c` | NVMe backend BAR/poll调度边界 |
| `qemu-mount/hw/misc/scope_fpga_vswitch_igb_backend.c` | 82580 BAR0、queue0、descriptor、cause/mask和reset逻辑 |
| `qemu-mount/hw/misc/scope_fpga_vswitch_vortex_backend.c` | Vortex虚拟CP、命令地址翻译和U280 worker |
| `qemu-mount/hw/misc/scope_vortex_bridge_proto.h` | QEMU与U280 bridge的固定RPC ABI |
| `qemu-mount/hw/misc/scope_fpga_vswitch_nvme.c` | 原NVMe-only稳定回退QOM |
| `qemu-mount/hw/misc/scope_fpga_vswitch_abi.h` | 带 BDF 的 32B packet ABI |
| `shell/nm37_vu37p/fpga/sources/hdl/recorder/virtual_pcie_switch_proxy.v` | ECAM/MMIO 前端、route table、mailbox 和 INTx |
| `shell/nm37_vu37p/fpga/sources/hdl/recorder/axi_alias_attr_bridge.v` | coherent alias 地址和 AXI cache 属性转换 |
| `shell/nm37_vu37p/fpga/scripts/xiangshan.tcl` | Vivado BD 连接与地址段 |
| `nanhu-g/software/dt/XSTop_vpcie.dts` | generic ECAM host bridge Device Tree |
| `work_farm/software/linux/drivers/misc/scope_vortex.c` | 香山Vortex PCI transport和coherent DMA UAPI |
| `nanhu-g/software/rootfs/apps/scripts/vortex-vecadd` | Vortex runtime、kernel和vecadd的可选rootfs集成 |
| `nanhu-g/software/rootfs/files/usr/share/udhcpc/default.script` | DHCP租约的IPv4地址、路由和DNS安装脚本 |
| `shell/software/xdma_drv/XDMA/linux-kernel/xdma` | DMA32 cyclic ring 和 XDMA host access |
| `doc/VSWITCH_REGISTER_INTERFACE_SPEC.md` | mailbox、route、ECAM shadow 与 packet ABI 接口合同 |
| `doc/VSWITCH_NIC_INTEGRATION_STUDY.md` | 82580 mediated backend技术依据、实现约束和验证状态 |

仓库 11 的 `scope_fpga_proxy.c`、`axilite_active_proxy.v`、`XSTop_pci.dts` 和 DUT-facing XDMA RP 路径仍可作为单设备兼容基线，但不再是仓库 14 vSwitch bitstream 的当前主线。
