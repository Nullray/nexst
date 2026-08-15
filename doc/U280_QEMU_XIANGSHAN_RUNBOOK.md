# U280 Vortex、QEMU vSwitch 与香山完整运行手册

本文给出当前服务器上的实际启动顺序。三个 FPGA/进程的职责不要混淆：

| 对象 | 当前标识 | 装载内容 |
| --- | --- | --- |
| Alveo U280 management PF | `0000:ab:00.0` (`10ee:500c`) | XRT `xclmgmt` |
| Alveo U280 user PF | `0000:ab:00.1` (`10ee:500d`) | XRT `xocl` 和 `vortex_afu.xclbin` |
| 香山 NM37/VU37P FPGA | `0000:2a:00.0` (`10ee:903f`) | 仓库 14 的 `system.bit`，主机驱动为 `xdma` |
| Vortex bridge | `/run/scope-vortex0.sock` | 把 QEMU RPC 转换为 XRT/Vortex 命令 |
| QEMU vSwitch manager | 主机进程，不启动 x86 guest OS | 管理香山 FPGA vSwitch、XDMA 和 Vortex backend |
| 香山系统 | NM37 FPGA 上的 RISC-V SoC | `bootrom.bin` 和 `RV_BOOT.bin` |

当前 BDF 是本机在本文编写时的枚举结果，换 PCIe 插槽或重新枚举后可能变化。
每次启动前都应重新用 `lspci -Dnnk` 确认，不能永久假设 BDF 不变。

## 1. 当前产物与重要限制

当前已存在以下运行产物：

```text
/home/yanjiarun/xrt-u280-2.16
/home/yanjiarun/Vortex/tools/scope_vortex_bridge/scope-vortex-bridge
/home/yanjiarun/Vortex/sw/runtime/libvortex-xrt.so
/home/yanjiarun/Vortex/hw/syn/xilinx/xrt/
  build1_p2p_xilinx_u280_gen3x16_xdma_1_202211_1_hw/bin/vortex_afu.xclbin
/home/yanjiarun/nexst_proxy_14/qemu-mount/build/qemu-system-x86_64
/home/yanjiarun/nexst_proxy_14/tools/proto/pcie-util
/home/yanjiarun/nexst_proxy_14/nanhu-g/ready_for_download/proto_nm37_vu37p/bootrom.bin
/home/yanjiarun/nexst_proxy_14/nanhu-g/ready_for_download/proto_nm37_vu37p/RV_BOOT.bin
/home/yanjiarun/nexst_proxy_14/nanhu-g/ready_for_download/proto_nm37_vu37p/RV_BOOT_vortex_1bank.bin
```

用于当前 `build1...xclbin` 的镜像是 `RV_BOOT_vortex_1bank.bin`。镜像包含 capability checker、通用启动器和一组彼此独立的 host/kernel：

```text
/bin/scope-vortex-check
/bin/vortex-run
/bin/vortex-run-all
/bin/vortex-{vecadd,sgemm,conv3,multikernel,bfs,sort}
/bin/vx-{vecadd,sgemm,conv3,multikernel,bfs,sort}
/usr/lib/vortex/{vecadd,sgemm,conv3,multikernel,bfs,sort}.vxbin
/usr/lib/vortex/build-info
```

`vortex-TEST` 是指向 `vortex-run` 的软链接。启动器会自动选择同名静态 host
程序和 `/usr/lib/vortex/TEST.vxbin`；`vortex-run TEST ...` 也可直接使用。

当前 `build1...xclbin` 只连接 `m_axi_mem_0 -> HBM[0]`。匹配的 guest
runtime/kernel 已按以下参数重新构建并封装到上述新镜像：

```text
VX_CFG_NUM_CLUSTERS=1
VX_CFG_NUM_CORES=1
VX_CFG_PLATFORM_MEMORY_NUM_BANKS=1
VX_CFG_PLATFORM_MEMORY_ADDR_WIDTH=28
VORTEX_STARTUP_ADDR=0x08000000
```

