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

## 2. 控制与数据边界

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

QEMU只patch `MEM_WRITE`的host source和`MEM_READ`的host destination。Vortex device/HBM地址、DCR和launch命令保持不变。数据经过两段：

1. 香山guest buffer与QEMU之间通过XDMA coherent alias访问。
2. QEMU与U280 CP之间使用XRT `host_only` BO和U280 `m_axi_host`。

因此第一阶段是有软件搬运的mediated path，不是香山FPGA到U280的直接P2P。AMD的Host Memory Access要求kernel port连接`HOST[0]`，并在主机端启用host memory：[XRT Host Memory Access](https://xilinx.github.io/XRT/2024.1/html/hm.html)、[xbutil configure](https://xilinx.github.io/XRT/2024.1/html/xbutil.html)。

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

## 4. U280 构建环境

服务器已有Vitis/Vivado 2020.2、2022.2和2024.2，但当前没有U280 development platform。安装与Vitis匹配的U280开发包后，确认：

```bash
find /opt/xilinx /opt/Xilinx_2022.2 -name '*u280*.xpfm' -print
```

对现有Vitis 2022.2，优先使用U280 `xilinx_u280_gen3x16_xdma_1_202211_1` development platform。Ubuntu开发包为
`xilinx-u280-gen3x16-xdma-1-202211-1-dev_1-3585755_all.deb`，约175MB，AMD下载需要有效账户。不要只安装deployment package；它不能提供Vitis链接所需的`.xpfm`。下载后执行：

```bash
sudo apt install ./xrt_202220.2.14.354_22.04-amd64-xrt.deb
sudo apt install ./xilinx-u280-gen3x16-xdma-1-202211-1-dev_1-3585755_all.deb
```

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

该模式使用逻辑平台名选择U280宏，不执行Vitis shell link。脚本会核对`.xo`
包含`m_axi_host`与`m_axi_mem_0..31`，release模式还会拒绝意外包含ILA的
包，并输出SHA-256。最终`.xclbin`仍必须使用真实U280 `.xpfm`生成。

脚本自动探测本机Vitis安装，也可显式指定：

```bash
VITIS_SETUP=/opt/Xilinx_2022.2/Vitis/2022.2/settings64.sh \
tools/scope_vortex_bridge/build_u280.sh --check-only --platform /path/to/u280.xpfm
```

## 5. 生成 U280 xclbin

第一版固定一个Vortex core和250MHz，先降低资源/时序风险：

```bash
cd /home/yanjiarun/Vortex
VITIS_SETUP=/opt/Xilinx_2022.2/Vitis/2022.2/settings64.sh \
tools/scope_vortex_bridge/build_u280.sh \
  --platform /path/to/xilinx_u280_gen3x16_xdma_1_202211_1.xpfm \
  --target hw --num-cores 1 --kernel-freq 250 --jobs 8
```

脚本默认显式关闭Vortex ILA/debug选项，避免shell中类似`DEBUG=release`的非空
变量被GNU Make误判为启用调试。只有需要片上调试时才添加`--debug`；该模式会
增加ILA、使用`--optimize 0`并显著增加资源和实现压力。

脚本内部调用：

```text
make -C hw/syn/xilinx/xrt TARGET=hw PLATFORM=<u280.xpfm>
     NUM_CORES=1 KERNEL_FREQ=250 PREFIX=build32_u280
```

U280 connectivity由`platforms.mk`指定：32个Vortex device-memory AXI master
逐一连接到对应HBM channel，即`m_axi_mem_i -> HBM[i]`（`i=0..31`）；CP
host-memory master独立连接`HOST[0]`。不能只把`m_axi_mem_0`映射到
`HBM[0:31]`，否则打包后真实存在的`m_axi_mem_1..31`会悬空。最终文件位于：

```text
/home/yanjiarun/Vortex/hw/syn/xilinx/xrt/
  build32_u280_<platform>_hw/bin/vortex_afu.xclbin
```

构建完成必须检查timing summary中WNS非负，并保存`bin/vivado.log`、utilization和timing报告。

## 6. 构建 Host Bridge

```bash
cd /home/yanjiarun/Vortex
source /opt/xilinx/xrt/setup.sh
make -C sw/runtime/xrt TARGET=hw
make -C tools/scope_vortex_bridge
```

产物：

```text
sw/runtime/libvortex-xrt.so
tools/scope_vortex_bridge/scope-vortex-bridge
```

若XRT工具因缺失`libboost_filesystem.so.1.71.0`或`libboost_program_options.so.1.71.0`不能启动，应先修复XRT安装/动态库环境，不应给bridge添加私有兼容库。

## 7. 构建 vecadd 与 Rootfs

Vortex device kernel是RV32代码，需要Vortex预编译工具链：

```bash
cd /home/yanjiarun/Vortex
./ci/toolchain_install.sh --llvm --riscv32 --libcrt32 --libc32
tools/scope_vortex_bridge/build_vecadd_riscv64.sh
```

该脚本默认使用与`build_u280.sh --num-cores 1`一致的U280配置：1个cluster、
1个core、32个HBM bank、平台内存地址宽度33。`build_u280.sh`启动时会打印
一行`GUEST_CONFIGS=...`；构建guest程序、GPU kernel和rootfs时应使用该行
给出的完整值。

如果xclbin使用了非默认Vortex配置，应在这里设置相同的`CONFIGS`，例如：

```bash
CONFIGS="-DVX_CFG_NUM_CLUSTERS=1 -DVX_CFG_NUM_CORES=2 -DVX_CFG_PLATFORM_MEMORY_NUM_BANKS=32 -DVX_CFG_PLATFORM_MEMORY_ADDR_WIDTH=33" \
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

默认rootfs配置已经与一核U280构建一致。自定义`--num-cores`或其他Vortex
宏时，再显式传入`VORTEX_CONFIGS="<build_u280.sh打印的GUEST_CONFIGS>"`。

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

## 8. 上板与启动顺序

1. 确认U280 deployment platform/XRT与xclbin platform匹配。
2. 启用U280 host memory，BDF使用`xbutil examine`显示的user function：

```bash
sudo xbutil configure --device <U280-user-BDF> --host-mem enable --size 1G
```

3. 启动bridge，它会加载xclbin并打开物理Vortex CP：

```bash
sudo /home/yanjiarun/Vortex/tools/scope_vortex_bridge/scope-vortex-bridge \
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
fpga-host-bdf=0000:3b:00.0,\
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

## 9. 分层验收

| 层级 | 验收方法 | 失败归属 |
| --- | --- | --- |
| U280 platform | `xbutil examine/validate` | XRT、shell、板卡 |
| xclbin | bridge成功open并读取CP capabilities | Vitis链接、Vortex RTL、HOST[0] |
| QEMU transport | ECAM出现`1b36:1310`且BAR可读caps | JSON、socket、route、BAR packet |
| guest driver | `/dev/scope-vortex0`出现且独占open生效 | Linux config、PCI probe、UAPI |
| command path | `Q_SEQNUM`随tail增长，`Q_ERROR=0` | ring可见性、RPC、物理CP |
| data path | vecadd逐元素校验通过 | MEM_WRITE/MEM_READ地址patch和回写 |

## 10. 当前外部阻塞

截至当前环境检查：

- Vitis/Vivado工具可从`/opt/Xilinx_2022.2`等目录发现。
- U280 release配置已完成RTL source展开和Vivado 2022.2 `.xo`打包；IP
  integrity check通过，`kernel.xml`确认存在一个`m_axi_host`和
  `m_axi_mem_0..31`共32个device-memory master，包内没有ILA实例。当前
  预链接产物为
  `/home/yanjiarun/Vortex/hw/syn/xilinx/xrt/build32_u280_xo_check_xilinx_u280_gen3x16_xdma_1_202211_1_hw/bin/vortex_afu.xo`，
  SHA-256为`6de9c4a1fdfb02031b020d4e0450f19057c664fe8cf7c82024cbb6a168a8d528`。
- Vortex v3.0 RV32 LLVM/GNU/libc/libcrt工具链已安装到
  `/home/yanjiarun/tools`，`tests/regression/vecadd/kernel.vxbin`、静态
  `vx-vecadd`和`scope-vortex-check`均已成功生成；临时rootfs打包检查通过。
- 没有安装U280 development `.xpfm`，所以尚不能在已生成`.xo`之后执行
  Vitis shell link、place/route并生成`vortex_afu.xclbin`。
- `platforminfo -p xilinx_u280_gen3x16_xdma_1_202211_1`当前明确报告
  `No platform found`；Vitis 2022.2的搜索路径是`/opt/xilinx/platforms`和
  `/opt/Xilinx_2022.2/Vitis/2022.2/platforms`，不是构建脚本遗漏了已有平台。
- `/opt/xilinx/xrt`是面向旧发行版的XRT 2.14构建，依赖当前Ubuntu 22.04
  不具备的Boost 1.71。AMD提供匹配Jammy的
  `xrt_202220.2.14.354_22.04-amd64-xrt.deb`，部署前应安装该正式包；不要
  用Boost 1.74软链接冒充1.71。当前AMD公开下载端点从该服务器访问会超时。

这些是环境/依赖阻塞，不是代码静态编译错误。安装U280 development
platform和匹配Ubuntu 22.04的XRT后，直接重跑第5、6和8节即可继续，不需要
再修改接口代码。
