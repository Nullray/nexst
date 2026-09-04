# 远端 Intel 82599 无驱动影子环架构设计

## 1. 文档目标

本文设计一种将 Host B 上的 Intel 82599（`8086:10fb`）提供给香山使用的远端
网卡路径。设计遵循以下原则：

- 香山继续枚举标准 `8086:10fb` PCI function，并绑定原生 `ixgbe` 驱动；
- Host B 的目标 82599 不绑定 `ixgbe`、VFIO 或其他功能驱动；
- Host B agent 通过 sysfs PCI resource/config 直接管理真实 BAR0 和 bus master；
- 真实 82599 只 DMA 到 Host B 的影子 ring 和 staging buffer；
- 跨主机传输仍通过独立 RDMA NIC 完成，目标 82599 不承载 RDMA 控制连接；
- 不把香山 guest PA、Host A PCIe 地址或 Host A 虚拟地址写入 Host B 物理描述符。

本文以仓库中的实际代码为边界，不假设 PCIe fabric 能跨主机路由，也不把普通
以太网/RoCE 网络描述成 PCIe 透明延伸。

## 2. 现状与修改后的边界

当前 `scope_fpga_vswitch_ixgbe_backend.c` 在 Host A QEMU 内实现一个最小 82599
模型。香山写 TDT 后，QEMU 读取 guest TX descriptor 和 payload，拼成完整帧并发送
`SCOPE_REMOTE_OP_IXGBE_TX`。现有 Host B `scope-remote-nic-agent` 通过绑定了
`ixgbe` 的 netdev 和 `AF_PACKET` 收发帧。

本设计保留 Host A 的 guest-facing 设备模型，只替换 Host B 数据面：

```text
XiangShan ixgbe driver
  -> guest BAR0 / guest TX and RX rings
  -> FPGA DMA32 mailbox
  -> Host A QEMU virtual 82599 model
  -> RDMA SEND (complete Ethernet frame)
  -> Host B shadow-ring agent
  -> Host B DMA staging + physical TX/RX descriptors
  -> unbound physical Intel 82599
```

因此，Phase 1 的 BAR 语义仍由 Host A 虚拟模型提供。Host B agent 只读取少量真实
状态（MAC、LINKS、descriptor DD），不把 guest 的每次 BAR 访问原样转发给真实
设备。这一点避免了 guest ring 地址覆盖 Host B shadow ring，也避免两个控制平面
同时拥有物理设备。

## 3. 组件职责

### 3.1 香山和 FPGA

香山使用标准 `ixgbe` 驱动。FPGA 继续提供配置空间 shadow、BAR route、DMA32
packet ring 和 aggregate INTx，不修改协议或 RTL。

### 3.2 Host A QEMU

Host A 继续负责：

- 模拟 probe 所需的 82599 BAR0、NVM 和中断寄存器；
- 稳定读取 guest descriptor 和 packet buffer；
- TX 完成后写回 guest descriptor DD；
- RX 到达后选择 guest RX descriptor、写入 payload/状态并产生中断；
- 用 feature negotiation 确认 Host B 是 packet agent 还是 shadow-ring agent。

配置项 `remote-device-mode` 有两个值：

| 值 | Host B 数据面 | 目标 82599 驱动状态 |
| --- | --- | --- |
| `packet` | `AF_PACKET` | 绑定 `ixgbe` |
| `shadow-ring` | BAR0 + 物理 DMA ring | 不绑定任何功能驱动 |

`shadow-ring` 使用 `rdma-memory-mode=inline`，会要求
`SCOPE_REMOTE_FEATURE_IXGBE_SHADOW_RING` 和
`SCOPE_REMOTE_FEATURE_IXGBE_INLINE`。该模式不分配 Host A payload staging MR；
完整帧直接放在已有 RDMA SEND message 中。能力不匹配时连接必须失败，禁止静默
落到 `AF_PACKET`。

### 3.3 Host B shadow-ring agent

agent 是物理 82599 的唯一 owner，负责：

- 检查 PCI identity 为 `8086:10fb`；
- 检查目标 function 没有绑定任何内核驱动；
- mmap `/sys/bus/pci/devices/<BDF>/resource0`；
- 从 hugetlbfs 文件分配并锁定物理连续的 DMA pool；
- 解析 `/proc/self/pagemap`，在 identity-DMA 前提下得到 82599 bus address；
- 保存并设置 PCI command 的 MEMORY 和 BUS_MASTER 位；
- 关闭物理 MSI-X/EIAC 路径，建立 queue 0 shadow TX/RX ring；
- 轮询 descriptor DD 和真实 `LINKS`；
- teardown 时先停止队列和 bus master，再注销 MR 和释放内存。
- 捕获 `SIGINT/SIGTERM`，从 RDMA/descriptor 轮询退出后执行同一 teardown。

