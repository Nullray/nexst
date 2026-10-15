# 重复启动修复版：手动启动步骤

本页统一保留修复版 QEMU/XDMA 启动、USB 自动枚举、B210 UHD 初始化及接收测试。
第 5 步选择基础镜像或 UHD 镜像，第 5.1 步为射频模块测试，第 6 步为停止流程。

根因证据、最终修复和 GitHub 同步清单见
[修复提交说明](USB_QEMU_RESTART_FIX_SUMMARY_ZH.md)。

本次按用户要求修复已确认的问题，不增加阶段定位日志，不安排故障复现。QEMU 和主机 XDMA 均有修改，必须使用配套产物；只更新其中一个不完整。bitstream、香山 Linux/OpenSBI、USB backend JSON 和 QEMU 参数沿用原 runbook。

原运行二进制、原驱动构建目录和原实验环境文件均保留。最初构建只做离线验证；用户随后反馈修复版重复启动成功、B210 初始化及低速 RX 通过。物理操作由用户执行，这些结果不代表已证明并消除了全部 PCIe fatal 根因。

`build/` 不上传 GitHub。其他机器需要先按仓库原有流程准备依赖，并执行
`bash tools/guest/bootstrap.sh`、`bash tools/host/bootstrap.sh`，构建新 QEMU
和 `tools/build_usb_dma32_driver.sh` 对应模块。主机 bootstrap 固定配套 QEMU
提交，或将保存的重启补丁应用到受支持的旧 USB 基线。完成这些源码恢复及构建后，
在 nexst 根目录创建本地环境文件；以下路径是本机示例，按实际目录和二进制名调整：

```bash
mkdir -p build
printf '%s\n' \
  'export USB_REPO=/home/maxiangyu/nexst' \
  'export USB_QEMU=/home/maxiangyu/qemu/build-nanhu-host/qemu-system-x86_64-restart-fixed' \
  'export USB_XDMA_MODULE=/home/maxiangyu/nexst/build/usb-dma32-driver-restart-fixed/linux-kernel/xdma/xdma.ko' \
  > build/usb-restart-fixed.env
```

UHD 镜像的构建支持也一并保存。`tools/build_b210_uhd.sh` 要求已准备好指定版本
的 UHD/libusb 源码缓存及 RV64 Boost sysroot，不会自动安装主机依赖或准备
Boost；输入满足后会输出运行库 overlay，再由 `tools/build_nanhu_host_software.sh`
的 `--output/--overlay` 构建独立镜像。已编译的镜像、库和下载缓存均不随 Git 上传。

## 修复内容与离线结果

- QEMU 普通进程退出清理物理后端；先停 xHCI 并关闭其 BME，再释放接收环。
- ALLOC 成功才取得资源归属，失败不 FREE 别人的环；启动前独占检查并拒绝残留环。
- XDMA 循环传输改为设备控制节点的私有状态，删除模块全局旧指针。
- PCI remove 在销毁接口、引擎和 BAR 前关闭 FPGA BME，等待 pending transaction，并清理自定义 DMA。
- 分配者的最后一个文件引用关闭时回收资源；其他进程不能 FREE/PUT/mmap 它的环，QUERY 仍可查询。
- 持引擎锁停止循环传输，等待 BUSY 清零后释放；超时保留 DMA 内存。remove 无法中止时也保留原分配设备的引用，避免新 probe 误处理旧资源。极端失败保留的内存直到重启回收。
- 内存/描述符分配失败不再冒充成功；分配 coherent DMA32 时保留 streaming DMA mask，并恢复 coherent mask。

已通过 [完整软件回归](../build/software-logs/usb-restart-fixed-regression.log)，包括生产 PCI remove helper 的清理顺序、重新 probe 隔离、文件归属、超时保留，以及 13 项 QEMU 后端和 6 项进程生命周期检查。补丁的初次应用与重复应用也已验证。ASan/UBSan 启用，因执行环境限制关闭 LeakSanitizer 的 leak 扫描；DTS 仍有原有 bus-error-unit 警告。

