# server48：nexst_usb / qemu_usb 的 USB 实验 Runbook

NI USRP B210 的接入层次、guest 软件要求及持续采样验收见
[USB_B210_BACKEND_ANALYSIS_ZH.md](USB_B210_BACKEND_ANALYSIS_ZH.md)。
USB 与 NVMe/NIC 的 DMA 地址转换区别见
[USB_DMA_ADDRESS_TRANSLATION_ZH.md](USB_DMA_ADDRESS_TRANSLATION_ZH.md)。

更新：2026-10-14（北京时间）。按用户提供的 maxiangyu history 摘录、复制仓库中的代码及产物核对。下面的启动命令沿用 history 的 `rp1`、XDMA、RAM 和 coherent alias 参数，改成本地路径，并为每轮实验启用独立运行日志及后端故障日志。

本机已经有可执行 QEMU、bootrom 和修复后的 Linux/OpenSBI。迁移产物与原 `preparation.json` 的八项哈希一致，固件完整嵌入本次 Image 和 DTB；本地路径记录见 [preparation-local.json](../build/nanhu-host/preparation-local.json)。迁移时修正了 `nexst_usb/qemu-mount → ../qemu_usb` 和旧绝对符号链接。

已经修复主机 DMA32 接收区的单描述符覆盖问题，见 [故障分析与测试证据](USB_BAR_DONE_FAILURE_ANALYSIS_ZH.md)。2026-10-13 的 `20261013-123859` 实验已加载新模块，guest 成功枚举 `05e3:0751` 读卡器及 58.2 GiB SD 卡 `/dev/sda`，分区为 `sda1`–`sda14`；用户随后完成第 6 步的只读挂载、文件内容读取和 README 哈希对照。ext4 error/recover 标志的诊断见 [只读文件系统说明](USB_EXT4_READONLY_DIAGNOSIS_ZH.md)。**新实验启动前核对已加载模块；需要切换时按文末驱动切换段操作。** bootrom、Linux/OpenSBI 可以沿用。本文操作命令由用户执行，分析与构建过程没有启动或重置物理设备。

**1．确认本轮使用的文件和设备（主机）。**

| 对象 | 当前路径或值 |
|---|---|
| NexST | `/home/yanjiarun/nexst_usb` |
| QEMU | `/home/yanjiarun/qemu_usb/build-usb-local/qemu-system-x86_64` |
| 主机 XDMA 模块 | `build/usb-dma32-driver/linux-kernel/xdma/xdma.ko`，需加载才能生效 |
| USB-only 配置 | `build/nanhu-host/backends-usb-only.json` |
| NM37 / XDMA | `0000:2a:00.0 / 10ee:903f`，`/dev/xdma0_*` |
| B650 xHCI | `0000:c2:00.0 / 1022:43fd` |
| NM37 BAR2 | 当前 `0x208000000000..0x2083ffffffff`，16 GiB |
| bootrom | `build/nanhu-host/bootrom.bin`，12 字节 |
| payload | `build/nanhu-host/opensbi/platform/ict/firmware/fw_payload.bin`，28,152,840 字节 |
| guest RAM / alias | `[0x80000000, 0x100000000)` / `0x100000000` |

重新枚举或重启后再核对 BDF、XDMA 实例和 BAR 地址。新版源码及镜像已经包含 RV64 `phys_ram_base` 初始化、hvc0 shell、xHCI 启动 IRQ 保护和 QEMU 中断状态检查；只重启 QEMU或只换固件都不能完整验证这轮改动。

```bash
cd /home/yanjiarun/nexst_usb
export USB_REPO="$PWD"
export USB_QEMU=/home/yanjiarun/qemu_usb/build-usb-local/qemu-system-x86_64
export USB_SESSION="$USB_REPO/build/usb-experiments/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$USB_SESSION"
# 让两个主机终端使用同一个日志目录。
printf 'export USB_REPO=%q\nexport USB_QEMU=%q\nexport USB_SESSION=%q\n' \
  "$USB_REPO" "$USB_QEMU" "$USB_SESSION" > build/usb-experiment-current.env

test -x "$USB_QEMU"
test -x tools/proto/pcie-util
test -s build/nanhu-host/bootrom.bin
test -s build/nanhu-host/opensbi/platform/ict/firmware/fw_payload.bin
lspci -Dnnk -s 0000:2a:00.0
lspci -Dnnk -s 0000:c2:00.0
ls -l /dev/xdma0_user /dev/xdma0_control /dev/xdma0_bypass
cat /sys/bus/pci/devices/0000:2a:00.0/resource
cat build/nanhu-host/backends-usb-only.json
```