`STARTUP_ADDR=0x08000000` 是当前所有 RV32 `.vxbin` 的链接/装载基址，位于单个
256 MiB HBM bank 的合法地址范围内。不能把使用旧默认值 `0x80000000` 构建的
kernel 与当前 28-bit HBM 地址空间组合；这类错误不一定在 capability checker
阶段暴露，可能表现为 module load、launch 或运行结果异常。

原来的 `RV_BOOT.bin` 仍保留为 32-bank 版本，没有被覆盖；不要将它与当前
单-bank xclbin 组合使用。

当前direct-P2P xclbin已经从包含`VX_cp_dma.sv` readback/error修改的RTL重新
生成，Vitis/Vivado实现完成且满足时序约束。板级验收必须使用上述
`build1_p2p.../vortex_afu.xclbin`，不能退回旧的`build1_u280...`产物。

重新生成单-bank guest镜像可执行：

```bash
cd /home/yanjiarun/nexst_proxy_14
./tools/build_vortex_guest_single_bank.sh
```

该脚本使用 `/usr/bin/riscv64-linux-gnu-*`，不会修改 `/opt`。当前版本会统一
传入 `STARTUP_ADDR=0x08000000`，构建六个 host/kernel，检查 initramfs 中的
wrapper、静态 host、`.vxbin` 和 RISC-V 动态库，并检查最终镜像内嵌的 startup
address、core 数、bank 数和地址宽度。

源码或测试 kernel 改变后不能只看旧镜像文件是否存在，应重新执行脚本。构建
完成后可在主机侧检查嵌入的版本、配置和 kernel 哈希：

```bash
strings -a \
  nanhu-g/ready_for_download/proto_nm37_vu37p/RV_BOOT_vortex_1bank.bin |
  grep -E '^(vortex_(commit|branch|configs|startup_addr|tests)=|VX_CFG_)'

git -C /home/yanjiarun/Vortex rev-parse HEAD
```

可复现的正式镜像应让 `vortex_commit` 对应预期源码提交，并显示
`vortex_startup_addr=0x08000000`、一个 core、一个 memory bank、28-bit address
width。若镜像是从 dirty tree 构建的，commit 字段本身不足以证明内容，必须重建
或同时核对 `build-info` 中每个 `*_kernel_sha256`。

## 2. 哪些动作需要重复

### 只在设计改变、掉电丢失配置或设备未枚举时做

- 用 Vivado 把仓库 14 的 `system.bit` 配置到 NM37/VU37P。
- 配置 FPGA 后在保持板卡供电的前提下温重启主机，使 PCIe endpoint 被固件和
  Linux 重新枚举。
- 内核升级后重建与新内核匹配的 XRT 模块。

### 每次主机启动后做

1. 检查 U280、香山 FPGA 和 BDF。
2. 运行本地XRT direct-P2P启动脚本；它装载驱动、启用64MiB control Host
   Memory、加载xclbin并校验相邻64MiB peer window。
3. 确认香山侧 `xdma` 驱动和 `/dev/xdma0_*`。
4. 启动Vortex bridge；bridge会打开同一xclbin并提供peer RPC。
5. 启动采用 Vortex backend JSON 的 QEMU manager。
6. 装载香山 `bootrom.bin`、`RV_BOOT_vortex_1bank.bin` 并打开串口。
7. 在香山 Linux 中检查虚拟 PCIe endpoint、驱动和 Vortex 测试套件。

仅仅执行 `xbutil program` 成功还不够。QEMU 运行期间必须一直有 bridge
进程提供 `/run/scope-vortex0.sock`。

## 3. 启动前停止旧 manager

同一组 `/dev/xdma0_*` 不能同时交给两个 QEMU manager。先检查：

```bash
pgrep -af 'scope-vortex-bridge|qemu-system-x86_64|pcie-util.*uart'
```