agent 不注册 Linux netdev，不运行 DHCP，不创建 IP 地址，也不依赖 VFIO。

## 4. Host B DMA 内存布局

Phase 1 使用一个 2 MiB hugetlbfs 文件，典型布局如下：

```text
offset 0x000000  TX descriptor ring: 256 * 16 B
offset 0x001000  RX descriptor ring: 256 * 16 B
offset 0x002000  TX staging:          256 * 2048 B
offset 0x082000  RX staging:          256 * 2048 B
remaining         reserved/guard
```

每个物理 descriptor 只能引用该 pool 内的 bus address。agent 对每个 4 KiB 页检查
PFN 连续性；任意页面未 present、PFN 不可见或不连续都会使启动失败。

### 4.1 为什么必须显式要求 identity DMA

未绑定内核驱动的普通用户态程序不能调用 Linux DMA API 为设备建立 IOVA mapping。
因此以下任一条件成立时，无 VFIO 方案不能工作：

- IOMMU 为 translated domain；
- 82599 的 DMA 地址不等于物理地址；
- `/proc/self/pagemap` 因权限策略不返回 PFN；
- 内存会迁移、换出或物理不连续。

Phase 1 要求 root、hugetlbfs、`mlock()`，并要求操作者显式传入
`--allow-unsafe-identity-dma`。该参数只是确认前置条件，不会修改 IOMMU。生产或
多租户环境不应使用这一模式。

## 5. 数据通路

### 5.1 TX

1. 香山 `ixgbe` 写 guest TDT。
2. Host A QEMU 稳定读取 guest TX descriptors，拼接完整帧并计算当前软件模型支持
   的 checksum。
3. QEMU 发送带 request ID 的 `IXGBE_TX`。
4. Host B agent 将帧复制到一个 TX staging slot。
5. agent 写入真实 advanced TX data descriptor，执行 release fence，再写真实 TDT。
6. 真实 82599 从 Host B staging DMA 读取帧并在线路上发送。
7. agent 轮询真实 descriptor DD，返回 `IXGBE_TX_COMPLETE(request_id)`。
8. Host A QEMU 写回 guest descriptor DD，并按 guest mask 产生 queue 0 INTx。

TX completion 的含义是物理 82599 已完成 descriptor，而不只是 RDMA SEND 完成。

### 5.2 RX

1. agent 启动时把所有 RX staging slot 发布给真实 82599，并设置真实 RDT。
2. 真实 82599 将收到的帧 DMA 到 RX staging，写回 descriptor DD/EOP/length。
3. agent 轮询 DD，验证长度和 EOP，把完整帧放入 `IXGBE_RX` 消息。
4. Host A QEMU 按 guest RDT 消费 guest RX descriptor，并将帧写入香山 DDR。
5. QEMU 写回 guest RX descriptor 状态并产生中断。
6. agent 清理真实 descriptor 状态并重新发布对应 slot。

如果 Host A 暂无 guest RX descriptor，现有 QEMU 模型会丢包并记录计数。Phase 1
不在 Host B 无限缓存帧。

## 6. BAR 和控制面真实性

不能把所有 guest BAR write 原样镜像到真实 82599。尤其是以下寄存器必须分离：

- `TDBAL/TDBAH/TDLEN/TDT`：guest 地址属于香山 DDR；真实值必须指向 Host B shadow
  TX ring；
- `RDBAL/RDBAH/RDLEN/RDT`：真实值必须指向 Host B shadow RX ring；
- `EIMS/EIMC/GPIE`：guest 使用 Host A aggregate INTx，真实设备使用 polling；
- reset：guest reset 只能重置虚拟模型，不能在还有在途 RDMA 请求时直接重置物理
  function。

真实状态只通过受控通道同步：

- `LINKS` -> `IXGBE_LINK` -> guest LINKS/LSC；
- physical descriptor DD -> TX completion；
- RX descriptor status/length -> RX event；
- agent 错误/超时 -> Host A backend failed + guest link down。

这种设计比盲目 BAR 镜像更真实：guest 的 packet completion 和 link 来自物理设备，
同时不会破坏真实 shadow queue 的地址安全。

## 7. 初始化和恢复

Phase 1 不执行全设备 reset，也不重新实现 82599 EEPROM、SFP 和 PHY 初始化。推荐
启动顺序是：

1. Host B 先临时由 `ixgbe` 完成固件、SFP 和链路初始化；
2. 确认目标 netdev 没有 Host B IP 和业务流量；
3. 从 `ixgbe` unbind；内核的 `unregister_netdev` 仍会执行 `ixgbe_down`，SFP+
   型号可能因此设置 `ESDP.SDP3` 并关闭 TX laser；