**启动前检查正在加载的驱动。** 仅修改 QEMU 路径或重新绑定 PCI function 不会替换内核里的 XDMA 模块。下面两个版本必须相同；不相同时先完成文末的驱动切换，暂停第 2–5 步：

```bash
USB_XDMA_EXPECTED=$(modinfo -F srcversion "$USB_REPO/build/usb-dma32-driver/linux-kernel/xdma/xdma.ko")
USB_XDMA_LOADED=$(cat /sys/module/xdma/srcversion)
printf 'loaded=%s\nexpected=%s\n' "$USB_XDMA_LOADED" "$USB_XDMA_EXPECTED"
test -n "$USB_XDMA_EXPECTED" && test "$USB_XDMA_LOADED" = "$USB_XDMA_EXPECTED"
```

2026-10-13 的 `20261013-120931` 实验使用新 QEMU，但仍加载旧模块 `E8D778DA2B4752B55C46541`，因此仍发生 doorbell `seq=527` 的 DONE 超时。该轮内核只打印旧的 `cyclic DMA started on C2H channel 1!`，尚未出现新模块的 `1024 slots, 64 bytes/slot`；这轮不能作为接收环修复后的物理验收。

JSON 只包含 `type=xhci` 和 `real-host-bdf=0000:c2:00.0`，这是此次实验的配置。

```bash
sudo fuser -v /dev/xdma0_user /dev/xdma0_control /dev/xdma0_bypass \
  /sys/bus/pci/devices/0000:c2:00.0/resource0
```

若显示旧 QEMU、串口工具或其他进程占用，先按第 7 步停机。新旧代理不能同时使用同一块 NM37；在旧 xHCI DMA 停止前，也不能复位 SoC 或重新装载 DDR。

**2．检查桥窗口与主机存储使用情况。**

history 曾修正 `29:01.0` 的 prefetchable window。当前只读核验值为下表，覆盖现有 BAR2，所以无需重新执行历史中的 `setpci ...=...`。

```bash
setpci -s 0000:29:01.0 PREF_MEMORY_BASE PREF_MEMORY_LIMIT \
  PREF_BASE_UPPER32 PREF_LIMIT_UPPER32
```

| 寄存器 | 当前值 |
|---|---|
| PREF_MEMORY_BASE | `0001` |
| PREF_MEMORY_LIMIT | `fff1` |
| PREF_BASE_UPPER32 | `00002080` |
| PREF_LIMIT_UPPER32 | `00002083` |

若读到的窗口无法覆盖本次 BAR2，停止启动并核对资源分配；这组值跟随本轮 BAR 地址，不能固定用于下一次枚举。

```bash
lsusb -t
lsblk -o NAME,PATH,TRAN,SIZE,RO,FSTYPE,MOUNTPOINTS
findmnt --mountpoint /mnt/b650-sd || true
```

读卡器曾在主机显示为 `/dev/sdg`，主分区 ext4；重新绑定后名字可能变化。只卸载实际挂在 B650 上的 SD 分区，例如确实挂在 `/mnt/b650-sd` 时执行 `sudo umount /mnt/b650-sd`。该控制器的全部 USB 端口会一起交给 guest。

若 B650 当前未绑定、没有旧代理，但尚未确认旧 DMA 已停止，先使用第 7 步的 `stop` 模式停控制器，再开始下面流程。

**3．让香山保持 reset，释放 B650 function（主机终端 A）。**

这一步开始操作硬件；须完成旧实验停机与存储卸载。