本文编写时主机上已有一个使用 `vswitch-backends-1SSD.json` 的 QEMU 进程。
切换到 Vortex 配置前，应回到启动它的终端按 `Ctrl-C`；若它由服务管理，则用
对应服务的正常停止命令。再次执行上面的 `pgrep`，确认旧 QEMU 已退出。不要在
QEMU 仍占用设备时卸载 `xdma` 或重新烧写香山 FPGA。

## 4. 检查两张 FPGA 卡

```bash
lspci -Dnnk | grep -A4 -B1 -E 'Xilinx|10ee:'

# U280：应分别显示 xclmgmt 和 xocl
readlink -f /sys/bus/pci/devices/0000:ab:00.0/driver
readlink -f /sys/bus/pci/devices/0000:ab:00.1/driver

# 香山 FPGA：当前应显示 xdma，并存在设备节点
readlink -f /sys/bus/pci/devices/0000:2a:00.0/driver
ls -l /dev/xdma0_user /dev/xdma0_control /dev/xdma0_bypass
```

预期 PCI ID/驱动为：

```text
0000:ab:00.0  10ee:500c  xclmgmt
0000:ab:00.1  10ee:500d  xocl
0000:2a:00.0  10ee:903f  xdma
```

如果 `ab:00.0` 显示为 `10ee:9038`、绑定通用 `xdma`，而且没有 `ab:00.1`，则
当前 U280 不处于本文要求的 Alveo deployment shell/XRT PF 状态。不要把这个
function 当作 `--u280-bdf` 继续运行；`u280_xrt_start.sh` 会按代码中的 PCI ID
检查主动拒绝。应先按既定板卡 provisioning 恢复 `500c/500d`，完成冷重启并
重新枚举，再继续本手册。

### 4.1 何时需要 Vivado

如果 `0000:2a:00.0` 已存在、绑定 `xdma`，并且确定卡上的设计就是当前仓库 14
的 vSwitch bitstream，本轮不需要在 Vivado 中操作。

若必须更新香山 FPGA，目标文件按仓库 flow 应为：

```text
/home/yanjiarun/nexst_proxy_14/nanhu-g/ready_for_download/
  proto_nm37_vu37p/system.bit
```

当前工作区中还没有这个 `system.bit`，因此不要拿其他项目或其他板卡的 bitstream
代替。先按仓库根目录 `README.md` 的 `nm37_vu37p` flow 生成它，再在 Vivado
Hardware Manager 中选择器件型号为 `xcvu37p` 的目标进行 Program Device。
U280 的 FPGA 器件是 `xcu280`；不要根据 cable 序列号猜测，更不能把香山
`system.bit` 下载到 U280。可见的两个 target 中，必须展开 target 并按器件型号
确认：`xcvu37p` 才是香山卡，`xcu280` 是 U280。

JTAG 配置是易失的。配置 `system.bit` 后，应在保持板卡供电的前提下温重启
主机，再重新检查 BDF 和 `/dev/xdma*`；不要对板卡断电，否则刚写入的配置会
丢失。运行中也不要直接重烧，否则当前 XDMA/QEMU 映射会失效。

## 5. 初始化本地 XRT（不修改 `/opt`）

```bash
cd /home/yanjiarun/nexst_proxy_14
sudo ./tools/u280_xrt_start.sh \
  --vortex-p2p \
  --u280-bdf 0000:ab:00.1 \
  --peer-bdf 0000:2a:00.0 \
  --xclbin /home/yanjiarun/Vortex/hw/syn/xilinx/xrt/\
build1_p2p_xilinx_u280_gen3x16_xdma_1_202211_1_hw/bin/vortex_afu.xclbin
source ./tools/u280_xrt_env.sh

xbutil examine --device 0000:ab:00.1 --report platform pcie-info
cat /sys/bus/pci/devices/0000:ab:00.1/host_mem_size
```

预期 user PF 为 `10ee:500d`、驱动为 `xocl`，`Enabled Host Memory` 为
`64 MB`，sysfs值为`67108864`。脚本还必须打印slot size `4194304`、control
size `67108864`、peer size `67108864`。当前代码还会读取 NM37 PCI resource
table，要求 `--peer-bdf` 的 BAR2 是已分配的 memory BAR 且至少 8 GiB；该检查
失败时不会装载 direct-P2P session。脚本成功时还会打印：

