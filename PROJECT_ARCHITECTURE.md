# 跨软硬件协同仿真与状态拦截系统架构解析

本项目实现了一个跨软硬件的协同仿真与状态拦截系统。核心链路是：**FPGA 硬件拦截总线事务 -> XDMA 通过 C2H DMA32 packet 把事件送到 x86/QEMU -> QEMU 解析并写回 ACK/响应 -> FPGA 按响应恢复或继续 AXI 事务**。

当前 `nexst_proxy_9` 的关键目标是：让 QEMU 作为真实 NVMe 的 proxy，可靠拦截 guest 对 NVMe BAR 的访问，解析并改写 Admin SQE 中的 DMA 地址，使真实 NVMe 通过 FPGA XDMA EP bypass BAR 进行 P2P DMA。为解决“QEMU 收到 SQ doorbell 后读到旧 SQE”的时序问题，当前版本使用 **BAR_WRITE_DONE + SQE_WRITE_DONE** 双事件闭环：QEMU 先让 guest 的 SQ doorbell MMIO 写完成，但只有同时看到 doorbell 的 BAR B 通道完成事件，以及 Admin SQE 写 DDR 的 B 通道完成事件后，才读取 SQE。

以下是项目中关键核心文件及其作用。

## 1. QEMU 侧：软件消费者与控制端

* **[qemu-mount/hw/misc/scope_fpga_proxy.c](qemu-mount/hw/misc/scope_fpga_proxy.c)**
  * **作用**：QEMU 自定义 PCI/虚拟设备，是 NVMe proxy 的软件状态机核心。
  * **功能详情**：
    1. 通过 XDMA 自定义 ioctl 分配 DMA32 ring，并将 ring `mmap` 到 QEMU 用户态。
    2. 启动 RX 线程轮询 DMA32 ring，解析硬件发来的固定 32B packet。
    3. 当前主要 packet type 包括 `CFG_WRITE`、`BAR_WRITE`、`BAR_READ`、`BAR_WRITE_DONE` 和 `SQE_WRITE_DONE`。
    4. 维护 NVMe BAR shadow 状态，包括 `AQA/ASQ/ACQ/CC`、doorbell、Admin queue 拓扑和虚拟 INTx 状态。
    5. 解析到 Admin SQ 参数后，QEMU 直接写 `sqe_write_done_monitor/s_cfg_axi` 配置寄存器，配置 Admin SQ base、bytes 和 valid。当前不再通过 `axilite_active_proxy` mailbox 传递 queue window，也不再配置 Admin CQ window 给 monitor。
    6. 对 Admin SQ doorbell 使用事件驱动延迟处理：收到 SQ doorbell `BAR_WRITE` 后先写 early OK response，并记录 pending doorbell；收到 `BAR_WRITE_DONE` 后只标记 BAR 完成；收到对应 slot 的 `SQE_WRITE_DONE` 后，如果 BAR 也已完成，才读取 SQE、patch PRP/metadata DMA 地址、写回 SQE，再把真实 doorbell 转发给真实 NVMe。
    7. 支持乱序事件：`SQE_WRITE_DONE` 可以先于 doorbell 到达并被记录；doorbell 也可以先于 `SQE_WRITE_DONE` 到达并保持 pending。pending doorbell 会记录每个 slot 的 done seq baseline，避免初始化或旧 `SQE_WRITE_DONE` 事件触发早读。
    8. Admin SQE 读取保留短 retry 和 seed 旧值拒绝逻辑作为异常兜底；正常路径不依赖固定长延时。
    9. 处理完成后，通过硬件 mailbox 写入 ACK/BAR response，包含 sequence、AXI response、读数据和可选 DONE request bit。

