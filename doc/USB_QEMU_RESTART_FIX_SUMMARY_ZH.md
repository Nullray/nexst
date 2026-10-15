# QEMU 重复启动宿主机卡死：修复说明与提交清单

2026-10-15。本文件描述最终的 `restart-fixed` 实现，供 QEMU/nexst 两个仓库
同步代码、编写提交说明和复核使用。本文已包含必要的历史证据和验证边界，操作步骤见
[修复版启动文档](USB_QEMU_RESTART_FIXED_START_ZH.md)。

## 问题和证据边界

原现象：服务器重启后首次启动 QEMU 通常能运行，后续启动可能整机无响应，
SSH、键盘均失效，但 BMC 显示仍通电。最后输出停在物理 xHCI 初始化信息附近。
用户每轮会退出代理和串口、PCI remove、重烧 FPGA、PCI rescan，不反复卸载模块。

启动命令和 `load_and_run_5.sh` 没有隐含执行 insmod/modprobe/rmmod；
不是这些命令重复加载 XDMA 模块。代码检查与离线复现确认的是 **QEMU 与 XDMA
自定义 DMA32 接收环的资源归属、退出和 remove/probe 生命周期缺陷**。

宿主机 BERT 日志曾报告 FPGA 上游 Root Port `0000:29:01.0` 的 fatal PCIe
记录，但没有故障瞬间调用栈；两份启动日志打印的 BERT 块完全相同，不能认定
它们是两次独立的新事件。因此，已修复确定的软件缺陷，但尚不能证明原始硬锁死
唯一由其中某一条路径触发，也不能只凭最后一行输出确定卡住的 MMIO 指令。

这里的 DMA32 接收环位于 **x86 宿主机内核分配的内存**，用于 FPGA C2H
传送 SCOPE CFG/BAR 报文；不是 B210 的 IQ FIFO，也不是 guest 的 USB 数据缓冲。
错误释放它可能影响整个宿主机，风险不限于 guest USB 请求失败。

## 已确认的问题与对应修复

| 问题 | 原行为及风险 | 最终修复 |
|---|---|---|
| QEMU 普通进程退出未执行 SCOPE 清理 | 仅注册 PCI device exit 回调，普通进程退出不等于设备撤销；内核环和循环传输可能遗留 | 注册进程 exit notifier，复用幂等清理；先停止 RX 线程，再清理物理后端，最后释放本进程拥有的 DMA32 环 |
| ALLOC 失败仍误认为拥有资源 | ALLOC 前写入 size；EBUSY 后清理以 size 判断 FREE，可能释放旧会话的环 | 使用独立请求结构，仅 ALLOC 成功设置 `dma32_db_owned`；分配失败不 FREE；mmap 失败由统一清理回收已取得的资源 |
| DMA 停止和释放缺乏同步 | 无要求的 engine lock，清 RUN 后不确认 BUSY 清零就释放描述符和接收环 | 串行化 DMA32 操作；持引擎锁检查/停止属于自己的传输；轮询 BUSY 清零后才释放；超时保留分配，返回错误 |
| remove/rescan 后跨设备处理旧对象 | `g_c2h_cyclic_transfer` 是模块全局；remove 未清自定义环，新 probe 可能用新 engine/pdev 处理旧传输 | 删除全局传输指针，改为每个 cdev 私有；在旧设备和 BAR 仍有效时清理自定义 DMA；新 probe 不继承旧对象 |
| 多进程/文件归属不明确 | 其他打开者可能干预设备级环，异常进程退出也缺少回收 | QEMU 启动前 flock 独占并 QUERY 检查遗留环；驱动记录分配者 `struct file`，限制 FREE/PUT/mmap，最后一个文件引用释放时尝试回收 |
| 分配失败和 DMA mask 处理不严谨 | 内存/描述符失败与 DMA 启动状态处理不完整；可能影响后续 DMA 地址能力 | 完整错误回滚，检查 C2H channel 1 与队列空闲、启动结果；DMA32 coherent 分配只临时调整 coherent mask 并恢复，不改变 streaming mask |

重烧 FPGA 不会自动执行宿主机驱动的资源析构。完整重配置可能终止旧硬件 DMA，
但常驻模块中的全局指针不会随之清空。remove 会销毁旧设备对象，rescan 创建
新对象；用模块全局变量跨越这个边界正是已确认的问题之一。新方案不要求每轮
反复 rmmod/insmod。

## 关键清理顺序

QEMU 正常退出：

```text
撤销退出 notifier，停止并 join RX 线程
  → 调用物理后端 cleanup（xHCI halt，并清 BME）
  → 解除映射，FREE 本会话成功 ALLOC 的 DMA32 环
  → 关闭文件，释放其余对象
```

本轮没有改写 xHCI backend 的 halt 实现，而是让 manager 在进程退出时调用
已有 cleanup，并将它排到 DMA32 环释放之前。

