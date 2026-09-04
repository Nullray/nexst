# RDMA 远端外设接入架构（当前实现）

## 1. 文档范围

本文描述仓库当前已经实现的远端外设接入路径，而不是未来规划。事实来源为以下
代码，最后核对日期为 2026-09-02：

- `qemu-mount/hw/misc/scope_fpga_vswitch.c`
- `qemu-mount/hw/misc/scope_fpga_vswitch_rdma.c`
- `qemu-mount/hw/misc/scope_fpga_vswitch_ixgbe_backend.c`
- `qemu-mount/include/hw/misc/scope_remote_proto.h`
- `tools/scope_remote_agent/scope_remote_agent.c`
- `tools/scope_remote_agent/scope_remote_nic_agent.c`
- `tools/scope_remote_agent/scope_remote_proto.h`
- `shell/software/xdma_drv/XDMA/linux-kernel/xdma/cdev_peer.c`

QEMU 和 agent 两份 `scope_remote_proto.h` 当前内容一致。修改 wire ABI 时必须同步
更新两份文件。

当前支持两种远端设备：

| 香山看到的设备 | Host B 设备 | 当前传输语义 |
| --- | --- | --- |
| NVMe 控制器 | Linux 管理的 NVMe controller/namespace | NVMe 命令语义 + RDMA payload |
| Intel 82599 `8086:10fb` | Linux `ixgbe` 管理的专用 netdev | 82599 虚拟模型 + 完整 Ethernet frame |

两者都不是“把 Host B 的 PCIe 总线延伸到香山”，也不把 Host B 的真实 BAR、真实
DMA 地址或真实队列直接映射给香山。

## 2. 总体结论

### 2.1 远端 NVMe

Host A QEMU 维护 guest 可见的 NVMe BAR、队列和完成状态。香山写 SQ doorbell 后，
QEMU读取SQE，解析并验证PRP，再发送`NVME_SUBMIT`给Host B。Host B agent使用：

- controller fd上的`NVME_IOCTL_ADMIN_CMD`执行允许的Admin命令；
- namespace fd上的`pread/pwrite(O_DIRECT)`执行普通READ/WRITE；
- `fsync()`执行FLUSH；
- Host B的一块page-aligned staging同时作为RDMA本地缓冲区和`pread/pwrite`缓冲区。

物理NVMe继续由Host B内核NVMe驱动管理。当前实现没有raw physical SQ/CQ engine、
没有`scope_remote_dma.ko`，也没有在userspace构造物理PRP。

### 2.2 远端 82599

Host A QEMU维护一个最小82599 PF模型。香山`ixgbe`驱动操作的是这个虚拟模型，
不是Host B真实82599的BAR。QEMU读取香山TX descriptor和packet buffer，把完整
Ethernet frame放进RDMA SEND消息。Host B nic agent收到后通过`AF_PACKET`
`sendto()`交给真实82599 netdev。

RX方向由Host B nic agent通过`AF_PACKET recvfrom()`取得完整帧，再用RDMA SEND
发给QEMU；QEMU把帧和descriptor完成状态写回香山DDR。

### 2.3 当前实际配置

仓库当前两个远端配置均显式使用`host-staging`：

- `vswitch-backends-remote-nvme.json`
- `vswitch-backends-remote-82599.json`

NVMe代码还实现了可选的`peer-dmabuf`模式；82599代码明确禁止该模式。

## 3. 分层架构

```text
                         Host A
┌────────────────────────────────────────────────────────────┐
│ XiangShan Linux                                            │
│   ├─ standard nvme driver                                  │
│   └─ standard ixgbe driver                                 │
│              │ CFG/BAR/descriptor/guest DMA address        │
│ NM37 FPGA virtual PCIe switch + XiangShan DDR              │
│              │ DMA32 control ring + BAR2 coherent alias    │
│ QEMU scope-fpga-vswitch                                    │
│   ├─ remote NVMe semantic model                            │
│   ├─ virtual 82599 packet model                            │
│   └─ remote-rdma RC transport                              │
│              │                                             │
│ Host A RNIC ─┴─────────────────────────────────────────────┼── RDMA
└────────────────────────────────────────────────────────────┘
                                                            │
                         Host B                             │
┌────────────────────────────────────────────────────────────┐
│ Host B RNIC                                                │
│   ├─ scope-remote-agent (NVMe)                             │
│   │    ├─ registered staging buffer                        │
│   │    ├─ NVME_IOCTL_ADMIN_CMD                             │
│   │    └─ pread/pwrite(O_DIRECT)                           │
│   └─ scope-remote-nic-agent (82599)                        │
│        ├─ registered SEND/RECV message buffers             │
│        └─ AF_PACKET socket                                 │
│                                                            │
│ Linux nvme driver / Linux ixgbe driver                     │
│              │                                             │
│ physical NVMe / physical Intel 82599                       │
└────────────────────────────────────────────────────────────┘
```