```text
Bridge allowlist argument: --allow-peer-bdf 0000:2a:00.0
```

若已经加载了不带`vortex_peer_mode=1`的xocl、Host Memory仍为1GiB，或bridge
正在占用U280，脚本会列出相关进程并退出，不会自动解绑设备。停止用户进程后，
由管理员显式卸载旧模块/禁用旧Host Memory，再重新运行脚本。后续不要混用
`/opt/xilinx/xrt`的XRT 2.14工具和本地XRT 2.16驱动；bridge也必须解析到本地
XRT 2.16动态库。

每次 bridge 启动前可检查：

```bash
LD_LIBRARY_PATH=/home/yanjiarun/xrt-u280-2.16/lib \
ldd /home/yanjiarun/Vortex/sw/runtime/libvortex-xrt.so | grep -E 'xrt|not found'
```

## 6. 启动 Vortex bridge（终端 A）

启动脚本中的`xbutil program`同时建立并验证HOST translator topology。正式链路
仍由bridge打开XRT device和同一xclbin，因此脚本成功后继续执行下面的命令：

```bash
sudo env \
  XILINX_XRT=/home/yanjiarun/xrt-u280-2.16 \
  LD_LIBRARY_PATH=/home/yanjiarun/xrt-u280-2.16/lib \
  /home/yanjiarun/Vortex/tools/scope_vortex_bridge/scope-vortex-bridge \
    --socket /run/scope-vortex0.sock \
    --driver-lib /home/yanjiarun/Vortex/sw/runtime/libvortex-xrt.so \
    --device-index 0 \
    --allow-peer-bdf 0000:2a:00.0 \
    --xclbin /home/yanjiarun/Vortex/hw/syn/xilinx/xrt/\
build1_p2p_xilinx_u280_gen3x16_xdma_1_202211_1_hw/bin/vortex_afu.xclbin
```

保持终端 A 运行。另开终端检查：

```bash
pgrep -af scope-vortex-bridge
sudo test -S /run/scope-vortex0.sock
```

若 bridge 已退出，先看它的终端输出；不要在 socket 缺失时继续启动香山。
正常情况下终端 A 可以长期只有下面一行，这不表示数据通路卡住：

```text
scope-vortex-bridge: U280 ready, socket=/run/scope-vortex0.sock
```

Bridge 负责 RPC/XRT 转换，但当前逐命令 trace 由 QEMU 的 `vortex-log` 属性输出。

> 如果以后生成 32-bank xclbin，需要同时换回或重建匹配的 32-bank guest
> 镜像，不能只替换 xclbin。

## 7. 启动 QEMU vSwitch manager（终端 B）

先确认 JSON 指向与 bridge 相同的 socket：

```bash
cat /home/yanjiarun/nexst_proxy_14/tools/proto/vswitch-vortex-u280.json
```

然后启动：

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
dma32-ring-size=0x10000,\
vortex-log=on
```

该JSON明确设置`"data-path": "direct-p2p"`。因此peer capability、BAR2范围、
mapping generation或physical `Q_ERROR`任一检查失败都会让backend报错退出，
不会回退到Socket payload搬运。

`vortex-log=on` 是当前 QEMU backend 的可观测性开关，建议在首次验收和排障时
保留。它会在终端 B 打印 virtual/physical job、opcode、peer window、PCIe
方向、guest PA、CP peer address、generation、耗时及
`payload_cpu_bytes=0`。稳定运行后若不需要逐命令输出，可以删除该属性或改为
`vortex-log=off`；它只影响日志，不改变数据路径。属性关闭时，QEMU 在枚举后
没有新的 Vortex 行为输出是正常现象。

保持终端 B 运行。这里的 `fpga-host-bdf` 是香山/NM37 的 `0000:2a:00.0`，
不是 U280 的 `ab:00.0` 或 `ab:00.1`。若启动时重新枚举出了不同 BDF，应把
命令中的值同步改为 `10ee:903f` 对应的新 BDF。

启动后若立刻退出，优先检查：旧 QEMU 是否仍占用 XDMA、bridge socket 是否
存在、JSON 是否可读、BDF 是否已经变化，以及终端 A 是否报告 xclbin/runtime
配置错误。

## 8. 装载并启动香山（终端 C）

QEMU manager 和 bridge 均正常运行后，再释放香山 reset：

```bash
cd /home/yanjiarun/nexst_proxy_14/tools/proto

