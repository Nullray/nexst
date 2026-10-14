# Nanhu-G 主机外设验证记录

## 2026-10-14 GitHub 同步与当前验收结果

后续用户实验已完成 USB 读卡器 `05e3:0751` 枚举、SD 容量和分区读取，
并以 `ro,noload` 挂载 `/dev/sda1`，读取 Ubuntu `etc/os-release` 和 `README.txt`。
README SHA-256 为 `73e05a180ff9544d76d06594fb266f6b4becdb1049231709037d667bec1d936e`，
与此前主机读取记录一致。SD 卡的 ext4 error/recover 状态另见
[USB_EXT4_READONLY_DIAGNOSIS_ZH.md](USB_EXT4_READONLY_DIAGNOSIS_ZH.md)。
SD 写入、持续高负载及 B210 尚未验收。

同步前的软件验证：

- QEMU `build-usb-local` 增量构建通过。
- `tests/host-proxy/run.sh` 通过：8 项工具测试、旧/新 xHCI 启动时序、6 项 P2P
  清理检查、生产 DMA32 描述符的 ASan/UBSan 检查、6 项驱动切换顺序检查、
  13 组生产 QEMU 文件模拟 I/O、guest DMA 正反映射及原 DTS 映射。
- Linux USB、XDMA UART 和 DMA32 报文环补丁均在临时目录通过反向还原、正向应用
  及 Git blob 哈希核验；本次没有修改物理驱动状态。
- 已验证的 hvc0 `/init` 与 `inittab` 纳入主仓库，由 initramfs 构建入口引用。
- QEMU 恢复入口从原基线、此前公开版本及新锁定版本均通过离线稀疏 checkout
  验证：恢复的七个文件与锁定提交逐字节一致，重复执行不应用补丁。

软件回归日志为 `build/software-logs/usb-github-sync-tests-20261014.log`。
下面保留较早阶段的记录，其中“尚未枚举/读取文件”描述的是修复前状态。

## 2026-10-13 server48 上板排障更新

NM37 FPGA `0000:2a:00.0`、B650 xHCI `0000:c2:00.0`。
用户串口日志确认 guest `03:00.0` 枚举 USB 控制器并接受 coherent P2P DMA 窗口。
中断中的 CPU 读取与主机 coherent alias 读取一致：
`0a000000 00000000 01000000 00008801`，为端口 10 的有效状态变化事件。
连续八次中断的 dequeue 均保持 `0x208182616000`；U 盘枚举及文件读写尚未通过。

当前 Linux 5.16 存在与上游初始化中断风暴修复相符的时序：USB2 根集线器阶段
开启中断，软件 HALTED 状态直到 USB3 控制器启动后才清除。
构建入口已加入 `install_xhci_start_fix.py`，移植上游 `a808925075fb`，
将中断开启和控制器启动放在同一个 IRQ 保护区间，失败路径恢复原 IRQ 状态。

物理 xHCI QEMU 后端另增加普通事件的 RUN/HCHalted 门控和全 1 读数拒绝。
HSE/HCE 错误中断保持转发；不由后端确认或丢弃事件。
修改只涉及 xHCI 后端及其测试，manager、NIC 后端、硬件与 DTS 保持原哈希。
`nanhu-host-proxy-import.json` 将该后端从 `unchanged_qemu` 移入
`modified_qemu`，保留原始导入哈希。

软件验证日志：

- `build/software-logs/firmware-xhci-start-fix.log`：Linux Image、DTB、OpenSBI。
- `build/software-logs/qemu-xhci-start-guard-build.log`：QEMU 后端编译。
- `build/software-logs/host-proxy-xhci-start-fix-tests.log`：旧启动 C 函数重现提前
  中断，实际修复函数验证启动成功与失败路径；生产 QEMU 模拟 I/O 检查未启动、
  已停止、错误中断、寄存器全 1、停机后撤销与重启后保留事件，及既有回归。

新版固件与 QEMU 仍待用户重启上板验证。最新产物哈希见
`build/nanhu-host/preparation.json`。以下为 2026-10-12 的原始导入记录，
其中“物理 xHCI 后端未修改”仅描述当时状态。

2026-10-12，独立目录 `nexst_nanhu_g_host_peripherals`，本地分支
`feature/nanhu-g-host-nic-usb`。

## 软件构建

