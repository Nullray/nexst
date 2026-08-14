# Vortex U280 vSwitch 集成与部署

## 1. 目标与产物

该实现让香山把U280上的Vortex视为vSwitch下游PCI endpoint。当前目标是在不引入Linux DRM/GPU驱动的前提下，运行Vortex原生回归测试套件。

整套系统包含三个独立产物：

| 产物 | 生成位置 | 部署位置 | 作用 |
| --- | --- | --- | --- |
| 香山vSwitch bitstream | 仓库14 FPGA flow | nm37_vu37p原型板 | ECAM、BAR packet、coherent alias |
| `vortex_afu.xclbin` | `/home/yanjiarun/Vortex/hw/syn/xilinx/xrt` | U280 | Vortex RTL kernel和Command Processor |
| 每测试独立的 `.vxbin` + static host | Vortex regression/rootfs flow | 香山initramfs | GPU程序及guest host runtime |

U280使用AMD Alveo shell和XRT动态加载xclbin，不烧写仓库14的Vivado bitstream。AMD说明development target platform提供Vitis编译所需的`.xpfm`，deployment platform和XRT用于上板运行：[U280 downloads](https://www.amd.com/en/support/downloads/alveo-downloads.html/accelerators/alveo/u280.html)、[UG1120](https://docs.amd.com/r/en-US/ug1120-alveo-platforms)。

本文重点解释Vortex接入层自身的实现和代码调用关系。通用vSwitch拓扑、ECAM、
route table和coherent alias见
[`PROJECT_ARCHITECTURE.md`](PROJECT_ARCHITECTURE.md)，精确寄存器和packet ABI见
[`VSWITCH_REGISTER_INTERFACE_SPEC.md`](VSWITCH_REGISTER_INTERFACE_SPEC.md)，
当前服务器的逐步操作见
[`U280_QEMU_XIANGSHAN_RUNBOOK.md`](U280_QEMU_XIANGSHAN_RUNBOOK.md)。下文只在
理解Vortex路径需要时引用这些公共机制，不重复完整定义。

## 2. 接入原理与控制/数据边界

### 2.1 为什么控制面使用mediated endpoint

U280 user PF属于x86服务器，由XRT负责装载xclbin、打开`vortex_afu` IP并管理
host-only BO；香山并没有到该PF的原生PCIe层次。因而这里不能把U280配置空间
或BAR简单转发给香山，而是在香山vSwitch中合成一个`1b36:1310` endpoint，
仅复现Vortex runtime真正依赖的两类抽象：

- 4KB Command Processor（CP）寄存器窗口；
- CPU可写且CP可DMA读取的host memory。

Vortex common runtime本来就通过`callbacks_t`把平台差异压缩成
`cp_reg_read/write`和`host_mem_alloc/free`。guest侧实现把这组callback接到
`scope_vortex` PCI驱动；x86 bridge则把同一组callback接到XRT。因此各回归
测试、module loader、buffer和queue代码保持平台无关，接入层只转换transport。

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

QEMU只patch `MEM_WRITE`的host source和`MEM_READ`的host destination。Vortex
device/HBM地址、DCR和launch命令保持不变。控制通路仍逐级中转，但明确选择
`direct-p2p`时，payload数据不再经过QEMU CPU：

```text
控制：guest驱动 → QEMU → Unix socket → bridge → U280 CP寄存器/队列
MEM_WRITE：U280 MRd → NM37 BAR2 coherent alias → M_AXI_BYPASS → 香山DDR → HBM
MEM_READ： HBM → U280 MWr → NM37 BAR2 coherent alias → M_AXI_BYPASS → 香山DDR
```

早期实现是有软件搬运的mediated path：香山guest buffer与QEMU之间通过XDMA
coherent alias访问；QEMU再把payload复制到XRT `host_only` BO，或在读方向完成
反向复制。它仍作为默认兼容模式保留，但不是direct-P2P验收路径。

之所以不能把guest command中的host地址**未经配置直接**交给物理CP，是因为
U280的`m_axi_host`普通映射只覆盖XRT管理的Host Memory。mediated模式中，bridge
通过XRT分配`host_only` BO，并使用`bo.address()`返回CP可见地址；XRT驱动和平台
Address Translator为这些地址建立映射。香山DDR地址（如`0x8...`）及其coherent
alias（`0x1_0000_0000 + PA`）默认都不在这个地址空间中，所以未经转换的guest
PA不会自动到达NM37。这解释了原句“第一阶段是有软件搬运的mediated path，
不是香山FPGA到U280的直接P2P”，但它描述的是原始实现约束，不是PCIe拓扑的
永久限制。

新路径利用已经验证的U280 PCIe Requester能力，在本地xocl的显式
`vortex_peer_mode=1`下把Address Translator分成32个4 MiB entry：前16个组成
64 MiB control Host Memory，后16个组成可动态重映射的64 MiB peer window。
`PEER_MAP`只接收allowlist内的NM37 BDF、BAR编号、BAR内offset和window size；
内核解析真实BAR总线地址并校验整个窗口。于是CP仍使用自己地址空间中的
`peer_cp_base + offset`，但该地址最终解析到NM37 BAR2，而不是普通host-only BO。
QEMU/bridge只做这一地址翻译和命令提交，Socket不携带MEM payload，日志必须显示
`payload_cpu_bytes=0`，NM37 XDMA H2C/C2H channel也不参与。

AMD的HOST[0]/Host Memory机制背景见
[XRT Host Memory Access](https://xilinx.github.io/XRT/2024.1/html/hm.html)和
[xbutil configure](https://xilinx.github.io/XRT/2024.1/html/xbutil.html)。本实现对
xocl的扩展位于用户目录XRT 2.16源码和安装树，不修改`/opt`。

### 2.3 双CP队列模型

实现中“虚拟CP”和“物理CP”是两套独立状态，不能把两者的地址混用：

| 状态 | 存储位置 | 地址含义 | 所有者 |
| --- | --- | --- | --- |
| guest ring/head/completion | 香山DDR，`dma_alloc_coherent()` | 香山DMA地址 | guest runtime/driver |
| 虚拟CP寄存器 | QEMU `ScopeVortexState` | guest BAR0 local offset | QEMU |
| physical ring/head/completion | x86 host-only XRT BO | U280 `m_axi_host`地址 | QEMU worker/bridge |
| 物理CP寄存器 | U280 `vortex_afu` | CP native offset，经XRT加`0x1000` | U280 RTL/XRT backend |

QEMU启动Vortex backend时先通过bridge停用物理queue并发出reset pulse，分配固定
64KB physical ring以及64B head/completion BO，把这些BO地址写入物理CP，再缓存
物理capability并启动专用worker。当前RTL的reset pulse不会清零fetch内部`head_r`
或engine的`seqnum_r`；因此QEMU重连时会读取现存physical seqnum，并按“一条64B
line对应一个command”的runtime约束恢复`physical_tail = seqnum * 64`。若重新加载
xclbin后seqnum为0，该公式自然从0开始。之后guest对`Q_RING/Q_HEAD/Q_CMPL`的
写入只更新虚拟CP状态，不会覆盖物理CP已经安装的BO地址。

guest每打开一次Vortex device也会先写`Q_CONTROL.bit1`复位虚拟tail、seqnum和
error，再安装自己的coherent ring。这一步位于Vortex
`sw/runtime/common/device.cpp::Device::cp_init()`，用于避免前一进程退出后
QEMU仍保留旧虚拟tail，正是重复运行checker和各测试仍能工作的前提。

### 2.4 一次命令如何执行

以common runtime提交一个64B command line为例，完整状态推进如下：

1. guest runtime把command line `memcpy`到香山coherent ring，并执行release
   fence。
2. runtime先写`Q_TAIL_LO`，再写`Q_TAIL_HI`；HI写是doorbell提交点。
3. BAR写经FPGA route table生成DMA32 packet；QEMU按packet中的BDF选择
   Vortex backend并更新虚拟tail。这里复用的是公共BAR transport，具体packet
   字段不在本文重复。
4. QEMU通过公共coherent-alias helper稳定读取command line本身；连续读取两次
   完全一致才认为guest写入可见，否则由非阻塞`poll`在5秒deadline内重试。这里
   读取的是64B控制描述符，不是MEM payload。
5. 稳定command被复制到`ScopeVortexJob`，共享DMA32 RX线程随即返回；耗时工作
   交给该backend的`scope-vortex` worker，避免GPU执行阻塞其他PCI backend。
6. direct-P2P worker顺序扫描命令。普通DCR、launch、fence、cache flush和
   device-to-device copy可组成physical batch；遇到MEM命令前先提交并等待此前
   batch，然后计算/切换64 MiB peer window，patch host operand，并单独提交这
   一条MEM命令。
7. 每个physical batch写入control Host Memory中的ring，doorbell物理`Q_TAIL`，
   等待`Q_SEQNUM`并读取物理`Q_ERROR`。由于窗口可能重编程，只有前一批PCIe请求
   完成后才允许切换generation。
8. 物理命令成功后才推进对应的virtual sequence；最后刷新cycle和DCR缓存。
   mediated兼容模式仍执行临时BO的payload上传/回写，但direct-P2P不会调用这些
   CPU copy路径。

若映射失败、物理`Q_ERROR`非零、CP超时或bridge断开，QEMU设置虚拟
`Q_ERROR`并退休失败virtual command，guest因此能从等待中退出；随后backend被
标记failed，QEMU停止/复位CP并撤销peer mapping。direct-P2P不会在同一job内自动
重试，也不会静默回退到mediated。guest `sw/runtime/vswitch/vortex.cpp`在读取
`Q_SEQNUM`前检查`Q_ERROR`，将transport错误转换成`-EIO`。详细错误码仍以
[`VSWITCH_REGISTER_INTERFACE_SPEC.md`](VSWITCH_REGISTER_INTERFACE_SPEC.md#72-queue-registers)
为准。

成功路径默认不打印日志，这是为了避免common runtime上传kernel、读写buffer和
轮询完成时淹没QEMU终端；它不表示命令绕过了QEMU。需要观察行为时，在
`scope-fpga-vswitch`设备参数中加入`vortex-log=on`。QEMU随后会在stderr打印
每个virtual job的tail/seqnum、command opcode和参数、guest PA、BAR offset、
peer target、window base、CP peer address、generation、map/command latency和
`payload_cpu_bytes=0`；高频`Q_SEQNUM`轮询不会逐次打印。

### 2.5 MEM_WRITE/MEM_READ地址翻译

Vortex command line固定为64B，其中memory命令的有效头部为28B：byte 0是
opcode，byte 4..11是destination，byte 12..19是source，byte 20..27是长度。
QEMU据opcode识别哪一个操作数属于guest host memory：

| 命令 | direct-P2P动作 | PCIe行为 |
| --- | --- | --- |
| `MEM_WRITE` | source由guest PA改成当前peer window中的CP地址；device destination不变 | U280发MRd读取香山DDR，再写HBM |
| `MEM_READ` | destination由guest PA改成当前peer window中的CP地址；device source不变 | U280从HBM读取并向香山DDR发MWr，随后readback MRd |
| `MEM_COPY` | 两个device地址均不改，只检查HBM aperture | 仅U280内部device memory AXI |
| DCR/launch/fence/flush | command内容保持不变 | 控制/执行，不切peer window |

固定地址规则为：

```text
guest DDR       = [0x80000000, 0x100000000)
coherent alias  = NM37 BAR2 offset 0x100000000 + guest PA
slot            = 4 MiB
peer window     = 64 MiB
window base     = align_down(guest_pa, 4 MiB)，DDR末尾钳制到end - 64 MiB
CP operand      = peer_cp_base + guest_pa - window base
```

长度先向上取整到64B，并同时检查guest DDR、当前64 MiB window、16 MiB单命令上限
和Vortex HBM aperture。窗口改变时，QEMU向bridge提交NM37 BDF、BAR2、BAR-relative
offset及64 MiB size；xocl在内核内解析BAR总线地址并返回递增generation。

mediated兼容模式才分配临时BO，并使用`scope_guest_mem_read/write()`进行CPU
payload复制。direct-P2P仍会通过公共coherent helper读取guest command ring这类
小型控制结构，但不会调用它搬运MEM数据；因此“QEMU不搬payload”并不等于QEMU
完全不访问guest DDR。
Vortex device地址不做host地址替换。QEMU从物理`GPU_CAPS`解码bank数量和每
bank容量，并按RTL实际可寻址的power-of-two aperture取模规则做范围检查。当前
单-bank设计的platform address width为28，即物理HBM窗口是256MiB；任何32位
Vortex地址最终只保留低28位。

这一截断还要求guest软件避免物理别名。标准kernel VMA `0x80000000`会落到HBM
offset 0，而console ring固定在`[0x40, 0x8340)`；两者会重叠。runtime随后会把
module指令当成console元数据读出，表现为`#3`、`#11`乱码或`xterm-256color`，
并在回写console读指针时破坏后续kernel指令。单-bank guest因此把所有RV32
`.vxbin`链接到`0x08000000`：低地址保留给console和从`0x10000`开始的buffer，
module loader预留`0x08000000`附近的镜像范围，`0x0fff0000`附近仍留给每hart
stack。该修复只改变guest kernel链接地址，不需要重编或重刷xclbin。


### 2.6 MEM_READ完成顺序与错误反馈

PCIe MWr是posted write，仅看到最后一个AXI `B` response不足以证明写入已经到达
NM37 DDR的一致性入口。`VX_cp_dma.sv`因此记录MEM_READ最初的host destination：
最后一个write burst收到`B`后，从同一地址再发一个64B、单拍AXI read，丢弃数据，
收到该non-posted read completion后才报告DMA完成。该fence适用于所有MEM_READ，
不依赖地址范围，也不复用guest `CMD_FENCE`。同一Requester/Function内，该read
completion为此前posted writes提供所需的完成顺序点。

DMA同时检查数据读`RRESP/RLAST`、写`BRESP`和readback `RRESP/RLAST`。错误携带
queue owner进入CP core，置对应queue的sticky `Q_ERROR`并汇总到
`CP_STATUS.error`；只由现有`Q_CONTROL.reset`或CP reset清除。RTL不新增第二套
超时/复位状态机，AXI无响应仍由QEMU 120秒watchdog处理。direct-P2P因此必须使用
包含该RTL修改重新生成的`vortex_afu.xclbin`，只更新host软件不能取得MEM_READ
完成保证和物理`Q_ERROR`反馈。
## 3. 代码组成

### 仓库14

| 文件 | 职责 |
| --- | --- |
| `qemu-mount/hw/misc/scope_fpga_vswitch.c` | 配置解析、ECAM endpoint、generic manager |
| `qemu-mount/hw/misc/scope_fpga_vswitch_vortex_backend.c` | 虚拟CP BAR、命令翻译、异步worker |
| `qemu-mount/hw/misc/scope_vortex_bridge_proto.h` | QEMU侧RPC ABI副本 |
| `work_farm/software/linux/drivers/misc/scope_vortex.c` | 香山PCI transport和DMA UAPI |
| `work_farm/software/linux/include/uapi/linux/scope_vortex.h` | ioctl ABI |
| `nanhu-g/software/rootfs/apps/scripts/vortex-vecadd` | 多测试构建、通用wrapper与rootfs安装；目录名为兼容旧入口而保留 |
| `tools/proto/vswitch-vortex-u280.json` | 单Vortex backend配置示例 |

### Vortex仓库

| 文件 | 职责 |
| --- | --- |
| `tools/scope_vortex_bridge/main.cpp` | XRT driver loader和Unix RPC server |
| `tools/scope_vortex_bridge/build_u280.sh` | U280 platform/tool检查与xclbin构建 |
| `tools/scope_vortex_bridge/build_guest_tests_riscv64.sh` | 多个RISC-V静态host和RV32 GPU kernel构建 |
| `tools/scope_vortex_bridge/build_vecadd_riscv64.sh` | 调用上述脚本的兼容入口 |
| `tools/scope_vortex_guest` | 共享静态runtime、各测试host和capability checker |
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
| QEMU翻译/执行 | `scope_vortex_patch_direct_mem()` / `scope_vortex_execute_job_direct()` | peer window切换、operand patch、physical batch提交 |
| bridge RPC | `Bridge::dispatch()` | 将固定RPC映射到Vortex callbacks |
| XRT transport | `vx_device` in `sw/runtime/xrt/vortex.cpp` | 加载xclbin、访问CP、control BO以及peer query/map/unmap |

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
     NUM_CORES=1 U280_MEMORY_MODE=single KERNEL_FREQ=200 PREFIX=build1_p2p
```

### xclbin中的三个接口角色

- AXI-Lite control口由XRT映射为`vortex_afu` IP寄存器。Vortex CP原生窗口在
  kernel control base之后，因此XRT backend对CP offset统一加`0x1000`。
- `m_axi_host`接到Vitis `HOST[0]`，既访问前64 MiB control Host Memory中的
  physical ring/head/completion，也经后64 MiB peer window访问NM37 BAR2。它是
  U280发起MRd/MWr的requester接口；direct-P2P不再分配MEM staging BO。
- `m_axi_mem_*`只访问Vortex device memory。当前`single`模式生成一个
  `m_axi_mem_0`并连接`HBM[0]`，capability报告1 bank、256MiB、address width
  28，guest也必须使用相同参数编译。

`platforms.mk`还保留`merged32`和`direct32`两种显式选项，供后续扩容到全部
32个pseudo-channel。connectivity必须与RTL实际生成的master数量一致，不能把
direct32构建误写成只有`m_axi_mem_0`的连接。当前验收不依赖这两个模式。最终
基线文件位于：

```text
/home/yanjiarun/Vortex/hw/syn/xilinx/xrt/
  build1_p2p_<platform>_hw/bin/vortex_afu.xclbin
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
`libvortex-xrt.so`，设置device index/xclbin环境变量并打开`vortex_afu`。v1 RPC
保留HELLO、CP读写和BO操作；v2增加`PEER_CAPS/PEER_MAP/PEER_UNMAP`，并由
`--allow-peer-bdf`把可映射目标限制为一个NM37 function。direct-P2P握手拿不到
v2 peer callback时直接失败，mediated仍可使用v1。

BO handle和peer generation都只在一次socket session内有效。bridge一次只服务
一个client，socket权限为0600。client断开时按“停止CP、撤销peer mapping、释放
control BO、关闭U280”的顺序清理。QEMU专用worker串行使用该连接，因此长时间
物理执行不会阻塞公共BAR packet接收线程，也不会在映射重编程时留下在途请求。

若XRT工具因动态库不匹配不能启动，应修复本地XRT环境，不应给bridge添加针对
旧`/opt`安装的私有兼容软链接。

## 7. 构建测试套件与 Rootfs

Vortex device kernel是RV32代码，需要Vortex预编译工具链：

```bash
cd /home/yanjiarun/Vortex
./ci/toolchain_install.sh --llvm --riscv32 --libcrt32 --libc32
CROSS_CXX=/usr/bin/riscv64-linux-gnu-g++ \
  tools/scope_vortex_bridge/build_guest_tests_riscv64.sh
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
STARTUP_ADDR=0x08000000 \
VORTEX_TESTS="vecadd sgemm conv3 multikernel bfs sort" \
CROSS_CXX=/usr/bin/riscv64-linux-gnu-g++ \
  tools/scope_vortex_bridge/build_guest_tests_riscv64.sh
```

随后把应用集成进香山rootfs：

```bash
cd /home/yanjiarun/nexst_proxy_14/nanhu-g/software/rootfs
make VORTEX_ENABLE=1 \
  VORTEX_HOME=/home/yanjiarun/Vortex \
  VORTEX_CONFIGS="-DVX_CFG_NUM_CLUSTERS=1 -DVX_CFG_NUM_CORES=1 -DVX_CFG_PLATFORM_MEMORY_NUM_BANKS=1 -DVX_CFG_PLATFORM_MEMORY_ADDR_WIDTH=28" \
  VORTEX_STARTUP_ADDR=0x08000000 \
  VORTEX_TESTS="vecadd sgemm conv3 multikernel bfs sort" \
  RISCV=/usr CROSS_COMPILE=riscv64-linux-gnu-
```

不要依赖rootfs中的默认bank数量；应显式传入
`VORTEX_CONFIGS="<build_u280.sh打印的GUEST_CONFIGS>"`。单-bank包装脚本已经
执行此操作。

`VORTEX_ENABLE`默认是0，因此没有Vortex工具链时普通rootfs构建不受影响。启用后initramfs新增：

```text
/bin/scope-vortex-check
/bin/vortex-run
/bin/vortex-run-all
/bin/vortex-{vecadd,sgemm,conv3,multikernel,bfs,sort}
/bin/vx-{vecadd,sgemm,conv3,multikernel,bfs,sort}
/usr/lib/vortex/{vecadd,sgemm,conv3,multikernel,bfs,sort}.vxbin
/usr/lib/vortex/build-info
```

构建系统先把Vortex common runtime和`vswitch` backend编成一个静态archive，再
分别链接六个测试的`main.cpp`；这样公共源码只编译一次，但每个guest ELF仍然
自包含，不依赖initramfs中的`libvortex*.so`、`libstdc++.so`或backend plugin。
`vortex-TEST`软链接统一进入`vortex-run`，由命令名选择`vx-TEST`及同名`.vxbin`。
wrapper在提交测试前运行capability checker；`vortex-run-all`只检查一次并按保守
规模依次运行整套测试，首项失败即退出。

`VORTEX_CONFIGS`、`VORTEX_STARTUP_ADDR`和`VORTEX_TESTS`都会写入`build-info`，后者还记录每个kernel的
SHA-256。xclbin、所有RV32 `.vxbin`、静态RISC-V runtime和checker必须使用同一
组配置。

### guest driver与runtime的分工

Linux `scope_vortex`驱动只提供两项机制：对4KB BAR0的对齐32-bit ioctl读写，
以及`dma_alloc_coherent()`得到的guest ring/staging buffer。设备采用独占open，
每个fd持有自己的allocation handle和mmap生命周期，单次allocation上限16MiB；
进程关闭时驱动统一回收。

静态RISC-V程序把Vortex common runtime与`sw/runtime/vswitch/vortex.cpp`直接
链接。callback打开`/dev/scope-vortex0`，把CP访问变成ioctl、把host allocation
变成driver mmap。`scope-vortex-check`只核对编译期capability是否与物理xclbin
一致；`vecadd`覆盖基本module上传、launch和双向数据搬运，`sgemm/conv3`增加
浮点计算，`conv3 -l`覆盖local-memory路径，`multikernel`覆盖连续多kernel提交，
`bfs/sort`增加不规则访存和同步压力。common runtime在每次
`Device::cp_init()`时先复位虚拟queue，保证前一个进程退出后再次运行不会继承
旧tail/seqnum/error。

## 8. 上板与启动顺序

本节保留概要。当前服务器的逐终端命令、实际BDF、香山镜像装载、验收和停止
顺序见[`U280_QEMU_XIANGSHAN_RUNBOOK.md`](U280_QEMU_XIANGSHAN_RUNBOOK.md)。

1. 确认U280 deployment platform/XRT与xclbin platform匹配。
2. 使用本地XRT 2.16脚本以peer mode装载驱动，并配置/验证64 MiB control
   Host Memory、4 MiB translator slot、64 MiB peer window和NM37 BAR2：

```bash
cd /home/yanjiarun/nexst_proxy_14
sudo ./tools/u280_xrt_start.sh \
  --vortex-p2p \
  --u280-bdf 0000:ab:00.1 \
  --peer-bdf 0000:2a:00.0
source ./tools/u280_xrt_env.sh
```

脚本只使用`/home/yanjiarun/xrt-u280-2.16`，不会读写或替换`/opt`。若xocl已用
普通模式加载，或Host Memory仍是1 GiB，脚本列出可能的占用进程并明确失败，
不会自动解绑设备。首次配置64 MiB后需要加载P2P-capable xclbin才能查询平台
layout；如query提示layout尚未active，加载xclbin后用`--no-host-mem`重跑校验。

3. 启动bridge，它会加载xclbin并打开物理Vortex CP：

```bash
sudo env \
  XILINX_XRT=/home/yanjiarun/xrt-u280-2.16 \
  LD_LIBRARY_PATH=/home/yanjiarun/xrt-u280-2.16/lib \
  /home/yanjiarun/Vortex/tools/scope_vortex_bridge/scope-vortex-bridge \
  --socket /run/scope-vortex0.sock \
  --driver-lib /home/yanjiarun/Vortex/sw/runtime/libvortex-xrt.so \
  --device-index 0 \
  --xclbin /path/to/vortex_afu.xclbin \
  --allow-peer-bdf 0000:2a:00.0
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
vortex-log=on,dma32-ring-size=0x10000
```

5. 启动香山后检查并运行：

```bash
lspci -nnk
ls -l /dev/scope-vortex*
cat /usr/lib/vortex/build-info
scope-vortex-check
vortex-vecadd -n 64
vortex-run-all
```

预期PCI ID为`1b36:1310`、class`120000`，driver为`scope-vortex`。先用
`vortex-vecadd`确认基本数据路径，再用`vortex-run-all`覆盖整套测试；必须看到
应用自身的数据校验通过，不能只以进程退出或QEMU无报错为通过。

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
| basic data path | vecadd逐元素校验通过 | peer映射、MEM_WRITE/MEM_READ和readback fence |
| extended execution | sgemm、conv3、multikernel、bfs、sort全部通过 | 浮点/local memory、多kernel、不规则访存与同步 |

capability通过只证明控制链和软硬件配置一致，不能替代数据通路测试。若checker
通过而计算测试失败，应先读取虚拟`Q_ERROR`并区分module上传、物理completion和
回写阶段；若重复运行第二次才失败，则优先检查guest `cp_init()`和bridge断连时
的queue reset，而不是重新烧写U280。

## 10. 实现状态与部署边界

当前代码已经包含direct-P2P所需的xocl私有ioctl、Vortex runtime v2、Bridge RPC
v2、QEMU direct executor、CP readback fence/error反馈、启动校验脚本和direct-P2P
JSON示例。本地xocl已构建并安装到
`/home/yanjiarun/xrt-u280-2.16/modules/<running-kernel>`；`/opt`未被修改。

这些代码完成不等于当前卡上产物已经切换：

- direct-P2P要求把新`VX_cp_dma/VX_cp_core`重新综合进
  `vortex_afu.xclbin`，然后以peer mode重新配置64 MiB Host Memory并启动bridge；
- 旧xclbin仍可配合默认`mediated` JSON和原1 GiB Host Memory运行，但不能宣称
  direct-P2P，也不具备MEM_READ readback fence和物理`Q_ERROR`反馈；
- 香山/NM37默认BDF为`0000:2a:00.0`、U280 user PF默认BDF为`0000:ab:00.1`。
  部署时仍由启动参数和sysfs校验，不能把默认值当作安全依据；
- guest继续采用匹配的单-bank配置：1 core、4 warps/core、4 threads/warp、1 bank、
  256 MiB。切换bank/core参数时，xclbin、全部`.vxbin`、static guest runtime、
  checker和`RV_BOOT`必须一起重建；
- direct-P2P板级验收不能由软件构建替代。必须按下一节检查ILA requester方向、
  `payload_cpu_bytes=0`、无H2C/C2H payload流量、无新增AER并连续运行全部测试。

具体运行和故障定位步骤见
[`U280_QEMU_XIANGSHAN_RUNBOOK.md`](U280_QEMU_XIANGSHAN_RUNBOOK.md)。

## 11. Direct-P2P板级验收

1. 运行`u280_xrt_start.sh --vortex-p2p`并确认slot为4 MiB、control/peer均64 MiB。
2. 先测64B MEM_WRITE/MEM_READ；在NM37 `M_AXI_BYPASS` ILA上确认前者出现AR/R，
   后者出现AW/W/B后紧跟readback AR/R。
3. 依次测试64B、4 KiB-64、4 KiB、4 KiB+64、1 MiB和16 MiB，并覆盖4 MiB slot、
   64 MiB window切换以及guest DDR末尾钳制。
4. 连续重复`scope-vortex-check`、`vortex-vecadd`、`vortex-sgemm`、`vortex-bfs`、
   `vortex-multikernel`和`vortex-run-all`，每项都检查应用结果而非只看退出码。
5. 注入非法地址、bridge kill、xclbin reset、peer remove和CP timeout，确认guest
   取得`Q_ERROR`并退出等待，mapping在owner fd关闭/reset/remove后撤销。
6. 检查direct日志始终为`payload_cpu_bytes=0`，Socket无MEM payload，
   `/dev/xdma*_h2c_*`和`/dev/xdma*_c2h_*`无Vortex payload流量，且`dmesg`无新增AER。