驱动 [构建记录](../build/software-logs/usb-restart-fixed-driver-build.log)、[manifest](../build/usb-dma32-driver-restart-fixed/manifest.json)、[产物哈希](../build/software-logs/usb-restart-fixed-artifacts.json) 已保存。新模块 srcversion 为 `9E4F32A8FDE1EF6344F83A5`，内核版本为 `6.8.0-146-generic`。

## 1. 完成原有停止、remove、烧写、rescan 流程

停止流程沿用原 [USB runbook](USB_EXPERIMENT_RUNBOOK_ZH.md) 第 7 步。必须先确认物理 xHCI DMA 停止，退出全部 QEMU、串口及其他 XDMA 工具，才能 remove 或改动 DDR。关闭串口本身不会停止香山 CPU 或 USB DMA。本修复未扩展为支持仍有用户文件打开时的任意热拔插。

## 2. 首次加载配套新驱动

在主机终端 A：

```bash
cd /home/maxiangyu/nexst
source build/usb-restart-fixed.env

if [ ! -d /sys/module/xdma ]; then
  sudo insmod "$USB_XDMA_MODULE"
fi

cat /sys/module/xdma/srcversion
modinfo -F srcversion "$USB_XDMA_MODULE"
```

两行版本都必须是 `9E4F32A8FDE1EF6344F83A5`，否则停在此处。准备时检查模块尚未加载；若之后发现仍有旧模块，不强制重复 insmod/rmmod。应在完整停机后安排一次版本切换，或在下一次宿主机重启后首次加载新模块。之后同一模块的 remove/rescan 会重新 probe，无需每轮卸载模块。

## 3. 卸载 B650 上实际挂载的分区，然后保持香山 reset 并解绑 B650

先检查挂载，按原 runbook 只卸载实际属于 B650 的 SD 分区，不猜测磁盘名：

```bash
lsblk -o NAME,PATH,TRAN,SIZE,RO,FSTYPE,MOUNTPOINTS
```

确认完成存储卸载和上一轮停机后：

```bash
source /home/maxiangyu/nexst/build/usb-restart-fixed.env
cd "$USB_REPO"
test "$(cat /sys/module/xdma/srcversion)" = "$(modinfo -F srcversion "$USB_XDMA_MODULE")"
sudo tools/proto/pcie-util /dev/xdma0_user write 0x100000 1

if [ -L /sys/bus/pci/devices/0000:c2:00.0/driver ]; then
  test "$(basename "$(readlink -f /sys/bus/pci/devices/0000:c2:00.0/driver)")" = xhci_hcd || exit 1
  printf '%s' 0000:c2:00.0 | sudo tee /sys/bus/pci/drivers/xhci_hcd/unbind
fi
test ! -L /sys/bus/pci/devices/0000:c2:00.0/driver
```

校验或任一步失败时停止后续操作。

## 4. 主机终端 B：启动修复版 QEMU

此处所有设备参数与原 runbook 一致，仅改为本地环境和修复版产物路径。没有启用新的阶段日志。

```bash
source /home/maxiangyu/nexst/build/usb-restart-fixed.env
cd "$USB_REPO"
export USB_SESSION="$USB_REPO/build/usb-experiments/$(date +%Y%m%d-%H%M%S)-restart-fixed"
mkdir -p "$USB_SESSION"
set -o pipefail

sudo "$USB_QEMU" \
  -machine q35 -S -m 128M \
  -display none -monitor none -serial none \
  -d guest_errors -D "$USB_SESSION/qemu-debug.log" \
  -device pcie-root-port,id=rp1,bus=pcie.0 \
  -device "scope-fpga-vswitch,bus=rp1,backend-config=$USB_REPO/build/nanhu-host/backends-usb-only.json,fpga-host-bdf=0000:2a:00.0,xdma-user-dev=/dev/xdma0_user,xdma-ctrl-dev=/dev/xdma0_control,xdma-bypass-dev=/dev/xdma0_bypass,guest-ddr-base=0x80000000,guest-ddr-size=0x80000000,bypass-coherent-alias-base=0x100000000,guest-mem-raw-fallback=off,dma32-ring-size=0x10000,allow-unsafe-xhci-p2p=on" \
  2>&1 | tee "$USB_SESSION/qemu.log"
```