设备语义和transport在配置层分开：

```text
Device semantics: nvme / igb / ixgbe / vortex
Transport:        local-p2p / remote-rdma
```

但是当前组合不是任意的：

- `remote-rdma`只接受`nvme`或`ixgbe`；
- `ixgbe`只接受`remote-rdma + host-staging`；
- `igb`和`vortex`没有远端实现；
- local NVMe/IGB/Vortex仍走原有路径。

## 4. RDMA控制协议

### 4.1 连接

QEMU和agent使用`librdmacm + libibverbs`建立RC QP。控制消息使用已注册的4 KiB
SEND/RECV buffer。QEMU建立连接时依次执行：

1. 创建RDMA endpoint和RC QP；
2. 注册control TX/RX MR；
3. 根据memory mode注册Host A payload MR；
4. `rdma_connect()`；
5. 交换`HELLO/HELLO_RSP`；
6. 交换`DEVICE_OPEN/DEVICE_OPEN_RSP`；
7. 进入非阻塞CQ polling。

QEMU检查RDMA route实际选择的verbs device是否等于JSON中的`rdma-device`。Host B
agent也做同样检查。

### 4.2 Wire ABI

当前协议版本为`major=1, minor=2`：

```c
struct scope_remote_hdr {
    uint32_t magic;          /* "SRDM" */
    uint16_t major;
    uint16_t minor;
    uint16_t opcode;
    uint16_t flags;
    uint32_t payload_len;
    uint64_t session_id;
    uint64_t request_id;
    uint64_t generation;
    int32_t  status;
    uint32_t reserved;
};
```

所有多字节字段在wire上使用little-endian。单条消息固定最大4096字节，单个NVMe
请求最多64个segment，Ethernet frame字段最大2048字节。

协议头定义了以下opcode：

```text
HELLO / HELLO_RSP
DEVICE_OPEN / DEVICE_OPEN_RSP
BAR_READ / BAR_READ_RSP
BAR_WRITE / BAR_WRITE_RSP
NVME_ENABLE / NVME_DISABLE
NVME_SUBMIT / NVME_COMPLETE
RESET / RESET_RSP
KEEPALIVE / ERROR / CLOSE
IXGBE_TX / IXGBE_TX_COMPLETE / IXGBE_RX / IXGBE_LINK
```

“在枚举中定义”不等于当前agent都实现：

- NVMe agent实际处理`HELLO`、`DEVICE_OPEN`、`NVME_SUBMIT`、`KEEPALIVE`、`CLOSE`；
- NIC agent实际处理`HELLO`、`DEVICE_OPEN`、`IXGBE_TX`、`CLOSE`，并主动发送
  `IXGBE_RX`和`IXGBE_LINK`；
- 当前NVMe和NIC运行路径都不使用远端物理`BAR_READ/BAR_WRITE`；
- `NVME_ENABLE/DISABLE`和`RESET`不是当前端到端控制路径。

### 4.3 会话检查

接收端检查magic、major、minor上限、payload长度和reserved。首次`HELLO`之后还检查
session ID与generation。QEMU另外按request ID匹配NVMe/TX completion，并对请求
设置timeout。无法匹配的completion或CQ错误会把backend置为failed。

当前协议没有加密和身份认证，安全模型是受信实验网络。

## 5. Host A payload memory模式

### 5.1 `host-staging`

QEMU在Host A普通内存中分配page-aligned buffer：

```c
host_staging = qemu_memalign(4096, size);
peer_mr = ibv_reg_mr(pd, host_staging, size,
                     IBV_ACCESS_LOCAL_WRITE |
                     IBV_ACCESS_REMOTE_READ |
                     IBV_ACCESS_REMOTE_WRITE);
```

