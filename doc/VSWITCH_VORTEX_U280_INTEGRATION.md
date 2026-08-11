# Vortex U280 vSwitch 集成与部署

## 1. 目标与产物

该实现让香山把U280上的Vortex视为vSwitch下游PCI endpoint。第一阶段目标是运行Vortex原生`vecadd`，不是实现Linux DRM/GPU驱动。

整套系统包含三个独立产物：

| 产物 | 生成位置 | 部署位置 | 作用 |
| --- | --- | --- | --- |
| 香山vSwitch bitstream | 仓库14 FPGA flow | nm37_vu37p原型板 | ECAM、BAR packet、coherent alias |
| `vortex_afu.xclbin` | `/home/yanjiarun/Vortex/hw/syn/xilinx/xrt` | U280 | Vortex RTL kernel和Command Processor |
| `kernel.vxbin` + static `vortex-vecadd` | Vortex regression/rootfs flow | 香山initramfs | GPU程序及guest host runtime |

U280使用AMD Alveo shell和XRT动态加载xclbin，不烧写仓库14的Vivado bitstream。AMD说明development target platform提供Vitis编译所需的`.xpfm`，deployment platform和XRT用于上板运行：[U280 downloads](https://www.amd.com/en/support/downloads/alveo-downloads.html/accelerators/alveo/u280.html)、[UG1120](https://docs.amd.com/r/en-US/ug1120-alveo-platforms)。

本文重点解释Vortex接入层自身的实现和代码调用关系。通用vSwitch拓扑、ECAM、
route table和coherent alias见
[`PROJECT_ARCHITECTURE.md`](PROJECT_ARCHITECTURE.md)，精确寄存器和packet ABI见
[`VSWITCH_REGISTER_INTERFACE_SPEC.md`](VSWITCH_REGISTER_INTERFACE_SPEC.md)，
当前服务器的逐步操作见
[`U280_QEMU_XIANGSHAN_RUNBOOK.md`](U280_QEMU_XIANGSHAN_RUNBOOK.md)。下文只在
理解Vortex路径需要时引用这些公共机制，不重复完整定义。

## 2. 接入原理与控制/数据边界

### 2.1 为什么使用mediated endpoint

U280 user PF属于x86服务器，由XRT负责装载xclbin、打开`vortex_afu` IP并管理
host-only BO；香山并没有到该PF的原生PCIe层次。因而这里不能把U280配置空间
或BAR简单转发给香山，而是在香山vSwitch中合成一个`1b36:1310` endpoint，
仅复现Vortex runtime真正依赖的两类抽象：

- 4KB Command Processor（CP）寄存器窗口；
- CPU可写且CP可DMA读取的host memory。

Vortex common runtime本来就通过`callbacks_t`把平台差异压缩成
`cp_reg_read/write`和`host_mem_alloc/free`。guest侧实现把这组callback接到
`scope_vortex` PCI驱动；x86 bridge则把同一组callback接到XRT。因此vecadd、
module loader、buffer和queue代码保持平台无关，接入层只转换transport。

### 2.2 分层调用链

```text
XiangShan static Vortex application/runtime
  -> /dev/scope-vortexN ioctl + coherent DMA buffer
  -> virtual 4KB Vortex CP BAR
  -> FPGA BAR packet
  -> QEMU scope_fpga_vswitch_vortex_backend worker
  -> Unix socket RPC
  -> scope-vortex-bridge
  -> libvortex-xrt.so
  -> U280 Vortex CP
```

这条链上有三个协议边界：guest ioctl UAPI、FPGA/QEMU BAR packet、QEMU/bridge
Unix RPC。它们有意保持简单；Vortex command line的语义只由common runtime和
物理CP定义，FPGA不解析Vortex opcode。

QEMU只patch `MEM_WRITE`的host source和`MEM_READ`的host destination。Vortex device/HBM地址、DCR和launch命令保持不变。数据经过两段：

1. 香山guest buffer与QEMU之间通过XDMA coherent alias访问。
2. QEMU与U280 CP之间使用XRT `host_only` BO和U280 `m_axi_host`。

因此第一阶段是有软件搬运的mediated path，不是香山FPGA到U280的直接P2P。AMD的Host Memory Access要求kernel port连接`HOST[0]`，并在主机端启用host memory：[XRT Host Memory Access](https://xilinx.github.io/XRT/2024.1/html/hm.html)、[xbutil configure](https://xilinx.github.io/XRT/2024.1/html/xbutil.html)。

### 2.3 双CP队列模型

实现中“虚拟CP”和“物理CP”是两套独立状态，不能把两者的地址混用：

| 状态 | 存储位置 | 地址含义 | 所有者 |
| --- | --- | --- | --- |
| guest ring/head/completion | 香山DDR，`dma_alloc_coherent()` | 香山DMA地址 | guest runtime/driver |
| 虚拟CP寄存器 | QEMU `ScopeVortexState` | guest BAR0 local offset | QEMU |
| physical ring/head/completion | x86 host-only XRT BO | U280 `m_axi_host`地址 | QEMU worker/bridge |
| 物理CP寄存器 | U280 `vortex_afu` | CP native offset，经XRT加`0x1000` | U280 RTL/XRT backend |

QEMU启动Vortex backend时先通过bridge复位物理CP，分配固定64KB physical ring
以及64B head/completion BO，把这些BO地址写入物理CP，再缓存物理capability并
启动专用worker。之后guest对`Q_RING/Q_HEAD/Q_CMPL`的写入只更新虚拟CP状态，
不会覆盖物理CP已经安装的BO地址。

guest每打开一次Vortex device也会先写`Q_CONTROL.bit1`复位虚拟tail、seqnum和
error，再安装自己的coherent ring。这一步位于Vortex
`sw/runtime/common/device.cpp::Device::cp_init()`，用于避免前一进程退出后
QEMU仍保留旧虚拟tail，正是重复运行checker/vecadd仍能工作的前提。

### 2.4 一次命令如何执行

以common runtime提交一个64B command line为例，完整状态推进如下：

1. guest runtime把command line `memcpy`到香山coherent ring，并执行release
   fence。
2. runtime先写`Q_TAIL_LO`，再写`Q_TAIL_HI`；HI写是doorbell提交点。
3. BAR写经FPGA route table生成DMA32 packet；QEMU按packet中的BDF选择
   Vortex backend并更新虚拟tail。这里复用的是公共BAR transport，具体packet
   字段不在本文重复。
4. QEMU通过XDMA bypass coherent alias对每个新增command line连续读取两次；
   两次完全一致才认为guest写入可见，否则由非阻塞`poll`在5秒deadline内重试。
5. 稳定command被复制到`ScopeVortexJob`，共享DMA32 RX线程随即返回；耗时工作
   交给该backend的`scope-vortex` worker，避免GPU执行阻塞其他PCI backend。
6. worker逐条检查opcode、长度和地址。普通DCR、launch、fence、cache flush及
   device-to-device copy保持原命令；host/device transfer按下一节转换。
7. worker经RPC把patch后的64B line写入physical ring，写物理`Q_TAIL`，轮询
   物理`Q_SEQNUM`，最长等待120秒。
8. 物理job完成后，worker完成必要的数据回写，刷新cycle/last-DCR缓存，最后
   推进虚拟`Q_SEQNUM`。guest runtime只轮询虚拟seqnum，因此不会看到物理ring
   地址和物理seqnum基线。

若某一步失败，QEMU设置虚拟`Q_ERROR`，同时退休对应虚拟seqnum，避免guest
永远自旋。guest `sw/runtime/vswitch/vortex.cpp`在读取`Q_SEQNUM`前先检查
`Q_ERROR`，将transport错误转换成`-EIO`。详细错误码仍以
[`VSWITCH_REGISTER_INTERFACE_SPEC.md`](VSWITCH_REGISTER_INTERFACE_SPEC.md#72-queue-registers)
为准。

### 2.5 MEM_WRITE/MEM_READ地址翻译

Vortex command line固定为64B，其中memory命令的有效头部为28B：byte 0是
opcode，byte 4..11是destination，byte 12..19是source，byte 20..27是长度。
QEMU据opcode识别哪一个操作数属于guest host memory：

| 命令 | 原始含义 | QEMU动作 | 完成后动作 |
| --- | --- | --- | --- |
| `MEM_WRITE` | guest staging → Vortex device | 从guest PA读取数据到新XRT BO，把source改成BO的CP地址 | 释放BO |
| `MEM_READ` | Vortex device → guest staging | 分配XRT BO，把destination改成BO的CP地址 | 把BO内容写回guest PA并释放BO |
| `MEM_COPY` | Vortex device → Vortex device | 地址不改，只做device aperture范围检查 | 无软件搬运 |
| DCR/launch/fence/flush | 控制或执行命令 | 逐字节保持原command line | 缓存cycle或DCR响应 |

每个临时BO按64B对齐，单次RPC payload和guest DMA allocation上限都是16MB。
guest数据访问使用`scope_guest_mem_read/write()`，默认地址为：

```text
XDMA bypass offset = 0x100000000 coherent-alias base + guest physical address
```

FPGA的alias bridge减去`0x100000000`并设置cache属性后进入香山
`u_role/s_axi_dma`，所以QEMU读到的是经过一致性入口的guest内存，而不是可能
陈旧的raw DDR视图。

Vortex device地址不做host地址替换。QEMU从物理`GPU_CAPS`解码bank数量和每
bank容量，只验证RTL实际可寻址的aperture。当前单-bank设计的platform address
width为28，RTL会把标准kernel VMA `0x80000000`截成HBM offset 0；QEMU采用同样
的power-of-two aperture取模规则做范围检查，否则会错误拒绝正常的
`kernel.vxbin`上传。

## 3. 代码组成

### 仓库14

| 文件 | 职责 |
| --- | --- |
| `qemu-mount/hw/misc/scope_fpga_vswitch.c` | 配置解析、ECAM endpoint、generic manager |
| `qemu-mount/hw/misc/scope_fpga_vswitch_vortex_backend.c` | 虚拟CP BAR、命令翻译、异步worker |
| `qemu-mount/hw/misc/scope_vortex_bridge_proto.h` | QEMU侧RPC ABI副本 |
| `work_farm/software/linux/drivers/misc/scope_vortex.c` | 香山PCI transport和DMA UAPI |
| `work_farm/software/linux/include/uapi/linux/scope_vortex.h` | ioctl ABI |
| `nanhu-g/software/rootfs/apps/scripts/vortex-vecadd` | 可选rootfs安装 |
| `tools/proto/vswitch-vortex-u280.json` | 单Vortex backend配置示例 |

### Vortex仓库

| 文件 | 职责 |
| --- | --- |
| `tools/scope_vortex_bridge/main.cpp` | XRT driver loader和Unix RPC server |
| `tools/scope_vortex_bridge/build_u280.sh` | U280 platform/tool检查与xclbin构建 |
| `tools/scope_vortex_bridge/build_vecadd_riscv64.sh` | RISC-V host程序和RV32 GPU kernel构建 |
| `tools/scope_vortex_guest` | 静态RISC-V vecadd和capability checker |
| `sw/runtime/vswitch/vortex.cpp` | 香山侧Vortex callback backend |
| `sw/runtime/vswitch/scope_vortex_uapi.h` | userspace ioctl ABI副本 |

### 关键代码调用关系

| 阶段 | 主要函数/对象 | 作用 |
| --- | --- | --- |
| guest打开设备 | `vx_device::init()` in `sw/runtime/vswitch/vortex.cpp` | 打开`/dev/scope-vortex0` |
| guest建队列 | `Device::cp_init()` | 分配coherent ring/head/cmpl、复位并配置虚拟CP |
| guest提交 | `Device::cp_ring_append_()` / `cp_submit_cl_()` | 写64B line、提交tail、轮询seqnum |
| Linux transport | `scope_vortex_ioctl()` / `scope_vortex_mmap()` | BAR寄存器访问和coherent buffer UAPI |
| QEMU BAR入口 | `scope_vortex_process_bar_packet()` | 校验32-bit lane/wstrb并读写虚拟CP |
| QEMU捕获tail | `scope_vortex_try_submit_tail()` | 稳定读取guest ring并建立异步job |
| QEMU翻译/执行 | `scope_vortex_patch_line()` / `scope_vortex_execute_job()` | BO staging、physical ring提交与完成回写 |
| bridge RPC | `Bridge::dispatch()` | 将固定RPC映射到Vortex callbacks |
| XRT transport | `vx_device` in `sw/runtime/xrt/vortex.cpp` | 加载xclbin、访问CP、分配host-only BO |

这一表格也是定位问题时的边界：例如PCI枚举失败尚未进入Vortex runtime；
`Q_ERROR`非零说明已经越过guest driver；物理`Q_SEQNUM`不前进则问题位于
bridge/XRT/xclbin一侧。

## 4. U280 构建环境

构建xclbin需要Vitis和与其版本匹配的U280 development platform；仅运行已经
生成的xclbin则只需要deployment platform和XRT。可用下面的命令确认构建机上
的`.xpfm`位置：

```bash
find /opt/xilinx /opt/Xilinx_2022.2 -name '*u280*.xpfm' -print
```

当前产物对应Vitis 2022.2和
`xilinx_u280_gen3x16_xdma_1_202211_1`。deployment package不能替代
development package完成Vitis link；两者的安装方法和当前服务器的XRT选择见
运行手册，本节不再重复。

环境检查：

```bash
cd /home/yanjiarun/Vortex
tools/scope_vortex_bridge/build_u280.sh --check-only \
  --platform /path/to/xilinx_u280_gen3x16_xdma_1_202211_1.xpfm
```

没有`.xpfm`时，可以先完成RTL展开和Vivado kernel打包：

```bash
cd /home/yanjiarun/Vortex
VERILATOR=/path/to/verilator \
VITIS_SETUP=/opt/Xilinx_2022.2/Vitis/2022.2/settings64.sh \
tools/scope_vortex_bridge/build_u280.sh --xo-only
```

该模式使用逻辑平台名选择U280宏，不执行Vitis shell link。脚本会按所选
memory mode核对`.xo`中的AXI端口，release模式还会拒绝意外包含ILA的包并
输出SHA-256。最终`.xclbin`仍必须使用真实U280 `.xpfm`生成。

脚本自动探测本机Vitis安装，也可显式指定：

```bash
VITIS_SETUP=/opt/Xilinx_2022.2/Vitis/2022.2/settings64.sh \
tools/scope_vortex_bridge/build_u280.sh --check-only --platform /path/to/u280.xpfm
```

## 5. 生成 U280 xclbin

当前已验收基线固定一个Vortex core、一个HBM pseudo-channel和200MHz，以降低
U280 SLR0布线压力：

```bash
cd /home/yanjiarun/Vortex
VITIS_SETUP=/opt/Xilinx_2022.2/Vitis/2022.2/settings64.sh \
tools/scope_vortex_bridge/build_u280.sh \
  --platform /path/to/xilinx_u280_gen3x16_xdma_1_202211_1.xpfm \
  --target hw --num-cores 1 --memory-mode single --kernel-freq 200 --jobs 8
```

脚本默认显式关闭Vortex ILA/debug选项，避免shell中类似`DEBUG=release`的非空
变量被GNU Make误判为启用调试。只有需要片上调试时才添加`--debug`；该模式会
增加ILA、使用`--optimize 0`并显著增加资源和实现压力。

脚本内部调用：

```text
make -C hw/syn/xilinx/xrt TARGET=hw PLATFORM=<u280.xpfm>
     NUM_CORES=1 U280_MEMORY_MODE=single KERNEL_FREQ=200 PREFIX=build1_u280
```

### xclbin中的三个接口角色

- AXI-Lite control口由XRT映射为`vortex_afu` IP寄存器。Vortex CP原生窗口在
  kernel control base之后，因此XRT backend对CP offset统一加`0x1000`。
- `m_axi_host`只访问XRT `host_only` BO，承载physical ring、head、completion
  和MEM_READ/MEM_WRITE staging buffer；Vitis connectivity必须把它接到
  `HOST[0]`。
- `m_axi_mem_*`只访问Vortex device memory。当前`single`模式生成一个
  `m_axi_mem_0`并连接`HBM[0]`，capability报告1 bank、256MiB、address width
  28，guest也必须使用相同参数编译。

`platforms.mk`还保留`merged32`和`direct32`两种显式选项，供后续扩容到全部
32个pseudo-channel。connectivity必须与RTL实际生成的master数量一致，不能把
direct32构建误写成只有`m_axi_mem_0`的连接。当前验收不依赖这两个模式。最终
基线文件位于：

```text
/home/yanjiarun/Vortex/hw/syn/xilinx/xrt/
  build1_u280_<platform>_hw/bin/vortex_afu.xclbin
```

构建完成必须检查timing summary中WNS非负，并保存`bin/vivado.log`、utilization和timing报告。

## 6. 构建 Host Bridge

```bash
cd /home/yanjiarun/Vortex
source /home/yanjiarun/xrt-u280-2.16/setup.sh
make -C sw/runtime/xrt TARGET=hw
make -C tools/scope_vortex_bridge
```

产物：

```text
sw/runtime/libvortex-xrt.so
tools/scope_vortex_bridge/scope-vortex-bridge
```

### 为什么bridge是独立进程

bridge把XRT ABI、x86动态库和xclbin生命周期留在U280所在的x86主机，QEMU只
依赖一个固定Unix RPC协议，guest更不需要链接XRT。启动时bridge `dlopen()`
`libvortex-xrt.so`，设置device index/xclbin环境变量并打开`vortex_afu`；其RPC
只暴露HELLO、CP读写、host BO分配/释放及BO读写，不转发任意XRT调用。

BO handle只在一次socket session内有效；回复同时携带物理CP可见地址。bridge
一次只服务一个client，socket权限为0600。client断开时先复位物理queue/CP，
再释放全部BO，避免U280仍在取指时回收ring。QEMU专用worker串行使用该连接，
因此长时间物理执行不会阻塞公共BAR packet接收线程。

若XRT工具因动态库不匹配不能启动，应修复本地XRT环境，不应给bridge添加针对
旧`/opt`安装的私有兼容软链接。

## 7. 构建 vecadd 与 Rootfs

Vortex device kernel是RV32代码，需要Vortex预编译工具链：

```bash
cd /home/yanjiarun/Vortex
./ci/toolchain_install.sh --llvm --riscv32 --libcrt32 --libc32
tools/scope_vortex_bridge/build_vecadd_riscv64.sh
```

当前单-bank镜像可由仓库脚本一次完成guest工具、kernel、rootfs、Linux和
OpenSBI payload的匹配构建：

```bash
cd /home/yanjiarun/nexst_proxy_14
./tools/build_vortex_guest_single_bank.sh
```

其配置是1个cluster、1个core、1个HBM bank和28位平台地址宽度。通用
`build_u280.sh`启动时会打印`GUEST_CONFIGS=...`；无论使用哪个memory mode，
构建guest程序、GPU kernel和rootfs都必须传递这一整行参数。

如果xclbin使用了非默认Vortex配置，应在这里设置相同的`CONFIGS`，例如：

```bash
CONFIGS="-DVX_CFG_NUM_CLUSTERS=1 -DVX_CFG_NUM_CORES=2 -DVX_CFG_PLATFORM_MEMORY_NUM_BANKS=1 -DVX_CFG_PLATFORM_MEMORY_ADDR_WIDTH=28" \
tools/scope_vortex_bridge/build_vecadd_riscv64.sh
```

随后把应用集成进香山rootfs：

```bash
cd /home/yanjiarun/nexst_proxy_14/nanhu-g/software/rootfs
make VORTEX_ENABLE=1 \
  VORTEX_HOME=/home/yanjiarun/Vortex \
  RISCV=/opt/riscv64-linux \
  CROSS_COMPILE=/opt/riscv64-linux/bin/riscv64-unknown-linux-gnu-
```

不要依赖rootfs中的默认bank数量；应显式传入
`VORTEX_CONFIGS="<build_u280.sh打印的GUEST_CONFIGS>"`。单-bank包装脚本已经
执行此操作。

`VORTEX_ENABLE`默认是0，因此没有Vortex工具链时普通rootfs构建不受影响。启用后initramfs新增：

```text
/bin/vortex-vecadd
/bin/vx-vecadd
/bin/scope-vortex-check
/usr/lib/vortex/kernel.vxbin
/usr/lib/vortex/build-info
```

`vx-vecadd`和`scope-vortex-check`都是静态RISC-V ELF，不需要在精简
initramfs中安装`libvortex*.so`、`libstdc++.so`或backend plugin。wrapper会先
运行capability checker，核对物理U280的core/warp/thread、memory bank和ISA
配置，再提交vecadd。`VORTEX_CONFIGS`会写入`build-info`；xclbin、RV32
`kernel.vxbin`、静态RISC-V runtime和checker必须使用同一组配置。

### guest driver与runtime的分工

Linux `scope_vortex`驱动只提供两项机制：对4KB BAR0的对齐32-bit ioctl读写，
以及`dma_alloc_coherent()`得到的guest ring/staging buffer。设备采用独占open，
每个fd持有自己的allocation handle和mmap生命周期，单次allocation上限16MiB；
进程关闭时驱动统一回收。

静态RISC-V程序把Vortex common runtime与`sw/runtime/vswitch/vortex.cpp`直接
链接。callback打开`/dev/scope-vortex0`，把CP访问变成ioctl、把host allocation
变成driver mmap。`scope-vortex-check`只核对编译期capability是否与物理xclbin
一致；`vortex-vecadd`进一步覆盖module上传、launch以及双向数据搬运。common
runtime在每次`Device::cp_init()`时先复位虚拟queue，保证前一个进程退出后再次
运行不会继承旧tail/seqnum/error。

## 8. 上板与启动顺序

本节保留概要。当前服务器的逐终端命令、实际BDF、香山镜像装载、验收和停止
顺序见[`U280_QEMU_XIANGSHAN_RUNBOOK.md`](U280_QEMU_XIANGSHAN_RUNBOOK.md)。

1. 确认U280 deployment platform/XRT与xclbin platform匹配。
2. 使用本地XRT 2.16脚本装载驱动并启用1 GiB host memory：

```bash
cd /home/yanjiarun/nexst_proxy_14
./tools/u280_xrt_start.sh
source ./tools/u280_xrt_env.sh
```

3. 启动bridge，它会加载xclbin并打开物理Vortex CP：

```bash
sudo env \
  XILINX_XRT=/home/yanjiarun/xrt-u280-2.16 \
  LD_LIBRARY_PATH=/home/yanjiarun/xrt-u280-2.16/lib \
  /home/yanjiarun/Vortex/tools/scope_vortex_bridge/scope-vortex-bridge \
  --socket /run/scope-vortex0.sock \
  --driver-lib /home/yanjiarun/Vortex/sw/runtime/libvortex-xrt.so \
  --device-index 0 \
  --xclbin /path/to/vortex_afu.xclbin
```

4. 再启动仓库14 QEMU manager：

```bash
cd /home/yanjiarun/nexst_proxy_14/qemu-mount/build
sudo ./qemu-system-x86_64 \
  -machine q35 -m 128M -display none -monitor null -serial null \
  -device pcie-root-port,id=rp1,bus=pcie.0 \
  -device scope-fpga-vswitch,bus=rp1,\
backend-config=/home/yanjiarun/nexst_proxy_14/tools/proto/vswitch-vortex-u280.json,\
fpga-host-bdf=0000:2a:00.0,\
xdma-user-dev=/dev/xdma0_user,\
xdma-ctrl-dev=/dev/xdma0_control,\
xdma-bypass-dev=/dev/xdma0_bypass,\
guest-ddr-base=0x80000000,guest-ddr-size=0x80000000,\
dma32-ring-size=0x10000
```

5. 启动香山后检查并运行：

```bash
lspci -nnk
ls -l /dev/scope-vortex*
cat /usr/lib/vortex/build-info
scope-vortex-check
vortex-vecadd -n 64
```

预期PCI ID为`1b36:1310`、class`120000`，driver为`scope-vortex`。`vortex-vecadd`输出必须完成数据校验，不能只以进程退出或QEMU无报错为通过。

这个顺序是协议要求而非仅为操作习惯：QEMU realize阶段会立即与bridge握手、
分配physical queue并读取capability，所以bridge必须在QEMU之前；香山只有在
QEMU已经建立ECAM shadow、route和BAR backend后启动，才能稳定枚举合成endpoint。

## 9. 分层验收

| 层级 | 验收方法 | 失败归属 |
| --- | --- | --- |
| U280 platform | `xbutil examine/validate` | XRT、shell、板卡 |
| xclbin | bridge成功open并读取CP capabilities | Vitis链接、Vortex RTL、HOST[0] |
| QEMU transport | ECAM出现`1b36:1310`且BAR可读caps | JSON、socket、route、BAR packet |
| guest driver | `/dev/scope-vortex0`出现且独占open生效 | Linux config、PCI probe、UAPI |
| command path | `Q_SEQNUM`随tail增长，`Q_ERROR=0` | ring可见性、RPC、物理CP |
| data path | vecadd逐元素校验通过 | MEM_WRITE/MEM_READ地址patch和回写 |

capability通过只证明控制链和软硬件配置一致，不能替代数据通路测试。若checker
通过而vecadd失败，应先读取虚拟`Q_ERROR`并区分module上传、物理completion和
回写阶段；若重复运行第二次才失败，则优先检查guest `cp_init()`和bridge断连时
的queue reset，而不是重新烧写U280。

## 10. 当前部署状态

截至当前环境检查：

- U280位于`0000:ab:00.0/.1`，本地XRT 2.16的`xclmgmt/xocl`已经加载，
  user PF的1 GiB host memory已经启用。运行时使用
  `/home/yanjiarun/xrt-u280-2.16`，不修改也不依赖mount到`/opt`的旧XRT。
- 香山/NM37 FPGA位于`0000:2a:00.0`，绑定`xdma`并生成`/dev/xdma0_*`。
- bridge、`libvortex-xrt.so`、QEMU manager、`pcie-util`和`bootrom.bin`均已
  生成。当前成功加载的是
  `build1_u280_xilinx_u280_gen3x16_xdma_1_202211_1_hw/bin/vortex_afu.xclbin`。
- 香山使用匹配的`RV_BOOT_vortex_1bank.bin`：1 core、4 warps/core、
  4 threads/warp、1 memory bank、256MiB。`scope-vortex-check`可重复通过，
  `vortex-vecadd -n 64`已经完成校验，实测`400`条指令、`1474`周期。
- 当前单-bank路径已经完成控制面和数据面验收。以后切换32-bank时必须一起重建
  xclbin、`kernel.vxbin`、静态guest runtime/checker和`RV_BOOT`，不能只替换
  其中一个产物。
- 当前工作区没有`proto_nm37_vu37p/system.bit`。现有香山FPGA已经能枚举，
  若卡上确实是当前vSwitch设计可直接运行；若需更新设计，必须先生成正确的
  `system.bit`，不能使用U280 xclbin或其他板卡bitstream代替。

具体运行和故障定位步骤见
[`U280_QEMU_XIANGSHAN_RUNBOOK.md`](U280_QEMU_XIANGSHAN_RUNBOOK.md)。
