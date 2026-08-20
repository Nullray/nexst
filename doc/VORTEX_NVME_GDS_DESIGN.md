# Vortex 从 NVMe 直接取数（GDS-like）设计方案

## 1. 目标、术语与结论

本文分析如何在当前 vSwitch/QEMU/Vortex 框架中实现类似 GPU Direct
Storage（GDS）的效果：数据从主机侧真实 NVMe 直接 DMA 到 U280 HBM，香山和
x86 CPU 只负责控制，不搬运 payload。

本文中的“GPU”是 U280 上的 Vortex，不表示 NVIDIA GPU。架构判断依据 NVIDIA
GDS Design/Overview 文档、NVM Express PCIe transport 规范以及 Linux 上游
`nvme-pci` 实现：GDS 保留 CPU 管理的标准 NVMe SQ/CQ 和 doorbell，改变的是
SQE 中 PRP/SGL 所指向的 data buffer。本文首先实现这一关键语义；文件系统与
`cuFile`-like API 在同一条一跳数据通路之上扩展。

结论如下：

1. 框架可以实现一跳的 `NVMe -> U280 P2P BAR -> HBM[0]` PCIe P2P 数据通路。
2. 不把 NVMe SQ/CQ 或 doorbell 移到 Vortex。香山/QEMU 继续承担 CPU control
   path，真实 NVMe 继续执行标准 SQ fetch、data DMA、CQE write 和 doorbell
   协议。
3. NVMe 不是一段可供 Vortex 直接读取的 BAR 空间。READ 命令的 PRP/SGL 必须
   指向映射 HBM 的 U280 P2P BAR，由 NVMe 作为 PCIe Requester 发起 Memory
   Write。这才是 GDS 的核心数据面。
4. 当前 NVMe 后端已经能够改写 PRP，并已验证 `NVMe -> NM37 BAR2 -> 香山 DDR`
   的 P2P；复用的是命令提交、队列管理和地址校验，不复用该 payload 路径。
5. 当前 Vortex direct-P2P 证明的是相反方向的能力：U280 CP 作为 Requester
   访问 NM37 BAR2。它不能单独证明 NVMe 能向 U280 HBM 写入。
6. 本地 XRT 2.16 源码已有 P2P BAR、Resizable BAR、HBM bank remapper 和
   `XCL_BO_FLAGS_P2P` 支持，因此一跳方案有软件基础；但必须先使正确的 U280
   user PF/P2P BAR 可用，并确认它映射到当前 xclbin 使用的 HBM[0]。
7. 本设计只实现 `direct-p2p`。不存在 NM37 payload staging、CPU memcpy 或
   silent fallback；前置条件不满足时启动失败。

## 2. 当前实现具备什么

### 2.1 NVMe 到香山 DDR 的现有路径

真实 NVMe 的 BAR/doorbell 由 QEMU 后端控制。香山提交 NVMe 命令后，QEMU 在
`qemu-mount/hw/misc/scope_fpga_vswitch.c` 中处理地址：

- `scope_translate_guest_pa_for_real_dma()` 把 guest PA 翻译为
  `NM37 BAR2 base + coherent alias + guest PA`；
- `scope_patch_prps_for_real_dma()` 处理 PRP1、PRP2；
- `scope_patch_prp_list()` 逐项改写多页数据的 PRP list；
- ASQ、ACQ、I/O SQ 和 I/O CQ 也使用相同的 NM37 coherent alias；
- QEMU 最终转发真实 NVMe doorbell，payload 由 NVMe 通过 PCIe P2P 搬运，
  不通过 XDMA H2C/C2H，也不经过 CPU memcpy。

现有数据方向为：

```text
NVMe READ：
真实 NVMe（PCIe Requester）
  -> PCIe MWr
  -> NM37 BAR2 coherent alias（PCIe Completer）
  -> M_AXI_BYPASS
  -> 香山 DDR
```

这已经解决了 NVMe 命令识别、真实队列提交、PRP 翻译和完成转发问题。GDS
不需要重做整个 NVMe 虚拟化，只需要增加另一种受控的数据目标。

### 2.2 调查报告对本框架的架构校准

标准 GDS 没有取消 NVMe SQ/CQ，也没有让 GPU kernel 直接敲 NVMe doorbell。
典型本地 NVMe GDS 中，各对象的角色如下：

| 对象 | 标准 GDS 的典型位置/操作者 | 本框架的对应实现 |
|---|---|---|
| NVMe SQ/CQ | host-addressable memory，CPU/NVMe driver 管理 | 香山 DDR 的 coherent alias，香山/QEMU 管理 |
| doorbell | CPU 写 NVMe BAR MMIO | QEMU 转发到真实 NVMe BAR |
| SQE/PRP/SGL | CPU storage stack 构造 | 香山提交，QEMU 保存、改写并在完成后恢复 |
| data buffer | GPU VRAM/peer memory | U280 HBM[0] P2P BO |
| payload DMA | NVMe DMA engine | NVMe PCIe MWr/MRd 直达 U280 P2P BAR |

SQ/CQ 在本框架中不是普通 x86 system DRAM，而是 NVMe 可寻址的 NM37 coherent
memory；这与 NVIDIA 的典型部署位置不同，但仍保持标准 NVMe control/data
分离语义。SQ/CQ、PRP list 和 CQE 可以经过 NM37，payload 不可以经过 NM37。

