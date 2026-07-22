# vSwitch 接入主机侧 GPU 的可行性与技术路线调查

## 1. 调查目标

本文分析如何在仓库 14 的虚拟 PCIe switch 中接入 x86 主机上的真实 GPU，使香山 Linux 将其识别为 PCIe GPU 或计算加速器，并评估现有 Intel 82580 mediated backend 的经验能复用到什么程度。

本文重点回答：

1. GPU 是否也可以采用“拦截 BAR doorbell、修改内存描述符、再转发 doorbell”的方式。
2. 整卡直通、SR-IOV/vGPU、virtio-gpu 和 API remoting 各自是否适合当前系统。
3. 当前 vSwitch、coherent alias、QEMU backend 和香山软件栈还缺少哪些能力。
4. 在尚未确定具体 GPU 型号时，应该先做哪些实验，避免过早绑定某个厂商或代际。

本文只提出研究和实施路线，不修改当前 GPU、FPGA、QEMU 或内核代码。具体设备选型完成后，应再形成设备专用设计文档。

## 2. 结论

### 2.1 能复用网卡框架，但不能复用网卡的数据地址修补方法

当前 vSwitch 的以下能力可直接复用：

- QEMU 维护多 BDF ECAM shadow，并使用标准 PCI config mask/W1C 语义。
- FPGA 拦截 guest BAR MMIO，通过 DMA32 C2H packet 交给 QEMU。
- BAR response mailbox、`BAR_WRITE_DONE` 和 backend dispatch。
- coherent alias，使主机侧设备和 QEMU 能访问香山一致性内存路径。
- backend 生命周期、真实设备独占、配置文件和日志框架。
- 多 endpoint 拓扑和共享 route diagnostics。

但是，82580 的关键数据结构是数量有限、格式固定的 TX/RX descriptor。QEMU 可以在 `TDT/RDT` 提交点扫描 descriptor，替换其中的 DMA 地址，然后再转发 tail。GPU 的地址关系远复杂于此：

- command ring 中通常放的是 GPU 命令和 GPU virtual address，而非一组可枚举的 host physical address。
- command ring 还可以引用 indirect buffer，间接命令又可引用其他 buffer。
- GPUVM/GART 页表决定 GPU virtual address 最终映射到 VRAM 或 system memory。
- firmware queue、context、fence、writeback、interrupt ring 和多个 engine 都可能使用 DMA 地址。
- 驱动会动态创建和更新大量 buffer object 与页表，不能只在单个 doorbell 前修补一段固定 descriptor。

因此，**GPU 接入的核心不是解析并改写所有 GPU command，而是让真实 GPU 使用的 GPUVM/GART/IOMMU 映射从一开始就指向 FPGA coherent alias。** 如果这条全局 DMA 地址路径无法成立，则不建议继续实现整卡 mediated backend。

### 2.2 推荐方案顺序

按当前系统的实现风险排序：

1. **virtio-gpu 或 API remoting**：最快获得“香山使用主机 GPU 加速”的功能，但不验证真实 GPU 原生驱动和 PCIe 设备语义。
2. **硬件 SR-IOV VF/vGPU**：若服务器 GPU 支持，这是原生 guest 驱动与资源隔离之间最好的长期方案。
3. **独占整卡 mediated passthrough**：最符合当前真实 NVMe/82580 backend 思路，但必须补齐多 BAR、MSI-X、GPU DMA/GPUVM、reset、firmware 和 RISC-V 软件栈。
4. **手工模拟某一型号 GPU**：不建议。其工作量接近重新实现一个厂商和代际相关的 vGPU/GVT 系统。

不论选择哪条原生 GPU 路线，都应先完成一个 go/no-go 实验：**真实 GPU 能否稳定地 DMA read/write FPGA coherent alias 中的一页内存。** 该实验失败时，应停止整卡/VF mediated backend，转向 virtio-gpu 或 API remoting。