该MR的base、length和rkey通过`HELLO`告诉Host B。NVMe请求提交前，QEMU把guest
segment改写成Host A staging中的连续地址。

NVMe WRITE：

```text
香山DDR
  -> QEMU scope_guest_mem_read()/memcpy
Host A staging MR
  -> Host B发起RDMA READ
Host B staging
  -> pwrite(O_DIRECT)
远端NVMe namespace
```

NVMe READ：

```text
远端NVMe namespace
  -> pread(O_DIRECT)
Host B staging
  -> Host B发起RDMA WRITE
Host A staging MR
  -> QEMU scope_guest_mem_write()/memcpy
香山DDR
```

所以当前NVMe `host-staging`路径确实是Host A和Host B各有一个staging。Host A
staging负责把FPGA BAR窗口转换成RNIC容易注册的普通RAM；Host B staging同时是
RDMA本地buffer和`pread/pwrite`的userspace buffer。

QEMU把`host-staging` backend限制为一个in-flight请求。Host B NVMe agent当前也
向QEMU报告`max_inflight=1`。

### 5.2 `peer-dmabuf`

该模式只对远端NVMe开放。它的目标是去掉Host A staging，而不是去掉Host B
staging，也不是让物理NVMe直接DMA香山DDR。

XDMA驱动把BAR2 coherent-alias范围作为PCI P2PDMA资源导出：

```text
pci_p2pdma_add_resource()
 -> pci_p2pmem_alloc_sgl()
 -> dma_buf_export()
```

QEMU通过`/dev/xdmaN_peer`取得dma-buf fd，然后调用：

```c
ibv_reg_dmabuf_mr(pd, 0, export.length, export.guest_iova,
                  export.dmabuf_fd, access);
```

注册成功时，Host B可以把经过验证的guest PA直接作为Host A MR中的RDMA address：

```text
NVMe WRITE: 香山DDR -> Host B RDMA READ -> Host B staging -> pwrite
NVMe READ:  pread -> Host B staging -> Host B RDMA WRITE -> 香山DDR
```

直接模式成立需要：

- XDMA模块包含当前`cdev_peer.c`并成功创建`/dev/xdmaN_peer`；
- kernel启用PCI P2PDMA；
- BAR index、offset、size和guest IOVA与QEMU配置完全一致；
- FPGA与Host A RNIC的PCI拓扑通过`pci_p2pdma_distance()`检查；
- RNIC provider支持`ibv_reg_dmabuf_mr()`和P2P SG mapping。

任一步失败，QEMU启动失败。当前代码不会自动回退到`host-staging`。

### 5.3 为什么不能直接对BAR mmap调用`ibv_reg_mr()`

`/dev/xdmaN_bypass`的`mmap()`只是CPU访问FPGA PCIe BAR的窗口，不是普通Host A
DRAM。普通`ibv_reg_mr()`面向可由RNIC pin和DMA-map的内存页；设备BAR需要上面的
P2PDMA dma-buf importer/exporter路径。CPU能够读写BAR不代表RNIC能够经PCIe P2P
访问该BAR。

## 6. 远端NVMe实现

### 6.1 Guest可见设备

QEMU使用Host B `DEVICE_OPEN_RSP`提供的信息创建虚拟NVMe endpoint。当前Host B
agent返回：

- vendor/device：`8086:4802`；
- class：`0x010802`；
- BAR0 size：`0x4000`；
- NVMe version：`1.4`；
- controller page size：4096；
- namespace容量和LBA shift：启动时Identify真实namespace得到；
- max transfer：Host B staging size；
- max in-flight：1。

这些是虚拟endpoint能力，不等于把真实控制器配置空间原样透传。

### 6.2 BAR语义

远端NVMe BAR由QEMU本地维护：

- `CAP/VS`来自agent在open时返回的能力；
- `CC/AQA/ASQ/ACQ/INTMS/INTMC`由QEMU shadow；
- `CSTS.RDY`根据guest `CC.EN`和remote failed状态合成；
- 未实现的普通BAR读返回0；
- 未实现的普通BAR写在remote模式下被接受，但不会写Host B物理NVMe BAR；
- SQ doorbell被转换成语义化`NVME_SUBMIT`；
- CQ doorbell只更新QEMU中的guest CQ head和INTx状态。

