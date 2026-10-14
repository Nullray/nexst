# 普通昆明湖单/双核 SCOPE 实现与运行

当前两版均以普通 `kunminghu` 分支、原生 TL/HuanCun L3 和 `FpgaDefaultConfig` 为基础。
硬件构建的路径、源提交和后台日志见 [NODE41_BUILD_RUN.md](NODE41_BUILD_RUN.md)。
主机 buffer 协议与完整地址关系见 [QDMA_HOST_BUFFER.md](QDMA_HOST_BUFFER.md)。

## 对齐 Nanhu 的功能

| 功能 | 本版本 |
| --- | --- |
| 双 BAR vSwitch | 使用原 NM37 文件，SHA256 `527a959fd056da2c1e15b262602aa7c413a6fd34c3fc06cb43eaaddd749f7efa` |
| guest PCI ECAM / CFG ACK / BAR response / DONE / INTx | 保留原协议和后端处理 |
| 既有 IGB/IXGBE/host-net 网卡后端 | 保留，新增 bridge 接收器不重写网卡逻辑 |
| 物理 xHCI | 保留 vendor DMA capability、READY/BME/RUN/DONE 门控及错误停 DMA |
| FPGA → host 通知 | 主机 coherent RAM；从 XDMA/C2H 改为 QDMA slave bridge SCB1 |
| host/外设 → guest coherent DMA | master bridge → alias → `u_role/s_axi_dma` → CPU native dma → L3 |
| 跨时钟和位宽适配 | AXIS 50→250 MHz；guest DMA SmartConnect 250→50 MHz、512→256 bit |

双 BAR 支持指硬件可路由每 endpoint 的两条 BAR 并保留报文 BAR 字段。
现有 NIC/xHCI 后端使用 BAR0；BAR1 可作为 BAR0 的 64 位高半部。此任务没有新增 FSA 的独立第二 BAR 软件语义。

## 软件修改

- QDMA PF driver：SCB1 misc device、64 位 `dma_alloc_coherent`、只读 mmap、START/ARM/批量 ACK、停止后 MemRd fence 及错误保留内存。
  不再使用旧 completion-only 队列的 libqdma 扩展。
- QEMU：`qdma-bridge` 接收器读取 host RAM counter/packet，并调用原 CFG/BAR 和 NIC/xHCI handlers；保留其它 transport 兼容代码。
- guest DT：从实际生成的 `XSTop.dts` 派生，核数必须匹配；保留 ISA 信息和每 hart CLINT/PLIC 上下文。
  RAM 2 GiB，CPU 50 MHz，RTC 10 MHz；UART `0x40600000` / PLIC 4；generic ECAM `0x60000000`，bus 0–15；SCOPE INTx 为 PLIC 34。
- Linux 6.6：逐 function xHCI coherent P2P DMA helper；启用 generic PCI、IGB/IXGBE、xHCI、UART、SMP。
  Linux 6.6 的 xHCI startup 保护已存在，版本检查不重复改写。
- OpenSBI：新增 `kunminghu_scope`/`serve_scope` 平台参数，UART `0x40600000`、PLIC sources 单核 66/双核 67、HART_COUNT 对应 1/2，PLIC 区域覆盖原生 64 MiB，heap 按核数分配；payload 使用实际 Image。
- 加载器：修正 host BAR1 GPIO reset `0x11000`、reset vector `0x11008`、UART `0x12000`；CPU reset 时使用 raw DDR 加载。

软件补丁保存在 `tools/host/patches/`，`bootstrap.sh` 对已应用补丁只验证，不重复应用。

## 编译软件

每份工程在自己的目录内执行，kernel module 必须匹配实际运行主机的内核：

```bash
bash tools/host/bootstrap.sh
bash tools/host/build_qdma_driver.sh
bash tools/host/build.sh
bash tests/host-proxy/run.sh
```