附件还区分了传统 `nvidia-fs` 和 Linux upstream PCI P2PDMA 两种实现。它们
解决的是“storage driver 如何获得 GPU peer DMA address”，不会改变 NVMe
SQ/CQ 协议。当前真实 NVMe 已由 QEMU backend 独占和控制，因此本设计选择：

- 不把真实 NVMe 迁回 host Linux `nvme-pci` driver；
- 不在 Vortex 上实现 GPU-resident SQ/CQ；
- 由本地 xocl 可信导出 U280 P2P BO 的 bus address；
- 由 QEMU 为真实 NVMe 生成指向该地址的 PRP/SGL。

这与标准 GDS 的 CPU control path、storage DMA data path 一致，同时保留当前
vSwitch 的设备虚拟化结构。若以后迁移到 Linux upstream `pci_p2pdma`，那是控制
实现替换，不是本次一跳数据通路的前提。

### 2.3 Vortex 的现有 direct-P2P 路径

`qemu-mount/hw/misc/scope_fpga_vswitch_vortex_backend.c` 当前把 U280 XRT
Address Translator 划分为 control window 和动态 NM37 peer window。QEMU 只
改写 Vortex `MEM_WRITE/MEM_READ` 的 host operand：

```text
MEM_WRITE：U280 PCIe MRd NM37 DDR，然后写入 HBM
MEM_READ ：从 HBM 读取，然后 U280 PCIe MWr NM37 DDR
```

此处 U280 是 Requester，NM37 BAR2 是 Completer。GDS READ 则需要 NVMe 是
Requester、U280 是 Completer，二者不是同一种映射：

| 功能 | Requester | PCIe 目标 | XRT 机制 |
|---|---|---|---|
| 当前 Vortex direct-P2P | U280 CP | NM37 BAR2 | HOST[0] outbound translator |
| 目标 GDS READ | NVMe | U280 P2P BAR/HBM | inbound P2P BAR remapper |

所以现有 `vortex_peer_mode` 不能直接代替 GDS 所需的 P2P BAR，但两种机制可以
在设计上共存。是否能在当前 shell/xclbin 上同时启用，必须用真实硬件验证。

### 2.4 本地 XRT 已有的 P2P 基础

`/home/yanjiarun/XRT-2.16-u280` 中已经存在以下能力：

- `XCL_BO_FLAGS_P2P` / `xrt::bo::flags::p2p`；
- `xocl/subdev/p2p.c` 中的 P2P BAR 映射、remap slot、Resizable BAR 与
  `MEMORY_DEVICE_PCI_P2PDMA`；
- `xocl_p2p_mem_map()` 把 device bank 地址映射到 P2P BAR offset；
- `xocl_p2p_get_bar_paddr()` 查询映射后的 BAR 总线物理地址；
- U280 board 配置的 `p2p_bar_sz` 为 64 GiB。

这些代码说明 U280 平台类别具备把 HBM 暴露为 PCIe peer memory 的设计入口，
不等于当前设备已经启用该能力。

### 2.5 当前机器状态与强制启动条件

当前板级实现使用的 PCIe 枚举结果是：

```text
0000:2a:00.0  Xilinx 10ee:903f        NM37，driver=xdma
0000:ab:00.0  Xilinx 10ee:500c        U280 management PF，driver=xclmgmt
0000:ab:00.1  Xilinx 10ee:500d        U280 user PF，driver=xocl
0000:e1:00.0  Intel 8086:0a54         NVMe，driver=nvme（准备数据时）
```

U280 已恢复为正确 deployment shell 的双 PF 形态。GDS 启动脚本要求 user PF
绑定 `/home/yanjiarun/xrt-u280-2.16` 中的本地 `xocl`，并同时启用 64 MiB
HOST control window、64 MiB NM37 outbound peer window和映射 HBM[0] 的 512 MiB
inbound P2P BAR。当前正在运行的旧 `xocl` 与新 GDS 模块 `srcversion` 不同时，
脚本会拒绝继续；必须先停止 XRT 用户并由管理员显式卸载旧模块，脚本不会替用户
强制解绑。

此外，从 `lspci -t` 看 NM37、U280 和 NVMe 位于不同 root-port 分支。现有
NVMe->NM37 和本设计的 NVMe->U280 HBM 均已完成板级验证，说明当前主机平台
允许这两组跨分支 P2P。该结论只适用于当前服务器、固件和 PCIe 拓扑；更换插槽、
BIOS/IOMMU 配置或服务器后仍须重新验证，不能仅由设备类型自动推出。

GDS 板级实验固定使用 `0000:e1:00.0` 作为真实 NVMe，当前对应
`/dev/nvme0n1`、Intel P4510（序列号 `PHLJ3252006F1P0UGN`）、namespace 1、
4 KiB LBA。检查时该 namespace 没有挂载点、分区、swap、LVM、MD 或 sysfs
holder。设备节点编号可能在重启后变化，因此配置和 allowlist 必须以 BDF 或
序列号识别，不能依赖 `/dev/nvme0n1`。首次写入测试数据前仍须用 root 权限检查
`fuser`、`fdisk -l` 和 `wipefs -n`，并只使用明确保留的测试 LBA，不能把“未挂载”
等同于“盘内没有需要保留的数据”。

### 2.6 当前 GDS 测试实现状态

一跳 READ 原型已经贯通所有软件层，当前实现包括：

