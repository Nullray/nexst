# 本地普通昆明湖 SCOPE 软件与启动镜像

本文记录本服务器现有产物；新克隆请按 [GitHub 分支说明](GITHUB_KUNMINGHU_BRANCHES.md) 和该分支 profile 构建。

维护与交付目录：`/home/yanjiarun/nexst_proxy_17/nexst_kunminghu_scope`。
分支：`feature/vp1902-kunminghu-scope-bridge`。
后续软件修改、镜像和文档在本地整理；41 已有两份硬件构建按原任务继续执行。

## 当前可用文件

| 内容 | 本地工程内路径 |
| --- | --- |
| QEMU 后端二进制 | `tools/host/qemu/build-kunminghu-scope/qemu-system-x86_64` |
| 本机 5.15.135-yfl QDMA 驱动 | `tools/driver/xdma_drv/QDMA/linux-kernel/driver/src/qdma-pf.ko` |
| 单核普通昆明湖启动镜像 | `build/guest-1core/RV_BOOT.bin`、`bootrom.bin`、`kunminghu-scope.dtb` |
| 双核普通昆明湖启动镜像 | `build/guest-2core/RV_BOOT.bin`、`bootrom.bin`、`kunminghu-scope.dtb` |
| 两版 Linux Image | 各自 `build/guest-1core/Image`、`build/guest-2core/Image` |
| 镜像校验与构建信息 | 各镜像目录 `SHA256SUMS`、`FIRMWARE_BUILD.json` |
| 软件验证记录 | `build/verification/SOFTWARE_VALIDATION.json` |
| QEMU/driver/guest 编译日志 | `build/software-logs/` |
| 最终回归日志 | `build/verification/host-proxy-regression.log` |

两版复用支持两核的同一份 Linux Image，DT/OpenSBI 的 hart 数分别为 1 和 2。
镜像按实际普通昆明湖生成的设备树制作，采用 SCB1 slave bridge 软件架构。
驱动二进制须匹配运行主机内核；不要把 41 的 `5.15.0-176-generic` module 当成本机 module。

## 本地软件编译与检查

```bash
cd /home/yanjiarun/nexst_proxy_17/nexst_kunminghu_scope
bash tools/host/bootstrap.sh
bash tools/host/build_qdma_driver.sh
bash tools/host/build.sh
bash tests/host-proxy/run.sh
```

已有两版镜像已做 SHA256 校验。需要重新制作时：

```bash
# 本地保存的实际普通双核生成 DT
NUM_CORES=2 JOBS=4 bash tools/guest/build_scope_guest.sh
# 复用 SCOPE Linux Image，按已保存的实际普通单核 DT 构建固件
python3 tools/guest/build_scope_firmware.py --num-cores 1 \
  --image build/guest-2core/Image --source build/ordinary-single.dts
```

每次完整 guest 编译输入的 DT 必须来自相同核数的实际 CPU 配置；脚本不接受不匹配的核数。
本地默认 CPU 生成 DT 为双核，单核固件命令显式选择保存的单核 DT。
最小 rootfs 仅用于 PCI/USB/网络 bring-up，尚未加入 UHD/RAN/核心网。

运行前检查实际 FPGA BDF 与 backend JSON，启动命令由 `tools/host/run_host_proxy.py` 生成。
它使用显式 QEMU BIOS 路径，选择 `qdma-bridge`，通过 coherent alias 访问 guest RAM。
编译、检查和完整运行顺序见 [KUNMINGHU_SCOPE_BRIDGE_IMPLEMENTATION.md](KUNMINGHU_SCOPE_BRIDGE_IMPLEMENTATION.md)。

本地软件回归使用模拟 PCI/BAR/DMA 环境；真实 cache coherency、网卡、B210 I/Q 仍需待对应 PDI 完成后上板验证。
