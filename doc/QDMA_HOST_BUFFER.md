# QDMA slave bridge 主机缓冲区（SCB1）

当前版本使用 QDMA v5.1 的普通 QDMA 功能，并同时启用 master/slave bridge。
不是仅有桥的 endpoint：原生 MM/ST DMA 功能保留，但 SCOPE 通知走 slave bridge，运行时 guest 内存访问走 master bridge 的一致性别名。

```text
CPU ECAM/BAR → 原 Nanhu 双 BAR vSwitch → AXIS 时钟转换
  → scope_qdma_bridge_ring → QDMA S_AXI_BRIDGE → x86 dma_alloc_coherent 缓冲区
QEMU → mmap 主机 RAM → 原 CFG/BAR/NIC/xHCI handlers → mailbox/批量 credit ACK
主机/外设 → FPGA BAR2 → QDMA M_AXI_BRIDGE → alias/SmartConnect
  → u_role/s_axi_dma → role SmartConnect → 普通昆明湖 dma → TL/L3 → DDR
```

QDMA 配置：`en_bridge_slv=true`、`axibar_notranslate=true`、`csr_axilite_slave=true`。
写入逻辑使用驱动返回的完整 64 位 DMA/IOVA 地址，不减去 FPGA BAR 基址，不把 CPU 物理地址当 DMA 地址。
PCIe PF0、PASID 关闭；没有新写 PCIe RQ/CQ 适配器。

## 与之前 C2H completion 版本的区别

SCB1 不创建 QDMA C2H/completion 队列，不依赖 qmax、qid、color 或 CIDX。
`scope_qdma_cmpt`、`scope_qdma_control` 和旧 FIFO 文件作为历史实现保留，但当前 shell 不实例化它们。
当前硬件通知器为 `scope_qdma_bridge_ring`。原 vSwitch、ECAM shadow、mailbox、两条 BAR 路由和报文体保持 Nanhu 功能。

普通 QDMA 驱动的描述符/完成环不能自动成为自定义 AXI slave bridge 的目标缓冲区，因此仍须驱动扩展：
PF 的 `dma_alloc_coherent` → 写入 base low/high、entries → 只读 mmap → ARM。
修改集中在 misc-device 生命周期、buffer 分配和 credit ioctl，原生 QDMA 队列库保持原来的处理逻辑。

## 地址与 ABI

主机 BAR1 的 SCOPE 区域：mailbox `0x200000`、ECAM shadow `0x220000`（128 KiB）、SCB1 CSR `0x240000`。
QDMA CSR AXI-Lite 从 BAR1 `0x260000` 可达。BAR2 raw DDR 为 0–4 GiB，一致性 alias 为 4–8 GiB。
guest RAM 为 `0x80000000..0xffffffff`，运行时通过 BAR2 offset `0x180000000..0x1ffffffff` 访问。
raw DDR 只用于 CPU 复位时加载启动镜像，QEMU runtime raw fallback 关闭。

| CSR offset | 含义 |
| --- | --- |
| 0x00 / 0x04 | magic `0x53434231` / ABI 1 |
| 0x08 / 0x0c | 完整 DMA base low/high |
| 0x10 | ring entries：2 的幂，4–65536 |
| 0x14 | control：0 STOP，1 ARM |
| 0x18 | status：RUN=1、DRAINED=2、BUSY=4、ERROR=8 |
| 0x1c | features：coherent guest ingress=1、full DMA address=2 |
| 0x20 | producer：32 位单调计数器，允许自然回绕 |
| 0x24 | 写：归还的 credit 数；读：剩余 credits |
| 0x28 / 0x2c | error / accepted 计数 |
| 0x30 / 0x34 | slot=64 / packet=32 字节 |

主机 coherent allocation：64 字节 header，producer 在 header offset 0；之后 N 个 64 字节 slot。
每个 slot 前 32 字节为原始 SCOPE 报文，BDF、BAR、访问宽度和 WSTRB 原样保留。
硬件先写 slot、等待 AXI B，再独立发布 producer；同一 PF 禁用 relaxed ordering/no-snoop。
QEMU 用 acquire/rmb 读取主机 RAM，处理后批量 ACK；空轮询不访问 FPGA BAR FIFO。

独占设备 `/dev/scope-qdma-<domain:bus:device.function>`，UAPI 为 `scope_qdma_bridge_uapi.h`：
`SCOPE_BRIDGE_START/INFO/ACK/ARM`。硬件、驱动和 QEMU 的 SCB1 ABI 必须同时匹配。
QEMU 保留旧 transport 兼容代码，但当前启动器选择 `control-transport=qdma-bridge`。

## 停机与错误

STOP 禁止接受新通知，完成已接收的 packet/producer 写，再向同一个主机 header 发起 MemRd fence。
仅在 fence 返回、数据与 producer 一致后报告 DRAINED；驱动才释放 coherent allocation。
VMA 只读且持有 file reference；正常关闭先停止 producer，再释放 buffer；设备移除会撤销用户映射。
B/R 错误、错误输入或 producer 距离非法均停止继续处理。xHCI 通知异常会关闭物理 DMA。
若 fence 失败，驱动保留可能仍被 DMA 使用的内存和设备引用至主机重启；不能用正常卸载宣称已安全回收。
当前没有验证运行中的 guest/QEMU 热重启，初次测试应在 CPU reset 状态建立后端。

## 证据与板级检查

RTL 回归覆盖完整 64 位 DMA 地址、原 packet/BAR 字段、AW/W 独立背压、ring 满、credits、slot/producer 回绕、STOP posted-write fence 和故障。
实际 Vivado BD 检查覆盖两种核数的全部 37 条 CPU DMA 信号及 master/slave bridge 地址路由。
QEMU 回归使用 file-backed PCI/BAR 与模拟 coherent ring，覆盖 NIC TX/RX、xHCI 控制、DONE、通知异常和双 endpoint。
这些检查没有验证真实 PCIe P2P、CPU 脏 cache line 一致性或 B210 I/Q 吞吐；须待 PDI 完成后上板验证。