## 3. 当前仓库 14 的边界

### 3.1 现有 vSwitch 能力

当前 `scope_fpga_vswitch.c` 已具备：

- 最多 13 个 endpoint backend。
- 128 KiB compact ECAM shadow。
- `0x60000000/16 MiB` guest ECAM window。
- `0x50000000/16 MiB` guest PCI memory window。
- 13 项 BAR route table。
- 通过 FPGA mailbox 完成 BAR read/write response。
- coherent alias 和共享 DMA32 ring。
- 一根 aggregate level INTx。
- NVMe 与 82580 两类 backend。

### 3.2 GPU 接入前必须改变的限制

当前实现仍有以下 GPU 阻断项：

| 当前限制 | 对 GPU 的影响 |
|---|---|
| 每个 backend 只有一个 `real_bar0_map` | GPU 通常有 MMIO、doorbell、VRAM aperture 等多个 BAR |
| 单 BAR 最大 aperture 为 1 MiB | 许多 GPU BAR0/BAR2 远大于 1 MiB |
| 全部 PCI memory window 只有 16 MiB | 无法容纳大型 prefetchable BAR 或 Resizable BAR |
| route table 每 backend 只有一个 BAR | 无法按 BAR index 区分寄存器、doorbell 和显存 aperture |
| 只有 aggregate INTx | 现代 GPU 主要依赖 MSI/MSI-X 和多个中断源 |
| 无 Expansion ROM/VBIOS 代理 | 部分原生驱动初始化依赖固件表或 VBIOS 数据 |
| 仅有简单 function disable/reset | GPU reset、firmware、power state 和 engine teardown 更复杂 |
| 香山内核未启用 AMDGPU | 当前不能直接绑定现代 AMD GPU |
| rootfs 未发现 Mesa/libdrm/ROCm/Vulkan 用户栈 | 即使内核 probe 成功，也暂时没有完整计算/图形应用环境 |

当前 RISC-V 配置只启用了 `DRM_RADEON` 和 `DRM_VIRTIO_GPU` 等基础选项，没有 `CONFIG_DRM_AMDGPU`。这意味着选择现代 AMD GPU 时，需要同时升级或重新配置内核、加入 firmware，并验证驱动在当前 RISC-V 内核版本上的可构建性。

## 4. GPU 提交和地址转换为什么更复杂

### 4.1 Doorbell 和 ring 仍然存在