sudo ./load_and_run_5.sh \
  xdma0 \
  /home/yanjiarun/nexst_proxy_14/nanhu-g/ready_for_download/\
proto_nm37_vu37p/bootrom.bin \
  /home/yanjiarun/nexst_proxy_14/nanhu-g/ready_for_download/\
proto_nm37_vu37p/RV_BOOT_vortex_1bank.bin
```

该脚本依次执行：assert reset、把 bootrom 写入片上 boot ROM window、把
`RV_BOOT_vortex_1bank.bin` 写到 DDR 的 `0x80000000`、读回 fence、deassert
reset，并在
`/dev/xdma0_user + 0x11000` 打开 115200-8-N-1 UART。不要再同时打开 minicom，
否则两个进程会争用 UART。

退出串口使用 `Ctrl-\`。只重新连接串口、不复位也不重载镜像时：

```bash
cd /home/yanjiarun/nexst_proxy_14/tools/proto
sudo ./load_and_run_5.sh xdma0
```

当前镜像把控制台shell配置为BusyBox `respawn` action；shell打开console失败、
收到EOF或意外退出后，PID 1会重新启动它，不再停留在只完成`sysinit`的状态。
如果画面仍只显示`Run /init as init process`，先按一次回车并输入
`echo SHELL_ALIVE`：能看到回显说明系统已进入shell，只是无换行的prompt字符丢失，
使用上面的单参数命令重新连接UART即可；完全没有回显时再重新装载镜像。

## 9. 香山 Linux 内验收

进入香山 shell 后执行：

```bash
lspci -nnk
ls -l /dev/scope-vortex*
cat /usr/lib/vortex/build-info
scope-vortex-check
vortex-vecadd -n 64
vortex-sgemm -n 32
vortex-conv3 -n 32
vortex-conv3 -n 32 -l
vortex-multikernel -n 128
vortex-bfs -n 256
vortex-sort -n 16

# 或按上述保守规模依次执行整套测试，首项失败即停止
vortex-run-all
```

预期结果：

- 虚拟 endpoint 的 PCI ID 为 `1b36:1310`、class 为 `120000`。
- kernel driver 为 `scope-vortex`，并出现 `/dev/scope-vortex0`。
- `scope-vortex-check` 比较 thread/warp/core 数、memory bank 数、每个 bank 的
  bytes 和 ISA flags。它不直接比较或打印 `STARTUP_ADDR`；28-bit address width
  由 `build-info` 记录，并通过预期 bank bytes 间接参与检查。
- `vortex-vecadd` 验证基本上传、launch 和双向搬运。
- `sgemm`、`conv3` 覆盖浮点矩阵/卷积；`conv3 -l` 额外覆盖本地内存路径。
- `multikernel` 装载一个带 VXSYMTAB footer 的 `.vxbin`，按名称解析并顺序启动
  `add_k`、`mul_k`、`acc_k` 三个入口；同时检查 `.init_array` constructor、
  `.tdata/.tbss` TLS 初始化、每个 kernel 的独立 PC、queue event 和结果回读。
  当前仍只有一个物理 Vortex core，不表示三个 core 同时运行。
- `bfs` 和 `sort` 覆盖更不规则的访存及同步模式。
- 每个 `vortex-TEST` wrapper 默认先运行一次 checker，再选择匹配的静态
  `/bin/vx-TEST` 和 `/usr/lib/vortex/TEST.vxbin`。`vortex-run-all` 只在开头运行
  一次 checker，随后设置 `VORTEX_SKIP_CAPS_CHECK=1` 依次执行固定保守规模；只有
  全部命令均返回成功时才打印最终通过。

当前单-bank `build1...xclbin` 应与 `RV_BOOT_vortex_1bank.bin` 内的
`build-info` 一致。如果误加载原来的 32-bank `RV_BOOT.bin`，
`scope-vortex-check` 失败是正确的保护行为；不要跳过 checker 强行运行或把
任何计算测试记为通过。

checker 通过仍不等于 host/kernel 文件来自同一次构建。当前多测试镜像还应
显示：

```bash
grep -E '^(vortex_(commit|startup_addr|tests)=|.*_kernel_sha256=)' \
  /usr/lib/vortex/build-info