驱动 FREE/close：验证归属，在引擎锁内处理本传输，等待 BUSY 清零后，使用原
PCI allocation device 释放描述符和接收环。PCI remove 另先清 FPGA BME、调用
`pci_wait_for_pending_transaction()`，再清自定义 DMA，最后销毁接口和标准
XDMA 引擎/BAR。若自定义 DMA 停止失败，保留分配并持有原设备引用，避免将可能
仍被 DMA 使用的内存归还系统，也避免新 probe 错误接管这些对象。

## QEMU 仓库应同步的文件

实现基线：`feature/nanhu-g-host-nic-usb` 的
`bbc8bbb7c1c7a2963a7e274f0ba1ad0df2e7c916`；配套 QEMU 修复提交为
`4489d38ce7d0c91efff252d2229de297b50b9aad`。

| 文件 | 内容 |
|---|---|
| `hw/misc/scope_fpga_vswitch.c` | `ScopeProxyState` 归属和 notifier 状态；`scope_alloc_dma32_ring()`、`scope_proxy_realize()`、`scope_proxy_cleanup()` 及进程退出回调 |
| `tests/scope-usb/fake-xdma.c` | 模拟 QUERY/ALLOC busy、stale 情况，记录 FREE，完全使用临时文件 |
| `tests/scope-usb/test-lifecycle.py`（新增） | busy/stale、SIGINT/SIGTERM、并发代理拒绝、两次启动退出回归 |
| `tests/scope-usb/run.sh` | 接入生命周期回归 |

本次不修改 `scope_fpga_vswitch_xhci_backend.c`，不引入新的 QEMU 设备参数或
阶段诊断打印。该文件中原有的 xHCI 中断/doorbell 修复属于此前工作。

## nexst 仓库应同步的文件

实现基线：`feature/nanhu-g-host-nic-usb` 的
`4f2d7660b9c853766ba08a3956dccc0789480dc9`。

| 文件 | 内容 |
|---|---|
| `.gitignore` | 允许跟踪 XDMA/QEMU lifecycle patch |
| `tools/guest/patches/xdma-dma32-lifecycle.patch`（新增） | 保存四个驱动源文件的实际修复，便于不更新私有依赖仓库也能重放 |
| `tools/guest/bootstrap.sh` | 在原 packet-ring 补丁之后应用 lifecycle 补丁；识别已应用状态并保持幂等 |
| `tools/host/bootstrap.sh`、`tools/host/patches/qemu-restart-lifecycle.patch` | 固定配套 QEMU 提交 `4489d38ce7d0c91efff252d2229de297b50b9aad`；支持从原 USB 基线应用重启修复，并校验最终源码哈希 |
| `tools/build_usb_dma32_driver.sh` | 构建 manifest 记录全部五个相关源文件的哈希 |
| `tests/host-proxy/test-dma32-lifecycle.py`（新增） | 编译生产 stop/free/close/remove 函数，模拟引擎、文件归属和两个 PCI 设备检查生命周期 |
| `tests/host-proxy/run.sh` | 接入驱动生命周期回归 |
| `doc/nanhu-host-proxy-import.json` | 将 QEMU manager 从未修改清单移到已修改清单，记录源码哈希 |
| 本文、`USB_QEMU_RESTART_FIXED_START_ZH.md` | 最终修复说明、证据边界、手动启动与测试步骤 |

驱动补丁实际修改的是：

```text
shell/software/xdma_drv/XDMA/linux-kernel/xdma/cdev_ctrl.c
shell/software/xdma_drv/XDMA/linux-kernel/xdma/xdma_mod.c
shell/software/xdma_drv/XDMA/linux-kernel/xdma/xdma_mod.h
shell/software/xdma_drv/XDMA/linux-kernel/xdma/xdma_cdev.h
```

`cdev_ctrl.c` 实现设备私有 transfer、文件 owner、停止等待、错误回滚、release
和 mmap 权限；`xdma_mod.c` 在 `xpdev_free()` 接入 remove 清理；`xdma_mod.h`
增加 `dma32_transfer/dma32_owner/dma32_removing`；`xdma_cdev.h` 导出清理接口。
`nexst_dma32_ring.h` 属于已有 packet-ring 补丁，本次增加了其构建哈希记录，
没有再改写环布局。

**提交父仓库时必须包含 lifecycle patch 和 bootstrap 修改。** 驱动目录是
git submodule，父仓库不会把内部改动作为普通文件提交。当前采用父仓库保存
补丁的方式，保留 XDMA gitlink 基线 `e63f5a117a5a2cd83738105ea6c7c4b5ac16f6a3`。
原 UART API、packet-ring 补丁已在父仓库；补丁顺序由 bootstrap 维护。
如果以后将修复正式提交到驱动子模块上游，需另行协调 gitlink 与补丁策略。

UHD 打包、UHD 镜像构建、临时手动加载 xHCI 的试验、VP1902 迁移等不属于本次
宿主机重启修复提交。不要直接 `git add .` 把工作区其他任务一起提交。
`build/` 中的二进制、日志、环境文件不作为源码同步方式。

## 拉取后的恢复与验证