QEMU 输出 `tools/host/qemu/build-kunminghu-scope/qemu-system-x86_64`，driver 输出
`tools/driver/xdma_drv/QDMA/linux-kernel/driver/src/qdma-pf.ko`。
编译日志在 `build/software-logs/`；缺少 tomli 时只在本工程 `build/tool-cache/qemu-python` 内安装。

构建完整 Linux + 静态 BusyBox initramfs + OpenSBI + boot ROM：

```bash
NUM_CORES=1 JOBS=4 bash tools/guest/build_scope_guest.sh   # 单核工程
NUM_CORES=2 JOBS=4 bash tools/guest/build_scope_guest.sh   # 双核工程
```

输出分别在 `build/guest-1core/`、`build/guest-2core/`，含 `Image`、`RV_BOOT.bin`、`bootrom.bin`、DTB 和 SHA256。
同一份支持两核的 Linux Image 可以用于单核；仍须为单核重新生成 DT/OpenSBI：

```bash
python3 tools/guest/build_scope_firmware.py --num-cores 1 --image /path/to/SCOPE/Image
```

最小 initramfs 用于 PCI/USB/网络 bring-up，包含 BusyBox、DHCP 脚本和交互 shell；没有包含 UHD 或蜂窝协议栈。

## 上板运行顺序

1. 下载对应 `system.pdi`，等待 PCIe/DDR 就绪并确认主机 BAR 资源。
2. 加载与主机内核匹配的 `qdma-pf.ko`，确认 `/dev/scope-qdma-<BDF>` 出现。
   默认 QDMA mode 可以保留；需要 polling 时 vendor 参数格式为 `mode=<十六进制 bus>:<PF>:1`，不是 `mode=1`。
   SCB1 通知无需 qmax/queue-start。
3. 沿用既有网卡配置；如使用物理 xHCI，先按 `scope_usb_preflight.py` 检查指定 controller 的所有权、64 位 DMA、P2P/IOMMU 条件。
   SCB1 host buffer 的 DMA/IOVA 能经过主机 IOMMU；物理 USB peer DMA 是另一条路径，仍沿用原 xHCI 的 identity/P2P 条件。
4. CPU 保持 reset 时先启动 QEMU 后端，再加载并释放 CPU，使 Linux 枚举期间 ECAM shadow 与 handler 已准备好。

先输出实际命令供检查（BDF、backend 配置使用实际设备）：

```bash
python3 tools/host/run_host_proxy.py --board uvhs2 --fpga-bdf 0000:BB:DD.F \
  --backends /absolute/path/backends.json --xhci-p2p
```

添加 `--run` 会执行 QEMU。QEMU 需要访问 PCI sysfs BAR/config 和 misc 设备的权限；后台运行示例：

```bash
sudo -n nohup python3 tools/host/run_host_proxy.py --board uvhs2 \
  --fpga-bdf 0000:BB:DD.F --backends /absolute/path/backends.json --xhci-p2p --run \
  > build/host-proxy-console.log 2>&1 < /dev/null &
make -C tools/proto
sudo bash tools/proto/load_and_run_qdma.sh 0000:BB:DD.F \
  build/guest-2core/bootrom.bin build/guest-2core/RV_BOOT.bin
```

单核换用 `guest-1core` 的镜像。示例 BDF 是占位，须替换为实际值；没有 USB backend 时省略 `--xhci-p2p`。
本次没有自动下载 PDI、绑定/解绑 PCI function、加载 module 或接管实际网卡/USB。

## 验证边界

已进行通知器 RTL 仿真、两版真实 BD 连线检查、QDMA driver/QEMU 编译、guest Linux/firmware 交叉编译、模拟 NIC/xHCI 回归。
B210 作为 USB3 RF 外设的实际枚举、UHD bulk I/Q、收发定时与带宽，需要上板验证。
手机 4G/5G 上网还需要 RISC-V 上的 UHD/RAN/核心网部署；本改动实现外设接入基础，没有实现完整基站。
上板首先应测试 CPU 保留脏 cache line 时的 host alias 读写，双核相互可见性、USB command/event/transfer ring 和 NIC 收发。