```bash
source /home/yanjiarun/nexst_usb/build/usb-experiment-current.env
cd "$USB_REPO"
test "$(cat /sys/module/xdma/srcversion)" = \
  "$(modinfo -F srcversion "$USB_REPO/build/usb-dma32-driver/linux-kernel/xdma/xdma.ko")" || exit 1
sudo tools/proto/pcie-util /dev/xdma0_user write 0x100000 1

if [ -L /sys/bus/pci/devices/0000:c2:00.0/driver ]; then
  test "$(basename "$(readlink -f /sys/bus/pci/devices/0000:c2:00.0/driver)")" = xhci_hcd || exit 1
  printf '%s' 0000:c2:00.0 | sudo tee /sys/bus/pci/drivers/xhci_hcd/unbind
fi
test ! -L /sys/bus/pci/devices/0000:c2:00.0/driver
```

只解绑 `c2:00.0`。该操作不需要 remove NM37，也不需要 rescan PCI 总线。

**4．启动 QEMU 代理（主机终端 B）。**

下面是 history 中实际 QEMU 命令的本地目录版本。`-S` 暂停 QEMU 的辅助 x86 VM，SCOPE 后端线程仍工作；香山 CPU 由另一个终端的 GPIO reset 控制。QEMU 在前台持续运行，这个终端先保持打开。

```bash
source /home/yanjiarun/nexst_usb/build/usb-experiment-current.env
cd "$USB_REPO"
set -o pipefail
sudo "$USB_QEMU" \
  -machine q35 -S -m 128M \
  -display none -monitor none -serial none \
  -d guest_errors -D "$USB_SESSION/qemu-debug.log" \
  -device pcie-root-port,id=rp1,bus=pcie.0 \
  -device "scope-fpga-vswitch,bus=rp1,backend-config=$USB_REPO/build/nanhu-host/backends-usb-only.json,fpga-host-bdf=0000:2a:00.0,xdma-user-dev=/dev/xdma0_user,xdma-ctrl-dev=/dev/xdma0_control,xdma-bypass-dev=/dev/xdma0_bypass,guest-ddr-base=0x80000000,guest-ddr-size=0x80000000,bypass-coherent-alias-base=0x100000000,guest-mem-raw-fallback=off,dma32-ring-size=0x10000,allow-unsafe-xhci-p2p=on" \
  2>&1 | tee "$USB_SESSION/qemu.log"
```

终端 A 查看日志，确认出现 `FPGA bypass BAR2`、`backend=0 type=xhci virtual=03:00.0` 和 `DMA32 CFG/BAR RX thread started`，且 QEMU 没有报错退出，再进行第 5 步。

```bash
tail -n 60 "$USB_SESSION/qemu.log"
```

这些初始化消息不代表完整 USB 传输已成功。B650 与 NM37 位于不同 root port，启动参数中的 P2P 开关也不证明物理路由通过。要先做独立实测，可在旧实验已停机且 B650 恢复 `xhci_hcd` 时使用 `sudo python3 tools/scope_usb_p2p_probe.py --run`；它会改写 scratch 区、安装 CPU 停驻循环并复位 SoC，不能在当前 guest 运行时执行。默认无 `--run` 仅打印计划。详细流程见 [主机外设说明](NANHU_G_HOST_PERIPHERALS.md)。

**5．装载镜像并启动香山（返回主机终端 A）。**

保持终端 B 的 QEMU 运行。在 `tools/proto` 目录执行 history 的装载命令：

```bash
source /home/yanjiarun/nexst_usb/build/usb-experiment-current.env
cd "$USB_REPO/tools/proto"
set -o pipefail
sudo env -u GUEST_DDR_SIZE bash -e ./load_and_run_5.sh xdma0 \
  ../../build/nanhu-host/bootrom.bin \
  ../../build/nanhu-host/opensbi/platform/ict/firmware/fw_payload.bin \
  2>&1 | tee "$USB_SESSION/guest-uart.log"
```

`env -u GUEST_DDR_SIZE` 沿用 history，避免继承旧终端中的限制值。当前脚本已修正大小判断，且本次 payload 小于脚本单次装载的 256 MiB 上限。

脚本会再次保持 reset、装载 bootrom、通过 raw DDR 偏移 `0x80000000` 装载 payload、校验三个首字，再释放 reset 并进入 UART。当前镜像预期：

| 读回位置 | 当前首字 |
|---|---|
| user `0x0`：bootrom | `0010029b` |
| bypass `0x80000000`：OpenSBI | `00050433` |
| bypass `0x80200000`：Linux entry | `106f5a4d` |