等到原有 `DMA32 CFG/BAR RX thread started` 出现且没有报错退出，再装载香山。新的环境文件不覆盖旧 `usb-experiment-current.env`；不要随后又 source 旧文件把 QEMU 路径切回旧版本。

## 5. 主机终端 A：装载原 baseline 香山固件

下面是未包含 UHD 的基础镜像。需要测试 UHD 时，将本步两个镜像路径中的
`build/nanhu-host/` 改成 `build/nanhu-b210/`。两种镜像均内置 xHCI，开机
自动初始化并枚举 USB，无需手动加载模块。本页其余停止、解绑和 QEMU 步骤不变。
UHD 镜像此前的无命令行问题尚未确认根因；与本次宿主机重启修复分开跟踪。

```bash
source /home/maxiangyu/nexst/build/usb-restart-fixed.env
cd "$USB_REPO/tools/proto"
sudo env -u GUEST_DDR_SIZE bash -e ./load_and_run_5.sh xdma0 \
  ../../build/nanhu-host/bootrom.bin \
  ../../build/nanhu-host/opensbi/platform/ict/firmware/fw_payload.bin
```

这次先沿用原 baseline 固件。进入香山后，分别一行一行执行：

```sh
echo SHELL_ALIVE
```

```sh
lspci
```

```sh
lsusb
```

### 测试 B210 时的 UHD 镜像选择

若本轮目的是测试 B210，第 5 步直接使用下面的装载命令，替代上面的基础镜像
命令，二者只执行一个。不要在旧 guest/USB DMA 运行时再次装载镜像：

```bash
source /home/maxiangyu/nexst/build/usb-restart-fixed.env
cd "$USB_REPO/tools/proto"
sudo env -u GUEST_DDR_SIZE bash -e ./load_and_run_5.sh xdma0 \
  ../../build/nanhu-b210/bootrom.bin \
  ../../build/nanhu-b210/opensbi/platform/ict/firmware/fw_payload.bin
```

xHCI 内置并自动枚举，不需要手动加载 guest 模块。若已进入这个 UHD 镜像，
重复应用测试只需执行下一节，不需要重启 QEMU、香山或重新烧写 FPGA。

## 5.1. 香山内的 B210 初始化和接收测试

以下命令均在香山 `~ #` 下执行。一次输入一条，确认整行完整后按回车，等待
程序退出再输入下一条；终端自动折行不影响参数，不要在参数中间手动回车。
初始化在本环境可能耗时约两分钟，`--duration` 是采样阶段的持续时间。

```sh
uhd_usrp_probe --version
```

预期 `4.11.0.0`。

```sh
lsusb
```

```sh
uhd_find_devices --args="type=b200,serial=313467A"
```

首次使用可能下载 `usrp_b200_fw.hex` 并重新枚举。`type=b200` 是 B200/B210
系列驱动选择，不表示把 B210 当成另一型号。

```sh
uhd_usrp_probe --args="type=b200,serial=313467A"
```

当前设备 UHD 识别为 B210，EEPROM 名称 NI2901，序列号 `313467A`。确认
`Operating over USB 3`、寄存器回环通过、RX/TX 通道信息并正常返回提示符后再采样。
每个 UHD 程序会重新创建和配置设备，重复出现 CODEC/Radio 初始化是正常流程。
换设备时使用实际序列号。

单通道 100 kS/s、30 秒，USB 和 CPU 样本格式均为 sc16：

```sh
benchmark_rate --args="type=b200,serial=313467A" --rx_rate=100e3 --rx_channels=0 --rx_otw=sc16 --rx_cpu=sc16 --duration=30
```