- 本地 xocl 的受控 P2P BO 查询 ioctl；
- Vortex XRT backend callback v3 和 Bridge `GDS_CAPS/ALLOC/FREE` RPC；
- QEMU 中 NVMe/Vortex 联合 GDS 状态机、PRP 改写、CQE 关联和恢复；
- `/dev/scope-vortex0` 上的 GDS query/alloc/arm/wait/release/free UAPI；
- Vortex runtime 的 `vx_gds_*` API 和 pre-launch cache flush；
- `vortex-gds_read` 4 KiB 块级读取/checksum 测试；
- GDS 专用 backend JSON 和 fail-closed 启动检查。

当前 single-bank guest 镜像构建：

```text
vecadd sgemm conv3 multikernel bfs sort gds_read
```

`vortex-run-all` 仍只执行非 GDS 回归。GDS 必须显式运行并提供保留测试 LBA 和
预期 checksum，避免普通 NVMe READ 被隐式改写。当前原型限制为一个 HBM0 P2P
buffer、一个 in-flight NVM READ、PRP 模式以及恰好 4096 字节；多队列、并发、
SGL、NVM WRITE 和文件 extent API 尚未实现。代码、镜像和真实
`NVMe -> U280 HBM` 板级链路已经通过验收：受控 NVMe READ 直接写入 U280
HBM，Vortex kernel 在 HBM 内计算校验和，日志中的 CPU/NM37 payload 字节均为 0。

## 3. 最终数据通路

### 3.1 控制与数据分离

控制通路保持 mediated：

```text
香山应用/驱动
  -> 虚拟 NVMe 或 GDS 控制接口
  -> QEMU vSwitch
  -> 真实 NVMe SQ/doorbell
```

读取数据通路改为一跳 P2P：

```text
真实 NVMe READ
  -> NVMe PCIe MWr
  -> U280 user PF P2P BAR
  -> XRT/shell P2P remapper
  -> HBM[0] 中的 GDS buffer
  -> Vortex kernel
```

完成通路可以继续使用 NM37 DDR：

```text
NVMe CQE
  -> NM37 BAR2 coherent alias
  -> 香山 DDR 中的 CQ
  -> QEMU/guest 得知完成
  -> cache/visibility 处理
  -> 启动 Vortex kernel
```

因此队列和数据不必位于同一种内存中：ASQ/ACQ、I/O SQ/CQ、PRP list
metadata 可以留在 NM37 DDR，只有 PRP data entries 指向 U280 P2P BAR。

NVMe WRITE 可以支持相反的数据方向：

```text
U280 HBM
  <- U280 P2P BAR 收到 NVMe PCIe MRd
  <- 真实 NVMe WRITE
  -> SSD media
```

一跳原型先用 NVM READ 验证 `NVMe -> HBM`，但接口、ownership 和地址模型从
原型开始就按双向设计；最终实现再开放 NVM WRITE。READ 和 WRITE 都不得引入
NM37 payload staging。

### 3.2 地址模型

不能让香山或普通 QEMU 配置直接提交任意 host PCIe 物理地址。Bridge/XRT 应
创建一个受控 GDS buffer，并返回以下信息：

```text
handle             不透明 buffer 标识
hbm_device_addr    Vortex 使用的 HBM 地址
p2p_bus_addr       NVMe PRP 使用的 U280 BAR 总线地址
size               可访问长度
generation         映射代次，防止 reset 后使用旧地址
```

内部关系为：

```text
p2p_bus_addr = pci_resource_start(u280_p2p_bar) + p2p_bar_offset
hbm_device_addr = HBM[0] bank base + buffer offset
```

`p2p_bus_addr` 只能由 xocl 根据已打开的 U280、P2P BO 和 BAR resource 计算。
用户请求只携带 `handle + offset + length`；驱动和 QEMU共同校验：

- owner fd、U280 BDF、xclbin UUID 与 generation；
- buffer 是否属于 HBM[0] 且以 `XCL_BO_FLAGS_P2P` 分配；
- offset/length 是否溢出，是否符合 NVMe page/PRP 对齐；
- 操作方向是否允许，映射是否仍处于 active 状态；
- NVMe BDF 是否在 allowlist 中。

当前 Vortex 单-bank xclbin连接 `m_axi_mem_0 -> HBM[0]`，容量 256 MiB。一跳
原型在 HBM[0] 预留固定 GDS arena，避免普通 `vx_mem_alloc()` 与 GDS BO 重叠；
最终实现将 P2P BO 纳入统一 allocator。二者使用相同的 U280 P2P BAR 数据路径，
原型不是临时 staging 方案。

### 3.3 PRP 组织

一跳原型只支持 PRP，并限制为 NVM READ；最终实现在同一 descriptor builder 中
增加 SGL 和 NVM WRITE：

- PRP1 可含页内 offset；
- 后续数据页必须按 controller page size 对齐；
- 单页使用 PRP1，两页使用 PRP1+PRP2，多页使用 PRP list；
- PRP list 页面自身保留在 NM37 DDR，便于 NVMe 通过现有路径读取；
- PRP list 中的数据条目指向连续或分段的 U280 P2P BAR 地址；
- MPTR、metadata 和 completion queue 不自动改到 HBM。

现有硬件合同没有另一块同时对香山、QEMU 和真实 NVMe 可见的 shadow control
pool，因此当前原型采用“保存、原位改写、完成后恢复”的等价做法：