首字随镜像变化，脚本会读取镜像本身计算期望值；不要改写检查来接受错误结果。检查失败时脚本保持 reset，不应手动跳过后继续启动。

成功时串口应继续到 OpenSBI、Linux、`SCOPE coherent P2P DMA`、xHCI root hub 与 `[nanhu-init]`。本次内核包含 `SCOPE-DIAG before/after xhci_start USB3` 和中断日志，可用于比较修复前后。串口交互退出键为 Ctrl-C；退出 UART 本身不停止香山或物理 USB DMA。

**6．在 guest 检查读卡器与 SD 卡。**

以下命令在香山串口 shell 中执行，不是在主机执行：

```bash
lspci -nnk
dmesg | grep -E 'SCOPE|xhci|usb|scsi|sd[a-z]'
ls /sys/bus/usb/devices
ls /sys/class/block
cat /proc/partitions
```

USB-only 时 xHCI 预期为 guest `0000:03:00.0`，物理 ID 为 `1022:43fd`；读卡器为 `05e3:0751`。先看到读卡器，再看到具有容量的 SD block device，才进入文件系统验收。

按 guest 本轮实际分区填写设备名。下例假设已确认 SD 主分区为 `/dev/sda1`；不能沿用主机的 `/dev/sdg1`：

```bash
SD_PART=/dev/sda1
test -b "$SD_PART"
blkid "$SD_PART"
cat /sys/block/sda/ro
```

本轮主分区预期 `TYPE="ext4"`、UUID `063c7ad1-b8d1-4874-a7d5-c348d08fc0ea`；以 `blkid` 实际输出核对。`/sys/block/sda/ro` 为 `1`，与 guest 的 `Write Protect is on` 一致。确认 ext4 后在 guest 执行：

```bash
mkdir -p /mnt/sdcard
mount -t ext4 -o ro,noload /dev/sda1 /mnt/sdcard
grep ' /mnt/sdcard ' /proc/mounts
ls -la /mnt/sdcard
cat /mnt/sdcard/etc/os-release
sha256sum /mnt/sdcard/README.txt
```

主机先前读取该卡 `README.txt` 的 SHA-256 为 `73e05a180ff9544d76d06594fb266f6b4becdb1049231709037d667bec1d936e`，`etc/os-release` 显示 Ubuntu 18.04.6。使用同一 SD 卡且文件未变时，可做只读对照。实际设备还报告写保护；本轮以读取和哈希为验收目标。

挂载成功且能够查看目录、读取文件、得到相同哈希，即完成“香山 guest 读取读卡器 SD 卡文件”的基础验收。后续可做下面的连续读测试。本次 BusyBox 已启用 `FEATURE_DD_IBS_OBS`，支持 `iflag=direct`，用于绕开 Linux 块设备页缓存，让每轮确实发起读取；它不能排除读卡器或 SD 卡内部缓存。

本轮用户已经完成目录读取、Ubuntu 18.04.6 的 `os-release` 读取及 README 哈希对照，**文件读取目标已达成**。同时出现 group 263/262/261 的 `ext4_mb_generate_buddy` bitmap/descriptor 空闲 cluster 计数不一致。前面的“跳过 orphan cleanup”“without journal”与写保护及 `noload` 相符，后面的 `EXT4-fs error` 则需要检查，不能当作正常提示或全部通过。后续 direct-read 实测 `s_state=0x0003`、`s_feature_incompat=0x00000246`，已确认错误位及 `needs_recovery` 位存在。详见 [ext4 只读诊断](USB_EXT4_READONLY_DIAGNOSIS_ZH.md)：当前只读挂载跳过了所需的日志恢复，仍需离线检查或对副本恢复验证，不能保证所有错误都能由 journal 回放解决。

```bash
for ROUND in 1 2 3; do
  echo "USB direct-read round $ROUND"
  dd if=/dev/sda of=/tmp/usb-read-test.bin bs=1M count=16 iflag=direct || break
  sha256sum /tmp/usb-read-test.bin || break
done
dmesg | tail -n 60
rm -f /tmp/usb-read-test.bin
```