* **[qemu-mount/hw/misc/scope_fpga_proxy_abi.h](qemu-mount/hw/misc/scope_fpga_proxy_abi.h)**
  * **作用**：QEMU 与 FPGA RTL 共享的 DMA32 packet ABI。
  * **功能详情**：
    1. 定义 `scope_dma32_packet` 固定 32B 格式，由 8 个 `uint32_t` 字段组成。
    2. RTL 的 `AXIS_NOTIFY_LEN` 固定为 32；AXIS 数据宽度虽然是 512-bit，但 `tkeep` 只标记低 32B 有效。
    3. `SCOPE_PKT_TYPE_BAR_WRITE_DONE = 4` 表示被 QEMU early response 且请求 DONE 的 BAR write 已经在 guest AXI B 通道完成握手。
    4. `SCOPE_PKT_TYPE_SQE_WRITE_DONE = 5` 表示 Admin SQ window 内的一次 AXI write 已经在 DDR 写路径收到 B response。该 packet 使用 `flags[15:0]` 表示 slot，`flags[23:16]` 表示 qid，`flags[25:24]` 表示 bresp，`flags[31]` 表示 monitor overflow；`bar_offset` 保存 `guest_pa[31:0]`，`guest_addr_lo` 保存 `guest_pa[63:32]`，`data` 保存 write bytes。
    5. QEMU 与 RTL 必须同步更新该 header 中的 packet type 数值，否则 QEMU 会无法识别硬件事件。

## 2. 硬件/FPGA 侧：拦截、监控与通知

* **[shell/nm37_vu37p/fpga/sources/hdl/recorder/axilite_active_proxy.v](shell/nm37_vu37p/fpga/sources/hdl/recorder/axilite_active_proxy.v)**
  * **作用**：AXI/AXI-Lite 主动拦截代理模块。
  * **功能详情**：
    1. `S_AXI` 侧处理配置/控制类 AXI-Lite 访问，`S_BAR_AXI` 侧拦截 guest 对真实 NVMe BAR 的 AXI 访问。
    2. 拦截目标请求后生成固定 32B DMA32 packet，通过 C2H AXI-Stream 发送给 XDMA/QEMU。
    3. 内部维护 mailbox 状态机，发包后阻塞对应 AXI 通道，直到 QEMU 写回 ACK/BAR response。
    4. 对 QEMU 设置 DONE request bit 的 BAR write，RTL 先按 QEMU response 给 guest 返回 B response；随后观察 `s_bar_axi_bvalid && s_bar_axi_bready`，只有 guest 侧 B 通道握手完成后才发 `BAR_WRITE_DONE`。
    5. 当前版本不再承载 Admin SQ/CQ queue window 配置，也不再输出 queue window 到 monitor；queue window 由 QEMU 直接写 monitor 的 AXI-Lite 配置口。
    6. 保留虚拟 INTx、VCONF mailbox、BAR response、BAR read/write 统计等职责。统计寄存器和 INTx mask 寄存器已整理为单一 always block/单一状态机驱动，避免多 always block 驱动同一寄存器。

* **[shell/nm37_vu37p/fpga/sources/hdl/recorder/sqe_write_done_monitor.v](shell/nm37_vu37p/fpga/sources/hdl/recorder/sqe_write_done_monitor.v)**
  * **作用**：Admin SQE 写完成事件监控模块。
  * **功能详情**：
    1. 工作在 `xdma_ep/axi_aclk` 域，带一个 32-bit AXI-Lite 配置口 `s_cfg_axi`。
    2. QEMU 通过 `s_cfg_axi` 写入 Admin SQ window：`0x00 ADMIN_SQ_BASE_LO`、`0x04 ADMIN_SQ_BASE_HI`、`0x08 ADMIN_SQ_BYTES`、`0x0c ADMIN_SQ_CTRL bit0=valid`、`0x10 STATUS`。
    3. 被动监听 DDR 写路径 `axi_ic_ddr_mem_reg_slice_S01/M_AXI` 的 AW/B 通道，不改变 AXI ready/valid，不阻塞 guest 写 DDR。
    4. 在 AW handshake 时记录写事务地址、长度、是否命中 Admin SQ window 和 slot。
    5. 在对应 B 通道 `bvalid && bready` 后，如果该写覆盖 Admin SQ window，则生成 `SQE_WRITE_DONE` packet。
    6. monitor 监听 AXI 返回方向信号时必须挂到已有 BD net 上。当前 Tcl 中 `AWREADY/BRESP/BVALID` 从 `axi_ic_ddr_mem/S01_AXI_*` 已存在 net 旁路 tap，避免把 `reg_slice_S01/m_axi_*` 输入 pin 单独拉成无源 net 导致 tied-off。
    7. 内部有小 FIFO 保存 AW 元信息和待发事件；FIFO 满时设置 overflow sticky，并通过 `flags[31]` 报给 QEMU，但不反压原始 DDR 写事务。