单通道 500 kS/s、60 秒：

```sh
benchmark_rate --args="type=b200,serial=313467A" --rx_rate=500e3 --rx_channels=0 --rx_otw=sc16 --rx_cpu=sc16 --duration=60
```

需要评估更高吞吐时，单通道 1 MS/s、60 秒：

```sh
benchmark_rate --args="type=b200,serial=313467A" --rx_rate=1e6 --rx_channels=0 --rx_otw=sc16 --rx_cpu=sc16 --duration=60
```

`sc16` 每个复数 IQ 样本占 4 字节；上述数据量分别约 0.4、2、4 MB/s。
以实际接收样本、overrun、dropped samples、RX sequence error 和 timeout
判断结果，错误计数期望为零。只打印 `Done!` 不代表零丢样。

2026-10-15 用户提供的结果：

| 配置 | 接收样本 | 丢样 | 溢出 | 结果 |
|---|---:|---:|---:|---|
| 100 kS/s，30 秒，通道 0，sc16 | 2,998,745 | 0 | 0 | 本轮低速传输通过 |
| 500 kS/s，60 秒 | — | — | — | 尚未提供结果 |
| 1 MS/s，60 秒，通道 0，sc16 | 15,501,681 | 44,537,464 | 203 | 未通过无损接收要求 |

连续 `O` 是设备接收 overrun 报告，当前代码路径对应 B210 FPGA 接收 FIFO
积压，不表示香山整块 DDR 用满。下游处理、USB 请求、中断或代理延迟都可能
造成反压并最终溢出；尚未确定瓶颈，不能直接归因于 CPU 主频。
100 kS/s 低于最小模拟滤波带宽的警告不阻止传输测试，但不能据此评价频谱质量。

如需保存 IQ 文件，在已经验证稳定的采样率下执行。例如使用已通过的 100 kS/s，
通道 0、RX2、中心频率 100 MHz，保存 100,000 个 sc16 复数样本：

```sh
rx_samples_to_file --args="type=b200,serial=313467A" --channels=0 --ant=RX2 --freq=100e6 --rate=100e3 --gain=10 --nsamps=100000 --type=short --otw=sc16 --file=/tmp/b210-rx.sc16 --stats
```

```sh
wc -c /tmp/b210-rx.sc16
```

完整接收预期为 400,000 字节，文件位于 guest RAM。

```sh
od -An -td2 -N64 /tmp/b210-rx.sc16
```

未接已知信号时可能主要是噪声。文件大小正确、样本非零不等于射频质量通过；
实际应用还需已知信号验证。此处测试只接收，不验证发射或双向功能。

## 6. 结束后停止设备，再处理 FPGA

如果在 guest 挂载过 SD 分区，先卸载实际挂载点。随后在香山中解绑控制器：

```sh
printf '%s' 0000:03:00.0 > /sys/bus/pci/drivers/xhci_hcd/unbind
```

在主机终端 B 按 Ctrl-C 退出 QEMU，并等待退出。主机执行原 runbook 的停止确认，成功后才保持香山 reset：

```bash
source /home/maxiangyu/nexst/build/usb-restart-fixed.env
cd "$USB_REPO"
if sudo build/nanhu-host/xhci-p2p-noop \
  0000:2a:00.0 0000:c2:00.0 /dev/xdma0_bypass 0x88000000 stop; then
  sudo tools/proto/pcie-util /dev/xdma0_user write 0x100000 1
else
  echo '控制器停止确认失败：保留 DDR，停止后续 reset/remove/烧写操作。'
fi
```

成功标志仍为 `PASS: xHCI stopped/reset, bus master off`。确认全部 QEMU、串口和 XDMA 工具退出后，才进入下一轮既有 remove/烧写/rescan 流程。guest 无法解绑或代理无法退出时，沿用原 runbook 第 7 步的异常停止流程，并将其中仓库路径改为 `/home/maxiangyu/nexst`。

不要把反复强制启动、FREE、模块卸载或 remove/rescan 用作自动重试。