`/tmp/usb-read-test.bin` 位于本次 initramfs 的 guest RAM；SD 卡仅作为 `if=` 输入。每轮应读出 `16777216` 字节，三次哈希一致，日志没有新出现的 `I/O error`、`device descriptor read ... error`、`HC died` 或 `timed out`。这是有限次数的连续读取验证，不能替代长时间或写入测试。更大范围读取可在本轮通过后把 `count=16` 改为 `64`；不需要为基础验收扫描整张 58.2 GiB 卡。

本卡当前写保护，暂不执行写入测试。文件查看与读测试结束后，若准备停机，先 `umount /mnt/sdcard`，再按第 7 步停控制器和代理。只卸载分区不会停止 xHCI 或香山。

若仍卡住，保存本轮 `qemu.log`、`qemu-debug.log`、`guest-uart.log`、最后的 `SCOPE-DIAG` 及事件 dequeue 地址。旧记录中的 `0x82616000` 不是固定事件环地址。旧事件 `0a000000 00000000 01000000 00008801` 是有效的 port-10 状态变化事件，CPU 与 coherent alias 曾一致；raw DDR 的 `ffffffc0` 单独不能证明一致性读取错误。新版本应观察中断处理是否返回、dequeue 是否推进及后续枚举，不能只检查事件字存在。

2026-10-13 第一次本地复测的事件 dequeue 已从 `0x208182616000` 推进到 `0x208182616010`，init/shell 正常；后续 Enable Slot 阶段仍超时，guest 将 xHCI 标记为 dead。`lsusb` 的 `1d6b:0002/0003` 是内核根集线器。此状态尚无读卡器或 SD block device，不能进入挂载步骤。

在本轮仍保留状态时，可只读采集实际控制器和命令/事件环：

```bash
sudo python3 /home/yanjiarun/nexst_usb/tools/scope_usb_failure_snapshot.py --capture
```

JSON 写入 `build/nanhu-host/usb-failure-*.json`，不复位或写设备。该后端在 doorbell DONE 超时/提交失败时会关闭 BME，并使后续 guest BAR 读取失败。新 QEMU 默认将失败原因和 pending seq/offset 打到 stderr；上面的 `-d guest_errors -D ...` 还记录等待/收到 DONE 与物理 doorbell 提交。旧 QEMU 的错误输出受日志开关控制，旧 `qemu.log` 没有错误行不能排除该路径。`--capture --transport-only` 可只读复制现有主机 DMA32 接收区；它是状态快照，不保证历史报文仍在。

**7．停机和主机归还。**

guest shell 可用时，先在 guest 卸载 SD 分区并解绑实际 xHCI function：

```bash
umount /mnt/sdcard
printf '%s' 0000:03:00.0 > /sys/bus/pci/drivers/xhci_hcd/unbind
```

确认解绑成功后，在终端 B Ctrl-C 停止 QEMU，等待进程退出。保持 DDR 与 SoC 状态，随后在主机使用仓库已有的 `stop` 模式确认物理控制器停止并关闭 BME；该模式不写 scratch 内存：

```bash
cd /home/yanjiarun/nexst_usb
sudo build/nanhu-host/xhci-p2p-noop \
  0000:2a:00.0 0000:c2:00.0 /dev/xdma0_bypass 0x88000000 stop
```

必须得到 `PASS: xHCI stopped/reset, bus master off` 后，才复位香山并归还 B650：

```bash
sudo tools/proto/pcie-util /dev/xdma0_user write 0x100000 1
printf '%s' 0000:c2:00.0 | sudo tee /sys/bus/pci/drivers/xhci_hcd/bind
lspci -Dnnk -s 0000:c2:00.0
lsusb -t
lsblk -o NAME,PATH,TRAN,SIZE,RO,FSTYPE,MOUNTPOINTS
```

若 guest 卡住、无法正常解绑，先用 `ps -eo user,pid,args` 确定这轮 QEMU 的 PID；暂停该进程，保持 guest 内存，再运行上面的 `stop`。下面的 PID 必须填实际 QEMU 进程，不能填 `sudo` 或 `tee`：

