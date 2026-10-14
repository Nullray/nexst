# GitHub 普通昆明湖 SCOPE 分支

两版使用同一普通 Kunminghu CPU 提交与 SCOPE/QDMA 实现，只分开核数配置及对应的 CPU wrapper。
默认核数来自跟踪文件 `config/kunminghu-profile.json`；不依赖另一台服务器上的 `build/CPU_SOURCE.json`。

| 仓库 / 分支 | 用途 |
| --- | --- |
| [Nullray/nexst: feature/kunminghu-1core-scope-qdma-bridge](https://github.com/Nullray/nexst/tree/feature/kunminghu-1core-scope-qdma-bridge) | 普通单核，默认 NUM_CORES=1 |
| [Nullray/nexst: feature/kunminghu-2core-scope-qdma-bridge](https://github.com/Nullray/nexst/tree/feature/kunminghu-2core-scope-qdma-bridge) | 普通双核，默认 NUM_CORES=2 |
| [Nullray/qemu: feature/kunminghu-scope-qdma-bridge](https://github.com/Nullray/qemu/tree/feature/kunminghu-scope-qdma-bridge) | 两版共用 x86 QEMU 后端 |

单核、双核没有复制维护两套驱动或后端：后续公共修改可以在两个 Nexst 分支间合并/挑选提交。
共享 QEMU 通过 gitlink 固定到实际提交，不因 QEMU 分支后续移动而改变构建内容。

## 依赖与修改保存方式

- 普通 XiangShan：`OpenXiangShan/XiangShan`，提交 `4bbdccbb077840af5e1b65c7138d31af3966f625`。
- Nexst 基线：`NEXST-TOOL/nexst:kunminghu`，提交 `8137ac2a299a354ba10acc89c731af90b6d8c8cb`。
- work_farm：公开 VP1902 提交 `42d3d45e76d8331d5a89ace8355f7abdfb348fe5`，原生日志支持补丁随主仓库保存。
- QDMA 驱动：上游 gitlink + `tools/host/patches/qdma-hostbuf.patch`，包含 SCB1 coherent buffer 驱动及 UAPI。
- OpenSBI：上游 gitlink + `tools/host/patches/opensbi-scope.patch`，包含 UART、PLIC、hart count 和 heap 设置。
- Linux：上游 gitlink + `tools/guest/install_pci_dma.py` 与 `include/scope-p2p-dma.h`，构建时安装逐 function DMA helper。
- QEMU：新的公开共享分支；相对旧基线的完整补丁也保留用于检查来源。

子模块 URL 使用明确的上游地址，因此从 Nullray 的 fork 克隆不会误去寻找不存在的 Nullray/opensbi 等仓库。
`bootstrap.sh` 会应用尚未应用的依赖补丁，也能识别已经应用的内容。
GitHub 分支包含源码、依赖补丁、构建脚本及验证说明；生成 RTL、Vivado 工程、PDI、启动二进制和原始编译日志仍保留在本地构建目录。

## 克隆与编译

分别克隆到不同目录，避免并行生成的 RTL/检查点互相覆盖：

```bash
git clone --recurse-submodules --branch feature/kunminghu-1core-scope-qdma-bridge \
  https://github.com/Nullray/nexst.git nexst_kunminghu_single
git clone --recurse-submodules --branch feature/kunminghu-2core-scope-qdma-bridge \
  https://github.com/Nullray/nexst.git nexst_kunminghu_dual
```

在任一目录安装/确认 Vivado 2025.1、VP1902 license、Java 11、Mill 0.12.3、对应 CPU 工程需要的 firtool，以及 RISC-V GNU 工具链。
然后：

```bash
bash tools/host/bootstrap.sh
python3 tools/hardware/profile.py --field num_cores
scope_log="build/scope-console-$(date +%Y%m%d_%H%M%S).log"
mkdir -p build
nohup python3 -u tools/hardware/run_profile.py --from-stage full \
  > "$scope_log" 2>&1 < /dev/null &
echo "PID=$! LOG=$scope_log"
```

管理器读取当前分支的核数、校验子模块、生成 CPU_SOURCE 元数据，依次执行 RTL、wrapper、BD、前端检查、shell/role 综合和 PDI。
低层 `tools/build_vp1902.sh` 完成 RTL 后也自动生成对应 wrapper，随后才允许综合。
如显式传 `--num-cores`，必须与分支的 profile 相同；修改核数时使用对应分支和独立构建目录。

CPU RTL 生成后，在对应工程构建软件：

```bash
bash tools/host/build_qdma_driver.sh
bash tools/host/build.sh
bash tests/host-proxy/run.sh
bash tools/guest/build_scope_guest.sh
```

最后一条命令按当前分支默认核数生成 guest DT、Linux、OpenSBI 和 boot ROM；DT 的 hart 数会与生成的 CPU 配置核对。
后台构建和上板运行的细节见 [VP1902_BUILD_RUN.md](VP1902_BUILD_RUN.md) 和 [KUNMINGHU_SCOPE_BRIDGE_IMPLEMENTATION.md](KUNMINGHU_SCOPE_BRIDGE_IMPLEMENTATION.md)。

## 验证范围

原 Nanhu 双 BAR vSwitch SHA256 未变；实际两种核数的 Vivado BD 已检查 master bridge → u_role/s_axi_dma → 原生 CPU DMA 的全部信号与地址窗。
SCB1 RTL、驱动/QEMU 编译、模拟 NIC/xHCI、双 endpoint、两个核数的 wrapper 与构建失败传播检查通过。
已交叉编译两种 hart 数的 guest 固件，并核对 DT/镜像哈希。

真实 PCIe P2P、脏 cache line 一致性、B210 USB3 I/Q 和手机 4G/5G 接入尚未上板验证。
本分支发布源码，不宣称 PDI 综合/布局布线已完成；最终结果以对应构建状态和产物为准。
