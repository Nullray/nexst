# Nanhu-G USB 后端同步到昆明湖 QDMA

2026-10-14。修改目录：`nexst_kunminghu_qdma_hostbuf`。

本次同步的远端版本：

- [Nullray/nexst `4f2d766`](https://github.com/Nullray/nexst/commit/4f2d7660b9c853766ba08a3956dccc0789480dc9)：
  Nanhu USB 驱动、guest 启动及诊断工具。
- [Nullray/qemu `bbc8bbb`](https://github.com/Nullray/qemu/commit/bbc8bbb7c1c7a2963a7e274f0ba1ad0df2e7c916)：
  xHCI 中断保护、门铃故障诊断及相关回归。

## 已同步的功能

`tools/host/qemu/hw/misc/scope_fpga_vswitch_xhci_backend.c` 与远端
`bbc8bbb` 对应文件逐字节一致：

- 普通 INTx 事件要求物理控制器 `RUN=1`、`HCHalted=0`。
- `USBCMD`、`USBSTS`、`IMAN` 全 1 读数不产生虚拟中断。
- 保留 `HSE/HCE` 硬件错误中断，即使控制器已自行停止。
- 门铃必须等匹配的 `BAR_WRITE_DONE` 后提交。
- 门铃 ACK/提交失败、等待 DONE 超时和无法停止 DMA 的原因直接输出到日志。
  QDMA 或 BAR FIFO 通知流故障也调用同一停机接口，附带明确原因。

保留本地 `qdma-cmpt`、完成环 mmap、批量 ACK/CIDX、额度和停机 marker；
已有网卡后端未修改。本次没有改动 RTL、QDMA IP 参数或正在综合的硬件输入。

QEMU 仍以主仓库 gitlink 中的 `6a30be8` 为基线。
`tools/host/patches/qemu-host-proxy.patch` 已重新生成，包含 USB 最新修复和
本地 QDMA 改动，`tools/host/bootstrap.sh` 可在该基线恢复完整软件实现。
导入版本和文件哈希记录在 [host-proxy-import.json](host-proxy-import.json) 的
`software_sync` 字段；原 `source_*` 和 `files` 字段保留早期导入快照的含义。

## 与 Nanhu-G 不同的部分

| 远端修改 | 昆明湖处理 |
|---|---|
| XDMA DMA32 每包一个循环描述符，避免 DONE 被后续读请求覆盖 | 当前使用 QDMA 完成环；保留已有槽位额度与背压，通过 DONE→readback 和环回绕回归验证。未移植 XDMA 模块切换脚本。 |
| Linux 5.16 xHCI 启动中断锁修复 | Linux 6.6 已有该修复。同步安装工具并增加现有实现识别；当前内核验证后不改写源码。 |
| RV64 `phys_ram_base` 初始化修复 | 同步到 PCI DMA 安装工具；旧内核按精确上下文补丁修复，6.6 已有正确下界，无需修改。 |
| Nanhu 5.16 xHCI IRQ 诊断插桩 | 使用旧 `ir_set/event_ring` 结构，不能直接应用于 6.6。当前通过 QEMU 日志和回归验证，不安装该旧版本插桩。 |
| NM37/B650 P2P probe、DMA32 驱动切换和故障快照 | 绑定了 NM37 身份、XDMA 设备节点及复位地址，不复制为 VP1902 可执行入口。XSAI 一致性 DMA 接线完成后，需按实际板卡另行验收。 |
| Nanhu initramfs/hvc0 输入和加载脚本 | 属于旧平台固件流程，保持昆明湖当前启动配置。 |

guest 工具可按以下顺序使用：

```bash
cd ~/nexst_proxy_17/nexst_kunminghu_qdma_hostbuf
python3 tools/guest/install_xhci_start_fix.py work_farm/software/linux
python3 tools/guest/install_pci_dma.py work_farm/software/linux
```

第一条在当前 Linux 6.6 输出 `Verified existing`；第二条负责安装已有的
SCOPE PCI DMA helper。修改 guest 内核后仍须按原软件流程重建 Linux 镜像。
本次同步未启动 guest 固件构建、加载驱动或操作真实 USB 控制器。

## 验证

```bash
JOBS=2 bash tools/host/build.sh
bash tests/host-proxy/run.sh
```

回归运行实际编译的 QEMU，使用文件模拟 PCI 寄存器与 DMA 内存：

- XDMA、BAR FIFO 和 QDMA 三种路径均检查中断状态保护、HSE/HCE、全 1 读数、
  门铃超时诊断及 DMA 关闭。
- XDMA 保留远端单槽覆盖复现和每包描述符回归；QDMA 新增暂停消费者后发布
  DONE→readback、八槽环多次回绕、ACK 额度归还及损坏通知关闭 DMA 的检查。
- guest 启动回归编译并执行当前 6.6 的 `xhci_run_finished()`，检查 IRQ 屏蔽
  恢复、成功消费事件和启动失败路径；旧实现仍可复现过早中断问题。
- 原 host-net/TAP、QDMA 通知 RTL、guest DMA 边界和设备树回归继续运行。

构建日志：`build/software-logs/qemu-upstream-usb-sync-build.log`。
测试日志：`build/software-logs/host-proxy-upstream-usb-sync-tests.log`。

本次 QEMU 重编、完整回归、bootstrap 重复执行、补丁从干净基线恢复及反向
核验均通过；结果记录于 `build/UPSTREAM_USB_SYNC_VALIDATION.json`。

这些是软件和传输层回归，未验证真实 VP1902→主机 USB 或 B210 链路。
当前 `COHERENT_DMA=0` 与 XSAI 一致性 DMA 入口限制仍按
[QDMA_HOST_BUFFER.md](QDMA_HOST_BUFFER.md) 执行。

## 本次对硬件构建的影响

本次远端增量与本地同步均不改变硬件输入，无需因这些软件修改重新编译 PDI。
原后台 PID `518509` 从 `role-synth` 续编，成功后脚本会自动进入 PDI 阶段。
硬件状态应以进程、阶段日志、检查点和最终 `system.pdi` 为准，不能把
`VP1902_LAUNCH.json` 中的启动时状态当作当前状态。

2026-10-14 12:43（北京时间）一次性核对：PID `518509` 仍在运行，阶段为
`role-synth`，该次日志没有失败记录。shell 的 `synth.dcp` 已生成；role 的
`synth.dcp`、布局布线时序报告和 `system.pdi` 尚未生成，无需另开构建进程。
状态快照保存于 `build/VP1902_STATUS.json`。