```bash
set -e
PROXY_PID=  # 填实际 qemu-system-x86_64 PID
test -n "$PROXY_PID"
sudo kill -STOP "$PROXY_PID"
cd /home/yanjiarun/nexst_usb
sudo build/nanhu-host/xhci-p2p-noop \
  0000:2a:00.0 0000:c2:00.0 /dev/xdma0_bypass 0x88000000 stop
sudo kill -KILL "$PROXY_PID"
sleep 1
if sudo kill -0 "$PROXY_PID" 2>/dev/null; then
  echo 'QEMU has not exited; keep SoC memory intact and inspect the process.'
  exit 1
fi
sudo tools/proto/pcie-util /dev/xdma0_user write 0x100000 1
```

`stop` 失败时停止后续操作，保持代理暂停、控制器未绑定和 guest 内存；不执行 SoC reset、DDR 装载或主机 bind。此故障恢复流程在物理 DMA 停止后直接终止暂停的代理，避免它恢复处理旧报文；确认进程退出后再复位 SoC 并归还 B650。进程退出本身不能作为物理 DMA 已停止的证据。

**8．history 中的故障恢复命令何时使用。**

history 的多次 remove/rescan、insmod、桥窗口写入与 ioctl FREE 是排障记录。启动和装载通常只需要第 1～6 步。

若新 QEMU 报 `XDMA_IOC_DMA32_DB_ALLOC failed`，且原因是旧 DMA32 缓冲区仍占用，先完成第 7 步、使 SoC 保持 reset、确认所有旧代理退出，再核对占用：

```bash
sudo fuser -v /dev/xdma0_user /dev/xdma0_control /dev/xdma0_bypass
```

只有上述条件满足、确实需要释放旧缓冲区时，使用 history 的 ioctl。实际复制的驱动仍定义 `_IO('x', 0x21)` 为 `XDMA_IOC_DMA32_DB_FREE`：

```bash
sudo python3 - <<'PY'
import os, fcntl
fd = os.open('/dev/xdma0_control', os.O_RDWR)
try:
    fcntl.ioctl(fd, (ord('x') << 8) | 0x21)
    print('DMA32 缓冲区已释放')
finally:
    os.close(fd)
PY
```

然后重新按第 3～5 步初始化新代理与 guest。不能在旧代理仍读取该 ring 时执行 FREE。若错误不是缓冲区占用，按具体 errno 排查驱动/API，不循环 FREE 或 remove/rescan。

**9．需要重新构建时。**

当前预编译产物已校验，首次复现直接使用它们。旧构建目录的 Ninja、Meson、Linux/OpenSBI Makefile 和 initramfs manifest 仍可能记录原编译目录；新构建应使用新的输出目录或重新生成构建元数据。

QEMU 本机缺少 RDMA 开发包，USB-only 可在新目录关闭 RDMA 重建，保留复制的运行版本：

```bash
cd /home/yanjiarun/qemu_usb
mkdir -p build-usb-local
cd build-usb-local
../configure --target-list=x86_64-softmmu --disable-rdma --disable-docs
ninja -j8 qemu-system-x86_64
```

重建后把第 1 步 `USB_QEMU` 改为 `/home/yanjiarun/qemu_usb/build-usb-local/qemu-system-x86_64`，重新生成本轮环境文件。保留现有 manager/NIC/xHCI 修改；`tools/host/bootstrap.sh` 的旧补丁反向检查不能接受当前已修改的 xHCI 文件，不要为了通过该检查回退 maxiangyu 的修复。

固件构建计划可用 `bash tools/build_nanhu_host_software.sh --dry-run` 查看。真正重建前先备份现有 `build/nanhu-host/linux` 和 `opensbi` 输出目录，再由此脚本生成本地 initramfs 路径与构建文件；rootfs 如需重建也应使用本地源码和新的输出目录。启动修复默认由 `install_xhci_start_fix.py` 安装，诊断日志由 `install_xhci_irq_diagnostics.py` 控制，详见 [实现说明](NANHU_G_HOST_PERIPHERALS.md)。

迁移后已通过 [本地软件回归](../build/software-logs/usb-local-migration-tests.log)：7 项工具检查、旧/新 xHCI 启动函数、6 项 P2P 清理模拟、11 项生产 QEMU 文件模拟、guest DMA sanitizers 和 DTS 检查；尚未执行新版固件的真实 USB 文件读取。

## DMA32 接收环修复后的驱动切换