| 项目 | 结果 | 日志 |
| --- | --- | --- |
| 原 NIC + xHCI 的 QEMU `x86_64-softmmu`，启用 RDMA | 通过，1881 个构建步骤完成 | `build/software-logs/qemu-20261012_204733-29168.log` |
| Linux 5.16 PCI DMA 集成，RISC-V `pci-driver.o` | 通过 | `build/software-logs/firmware-20261012_205013-38501.log` |
| RISC-V Linux Image、原 Nanhu-G DTB、OpenSBI `fw_payload.bin` | 全部通过 | `build/software-logs/firmware-20261012_205127-41060.log` |

检查生成 `.config`，`IGB=y`、`IXGBE=y`、`SCOPE_PCIE_P2P_DMA=y`、
`USB_XHCI_HCD=y`、`USB_XHCI_PCI=y` 生效。
检查 OpenSBI 的实际二进制：在偏移 `0x200000` 完整嵌入本次生成的 Linux Image，
并包含本次原 Nanhu-G DTS 编译得到的完整 DTB；没有误打包默认测试 payload。

产物 SHA-256：

```text
31f8b15d6c2b6a4ad495dcc5f98c352d4aeb071c79121d6e4ddfc21b481c1043  Linux Image
47db523bd8ee2bcc190060ca677913f176a1b056b36f62c31f5a4416d7c3d7f5  XSTop_vpcie.dtb
b8bf8d69004dc4d01a9355494e4161e9e31e7fa45a4846e8493c9ab674914582  fw_payload.bin
```

## 软件回归

`bash tests/host-proxy/run.sh` 完整通过，日志为
`build/verification/host-proxy-tests.log`。

- 6 项工具检查：原配置的参数与顺序保持、重复 BDF/设备上限、原 NIC/硬件源码
  哈希保持、原 XDMA 启动参数、XDMA PCI 归属拒绝、initramfs 路径迁移及缺文件拒绝。
- 原 xHCI 后端的 11 组生产 QEMU 模拟 I/O：正常路径、legacy ownership、已绑定
  驱动、IOMMU、错误 class、MSI、32-bit DMA、无显式 P2P 选择、错误 BAR 布局、
  CNR 和 BIOS ownership。
- guest DMA helper：实际头文件通过 ASan/UBSan 检查，涵盖正反映射、解绑恢复/
  重绑定、8 种错误描述、非 SCOPE 设备及关闭 Kconfig 时拒绝 SCOPE xHCI。
- 原 DTS 的 2 GiB RAM、generic ECAM 和四个 INTx 到 PLIC 2 的映射。

Bash 语法、ShellCheck、根仓库和 QEMU 的 `git diff --check` 通过。
原 DTS 保留三个既有告警：bus-error-unit 缺少 reg/ranges，CPU/PLIC 的中断节点
缺少 #address-cells；DTB 编译与上述映射检查通过。本次不修改硬件或 DTS 来消除它们。

## 原实现保持与边界

逐字节确认以下文件与 `nexst_proxy_16` 一致：

- QEMU manager、`igb`、`ixgbe`、物理 xHCI 后端。
- 原本地/远程网卡配置，已有设备排列不变。
- 原 Nanhu-G kernel defconfig、PCI DMA 集成、DMA helper 和 UAS 修复。
- proxy RTL、alias bridge、shell/role Tcl、SoC DMA 入口和原 DTS。

关键源码哈希保存在 `doc/nanhu-host-proxy-import.json`。新目录中只恢复了复制过来的
QEMU/Linux 生成链接为 Git 基线内容，解决旧构建输出残留的链接问题；不修改原目录。
原工作区分支仍为 `usb-b650-xhci`，原修改状态保持。

本次未执行 Vivado、下载 FPGA 镜像、加载 XDMA、解绑设备或运行真实 PCI 代理。
没有对既有物理网卡进行重新测试；其软件完全复用原版本。
物理 xHCI → FPGA P2P DMA、USB 枚举、B210 固件重新枚举和持续双向 I/Q 尚未验收。
UHD/RAN/核心网与手机 4G/5G Internet 端到端链路未在本次部署。

## GitHub 同步准备

QEMU、Linux 和 XDMA 的 USB 依赖修改均导出为补丁纳入主仓库，保持原子模块
gitlink 不变。恢复脚本分别校验原基线，识别已应用状态并拒绝冲突。
Linux/XDMA 补丁已通过当前树反向检查及从原基线文件正向恢复检查；恢复出的文件
与本次编译使用的文件逐字节一致。构建产物、运行日志和其他工作区临时文件不提交。

QEMU 的物理 xHCI 实现另行提交为 `ca732b08d6fa2805c0fc81d56d295690155e3003`，
主仓库恢复脚本同步锁定这个公开提交；`igb/ixgbe` 后端与原版本保持一致。
保存的 QEMU 补丁仍用于兼容原基线，不重复应用到已包含 xHCI 的新提交。