1. guest 只通过 GDS UAPI 提交 handle/generation/offset，不接触 bus address；
2. QEMU 精确匹配下一条 NVM READ 的 NSID、SLBA 和长度；
3. 提交真实 doorbell 前保存原始 SQE 和所有涉及的 PRP-list page；
4. 只把 data PRP entry 改成受控 U280 P2P BO 地址；PRP-list page本身、SQ/CQ
   和 CQE 仍使用 NM37 coherent alias；
5. QEMU 以 qid/cid 关联 CQE，在发布 `GPU_READY` 前恢复原始 SQE/list；
6. reset、teardown 或改写失败也恢复保存的 descriptor；恢复失败进入
   `FAILED`，不能静默重试或走普通路径。

该方案会由 CPU 读写少量 SQE/PRP metadata，但不会读取、写入或中转 payload，
所以日志仍必须为 `payload_cpu_bytes=0 payload_nm37_bytes=0`。单 buffer、单
in-flight 的限制保证 descriptor 不会在恢复前被复用；扩展并发时再引入独立
shadow control pool，数据通路不变。

## 4. 软件修改范围

### 4.1 本地 XRT/xocl

实现复用 XRT 原生 P2P BO 和 P2P BAR remapper，没有重新设计硬件窗口。新增的
私有 xocl ioctl 只查询一个已由同一 DRM file owner 创建的 BO：

```text
VORTEX_GDS_BO_QUERY(gem_handle)
  -> flags, hbm_device_addr, p2p_bus_addr, size
```

实现要点：

- XRT backend 在 HBM[0] 的 `0x0f000000` 位置保留 16 MiB GDS arena，BO 使用
  `XCL_BO_FLAGS_P2P | mem_index(HBM[0])`；前面的 device-only guard BO 防止普通
  Vortex allocator 与该固定 arena 重叠；
- ioctl 从 GEM handle 反查同 owner、同 device 的 BO，要求 `CAP_SYS_RAWIO`、
  P2P flag、HBM[0] topology 和合法范围；
- 内核通过 P2P subdevice 的 `bar_offset_to_paddr()` 计算 bus address，不接受
  用户传入的绝对地址；
- XRT backend/Bridge 分别维护不透明 handle 和递增 generation，连接关闭时
  释放 BO；QEMU 在 `NVME_INFLIGHT` 状态拒绝 free；
- outbound Address Translator generation 与 inbound P2P BO generation 分开，
  不混用。

若 XRT 原生 API 已能稳定返回 P2P BO 的总线地址，则只需在 Bridge 层封装；
若公共 API 不暴露该地址，才增加最小的 xocl ioctl。不要通过解析 sysfs 后让
QEMU 自行拼接任意地址。

Linux upstream `nvme-pci` + `pci_p2pdma` 是附件所述的标准实现之一，但它要求
真实 NVMe 重新绑定内核 driver，并把当前 QEMU BAR/queue 直控模式改造成内核
I/O 请求接口。本项目的最终实现不选择这条路线：QEMU 继续承担 CPU control
path，xocl 只提供可信 peer mapping。这样不会改变最终 payload 是否一跳直达
HBM；未来若迁移到 upstream P2PDMA，可替换控制层而保留 GDS buffer ABI。

### 4.2 Vortex runtime 与 Bridge

在现有 peer RPC 旁新增 callback ABI v3 和 GDS RPC，不复用 `PEER_MAP`：前者
导出 U280 入站 BAR，后者把 NM37 BAR 映射到 U280 出站 HOST window，方向不同。

当前 RPC 为：

```text
GDS_CAPS
GDS_ALLOC
GDS_FREE
```

Bridge 负责：

- 独占 U280/xclbin 并创建 HBM[0] P2P BO；
- 维护 handle、generation 和 owner；NVMe in-flight 状态由联合状态机维护；
- 只有 QEMU 先用 allowlist 中的 NVMe BDF 完成 `GDS_CAPS` 授权，Bridge 才接受
  `GDS_ALLOC`；
- 断连时停止接收新命令并回收仍登记的 BO；
- 提供 `hbm_device_addr` 给 Vortex launch 参数，不复制 payload；
- 日志记录 `payload_cpu_bytes=0`。

Vortex runtime 需要让 kernel 直接使用该 BO 的 device address。一跳原型可把
GDS arena 与普通 allocator 分开；最终实现再把它纳入统一 device buffer
allocator，P2P 数据通路保持不变。

### 4.3 QEMU/vSwitch

当前 NVMe 和 Vortex backend 之间通过 manager 内唯一的 `ScopeGdsState` 建立
受控关联：

```text
ScopeGdsState
  key: handle + generation
  owner: one Vortex backend/session
  target: U280 BDF/BAR
  range: p2p_bus_addr + size
  match: NVMe backend + NSID + SLBA + bytes + qid/cid
  state: DISABLED/IDLE/GPU_OWNED/ARMED/NVME_INFLIGHT/GPU_READY/FAILED
```

JSON 通过 Vortex backend 的 `gds-nvme-bdf` 显式把两个 backend 配对；缺少该字段
时 GDS 关闭，普通 direct-P2P Vortex 功能不受影响：

```json
{
  "version": 1,
  "devices": [
    { "type": "nvme", "real-host-bdf": "0000:e1:00.0" },
    {
      "type": "vortex",
      "bridge-socket": "/run/scope-vortex0.sock",
      "data-path": "direct-p2p",
      "gds-nvme-bdf": "0000:e1:00.0"
    }
  ]
}
```