因此远端NVMe的BAR访问延迟不是“香山到Host B真实NVMe BAR完成”的延迟。

### 6.3 SQE与PRP处理

香山写SQ tail后，QEMU：

1. 从香山DDR稳定读取SQE；
2. 根据qid/opcode计算数据方向和长度；
3. 解析PRP1、PRP2和PRP list；
4. 验证地址非零、页面对齐、长度不溢出且全部位于guest DDR窗口；
5. 把连续页面合并成`{guest_pa, length}`segment；
6. 限制segment数量不超过64；
7. 在`host-staging`模式复制payload并改写segment地址；
8. 发送包含原始64字节command和segment列表的`NVME_SUBMIT`。

这里的“PRP转换”是把PRP编码展开成经过验证的segment列表，不是把guest PA转换成
Host B物理NVMe的DMA地址。

### 6.4 Host B执行路径

Host B NVMe agent启动时：

1. 以`O_RDWR|O_DIRECT`打开namespace；
2. 以`O_RDWR`打开controller；
3. 分配page-aligned staging；
4. Identify namespace并得到容量与LBA格式；
5. 建立RDMA listener；
6. 接受一个连接；
7. 注册control TX/RX MR和staging MR。

当前没有自动检查namespace是否已挂载，也没有自动解绑Host B内核NVMe驱动。部署者
必须保证测试namespace没有文件系统挂载、没有其他写入者，并明确接受原始I/O风险。

普通I/O支持：

| Guest opcode | Host B动作 |
| --- | --- |
| FLUSH `0x00` | `fsync(namespace_fd)` |
| WRITE `0x01` | RDMA READ到B staging，再`pwrite(O_DIRECT)` |
| READ `0x02` | `pread(O_DIRECT)`到B staging，再RDMA WRITE |
| 其他I/O opcode | `INVALID_OPCODE` |

Host B按namespace ID、LBA、NLB、LBA shift、staging上限和segment总长度做二次校验。

### 6.5 Admin命令

当前Admin处理分为三类：

1. Create/Delete SQ/CQ：Host B直接返回成功，实际guest queue拓扑由QEMU维护；
2. Number of Queues、Interrupt Coalescing、Interrupt Configuration、Async Event
   Configuration：部分由agent虚拟化；
3. Identify、Get Log Page及允许的Get/Set Features：通过
   `NVME_IOCTL_ADMIN_CMD`交给Host B内核NVMe驱动。

其他Admin opcode返回`INVALID_OPCODE`。当前实现不是任意NVMe Admin passthrough，
也没有物理queue与guest queue一一对应。

### 6.6 Completion

Host B只有在RDMA payload和`pread/pwrite/ioctl/fsync`完成后才发送`NVME_COMPLETE`。
QEMU按request ID、qid和cid匹配请求；READ在`host-staging`模式下还要先把Host A
staging复制回香山DDR，然后才：

1. 合成guest CQE；
2. 写入香山guest CQ；
3. 更新CQ phase/tail；
4. 根据guest interrupt mask产生aggregate legacy INTx。

这条完成语义覆盖整个远端NVMe命令，不是假完成。

## 7. 远端Intel 82599实现

### 7.1 设备模型边界

QEMU维护最小82599 PF模型，包含：

- 128 KiB BAR0寄存器数组；
- 单TX queue和单RX queue；
- descriptor base/length/head/tail；
- TX/RX enable；
- MAC、MTU和link状态；
- EICR/EIMS和aggregate legacy INTx；
- 满足Linux `ixgbe` probe的最小EEPROM、firmware、reset和I2C语义。

香山所有82599 BAR读写首先在QEMU虚拟模型中处理。它们不会转发到Host B真实
82599 BAR。

### 7.2 TX路径

```text
guest写TDT
 -> QEMU把tail加入pending queue
 -> QEMU稳定双读TX descriptor
 -> QEMU通过scope_guest_mem_read()读取guest packet buffer
 -> 拼接完整frame到QEMU tx_frame
 -> RDMA SEND(IXGBE_TX，frame内嵌在control message)
 -> Host B agent从RDMA RECV buffer取出frame
 -> sendto(AF_PACKET, real 82599 netdev)
 -> IXGBE_TX_COMPLETE
 -> QEMU写回guest TX descriptor DD
 -> queue 0 legacy INTx
```