GPU 与网卡相似，也广泛使用 ring 和 doorbell。AMDGPU 文档说明，用户队列包含 ring、read pointer、write pointer、context buffer 等对象；软件更新 write pointer 后写 doorbell，调度 firmware 再获取新的 wptr。AMDGPU ring 同样是 producer/consumer 结构，GPU 根据 rptr/wptr 解析 command stream。[AMDGPU User Mode Queues](https://docs.kernel.org/gpu/amdgpu/userq.html) [AMDGPU Ring Buffer](https://docs.kernel.org/gpu/amdgpu/ring-buffer.html)

因此，当前 FPGA 的 BAR write 拦截、QEMU backend dispatch 和 `BAR_WRITE_DONE` 仍有价值。它们可以用于：

- 观察 doorbell。
- 在真实 GPU 收到提交前完成必要的内存可见性检查。
- 对危险控制寄存器进行过滤。
- 记录队列和故障状态。

但 doorbell 只是提交边界，不足以告诉 QEMU 本次提交涉及的全部内存地址。

### 4.2 GPUVM/GART 才是地址路径中心

AMDGPU 将 system memory 中 GPU 可访问的部分称为 GTT，并通过 GART/GPUVM 建立地址映射；buffer object 可以位于 VRAM 或 GTT，indirect buffer 又承载实际 GPU 命令。[AMDGPU Driver Core](https://docs.kernel.org/next/gpu/amdgpu/driver-core.html) [AMDGPU Glossary](https://docs.kernel.org/gpu/amdgpu/amdgpu-glossary.html)

典型路径是：

```text
guest application virtual address
  -> guest CPU page table
  -> DRM buffer object
  -> guest driver建立GPUVM/GART映射
  -> command中使用GPU virtual address
  -> real GPU page-table walker
  -> system-memory DMA address或VRAM地址
```

在当前系统中，guest driver 所理解的 system-memory DMA address 是香山 guest PA；真实 GPU 位于 x86 主机 PCIe 拓扑中，需要的却是能到达 FPGA EP coherent alias 的 host PCIe bus address。两者不相等。

网卡 backend 可以在 TDT/RDT 前修改几个 descriptor 字段，而 GPU 若采用同样办法，就需要理解并修改：

- ring 和 indirect buffer。
- GPUVM/GART 页表项。
- firmware queue/context descriptor。
- fence、writeback、interrupt ring 地址。
- 各 engine 私有的命令格式和地址编码。

这会迅速变成厂商、GPU generation 和 firmware 版本相关的完整虚拟化实现。

### 4.3 推荐的 DMA 地址解决顺序

按优先级应尝试：

1. **使 guest DMA API 直接产生真实 GPU 可使用的 coherent-alias DMA 地址。** CPU 仍通过 guest PA 访问内存，但设备看到统一的 alias 地址。需要确认香山 DMA domain、PCI host bridge `dma-ranges` 或设备专用 DMA offset 是否允许这种分离。
2. **利用 host IOMMU/VFIO 建立 IOVA 映射。** VFIO 提供设备 region、interrupt 和 DMA mapping 接口，但当前 guest memory 实际来自 FPGA PCI BAR，不是普通匿名内存。PCI P2PDMA 页面与 `pin_user_pages()` 存在专门限制，所以不能假定普通 `VFIO_IOMMU_MAP_DMA` 能直接把 XDMA BAR mmap 作为后端；必须用实测确认。[VFIO](https://www.kernel.org/doc/html/latest/driver-api/vfio.html) [PCI P2PDMA](https://docs.kernel.org/driver-api/pci/p2pdma.html)
3. **在 QEMU 中 shadow GPUVM/GART 页表并翻译 PTE。** 只在前两种不可行、且目标 GPU 型号固定时考虑。这比解析所有命令更合理，但仍高度依赖厂商和代际。

Linux PCI P2PDMA 文档还指出，provider 与 client 通常应位于同一 root port/switch 路径，或命中允许列表；IOMMU、ACS 和 host bridge 拓扑会影响事务是否可达。因此 NVMe 已能访问 coherent alias，并不能自动证明 GPU 也一定可达。[PCI Peer-to-Peer DMA Support](https://docs.kernel.org/driver-api/pci/p2pdma.html)

## 5. 可复用与需要重写的组件

| 组件 | 复用程度 | GPU 侧工作 |
|---|---|---|
| 多 BDF ECAM shadow | 高 | 增加 GPU config template、capability 和 ROM |
| backend JSON 配置 | 高 | 新增 `type: gpu`、厂商/模式和多 function 参数 |
| FPGA BAR request packet | 高 | flags 中保留/扩展 BAR index |
| mailbox response | 高 | 无需改变基本提交协议 |
| `BAR_WRITE_DONE` | 高 | 保留为 guest MMIO 完成边界 |
| coherent alias | 高 | 作为 system-memory 数据面基础 |
| 一项 route/backend | 低 | 改为多 BAR route，支持 64-bit/prefetchable BAR |
| 16 MiB PCI window | 低 | 按实卡 BAR inventory 扩大并支持 64-bit window |
| aggregate INTx | 低 | 仅能用于最早期调试，正式路径需 MSI/MSI-X |
| 网卡 descriptor patch | 很低 | 替换为全局 DMA/GPUVM 方案 |
| backend reset | 低 | 加入 GPU FLR/SBR/vendor reset、firmware和power序列 |
| QEMU polling | 中 | 可用于 bring-up，正式中断应由 VFIO/eventfd 驱动 |

## 6. 技术方案比较

### 6.1 方案 A：virtio-gpu 或 API remoting

**目标**：让香山应用使用主机 GPU 能力，不要求香山加载真实 GPU 的原生 PCI 驱动。

QEMU virtio-gpu 支持基础 2D、virglrenderer 3D 和基于 rutabaga/Venus 的 Vulkan 路径。它把 guest 的图形/计算协议翻译到 host 图形栈，而不是把真实 GPU 寄存器暴露给 guest。[QEMU virtio-gpu](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html) [vhost-user-gpu](https://www.qemu.org/docs/master/interop/vhost-user-gpu.html)

可在当前系统中新增一个 virtio PCI endpoint backend：

```text
guest virtio-gpu driver
  -> vSwitch BAR/virtqueue notification
  -> QEMU virtio backend
  -> host virglrenderer/rutabaga/Mesa
  -> host GPU driver
```

优点：

- 不需要理解真实 GPU MMIO、firmware 和 GPUVM 格式。
- host 驱动继续完整拥有真实 GPU，reset 和电源管理风险较小。
- 更适合不同厂商 GPU。

缺点：

- 当前 vSwitch 还没有通用 virtio transport backend。
- host blob aperture 常达到数百 MiB 或更多，必须扩大当前 16 MiB PCI memory window。
- 它验证的是虚拟 GPU 协议，不是目标真实 GPU 驱动的容错与 PCIe 行为。
- RISC-V guest 仍需要合适的 Mesa/Vulkan 用户栈。

若目标是 CUDA 一类专有计算 API，可考虑 RPC/API remoting：guest 发送 API 和 buffer 请求，host 执行实际 GPU 工作。rCUDA 等研究证明了这种 acceleration-as-a-service 路线的可行性，但它会引入协议兼容和调用延迟问题。[rCUDA](https://arxiv.org/abs/1508.02558) [API Remoting Latency](https://arxiv.org/abs/2401.13354)

需要特别注意：当前 NVIDIA CUDA Linux 安装指南列出的目标架构是 x86_64 和 Arm64，未列出 riscv64，因此不能把“在香山直接安装官方 CUDA guest 用户栈”作为默认前提。[CUDA Installation Guide for Linux](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html)

**适用结论**：若近期目标是功能演示、图形加速或远程计算，这是首选路线。

### 6.2 方案 B：SR-IOV VF 或厂商 vGPU

**目标**：让香山加载接近原生的 GPU guest 驱动，同时由硬件/厂商 host driver 提供隔离和调度。

AMD MxGPU 基于 SR-IOV，由 PF 创建 VF，每个 VF拥有相对独立的内存、DMA 和中断资源。[AMD MxGPU](https://instinct.docs.amd.com/projects/virt-drv/en/latest/userguides/Getting_started_with_MxGPU.html) NVIDIA 在支持的 Ampere 及后续产品上也使用 SR-IOV VF 结合 vGPU/mdev 管理；一个 mdev 可关联到一个 VF。[NVIDIA vGPU User Guide](https://docs.nvidia.com/vgpu/latest/grid-vgpu-user-guide/index.html)

Linux mdev 框架的基本模型是：vendor physical driver 继续拥有物理设备，通过 mdev 创建受控实例，再由 VFIO 向用户态 VMM 暴露 region、interrupt 和 DMA 接口。[VFIO Mediated Device](https://www.kernel.org/doc/html/v5.15/driver-api/vfio-mediated-device.html)

优点：

- queue、调度、显存隔离和大量寄存器语义由硬件及厂商软件承担。
- 比手写 mediated GPU backend 更接近成熟方案。
- 每个 VF 天然适合映射为一个 vSwitch endpoint。

缺点：

- 只适用于明确支持 SR-IOV/vGPU 的 GPU 和驱动版本。
- 可能受厂商授权、host OS、guest OS 和产品矩阵限制。
- 仍需在当前框架中实现 VF 多 BAR、MSI-X、DMA 到 FPGA coherent alias 和 reset。
- 厂商支持矩阵通常以 x86/Arm 服务器 guest 为主，RISC-V guest 驱动和用户态仍需验证。AMD 当前虚拟化支持也只覆盖特定 Instinct/Radeon Pro 型号和组合。[ROCm System Requirements](https://rocm.docs.amd.com/projects/install-on-linux/en/develop/reference/system-requirements.html)

NVIDIA MIG 可以把支持的 GPU 划分为多个具有独立计算和显存资源的实例，但 MIG 本身不等同于普通 PCI VF；如何呈现给 VM 仍取决于 passthrough/vGPU 部署方案。[NVIDIA MIG Introduction](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/introduction.html)

**适用结论**：若服务器已有支持 SR-IOV/vGPU 的数据中心 GPU，这是长期最优路线；应优先于自研整卡寄存器代理。

### 6.3 方案 C：独占整卡 mediated passthrough

**目标**：一个真实 GPU function 对应一个香山 endpoint，guest 使用原生 DRM 驱动，host 不再使用该 GPU。

这条路线与当前 82580 backend 最接近，但 backend 只应代理控制面，不能尝试完整解释所有 GPU command。建议第一阶段选择：

- 非主显示 GPU，避免 host console/Xorg/Wayland 占用。
- 能从 host driver 完整 unbind。
- 支持可靠 FLR，或有已验证的 vendor reset。
- BAR 和 ROM 信息清晰。
- Linux 驱动与 firmware 可获得并能在 riscv64 构建。
- 优先考虑开源内核驱动覆盖较完整的 AMD GPU；但具体型号必须按实际硬件和当前内核版本重新评估。

需要新增：

1. GPU config/capability shadow 和可选多 function 拓扑。
2. 多 BAR route，支持 MMIO、doorbell 和 VRAM aperture。
3. 64-bit prefetchable PCI memory window 和 Resizable BAR 策略。AMDGPU 的 `rebar` 参数及 BIOS BAR resize 会改变 aperture，不能继续硬编码 1 MiB。[AMDGPU Module Parameters](https://docs.kernel.org/gpu/amdgpu/module-parameters.html)
4. Expansion ROM/VBIOS 访问。
5. MSI/MSI-X eventfd 到香山中断控制器的完整路径。
6. GPUVM/GART 或 IOMMU DMA 映射方案。
7. firmware loading、power state、FLR/SBR/vendor reset 和异常退出恢复。
8. DRM kernel driver、firmware、libdrm/Mesa 或计算用户栈。

Intel GVT-g 是这类 mediated passthrough 的典型已有工作：guest 使用原生 i915 驱动，host 侧虚拟化 privileged resource，维护 virtual interrupt、shadow context 和 PPGTT page table，并由 host driver 负责真实 submission。它表明高性能 GPU mediated passthrough 可行，也表明所需工作远超 BAR 转发。[Intel GVT-g Architecture](https://github.com/intel/gvt-linux/wiki/GVTg-New-Architecture-Introduction-Update) [Linux i915 GVT-g](https://www.kernel.org/doc/html/v5.15/gpu/i915.html)

USENIX gVirt 研究将 mediated pass-through 的重点概括为：有选择地 trap privileged operations，同时让性能关键资源接近直接访问。论文报告接近原生性能，但其实现包含完整的 GPU command、memory 和 interrupt virtualization，而不是简单寄存器代理。[gVirt: A Full GPU Virtualization Solution with Mediated Pass-Through](https://www.usenix.org/sites/default/files/atc14_full_proceedings_interior.pdf)

**适用结论**：可作为研究主线，但应在 DMA 可达性验证成功后再投入。

### 6.4 方案 D：手写 GPU device model

完全模拟某个真实 GPU 的 config、MMIO、firmware、command processor、GPUVM、display 和 interrupts，实质上是在实现新的 GPU 虚拟化产品。即使只代理真实硬件，也必须持续跟踪闭源 firmware 协议和 GPU generation 差异。

**适用结论**：除非研究目标本身就是 GPU 虚拟化机制，不建议选择。

## 7. 推荐的仓库 14 演进架构

### 7.1 manager 与 GPU backend 的边界

保持现有软件分层，新增：

```text
scope_fpga_vswitch.c
  ECAM shadow、DMA32 ring、FPGA mailbox、多BAR route、MSI/MSI-X transport

scope_fpga_vswitch_gpu_backend.c
  GPU/VF config、BAR policy、VFIO fd、reset、GPUVM/DMA策略、故障状态

scope_fpga_vswitch_nvme_backend.c
scope_fpga_vswitch_igb_backend.c
  保持现有设备专用逻辑
```

公共 backend interface 需从单 BAR 扩展为：

```text
realize / unrealize
config_write
bar_read(backend, bar_index, offset, size)
bar_write(backend, bar_index, offset, size, data)
dma_map / dma_unmap
reset
poll_or_handle_irq(vector)
has_pending_interrupt(vector)
```

配置文件可增加模式区分：

```json
{
  "type": "gpu",
  "mode": "whole-function",
  "real-host-bdf": "0000:xx:00.0",
  "rom": "auto"
}
```

或：

```json
{
  "type": "gpu-vf",
  "real-host-bdf": "0000:xx:00.1"
}
```

### 7.2 多 BAR 路由

route key 应从：

```text
backend_id -> BAR0
```

改为：

```text
(backend_id, bar_index) -> guest_base, size, real resource, attributes
```

每项至少包含：

- backend ID。
- BAR index。
- 64-bit / prefetchable 属性。
- guest base 和 size。
- route type：trap、direct aperture 或 disabled。
- real BAR resource offset。

寄存器 BAR 和 doorbell BAR可以继续 trap 到 QEMU。大型 VRAM aperture 不应逐次经 QEMU MMIO callback，否则带宽完全不可用；它必须走硬件直通/地址转换或干脆不向 guest 暴露。

### 7.3 中断路径

aggregate INTx 不足以承载正式 GPU backend。建议新增：

```text
real GPU MSI/MSI-X
  -> host VFIO eventfd
  -> QEMU backend vector
  -> FPGA MSI request mailbox/packet
  -> 香山 PCI host/IMSIC/PLIC 对应 vector
```

若香山当前平台无法注入 MSI-X，可先用一个合并中断做 bring-up，但必须由 QEMU 保存每个 GPU cause/vector pending，不能把它当成长期数据面。

## 8. 分阶段实施路线

### Phase 0：设备和拓扑盘点

先对候选 GPU 收集：

```text
lspci -vvnn -s <BDF>
lspci -xxx -s <BDF>
cat /sys/bus/pci/devices/<BDF>/resource
cat /sys/bus/pci/devices/<BDF>/reset_method
cat /sys/bus/pci/devices/<BDF>/sriov_totalvfs
readlink /sys/bus/pci/devices/<BDF>/iommu_group
```

同时记录：

- GPU vendor/device/subsystem ID 和 revision。
- 所有 BAR 的大小、属性和 Resizable BAR capability。
- Expansion ROM。
- MSI/MSI-X vector 数量。
- PF/VF、mdev/MIG 能力。
- FLR/SBR/vendor reset 行为。
- GPU 与 FPGA EP 的 PCIe root port/switch/ACS/IOMMU 关系。
- host 和 guest 所需 kernel、firmware、用户态版本。

**停止条件**：候选 GPU 是 host 主显示设备、不能可靠 reset、不能隔离，或没有 riscv64 可用驱动路径时，不进入整卡 backend。

### Phase 1：独立 P2P DMA 可达性实验

不先实现完整 vSwitch GPU。写一个 host 侧最小测试，验证真实 GPU 的 DMA engine 能否：

1. 从 FPGA coherent alias 页读取已知 pattern。
2. 向 FPGA coherent alias 页写入结果。
3. 在 IOMMU on/off、ACS 不同状态下保持正确。
4. 由香山 CPU 通过一致性路径观察结果。

优先使用厂商驱动提供的 SDMA/copy engine 测试接口；若使用 VFIO，必须验证 IOVA mapping 是否接受 P2PDMA/BAR backing，而不是根据普通 RAM 映射成功进行推断。

**停止条件**：GPU 不能稳定 DMA 到 coherent alias，且没有可接受的 host bounce buffer/API remoting 方案时，停止直接 passthrough。

### Phase 2：枚举与驱动 probe

- 扩展 vSwitch 为多 BAR 和 64-bit prefetchable window。
- 根据真实 function 或 VF 构造 ECAM shadow。
- 支持 ROM/VBIOS。
- 禁用尚未实现的 capability。
- 在香山启用目标 DRM driver 和 firmware。
- 只验证 `lspci -vv`、BAR sizing、driver probe、reset，不运行 workload。

此阶段的 BAR window 大小必须由 Phase 0 的实际资源决定，不预设固定 GiB 数值。

### Phase 3：MSI/MSI-X 与生命周期

- 使用 VFIO/eventfd 接收真实 vector。
- 实现 QEMU 到 FPGA、FPGA 到香山的 vector 注入。
- 验证 mask/unmask、pending bit、并发 vector 和 reset 后状态。
- 实现 guest FLR、driver unbind、QEMU abnormal exit 和下一次启动恢复。

### Phase 4：GPUVM/GART 与 command submission

- 选定 DMA 地址模型：guest DMA offset、host IOMMU IOVA 或 shadow GPUVM。
- 验证 page table 本身和所有 system-memory BO 均指向正确 alias。
- 先运行 kernel driver 自带 ring/IB/SDMA 测试。
- 确认 fence/writeback 和 interrupt ring 正常。
- 不在第一版中解析和重写任意 shader command。

### Phase 5：headless compute/graphics

- 先创建 DRM render node，不启用显示输出。
- 构建 riscv64 libdrm/Mesa/OpenCL/Vulkan 或选择 API remoting client。
- 运行 buffer copy、简单 compute、长时间压力和 reset recovery。
- 最后才考虑 scanout、EDID、显示中断、音频 function 和物理输出。

## 9. 建议的验证矩阵

| 类别 | 最小验证 |
|---|---|
| PCI config | BAR sizing、capability、W1C、ROM、FLR |
| BAR | 每个 BAR 边界、大小、属性、非法访问 |
| P2P DMA | GPU read/write coherent alias、数据校验、IOMMU/ACS |
| GPUVM | map/unmap、页表更新、TLB invalidation、fault |
| Submission | ring、IB、doorbell、fence、writeback |
| Interrupt | MSI-X mask/pending、多 vector、丢失/重复 |
| Reset | guest reset、host unbind、QEMU退出、连续启动 |
| 并发 | GPU 与 NVMe/NIC 同时 DMA 和中断 |
| 故障 | 非法 PTE、GPU page fault、engine hang、AER |
| 用户态 | render node、Mesa/compute runtime、数据正确性 |

## 10. Go/No-Go 决策点

整卡或 VF GPU backend 只有同时满足以下条件才继续：

1. 真实 GPU function 可由 QEMU 独占并可靠 reset。
2. vSwitch 可承载其全部必要 BAR、ROM 和 capability。
3. GPU 能 DMA 到 FPGA coherent alias，或 host IOMMU 能建立等价映射。
4. 目标 guest kernel driver 和 firmware 能在当前 riscv64 内核上运行。
5. 存在可用的 riscv64 用户态图形/计算栈，或项目接受 API remoting。
6. MSI/MSI-X 注入方案可实现，而非长期依赖 aggregate INTx。

任一条件失败时的推荐降级：

```text
native VF/whole GPU
  -> virtio-gpu/Venus
  -> API remoting
  -> host bounce buffer，仅用于功能实验
```

## 11. 对当前项目的最终建议

### 近期

1. 先确定服务器上的具体 GPU 型号和 PCIe 拓扑。
2. 独立完成 GPU 到 FPGA coherent alias 的 P2P DMA 实验。
3. 若目标是尽快展示 GPU 能力，优先做 virtio-gpu 或自定义计算 RPC。
4. 不在 P2P 实验前扩写 GPU BAR backend。

### 中期

若有受支持的 SR-IOV/vGPU 卡，优先把 VF 映射为 vSwitch endpoint；否则选择一张专用、可 reset、驱动开放的 GPU 做整卡 headless backend。

### 长期

将 vSwitch 从“单 BAR + aggregate INTx”升级为通用多 BAR、64-bit PCI window、MSI/MSI-X 和 VFIO DMA backend。该基础设施不仅服务 GPU，也能支持高性能 NIC、加速卡和其他复杂 PCIe endpoint。

## 12. 资料与已有工作

### Linux/QEMU 接口

- [VFIO - Virtual Function I/O](https://www.kernel.org/doc/html/latest/driver-api/vfio.html)
- [VFIO Mediated Device](https://www.kernel.org/doc/html/v5.15/driver-api/vfio-mediated-device.html)
- [PCI Peer-to-Peer DMA Support](https://docs.kernel.org/driver-api/pci/p2pdma.html)
- [QEMU virtio-gpu](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html)
- [QEMU vhost-user-gpu](https://www.qemu.org/docs/master/interop/vhost-user-gpu.html)

### AMD

- [AMDGPU Driver Core](https://docs.kernel.org/next/gpu/amdgpu/driver-core.html)
- [AMDGPU Ring Buffer](https://docs.kernel.org/gpu/amdgpu/ring-buffer.html)
- [AMDGPU User Mode Queues](https://docs.kernel.org/gpu/amdgpu/userq.html)
- [AMDGPU Glossary](https://docs.kernel.org/gpu/amdgpu/amdgpu-glossary.html)
- [AMDGPU Module Parameters](https://docs.kernel.org/gpu/amdgpu/module-parameters.html)
- [AMD MxGPU Getting Started](https://instinct.docs.amd.com/projects/virt-drv/en/latest/userguides/Getting_started_with_MxGPU.html)
- [ROCm System Requirements](https://rocm.docs.amd.com/projects/install-on-linux/en/develop/reference/system-requirements.html)

### NVIDIA

- [NVIDIA vGPU User Guide](https://docs.nvidia.com/vgpu/latest/grid-vgpu-user-guide/index.html)
- [NVIDIA MIG Introduction](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/introduction.html)
- [NVIDIA MIG Supported GPUs](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/supported-gpus.html)
- [CUDA Installation Guide for Linux](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html)

### GPU mediated virtualization 与 API remoting

- [Intel GVT-g Architecture Introduction](https://github.com/intel/gvt-linux/wiki/GVTg-New-Architecture-Introduction-Update)
- [Linux i915 GVT-g Documentation](https://www.kernel.org/doc/html/v5.15/gpu/i915.html)
- [gVirt: A Full GPU Virtualization Solution with Mediated Pass-Through](https://www.usenix.org/sites/default/files/atc14_full_proceedings_interior.pdf)
- [rCUDA: Acceleration-as-a-Service](https://arxiv.org/abs/1508.02558)
- [Reducing API Remoting Overheads](https://arxiv.org/abs/2401.13354)