在两个仓库均同步本修复、且原依赖基线齐全后，在 nexst 执行：

```bash
bash tools/guest/bootstrap.sh
bash tools/build_usb_dma32_driver.sh "$PWD/build/usb-dma32-driver-restart-fixed"
```

bootstrap 会对依赖源码应用补丁；构建脚本只编译模块，不执行 insmod/rmmod。
QEMU 用原构建流程重新编译，将测试参数指向新编译的二进制。可运行已有完整
软件回归（示例假定 qemu 是相邻目录）：

```bash
SCOPE_GUEST_KERNEL="$PWD/work_farm/software/linux" \
  bash tests/host-proxy/run.sh ../qemu/build-nanhu-host/qemu-system-x86_64-restart-fixed
```

`-restart-fixed` 是本机为保留旧二进制使用的名字；若对方构建输出仍叫
`qemu-system-x86_64`，应使用实际新编译文件，不能仅凭文件名判断版本。
模块需针对运行主机的内核编译，不能跨内核直接复制本机 `.ko`。
ioctl 编号和结构未改变，但独立文件打开者不再能 FREE/PUT/mmap 别人的环；
已有快照/调试工具若依赖跨文件 mmap，也会受到这一权限约束。QUERY 仍允许读取。

已完成的离线验证：

- 13 项既有 QEMU USB 后端检查、6 项新增 QEMU 生命周期场景。
- 生产驱动 stop/free/close/PCI remove helper 的锁、归属、BUSY 超时保留、
  两个设备上下文隔离、原 allocation device 和 remove 顺序检查。
- 驱动构建，补丁首次应用/重复应用检查，以及原 guest DMA 映射和配置检查。
- 驱动/DMA C 测试使用 ASan/UBSan；原执行环境限制下关闭 LeakSanitizer 的
  leak 扫描。这些测试不连接真实 FPGA/USB、不验证物理 PCIe P2P 行为。

本次整理提交说明时再次运行完整软件回归，通过；源码和现有二进制哈希也与
`restart-fixed` 记录一致。本地复核日志：
`build/software-logs/usb-restart-fix-summary-check.log`。

本机初次构建对应模块 srcversion：`9E4F32A8FDE1EF6344F83A5`，运行内核
`6.8.0-146-generic`。这是本机版本核对信息，不是跨环境必须相同的通用常量。

## 后续物理观察和仍存在的限制

用户随后报告修复版 QEMU 再次启动未导致服务器卡死；会话中也只读观察到配套
模块已加载、代理继续处理请求。B210 在香山中完成 USB 3、UHD probe 和
100 kS/s、30 秒单通道 RX（2,998,745 样本，溢出/丢样/超时均为零）。
这些是用户操作后的观测，不是自动故障复现或大规模重复启动压力验收。
1 MS/s、60 秒测试出现设备接收溢出和丢样，属于尚待定位的流式性能问题，
不能与本次启动硬锁死混作同一已证实根因。

- 无故障瞬间堆栈，不能宣称所有宿主机 PCIe fatal 或硬锁死均已根治。
- BUSY 等待的 100 ms 只限制循环；若单次 PCIe MMIO 读本身不返回，不能保证
  整个清理操作 100 ms 内结束。pending transaction 等待也不是绝对物理保证。
- remove 失败路径可能保留 DMA 分配与设备引用直到宿主机重启，优先避免错误
  释放；不将这种保留包装成资源已完全回收。
- SIGKILL 无法运行 QEMU 的物理后端清理；驱动 release 只负责它拥有的
  DMA32 环，不能代替物理 xHCI 停止流程。
- 不支持所有用户 FD 尚打开时任意 remove/reflash。停止物理 DMA、退出旧
  QEMU/串口工具后再改 DDR 或 remove，仍是使用前提。flock 是协作锁，驱动
  ownership 才提供自定义 DMA32 操作的权限约束。

## 可用的提交标题与描述

QEMU 标题：`scope: fix process-exit cleanup and DMA32 ring ownership`

> 正常退出代理时执行 SCOPE 清理，并在释放本会话 DMA32 接收环前停止物理
> 后端。仅成功 ALLOC 后取得资源归属，避免 EBUSY 错误清理释放旧会话的环；
> 在触碰物理后端前使用 flock/QUERY 拒绝并发代理或遗留环。增加六类离线
> 生命周期回归。须与 nexst 的 XDMA lifecycle 补丁配套使用。

nexst 标题：`host-proxy: fix XDMA DMA32 lifetime across close and PCI reprobe`

> 自定义循环传输改为设备私有并绑定分配文件，停止时持引擎锁、等待 BUSY
> 清零后再释放；close 与 PCI remove 在旧设备仍有效时清理，避免新 probe
> 使用新设备上下文释放旧全局对象。停止失败保留 DMA 内存，补齐分配失败
> 回滚及 DMA mask 恢复。将修复保存为可重放补丁，更新 bootstrap、manifest
> 和生产 helper 离线回归。软件缺陷已验证，原始整机硬锁死触发点尚未锁定。