`IXGBE_TX_COMPLETE`表示Host B的`sendto()`成功接受完整帧，不保证帧已经从物理线缆
发出，也不是Host B真实82599的PCIe completion。

### 7.3 RX路径

```text
physical 82599 netdev收到frame
 -> Host B AF_PACKET recvfrom()
 -> RDMA SEND(IXGBE_RX，frame内嵌在control message)
 -> QEMU检查RX ring和可用descriptor
 -> scope_guest_mem_write()写guest RX buffer
 -> 写回DD/EOP和length
 -> queue 0 legacy INTx
```

Host B agent过滤`PACKET_OUTGOING`，避免把本机刚发送的frame当作RX回送。

### 7.4 `host-staging`名称容易误解的地方

配置和握手强制NIC使用`host-staging`，公共RDMA层也会在Host A分配并注册
`host_staging`。但是当前NIC frame并不使用NVMe的segment + one-sided RDMA路径：

- TX payload实际经过QEMU `tx_frame`和RDMA control TX buffer；
- Host B从RDMA control RX buffer直接调用`sendto()`；
- RX payload经过Host B control TX buffer和QEMU control RX buffer。

因此NIC不能画成“香山DDR -> A staging MR -> B staging -> 82599 DMA”。更准确的
描述是“香山DDR -> QEMU frame buffer -> RDMA SEND/RECV buffer -> AF_PACKET”。

当前NIC agent没有NVMe agent那种专用Host B staging pool。

### 7.5 当前限制

- 固定单TX/RX queue；
- 只支持legacy INTx，不支持MSI/MSI-X；
- 不支持TSO和多队列/RSS；
- wire frame字段最大2048字节，agent报告MTU范围576到1500；
- 真实82599继续绑定Host B `ixgbe`；
- Host B专用82599 netdev不得承载SSH或RDMA管理地址；
- guest link跟随Host B物理carrier；当前代码没有强制虚拟link-up开关。

## 8. BAR写完成语义与测量口径

### 8.1 远端NVMe BAR

普通寄存器由QEMU shadow或虚拟逻辑处理，SQ doorbell转化为`NVME_SUBMIT`。香山的
BAR write response不会等待Host B物理NVMe BAR被修改，因为当前路径根本不写该
物理BAR。

### 8.2 远端82599 BAR

普通寄存器写入QEMU的虚拟82599寄存器数组。TDT/RDT写只触发QEMU后续处理ring。
BAR write response不等待frame到达Host B；TX descriptor的DD与中断则等待
`IXGBE_TX_COMPLETE`。

### 8.3 实验解释

因此三种延迟不能混为一谈：

| 测量 | 实际含义 |
| --- | --- |
| 本地物理设备BAR访问 | 香山到本地真实PCIe BAR的同步访问路径 |
| 远端虚拟设备BAR访问 | 香山到FPGA/QEMU虚拟寄存器模型的响应路径 |
| `fio`或真实收发包 | 包含Host A、RDMA、Host B agent和真实设备操作的端到端I/O路径 |

要评价远端设备真实性能，应以NVMe实际I/O完成或NIC实际TX/RX完成为主，不能把远端
虚拟BAR延迟直接当作Host B真实外设BAR延迟。

## 9. 配置

### 9.1 当前远端NVMe `host-staging`

```json
{
  "version": 1,
  "devices": [
    {
      "type": "nvme",
      "transport": "remote-rdma",
      "remote-host": "10.30.19.15",
      "remote-service": "7471",
      "remote-device-id": "remote-nvme0",
      "rdma-device": "iwo3",
      "rdma-memory-mode": "host-staging",
      "rdma-staging-size": 4194304,
      "namespace-id": 1
    }
  ]
}
```

`rdma-staging-size`必须是4 KiB整数倍，范围为4 KiB到64 MiB。Host A staging不能
小于Host B agent报告的max transfer。

### 9.2 可选NVMe `peer-dmabuf`