配置只接受 `direct-p2p`。U280 P2P BAR、mapping、PRP 构造或 completion 任一
环节失败都必须向 guest 返回错误；禁止 CPU memcpy、NM37 payload staging 和
任何 silent fallback。

`"enabled": true` 只是允许建立 GDS capability 和 registry，不是“把所有
NVMe READ 自动改成 GDS”的开关。普通 NVMe READ 和 GDS READ 的 opcode 相同，
不能根据 opcode、长度或目标应用名称猜测数据路径；只有 guest 通过专用 GDS
UAPI 提交有效的 `handle + generation + offset` 时，QEMU 才能把该请求的
data PRP 临时改写为 U280 P2P BAR 地址。

QEMU 的当前核心改动为：

1. 增加 GDS buffer handle 到 U280 P2P bus address 的可信解析；
2. NVM READ 只改写 data PRP，队列/list/metadata/completion 继续翻译到 NM37；
3. 保存并原位改写 SQE/PRP list，CQE 或 teardown 后恢复，bus address不暴露给
   guest；
4. 用 `(backend, qid, cid, generation)` 关联真实 CQE 与 GDS buffer；
5. CQE 成功且 descriptor 恢复后用 memory barrier 发布 `GPU_READY`；guest
   runtime 随后提交同步 cache flush，再 launch kernel；
6. CQE 错误、timeout、Bridge 断开、U280 reset 时设置 buffer 为 `FAILED`，
   让香山退出等待；
7. 日志同时报告 NVMe 数据长度和 CPU 搬运字节数。

当前关键日志格式：

```text
[SCOPE GDS] op=READ qid=1 cid=7 lba=... bytes=1048576
  target=U280_HBM handle=3 generation=12
  hbm_addr=... p2p_bus_addr=... payload_cpu_bytes=0
```

### 4.4 香山 guest 接口

一跳原型不修改通用 Linux page cache，也不让 stock NVMe driver 接受任意 GPU
物理地址。GDS ioctl 扩展在现有独占设备 `/dev/scope-vortex0` 上；runtime 对外
提供：

```c
vx_gds_query(device, &caps);
vx_gds_alloc(device, size, &buffer);
vx_gds_arm_read(device, &buffer, &read);
pread(virtual_nvme, dummy_guest_buffer, size, byte_offset);
vx_gds_wait(device, &buffer, &read);
vx_device_cache_flush(device);
vx_start(kernel, buffer.hbm_addr);
vx_gds_release_read(device, &buffer, read.token);
vx_gds_free(device, &buffer);
```

`arm_read` 把 NSID、LBA、长度、handle、generation 和 offset 写入 Vortex 虚拟
BAR 中的 GDS 寄存器。随后对虚拟 NVMe 发出的普通 `pread(O_DIRECT)` 只承担一次
标准 NVMe 请求的提交与 completion；它的 dummy guest buffer不会收到 payload，
因为 QEMU 只在所有字段精确匹配时把该 READ 的 data PRP 改到 U280。接口逐层检查
块大小、对齐、长度、越界、owner、generation 和状态。

路径选择必须由接口类型和 buffer 身份显式决定：

```text
普通 NVMe READ：
  stock NVMe 请求 + guest PRP
  -> 现有 guest-PA-to-NM37 coherent alias 翻译
  -> payload 写入香山 DDR

GDS READ：
  /dev/scope-vortex0 GDS ioctl + 有效 GDS handle/generation/offset
  -> GDS registry 解析
  -> 临时改写的 data PRP 指向 U280 P2P BAR
  -> payload 写入 U280 HBM
```

因此，普通文件/块设备读取、现有 NVMe 回归以及
`vortex-vecadd/sgemm/conv3/multikernel/bfs/sort` 都不触发 GDS。后几项即使使用
当前 Vortex direct-P2P，也只是 U280 与 NM37 DDR 之间的 Vortex
`MEM_WRITE/MEM_READ`，没有提交 NVMe GDS handle。若应用明确调用 GDS UAPI，
但 GDS 未启用、handle 无效或 P2P 前置条件失败，接口必须返回错误，禁止按普通
NVMe 请求处理或静默回退到 NM37 staging。

这一级实现的是“块设备 LBA 直达 HBM”。要支持普通文件路径，还需要增加：

- filesystem extent 到 LBA 的稳定映射；
- direct-I/O 对齐、稀疏文件和 CoW 处理；
- page cache 绕过与一致性；
- 异步请求、取消、错误恢复；
- 类似 `cuFile` 的用户 API。

上述块级 LBA API 完成后即可提供真正的一跳 GDS 数据面，但仍不是完整的文件级
GDS API。后续可在相同 buffer、descriptor 和 completion ABI 上增加文件
extent/direct-I/O 层，不改变 NVMe 到 HBM 的数据通路。

## 5. 顺序、一致性与生命周期

### 5.1 NVMe completion 与 HBM 可见性

标准 NVMe SQ/CQ completion 仍是本设计的数据传输完成边界。成功 CQE 表示
controller 已完成该命令的数据传输；GDS 不需要额外的数据搬运命令。Vortex
运行前仍需明确处理两类问题：

1. PCIe posted write 的平台可见性；
2. Vortex/HBM 访问路径中可能存在的旧 cache line。