新模块已针对当前 `6.8.0-146-generic` 编译到 `build/usb-dma32-driver/linux-kernel/xdma/xdma.ko`，`20261013-123859` 实验确认已经加载。驱动版本一致时无需再次切换，正在运行的实验继续第 6 步即可。需要重新构建时运行 `bash tools/build_usb_dma32_driver.sh`；该脚本仅在隔离目录构建，不安装、不加载模块。

**先完成第 7 步停止旧实验，同时在 UART 终端 Ctrl-C 退出 `pcie-util`。** 新切换脚本允许 B650 保持未绑定状态；切换前会用 `stop` 模式停/reset xHCI 并关闭 DMA。若 B650 已绑定主机 `xhci_hcd`，则保留主机所有权。脚本先确认 NM37 是唯一绑定 XDMA 的设备、模块版本/哈希匹配且设备无人占用。

原来的长命令使用 `set -e` 和无错误提示的 `[[ ... ]]`。在 B650 未绑定时，它会在“必须绑定 xhci_hcd”的检查处退出，尚未执行模块卸载/加载；2026-10-13 现场正是该状态。现在使用下面的脚本逐步打印结果：

```bash
cd /home/yanjiarun/nexst_usb
python3 tools/switch_usb_dma32_driver.py
```

默认只核对和显示当前版本、PCI COMMAND 和驱动归属，不改变硬件。需要切换时，在主机终端执行：

```bash
sudo python3 /home/yanjiarun/nexst_usb/tools/switch_usb_dma32_driver.py --switch
```

`--switch` 的顺序为：检查身份及占用 → 停止未绑定 B650 的旧 DMA → 若 FPGA MEMORY 解码已关闭，只打开 MEMORY 位以访问 GPIO → 保持香山 reset 并校验 → 卸载旧 XDMA → 使用原参数加载新模块并校验版本、绑定和 reset。任何前置失败都会明确打印 `STOP: ...` 并停止；新模块加载/验证失败会尝试恢复匹配本轮的旧模块。脚本不启动香山、不装载 DDR、不写 SD 数据，也不覆盖系统安装的模块。

本次现场 FPGA PCI COMMAND 为 `0x0000`，其 MMIO 解码已关闭。原来的 reset 读取不能在这个状态下作为有效证明；新脚本只在 USB DMA 已停止后启用 MEMORY，再操作 reset GPIO。脚本允许 B650 保持未绑定，随后可直接按第 1–6 步接管运行。

切换成功必须显示 `PASS: loaded=...; XiangShan remains in reset`。当前在线会话 sudo 需要密码，该命令由用户在主机终端执行。完整输出可保存为：

```bash
cd /home/yanjiarun/nexst_usb
set -o pipefail
sudo python3 tools/switch_usb_dma32_driver.py --switch \
  2>&1 | tee build/software-logs/usb-driver-switch.log
```

当前旧模块 srcversion 为 `E8D778DA2B4752B55C46541`，本次新模块为 `8813CBD0853FD1FC9DA7C8A`；重新编译后以 `modinfo` 和 manifest 为准。若新模块已加载，跳过上述切换，不重复卸载。此方法仅切换本轮模块，重启主机后仍按系统配置加载模块。

切换完成后，从第 1 步创建新日志目录并重新启动本轮实验；QEMU 选择 `build-usb-local/qemu-system-x86_64`。第 4 步代理分配接收区时，用主机 `journalctl -k` / `dmesg` 确认出现：

```text
NexST proxy cyclic DMA started on C2H channel 1: 1024 slots, 64 bytes/slot!
```

再检查 `qemu-debug.log` 的 `waiting for DONE` → `DONE` → `doorbell committed` 是否序号一致。读卡器 `05e3:0751` 出现后，再按第 6 步确认 SD 容量并只读读取文件。测试结果见 [修复回归](../build/software-logs/usb-dma32-fixed-regression.log)；测试没有启动实际香山，最终文件验收需要下一轮物理实验。

参考：[实现与构建说明](NANHU_G_HOST_PERIPHERALS.md)、[本轮启动中断修复记录](NANHU_G_HOST_PERIPHERALS_VALIDATION.md)、[物理 xHCI 接管原理](B650_USB_XHCI_OWNERSHIP.md)。