4. 启动 shadow agent，接管 BAR、bus master 和 queue 0；对已确认由 SDP3 控制
   laser 的目标显式清除此位；
5. agent 等待并检查真实 `LINKS.UP`。部署模式默认要求链路恢复，否则启动失败，
   防止把物理链路故障误判成 guest DHCP 故障。

断电、`SIGKILL` 或进程崩溃仍可能留下设备寄存器状态。`SIGINT/SIGTERM` 的正常
cleanup 顺序固定为：关闭 RX/TX queue、清 bus master、unmap BAR、deregister RDMA
MR、munlock/unmap pool。部署脚本必须确认 agent 已退出，才能重新 probe `ixgbe`
恢复 Host B 管理；超时则保留 unbound 状态并报错，禁止一边 DMA 一边重绑驱动。

当前 Phase 1 只接管 queue 0，没有完整重写 `ixgbe` 的 EEPROM、PHY、MAC、flow
control 和 packet-buffer 初始化序列。`ixgbe` unbind 的 remove/reset 行为是否保留
足够的全局状态与具体固件和内核版本有关。因此该实现是可编译、fail-closed 的实验
原型，必须通过第 10 节的真实 TX/RX 计数器测试后，才能用于性能数据。若 queue
takeover 在目标机器上不能保持链路，应增加一个最小内核辅助驱动执行标准 ixgbe
初始化和 DMA mapping，而不是继续向用户态复制整套内核驱动。

## 8. 性能和后续优化

### 8.1 Phase 1 已消除和未消除的搬运

Phase 1 消除了 Host B 内核网络栈、skb 和 AF_PACKET 路径，真实 82599 直接 DMA
访问紧凑的 Host B staging。但是仍存在 CPU payload copy：

```text
TX: FPGA DDR -> Host A QEMU frame -> RDMA message -> Host B TX staging
RX: Host B RX staging -> RDMA message -> Host A QEMU -> FPGA DDR
```

Phase 1 已经移除了原来未被 packet agent 使用的 Host A payload staging pool，
但 RDMA message buffer 仍经过 QEMU CPU。因此它的价值是验证真实无驱动设备、
真实 DMA ring、完成和链路语义；不能标记为端到端 zero-copy。

### 8.2 Phase 2：去掉 Host A payload copy

保持系统配置改动最少的优化是保留同样的虚拟 BAR/队列控制面，替换 payload
消息：

- Host A 为 FPGA DDR coherent alias 注册 peer dma-buf MR；
- TX request 只携带 `{guest_pa, length}` segment；Host B RNIC RDMA READ 到同一个
  82599 TX staging slot；
- RX descriptor 完成后，Host B RNIC 从 RX staging RDMA WRITE 到 guest RX buffer；
- control SEND 只传 request ID、segment 和 completion 元数据。

此时 Host B 仍需要小型 staging，因为 82599 不能跨主机 PCIe DMA，但 CPU 不复制
payload。Host A 与 Phase 1 一样没有独立普通内存 staging pool，同时也不再把帧
payload 放进 QEMU RDMA message buffer。

该优化的硬前提是 Host A RDMA provider 支持 `ibv_reg_dmabuf_mr()`、XDMA peer
exporter 和 PCI P2P topology。当前目标 X722/`irdma` 环境尚未满足这些条件，因此
Phase 2 必须 fail closed，不能自动退回后仍宣称 zero-copy。

## 9. 安全和适用范围

无 VFIO + identity DMA 没有 IOMMU 隔离。82599 若收到错误 descriptor，可 DMA 到
任意物理内存。该模式只适用于专用实验 Host B，并要求：

- 目标 function 独占且无 driver symlink；
- RDMA NIC 与目标 82599 是不同 function；
- staging bus address 全部由 agent 内部生成；
- wire request 永远不能直接提供 physical address；
- 所有长度、ring index、device ID 和 generation 均验证；
- agent 退出前清 bus master；机器异常后重新绑定/重置设备。

## 10. 验收标准

- `remote-device-mode=shadow-ring` 无法连接旧 AF_PACKET agent；
- shadow agent 在目标 82599 已绑定驱动时拒绝启动；
- 非 `8086:10fb`、非 hugetlbfs、PFN 不连续或未确认 identity DMA 时拒绝启动；
- guest TX DD 只在真实 82599 descriptor DD 后写回；
- guest link 跟随真实 LINKS；
- RX payload 来源于真实 RX staging；
- agent 正常退出后 PCI bus master 已关闭；
- `SIGTERM` 停止时脚本只在 agent 完全退出后重新绑定 `ixgbe`；
- 旧 `remote-device-mode=packet` 行为保持兼容。