实现要求：

- NVMe 请求不能设置未经验证的 Relaxed Ordering/No Snoop 组合；
- 以真实 CQE 成功作为 NVMe data DMA 完成边界；
- QEMU 按 NVMe CQ phase/tag 消费 CQE，并在发布 `GPU_READY` 前执行必要的
  completion memory ordering；
- 完成 XRT/P2P ownership sync，并在 Vortex 获得 buffer 前执行与当前 cache
  结构匹配的 invalidate/flush；
- ownership sync 和 cache invalidate 完成前禁止启动读取该 buffer 的 kernel。

当前 Vortex 已有 `CMD_CACHE_FLUSH`：CP 对所有 core 发起
`VX_DCR_BASE_CACHE_FLUSH`，并在最后一个 core 的 cache flush 完成后才退休；
`VX_cache_flush.sv` 会等待 cache pipeline/MSHR 排空并使 cache line 失效。因此
GDS READ 的命令顺序必须是：

```text
NVMe CQE success
  -> XRT/P2P ownership sync
  -> CMD_CACHE_FLUSH（等待退休）
  -> CMD_LAUNCH
  -> 既有的 post-launch CMD_CACHE_FLUSH
```

现有 `Device::cp_submit_launch()` 自动添加的是 post-launch flush，用于让 kernel
结果对 host/后续步骤可见；它发生得太晚，不能代替 GDS 所需的 pre-launch
invalidate。runtime 应增加一个明确的 GDS acquire 操作，在 launch 入队前提交并
等待 pre-launch `CMD_CACHE_FLUSH`。当前 RTL 已有这项能力，只有覆盖测试发现某级
cache 未参与 flush 时才需要补 RTL。

不增加 U280 P2P BAR readback，也不复用当前 Vortex `MEM_READ` readback fence：
后者属于 U280 Requester 的出站命令，不能替代 NVMe Requester 的标准 command
completion。若某个平台必须依赖超出 NVMe/XRT 语义的私有 readback 才能正确，
则该平台不满足本设计的 direct-P2P 支持条件，应在启动或压力测试时失败，而不把
未经证明的 readback 当成通用协议。

### 5.2 Buffer ownership

当前 QEMU/guest 联合状态机为：

```text
FREE
  -> IDLE
  -> GPU_OWNED
  -> ARMED
  -> NVME_INFLIGHT
  -> GPU_READY
  -> GPU_OWNED
```

任一阶段发生 reset、timeout、AER、CQE error 或 generation 不匹配，都转到
`FAILED`。`GPU_READY` 只表示真实 NVMe CQE 成功且 descriptor 已恢复；runtime
必须在 Vortex launch 前同步执行 `CMD_CACHE_FLUSH`。处于 `NVME_INFLIGHT` 的
buffer不允许释放或重映射；只有持有同一 device fd、handle 和 generation 的
owner可以转换状态。

### 5.3 Reset 与错误传播

生命周期至少关联以下对象：

- Bridge connection/owner fd；
- U280 user PF 与 xclbin UUID；
- XRT P2P BO 和 BAR mapping generation；
- NVMe controller reset generation；
- QEMU backend/qid/cid。

U280 reset、xclbin reload、NVMe reset 或 Bridge 断开时，QEMU 必须让 guest 请求
得到明确错误，不能永久等待。只有所有 in-flight DMA 已结束或已由设备 reset
终止后才能释放 P2P BO。

## 6. 直接一跳实施方案

### 6.1 原型从第一笔 payload 就使用最终数据通路

第一个可运行原型就必须完成下面这条真实路径：

```text
香山/QEMU 构造并提交标准 NVMe READ
  -> NVMe fetch SQE/PRP
  -> NVMe PCIe MWr U280 P2P BAR
  -> XRT P2P remapper
  -> HBM[0] P2P BO
  -> NVMe 写 CQE 到 NM37 control memory
  -> QEMU/guest 处理 completion
  -> Vortex cache invalidate
  -> Vortex kernel 直接读取同一个 HBM buffer
```

原型可以先限制为单 NVMe queue、单 P2P BO、单个 in-flight READ 和 PRP 模式，
但不能改变任何一段 payload 路径。由原型扩展到最终实现时，只增加并发、
descriptor 类型和文件 API，不替换数据通路。

一次原型请求的完整动作固定为：

1. Bridge 用本地 XRT 打开 U280、加载目标 xclbin，并在 HBM[0] 分配页对齐 P2P
   BO；
2. xocl 返回 BO handle、HBM device address、P2P BAR bus address、长度和
   generation；
3. QEMU 把该对象登记到跨 NVMe/Vortex backend 的 GDS registry；
4. 香山提交 `namespace + LBA + length + handle + offset`；
5. QEMU 保存并改写这一个请求的 SQE/PRP list，data PRP 只指向已登记的 U280
   P2P BAR 范围，SQ、PRP-list page 和 CQ 仍位于 NM37 control memory；
6. QEMU 更新真实 NVMe SQ tail doorbell；
7. NVMe 直接把 payload 写入 HBM，并将 CQE 写到 NM37 CQ；
8. QEMU 校验 CQE、qid/cid/generation，恢复 descriptor 并发布 `GPU_READY`；
9. runtime 执行 Vortex cache flush，Vortex kernel 再使用
   `hbm_device_addr + offset` 计算 SSD 已知 pattern 的 checksum；