* **[shell/nm37_vu37p/fpga/scripts/xiangshan.tcl](shell/nm37_vu37p/fpga/scripts/xiangshan.tcl)**
  * **作用**：Vivado Block Design 构建脚本。
  * **功能详情**：
    1. 例化 `axilite_active_proxy_0`、`sqe_write_done_monitor_0`、AXIS clock converter、AXIS register slice 和 C2H 合流 interconnect。
    2. `axi_ic_host_vconf/M02_AXI` 连接到 `sqe_write_done_monitor_0/s_cfg_axi`，QEMU 通过 host AXI-Lite 空间直接配置 monitor。
    3. active proxy C2H packet 和 SQE monitor C2H packet 通过 `axis_ic_proxy_c2h1` 2-to-1 合流，再接到 `xdma_ep/S_AXIS_C2H_1`。
    4. monitor 的 AW 地址/长度/valid 从 `axi_ic_ddr_mem_reg_slice_S01/M_AXI` 侧 tap；返回方向 `AWREADY/BRESP/BVALID` 从 `axi_ic_ddr_mem/S01_AXI_*` 已存在 net tap，保证不破坏真实 AXI 写返回路径。
    5. 地址分配：`HOST_MBX_REG = 0x11000000-0x11000fff`，`HOST_SQE_MONITOR_CFG = 0x11001000-0x11001fff`，`HOST_VCONF_BRAM = 0x11010000-0x11010fff`。QEMU 侧 monitor config offset 对应 `0x01001000`。
    6. 当前保留 ILA 重点观察 XDMA EP bypass AXI、guest/role DDR 写路径、SQE monitor packet stream 和合流后的 C2H stream。

## 3. NVMe Proxy 数据路径与时序闭环

1. guest NVMe 驱动把 Admin SQE 写入 FPGA 侧 queue memory。
2. `sqe_write_done_monitor.v` 在 DDR 写路径看到 Admin SQ window 内的 AW handshake，并等待该写事务 B response handshake。
3. guest 对 NVMe BAR doorbell 写 tail。
4. `axilite_active_proxy.v` 捕获 SQ doorbell `BAR_WRITE`，把它作为 DMA32 packet 发给 QEMU。
5. QEMU 识别这是 Admin SQ doorbell 后，先通过 mailbox 写 OK response，并设置 DONE request bit，但暂时不读 SQE。
6. 硬件收到 response 后给 guest 返回 AXI B response。等 `s_bar_axi_bvalid && s_bar_axi_bready` 完成后，硬件发 `BAR_WRITE_DONE` packet。
7. SQE 写事务在 DDR 写路径收到 B response 后，monitor 发 `SQE_WRITE_DONE` packet。
8. QEMU 只有在 pending doorbell 同时满足 `BAR_WRITE_DONE` 和对应 slot 的新 `SQE_WRITE_DONE` 后，才读取 SQE。这个判断包含 baseline seq，避免旧 done 事件导致早读。
9. QEMU 将 SQE 中的 PRP/metadata guest 地址改写成真实 NVMe 可访问的 FPGA XDMA EP bypass BAR host 地址。
10. QEMU 把 patch 后的 SQE 写回 queue memory，并把真实 doorbell 转发给真实 NVMe。
11. 真实 NVMe 通过 P2P 路径访问 FPGA XDMA EP bypass BAR 完成 PRP 数据和 CQE 读写。