```json
{
  "version": 1,
  "devices": [
    {
      "type": "nvme",
      "transport": "remote-rdma",
      "remote-host": "10.30.19.15",
      "remote-service": "7471",
      "remote-device-id": "remote-nvme0",
      "rdma-device": "iwo3",
      "rdma-memory-mode": "peer-dmabuf",
      "peer-memory-device": "/dev/xdma0_peer",
      "namespace-id": 1
    }
  ]
}
```

`peer-memory-device`省略时默认`/dev/xdma0_peer`。该模式禁止配置
`rdma-staging-size`，且不存在失败后的自动fallback。

### 9.3 当前远端82599

```json
{
  "version": 1,
  "devices": [
    {
      "type": "ixgbe",
      "transport": "remote-rdma",
      "remote-host": "10.30.19.15",
      "remote-service": "7472",
      "remote-device-id": "remote-82599-0",
      "rdma-device": "iwo3",
      "rdma-memory-mode": "host-staging",
      "rdma-staging-size": 4194304
    }
  ]
}
```

远端82599禁止`namespace-id`和`peer-memory-device`。

## 10. 启动和生命周期

### 10.1 NVMe agent

示例参数模型：

```text
scope-remote-agent
  --listen 10.30.19.15
  --service 7471
  --rdma-device irdma0
  --device-id remote-nvme0
  --controller /dev/nvmeX
  --namespace /dev/nvmeXn1
  --namespace-id 1
  --staging-size 4194304
```

agent当前只接受一个RDMA connection，连接退出后进程结束。它没有多租户、自动
重连或设备owner仲裁。

### 10.2 NIC agent

NIC部署脚本为：

```text
tools/scope_remote_agent/setup_remote_82599_rdma.sh
```

脚本检查Host A route、两端RDMA device、Host B RDMA netdev、真实82599 netdev和
driver，并拒绝复用带有Host B全局IP的82599 netdev。随后复制并编译nic agent、
启动agent并生成QEMU JSON。

### 10.3 QEMU停止与FPGA重烧

重烧FPGA或重新加载XDMA会使BAR映射、peer dma-buf generation和正在运行的QEMU
状态失效。安全顺序是先停止香山I/O和QEMU，再停止agent，之后重烧/重载，最后按
agent -> QEMU -> 香山的顺序重新启动。当前代码不能在XDMA reset后透明恢复session。

## 11. 失败和安全边界

当前实现提供：

- MR范围检查；
- guest PRP与segment范围检查；
- namespace、LBA和长度检查；
- session/generation/request ID检查；
- QEMU request timeout；
- CQ error和不匹配completion后fail backend；
- memory mode不匹配时启动失败。

当前尚未提供：

- RDMA连接认证或加密；
- 自动重连；
- 不确定WRITE状态的恢复协议；
- Host B namespace自动卸载/独占；
- 多session device arbitration；
- peer-dmabuf失败后自动回退；
- 远端设备reset的完整端到端状态机。

实验环境必须自行保证：

- Host B namespace未挂载且无其他写入者；
- Host B 82599 netdev是实验专用接口；
- RDMA网络可信且隔离；
- 不把rkey、payload或凭据写入公共日志；
- FPGA重烧、XDMA卸载和QEMU运行不并发。

## 12. 当前实现与未实现方案对照

| 功能 | 当前状态 |
| --- | --- |
| `nvme + remote-rdma + host-staging` | 已实现，当前JSON使用 |
| `nvme + remote-rdma + peer-dmabuf` | 代码已实现，运行依赖P2PDMA拓扑和RNIC provider |
| Host A与Host B各一个NVMe staging | 当前host-staging模式成立 |
| 去掉Host A staging | 仅peer-dmabuf成功时成立 |
| 去掉Host B NVMe staging | 未实现 |
| Host A发起RDMA WRITE推送NVMe WRITE payload | 未实现；当前由Host B发起RDMA READ |
| Host B raw physical SQ/CQ engine | 未实现 |
| `scope_remote_dma.ko`固定DMA pool | 未实现且当前不需要 |
| 远端物理NVMe BAR映射/转发 | 未实现，当前使用QEMU虚拟BAR |
| `ixgbe + remote-rdma`完整帧模式 | 已实现，当前JSON使用 |
| NIC直接RDMA guest packet buffer | 未实现 |
| NIC Host B staging pool | 未实现；当前使用RDMA消息buffer和AF_PACKET |
| 真实82599 BAR透传 | 未实现 |
| MSI/MSI-X、多队列、RSS、TSO | 未实现 |
| `igb + remote-rdma` | 未实现 |