10. 日志和计数器证明 `payload_cpu_bytes=0`、`payload_nm37_bytes=0`。

任何一步失败都结束该请求并向 guest 返回错误，不调用
`scope_guest_mem_read/write()` 搬 payload，也不生成 Vortex `MEM_WRITE` staging
命令。

### 6.2 强制启动门槛

下面是 direct-P2P 实现的运行前校验，不是独立开发阶段，也不产生替代路径：

- U280 必须枚举为正确的 XRT user PF，并绑定本地 `xocl`；
- xclbin UUID、Vortex capability 与 HBM[0] memory topology 必须匹配；
- U280 P2P/Resizable BAR 已分配且覆盖所需 P2P BO；
- `p2p_enable` 和 `XCL_BO_FLAGS_P2P` 分配成功；
- NVMe 到 U280 BAR 的 PCIe route、ACS/IOMMU 策略允许 P2P；
- NVMe、U280 和 NM37 BAR 资源没有重叠或溢出；
- 当前 `vortex_peer_mode` outbound translator 与 inbound P2P remapper 可同时
  使用；
- 启动时用一个受控 cacheline 验证 P2P BAR 与 Vortex HBM 地址指向同一内容。

任一条件不满足，Bridge/QEMU 必须拒绝启用 GDS。Resizable BAR 或 P2P 配置若
需要 warm reboot，应在维护窗口完成；脚本不能自动解绑正在使用的设备，也不能
修改 `/opt`。

### 6.3 一跳核心工作包

| 组件 | 直接修改位置 | 必须实现的最终能力 |
|---|---|---|
| xocl UAPI/BO | 本地 XRT 的 `xocl_vortex_peer.c`、`xocl_drm.c`、`subdev/p2p.c` | 校验同 owner HBM[0] P2P BO，可信查询 bus address |
| Vortex Bridge/RPC | `/home/yanjiarun/Vortex/tools/scope_vortex_bridge` 及 RPC header | callback v3、`GDS_CAPS/ALLOC/FREE`、allowlist、owner/generation |
| QEMU Vortex backend | `qemu-mount/hw/misc/scope_fpga_vswitch_vortex_backend.c` | 注册 U280 GDS buffer，向 NVMe backend 提供只读 target descriptor |
| QEMU NVMe backend | `qemu-mount/hw/misc/scope_fpga_vswitch.c` | SQE/PRP 保存改写恢复、GDS target 翻译、CQE correlation、无 payload fallback |
| guest driver/UAPI | `work_farm/software/linux/drivers/misc/scope_vortex.c` 与 `include/uapi/linux/scope_vortex.h` | query/alloc/free、READ arm/wait/release、错误和取消 |
| Vortex runtime/cache | `/home/yanjiarun/Vortex/sw/runtime/common/device.cpp` 与现有 cache-flush RTL | CQE 后、LAUNCH 前执行 `CMD_CACHE_FLUSH` 并等待退休 |
| guest runtime/tests | Vortex guest runtime 与 `tests/regression/gds_read` | 4 KiB 块级 API 和 HBM checksum kernel；异步多 buffer 待扩展 |
| 启动脚本 | `tools/u280_xrt_start.sh` | P2P BAR/HBM/route 强校验并输出 GDS capability |

这些修改可以拆成多个 commit，但必须始终保持 direct-P2P 配置 fail-closed；不能
提交一个会在运行时转用 NM37 payload staging 的过渡版本。

### 6.4 从一跳原型收敛到最终实现

固定 buffer 原型通过后，在同一条通路上补齐：

- 多 P2P BO 与统一 HBM allocator；
- 多 queue、多 in-flight、异步 event 和双/多缓冲流水；
- PRP list 全边界、SGL、NVM WRITE；
- reset、timeout、取消、AER 和 device removal；
- namespace/LBA 权限和进程级 buffer 隔离；
- 文件 extent/direct-I/O 层及 `cuFile`-like 用户 API；
- 性能、带宽、延迟和 payload 路径硬件计数器。

最终实现仍由 CPU/香山/QEMU 管理 SQ/CQ 和 doorbell，Vortex 只提供/消费 HBM
data buffer；不演变为 GPU-initiated NVMe。

## 7. 板级测试与验收

### 7.1 正确性测试

GDS 测试作为独立程序构建和运行，不混入现有 `vortex-run-all`，以免路径选择
变得隐式。当前构建和命令边界为：

```text
VORTEX_TESTS=vecadd sgemm conv3 multikernel bfs sort gds_read

vortex-run-all       # 只运行非 GDS 回归
vortex-gds_read ...  # 只在显式提供 LBA/checksum 时运行 GDS
```

首个块级 READ CLI 已实现为固定 4 KiB：

```bash
vortex-gds_read \
    -l <保留测试区域起始LBA> \
    -e <32-bit checksum> \
    -d /dev/nvme0n1 -b 4096 -i 1
```

测试数据使用 `tools/prepare_vortex_gds_ssd.sh` 准备。脚本先以 root 权限核对
BDF、序列号、挂载、分区、swap、holder、open fd、文件系统签名、LVM 和 MD，
默认只审计；只有同时给出 `--write` 和包含准确 SLBA 的 confirmation token 才
覆盖那一个 4 KiB LBA。单次 READ 测试的完整步骤为：