## 4. Linux 驱动侧：XDMA 内核态桥梁

* **[shell/software/xdma_drv/XDMA/linux-kernel/xdma/cdev_ctrl.c](shell/software/xdma_drv/XDMA/linux-kernel/xdma/cdev_ctrl.c)**
  * **作用**：XDMA 字符设备控制节点的增强实现。
  * **功能详情**：
    1. 新增 `XDMA_IOC_DMA32_DB_ALLOC` 等自定义 ioctl，为 QEMU 分配连续 DMA 内存。
    2. 分配内存时自动配置并启动 C2H cyclic DMA 引擎，使硬件 packet 自动写入 host ring。
    3. 提供 stale cyclic transfer 清理机制，提升多次运行、remove/rescan 和异常退出后的稳定性。

* **[shell/software/xdma_drv/XDMA/linux-kernel/xdma/libxdma.c](shell/software/xdma_drv/XDMA/linux-kernel/xdma/libxdma.c)**
  * **作用**：底层 DMA 引擎控制核心。
  * **功能详情**：增强 cyclic stop 等路径的鲁棒性，避免 QEMU 异常退出或链路断开时留下坏状态。

## 5. 测试与运行工具侧

* **[tools/proto/load_and_run.sh](tools/proto/load_and_run.sh) / [tools/proto/load_and_run_5.sh](tools/proto/load_and_run_5.sh)**
  * **作用**：FPGA 原型运行入口脚本。
  * **功能详情**：对目标系统 assert/deassert reset，加载 bootrom 和 payload，并通过 readback fence 排空/确认 DDR bypass posted write，随后启动串口连接。

* **ILA/Tcl/Python 调试脚本**
  * **作用**：在枚举卡死、丢包、SQE 旧值、P2P DMA 路径异常时抓取硬件侧波形。
  * **重点观察点**：
    1. guest/role 写 `0x845ca000` 等 Admin SQ 地址的 AW/W/B。
    2. SQ doorbell BAR write 及 `BAR_WRITE_DONE`。
    3. `SQE_WRITE_DONE` packet stream。
    4. XDMA EP bypass 的 AR/AW/R/W，确认 QEMU 或真实 NVMe 是否在正确完成点之后读取/写入。
    5. Vivado build 日志中不应再出现 monitor 相关 `AWREADY/BRESP/BVALID tied-off` 或 `NET has no source`。

## 6. 当前实现边界

1. Linux NVMe 驱动不依赖额外 `dma_wmb()` 修改；当前修复目标放在 proxy 软硬件事件闭环上。
2. QEMU 与 RTL 必须同步更新。只更新 QEMU 而不更新 bitstream 时，QEMU 会等待硬件永远不会发出的 `BAR_WRITE_DONE` 或 `SQE_WRITE_DONE`。
3. `BAR_WRITE_DONE` 只证明 doorbell MMIO 写对 guest 完成；`SQE_WRITE_DONE` 证明 Admin SQE 写事务在 DDR AXI 写路径收到 B response。QEMU 正常路径需要两个事件都到达。
4. `SQE_WRITE_DONE` 的完成语义不是 CPU cache/PMA 层面的全局一致性证明。如果 `SQE_WRITE_DONE` 之后仍读到旧 SQE，应继续排查 queue memory/cache coherency/alias，而不是继续增加固定 sleep。
5. `sqe_write_done_monitor` 当前只覆盖 Admin SQ window，这是为 probe 阶段 qid 0 的 SQE 读早问题设计的第一阶段修复。
6. monitor 是旁路监听模块，不能驱动或截断原 AXI ready/valid。BD 连接时返回方向信号必须挂到已有 net，不能从 master 侧 input pin 新建无源 net。