```

其中 `vortex_startup_addr` 应为 `0x08000000`，`vortex_tests` 应包含
`vecadd sgemm conv3 multikernel bfs sort`。若准备验收当前源码提交，应把
`vortex_commit` 与主机的 `git -C /home/yanjiarun/Vortex rev-parse HEAD` 对照；
不一致时重新生成并装载 guest 镜像。

## 10. 故障定位顺序

按下面的边界逐层检查，不要一开始就重烧两张卡：

1. `lspci`：U280 `500c/500d` 和香山 FPGA `903f` 是否都存在。
2. 驱动：U280 是否为 `xclmgmt/xocl`，香山是否为 `xdma`。
3. U280：`xbutil examine`是否健康、host memory是否为64MiB、peer query是否
   报告4MiB slot和两个64MiB窗口。
4. bridge：进程是否存在、`/run/scope-vortex0.sock` 是否为 socket。
5. QEMU：终端 B 是否仍运行，是否连接 bridge，是否独占 `/dev/xdma0_*`。
6. 香山启动：bootrom/firmware load 是否完成，readback fence 是否成功，UART
   是否出现 OpenSBI/Linux 输出。
7. guest PCI：是否枚举 `1b36:1310`，`scope_vortex` 是否 probe 成功。
8. capability：checker 的 bank/core/ISA 是否匹配；`build-info` 的 address
   width、startup address、测试列表和 kernel hash 是否来自预期构建。
9. 基本数据路径：先运行 `vortex-vecadd -n 64`。
10. 扩展回归：基本测试通过后再运行 `vortex-run-all`；若失败，单独重跑它
    打印的最后一个测试命令。

如果终端 A 只有 `U280 ready`，而 guest 正在等待，先确认终端 B 是否启用了
`vortex-log=on`。查看最后一条 job/opcode、peer-map generation、physical
sequence、`Q_ERROR` 和是否出现 `payload_cpu_bytes=0`；不要仅凭 Bridge 没有
逐命令输出判断它卡死。

若只有 `vortex-multikernel` 失败，优先核对 `vortex_startup_addr`、
`multikernel_kernel_sha256` 和 `vortex_commit`，确认静态 host 与多入口 `.vxbin`
来自同一次构建。旧的单入口 runtime/kernel 组合可能出现入口解析失败、结果全
零或异常 console 字符；应重新执行 `build_vortex_guest_single_bank.sh`，不要只
替换某一个 `.vxbin`。

## 11. 正常停止顺序

1. 在香山 Linux 中执行 `sync`；需要停止系统时再执行 `poweroff`。
2. 在终端 C 用 `Ctrl-\` 退出 UART。
3. 在终端 B 用 `Ctrl-C` 停止 QEMU manager。
4. 在终端 A 用 `Ctrl-C` 停止 bridge。
5. 用 `pgrep -af 'scope-vortex-bridge|qemu-system-x86_64|pcie-util.*uart'`
   确认没有残留进程。

一般不需要卸载 `xocl`、`xclmgmt` 或 `xdma`。只有确认所有用户进程均退出后，
才能进行 FPGA 重配置或驱动维护。