1. 在 `0000:e1:00.0` 的保留测试 LBA 写入确定性 pattern，并记录预期 checksum；
2. Bridge 在 HBM[0] 分配并登记 P2P BO，返回 handle、HBM address、P2P bus
   address 和 generation；
3. guest 测试通过 Vortex runtime 和 `/dev/scope-vortex0` GDS ioctl 提交
   `nsid + LBA + length + handle + generation + offset`；
4. QEMU 保存并改写 SQE/PRP，只有 data PRP 指向 U280 P2P BAR；
5. NVMe 完成后执行 ownership sync、visibility fence 和 pre-launch cache
   invalidate；
6. Vortex pattern/checksum kernel 直接读取同一个 HBM buffer；
7. 只回传 checksum、错误计数和性能元数据，不把完整 payload 下载到 NM37 DDR
   后再校验；
8. 同时检查 QEMU/Bridge 日志中的 `target=U280_HBM`、
   `payload_cpu_bytes=0` 和 `payload_nm37_bytes=0`。

当前首笔板级验收包含：

- 固定 pattern 的一个 4 KiB NVM READ；
- Vortex kernel直接遍历同一 HBM buffer并计算 32-bit checksum；
- 连续重复运行和普通 NVMe/Vortex 回归；
- 日志、AER 和 NM37/U280 ILA 路径核对。

原型通过后应继续增加：

- 固定 pattern 的 4 KiB、64 KiB、1 MiB、16 MiB NVMe READ；
- PRP1 非页对齐、PRP1+PRP2、单层和多层 PRP list；
- HBM buffer 起止边界、越界、generation 失效；
- 多 buffer 并发、重复读取、读取后立即启动 Vortex kernel；
- NVMe timeout/CQE error、Bridge kill、U280 reset、xclbin reload、PCIe AER；
- 现有 Vortex direct-P2P 和 NVMe control-path 回归测试保持通过；
- 测试程序必须直接比较 HBM pattern/checksum，不能先把 payload 下载到 NM37
  再判定正确性。

### 7.2 ILA/PCIe 观察

NVMe READ 期间应看到：

- NVMe 发出的 PCIe MWr 目标落在 U280 P2P BAR；
- U280 shell/P2P remapper 后出现 HBM 写入；
- NM37 M_AXI_BYPASS 只有 SQ/CQ/PRP-list 等控制流量，不出现 payload 大小的写入；
- Vortex kernel 随后从对应 HBM 地址读取。

NVMe WRITE 后续应看到 NVMe 对 U280 P2P BAR 发起 MRd，以及 HBM 侧读流量。

### 7.3 必须满足的验收标准

- `NVMe READ -> U280 HBM` 结果逐字节正确，可连续重复；
- QEMU/Bridge 日志中 `payload_cpu_bytes=0`；
- payload 不经过香山 DDR、NM37 XDMA H2C/C2H 或 Unix Socket；
- NM37 BAR2 只承载队列、PRP list 和 CQE 等控制数据；
- 真实 NVMe PRP data address 全部位于已登记的 U280 P2P BO；
- Vortex 只有在 completion、visibility 和 cache 处理完成后才能读取 buffer；
- 无新增 AER，所有错误都能返回 guest，不能永久卡住；
- `direct-p2p` 失败必须 fail-closed，不允许任何 payload 替代路径；
- 与当前 Vortex direct-P2P outbound path 可以同时运行或给出明确互斥错误。

## 8. 最终实现决策

本项目直接实现以下唯一 GDS 数据通路：

```text
control：香山/QEMU -> 标准 NVMe SQ/CQ/doorbell
data   ：NVMe -> U280 P2P BAR -> HBM[0]
```

实际编码和运行前必须恢复并确认 U280 XRT user PF 与 P2P BAR。若当前 shell
不能提供映射 HBM 的 inbound P2P BAR，则不能只靠 QEMU 改 PRP 实现一跳；应先
更换/恢复支持 P2P 的 U280 deployment platform，而不是给 NVMe 填入一个无法由
U280 完成的地址，也不能转入 NM37 payload staging。

首个原型和最终版本共享同一套关键对象：XRT P2P BO、Bridge GDS handle、QEMU
受控 descriptor 改写、标准 NVMe completion 和 Vortex HBM buffer。原型只减少
queue/buffer/descriptor 数量；最终版本补齐并发、双向 I/O、文件 API 与错误
恢复，不改变 payload 路径。

这也与附件调查结论一致：GDS bypass 的是 host payload bounce buffer，而不是
NVMe control path。SQ/CQ 和 doorbell 继续由 CPU 软件管理，NVMe DMA engine
根据 PRP/SGL 直接访问 GPU peer memory。

## 9. 调查依据

- [NVIDIA GPUDirect Storage Design Guide](https://docs.nvidia.com/gpudirect-storage/design-guide/index.html)
- [NVIDIA GPUDirect Storage Overview Guide](https://docs.nvidia.com/gpudirect-storage/overview-guide/index.html)
- [NVIDIA GPUDirect Storage Getting Started](https://docs.nvidia.com/gpudirect-storage/getting-started/index.html)
- [NVM Express Base Specification](https://nvmexpress.org/base-nvm-express-part-one/)
- [NVM Express PCIe Transport Specification 1.0b](https://nvmexpress.org/wp-content/uploads/NVM-Express-PCIe-Transport-Specification-1.0b-2021.12.18-Ratified-2.pdf)
- [Linux upstream nvme-pci driver](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/pci.c)