## 13. 代码位置

| 位置 | 当前职责 |
| --- | --- |
| `qemu-mount/hw/misc/scope_fpga_vswitch.c` | JSON解析、guest内存访问、NVMe虚拟BAR/队列、PRP验证、completion/INTx |
| `qemu-mount/hw/misc/scope_fpga_vswitch_rdma.c` | RC连接、control MR、Host A payload MR、消息发送队列和CQ polling |
| `qemu-mount/hw/misc/scope_fpga_vswitch_ixgbe_backend.c` | 虚拟82599寄存器、单队列TX/RX、descriptor与INTx |
| `qemu-mount/include/hw/misc/scope_remote_proto.h` | QEMU侧wire ABI |
| `tools/scope_remote_agent/scope_remote_agent.c` | Host B NVMe agent、staging、one-sided RDMA、ioctl/pread/pwrite |
| `tools/scope_remote_agent/scope_remote_nic_agent.c` | Host B 82599 AF_PACKET agent |
| `tools/scope_remote_agent/scope_remote_proto.h` | agent侧wire ABI |
| `shell/software/xdma_drv/XDMA/linux-kernel/xdma/cdev_peer.c` | BAR2 P2PDMA dma-buf exporter |
| `tools/scope_remote_agent/scope_peer_mr_probe.c` | XDMA peer dma-buf MR注册探测 |
| `tools/scope_remote_agent/setup_remote_82599_rdma.sh` | 远端82599检查、部署、启动与配置生成 |

## 14. 验证建议

### 14.1 NVMe

分层确认：

1. RDMA route和RC连接正常；
2. `DEVICE_OPEN`返回的namespace容量/LBA格式正确；
3. 香山`lspci`和NVMe probe完成；
4. 小范围只读I/O正确；
5. 在确认测试namespace无有效数据后再做破坏性WRITE测试；
6. 对比QEMU日志中的`NVME SUBMIT/COMPLETE`和Host B agent状态；
7. 使用`fio`或校验程序测真实端到端I/O，而不是用BAR microbenchmark替代。

`host-staging`实验必须在结果中注明每个I/O方向都包含一次Host A侧CPU payload
copy：WRITE时guest DDR复制到A staging，READ时A staging复制回guest DDR。

### 14.2 82599

分层确认：

1. Host B RDMA netdev和82599 netdev角色没有混用；
2. 真实82599 carrier状态符合实验要求；
3. 香山`ixgbe`完成probe并看到预期MAC；
4. QEMU出现`TX_SUBMIT`，Host B `sendto()`成功并返回`TX_COMPLETE`；
5. 接上线缆和对端后验证真实TX/RX；当前实现不能在carrier down时强制guest
   虚拟link-up。

## 15. 最终数据路径摘要

```text
当前远端NVMe WRITE：
XiangShan DDR -> QEMU copy -> A staging -> RDMA READ
                -> B staging -> pwrite(O_DIRECT) -> NVMe

当前远端NVMe READ：
NVMe -> pread(O_DIRECT) -> B staging -> RDMA WRITE
     -> A staging -> QEMU copy -> XiangShan DDR

可选NVMe peer-dmabuf WRITE：
XiangShan DDR -> RDMA READ -> B staging -> pwrite(O_DIRECT) -> NVMe

可选NVMe peer-dmabuf READ：
NVMe -> pread(O_DIRECT) -> B staging -> RDMA WRITE -> XiangShan DDR

当前远端82599 TX：
XiangShan DDR -> QEMU tx_frame -> RDMA SEND buffer
                -> Host B RECV buffer -> AF_PACKET sendto -> 82599

当前远端82599 RX：
82599 -> AF_PACKET recvfrom -> Host B SEND buffer -> RDMA SEND
      -> QEMU RECV buffer -> XiangShan DDR
```

最重要的边界是：当前系统实现的是设备语义中介，不是远端PCIe BAR/DMA透明映射。
远端NVMe的真实完成由Host B实际I/O完成后返回；远端82599的TX完成表示Host B
`AF_PACKET sendto()`接受帧。两者的虚拟BAR访问都不能解释成Host B真实外设BAR
访问延迟。
