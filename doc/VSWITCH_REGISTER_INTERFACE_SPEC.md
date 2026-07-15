# vSwitch 寄存器与软件接口规范

## 1. 文档约定

本文档定义 `scope-fpga-vswitch-nvme` 与 `virtual_pcie_switch_proxy` 之间的运行时接口合同。内容以移除 SQE write-done monitor 后的仓库 14 实现为准。

术语约定：

- **Producer**：负责生成或写入字段的一方。
- **Consumer**：读取字段并据此执行动作的一方。
- **RW**：可读写。
- **RO**：只读；软件写入被忽略。
- **W1C**：对应位写 `1` 清除，写 `0` 不改变。
- **commit-on-toggle**：数据寄存器预写，toggle 变化时整体提交。
- 所有寄存器和 packet dword 均采用 little-endian。
- 除特别说明外，寄存器访问宽度为 32 bit。
- 保留位写入被忽略，读取为 `0`。

每个接口合同均使用相同字段。连续且必须作为一个事务使用的寄存器可以共享一张合同表，但其成员寄存器仍逐项列出。

## 2. 地址视图

XDMA user BAR 在 FPGA AXI 地址视图中带有 `0x10000000` 基址，而 QEMU 对 `/dev/xdma0_user` 使用 BAR 内文件偏移。软件不得混用这两种地址。

| Block | FPGA AXI address | `/dev/xdma0_user` offset | Size | Owner |
| --- | ---: | ---: | ---: | --- |
| vSwitch mailbox | `0x11000000` | `0x01000000` | `0x1000` | FPGA registers |
| Retired SQE monitor hole | `0x11001000` | `0x01001000` | `0x1000` | Reserved, unmapped |
| Compact ECAM shadow | `0x11010000` | `0x01010000` | `0x20000` | Dual-port BRAM |
| Guest PCI MMIO window | `0x50000000` | N/A | `0x01000000` | FPGA vSwitch MMIO slave |
| Guest ECAM window | `0x60000000` | N/A | `0x01000000` | FPGA vSwitch ECAM slave |

`0x11001000/0x01001000` 不映射到任何从设备。软件不得探测、读取或写入该区域。

## 3. Mailbox Register Map

Mailbox local offset 以 `0x11000000` 或 `/dev/xdma0_user + 0x01000000` 为基址。

| Local offset | Register | Access | Reset | Producer | Consumer |
| ---: | --- | --- | ---: | --- | --- |
| `0x010` | `MBX_ACK` | RW | `0` | QEMU | FPGA ECAM write FSM |
| `0x020-0x02f` | Reserved | RO/ignored | `0` | None | None |
| `0x030` | `PROXY_CTRL` | RW | `0` | QEMU | FPGA ECAM/MMIO FSM |
| `0x034` | `BAR_RESP_DATA_LO` | RW | `0` | QEMU | FPGA MMIO response FSM |
| `0x038` | `BAR_RESP_SEQ` | RW | `0` | QEMU | FPGA MMIO response FSM |
| `0x03c` | `BAR_RESP_CTRL` | RW, commit-on-toggle | `0` | QEMU | FPGA MMIO response FSM |
| `0x04c` | `BAR_RESP_DATA_HI` | RW | `0` | QEMU | FPGA MMIO response FSM |
| `0x050` | `RP_INTX_CTRL` | RW | `0` | QEMU | FPGA interrupt output |
| `0x054` | `RP_INTX_STATUS` | RO | `0` | FPGA | QEMU/debug software |
| `0x058` | `RP_INTX_COUNT` | RO | `0` | FPGA | QEMU/debug software |
| `0x060` | `ROUTE_ERROR_STATUS` | RO/W1C | `0` | FPGA | QEMU/debug software |
| `0x064` | `ROUTE_ERROR_COUNT` | RO | `0` | FPGA | QEMU/debug software |
| `0x068` | `ROUTE_ERROR_ADDR_LO` | RO | `0` | FPGA | QEMU/debug software |
| `0x06c` | `ROUTE_ERROR_ADDR_HI` | RO | `0` | FPGA | QEMU/debug software |
| `0x100-0x29f` | BAR route table | Mixed | `0` | QEMU | FPGA route matcher |

### 3.1 `MBX_ACK` (`0x010`)

| Contract field | Value |
| --- | --- |
| Register | `MBX_ACK` |
| AXI address | `0x11000010` |
| XDMA offset | `0x01000010` |
| Local offset | `0x010` |
| Access | RW |
| Reset | `0x00000000` |
| Producer | QEMU config manager |
| Consumer | FPGA ECAM write FSM |
| Fields | `[31:0] CFG_SEQ_ACK` |
| Ordering | QEMU最后写入；必须晚于ECAM shadow、BAR route及其readback fence |
| Invalid behavior | 非当前等待sequence的值会被保存，但不会完成ECAM write |

| Bits | Name | Meaning |
| --- | --- | --- |
| `[31:0]` | `CFG_SEQ_ACK` | 已由 QEMU 完成处理的 `CFG_WRITE` sequence |

QEMU 在更新 ECAM shadow、同步相关 BAR route 并完成 readback fence 后写入 packet sequence。FPGA 仅在 `CFG_SEQ_ACK == ecam_write_seq` 时向 guest 返回 ECAM write 的 AXI B response。

不支持累积 ACK 或 bitmap；任意时刻 FPGA 只允许一条 ECAM write 等待 ACK。

### 3.2 Reserved (`0x020-0x02f`)

| Contract field | Value |
| --- | --- |
| Register | Reserved single-BAR shadow range |
| AXI address | `0x11000020-0x1100002f` |
| XDMA offset | `0x01000020-0x0100002f` |
| Local offset | `0x020-0x02f` |
| Access | RO/ignored |
| Reset | `0x00000000` |
| Producer | None |
| Consumer | None |
| Fields | All bits reserved |
| Ordering | None |
| Invalid behavior | Write ignored; read returns zero |

该范围曾用于单设备 BAR shadow，当前 vSwitch 使用 `0x100` 起始的 route table。读取返回 `0`，写入无副作用。

### 3.3 `PROXY_CTRL` (`0x030`)

| Contract field | Value |
| --- | --- |
| Register | `PROXY_CTRL` |
| AXI address | `0x11000030` |
| XDMA offset | `0x01000030` |
| Local offset | `0x030` |
| Access | RW |
| Reset | `0x00000000` |
| Producer | QEMU initialization/config manager |
| Consumer | FPGA ECAM and MMIO FSMs |
| Fields | bit0 `BAR_ROUTE_READY`; bit1 `ECAM_SHADOW_READY` |
| Ordering | 对应数据结构完成写入及readback后，最后设置各自ready bit |
| Invalid behavior | bits `[31:2]` are masked to zero |

| Bits | Name | Meaning | Producer | Consumer |
| --- | --- | --- | --- | --- |
| `[0]` | `BAR_ROUTE_READY` | 13 项 route table 已完成初始化，允许 MMIO route match | QEMU | FPGA MMIO FSM |
| `[1]` | `ECAM_SHADOW_READY` | Compact ECAM shadow 已完成初始化和 fence，允许 ECAM BRAM read | QEMU | FPGA ECAM FSM |
| `[31:2]` | Reserved | 写入忽略，读取为 `0` | N/A | N/A |

两个 ready 位相互独立。`ECAM_SHADOW_READY=1` 不表示 BAR route 可用；`BAR_ROUTE_READY=1` 也不表示 ECAM shadow 已初始化。

### 3.4 BAR Response Registers (`0x034-0x04c`)

| Contract field | Value |
| --- | --- |
| Register | `BAR_RESP_DATA_LO`, `BAR_RESP_SEQ`, `BAR_RESP_CTRL`, `BAR_RESP_DATA_HI` |
| AXI address | `0x11000034`, `0x11000038`, `0x1100003c`, `0x1100004c` |
| XDMA offset | `0x01000034`, `0x01000038`, `0x0100003c`, `0x0100004c` |
| Local offset | `0x034`, `0x038`, `0x03c`, `0x04c` |
| Access | RW; `BAR_RESP_CTRL` is commit-on-toggle |
| Reset | All zero |
| Producer | QEMU selected NVMe backend |
| Consumer | FPGA MMIO response FSM |
| Fields | 64-bit read data, sequence, AXI response, commit toggle, DONE request |
| Ordering | DATA_LO, DATA_HI, SEQ, then CTRL toggle |
| Invalid behavior | Reserved CTRL bits are masked; unmatched sequence remains pending and cannot complete the guest request |

`BAR_RESP_DATA_LO` 与 `BAR_RESP_DATA_HI` 保存 BAR read 的 64-bit data lane。BAR write response 不消费 data 字段。

`BAR_RESP_SEQ` 必须等于 FPGA 当前等待的 `mmio_active_seq`。sequence 不匹配时，FPGA保留 response pending，不完成当前 AXI transaction。

`BAR_RESP_CTRL`：

| Bits | Name | Meaning |
| --- | --- | --- |
| `[1:0]` | `AXI_RESP` | 返回给 guest 的 AXI `RRESP/BRESP`，正常为 `2'b00`，错误为 `2'b10` |
| `[2]` | `COMMIT_TOGGLE` | 与 FPGA 上次消费值不同时提交一条新 response |
| `[3]` | `REQUEST_BAR_WRITE_DONE` | guest write B handshake 后生成 `BAR_WRITE_DONE` packet |
| `[31:4]` | Reserved | 写入忽略，读取为 `0` |

QEMU 必须按以下顺序写入：

1. BAR read 时写 `BAR_RESP_DATA_LO`。
2. BAR read 时写 `BAR_RESP_DATA_HI`。
3. 写 `BAR_RESP_SEQ`。
4. 最后写 `BAR_RESP_CTRL`，并翻转 `COMMIT_TOGGLE`。

第 4 步是整条 response 的提交点。QEMU 不得在更新 data 或 sequence 之前翻转 toggle。

`REQUEST_BAR_WRITE_DONE` 只用于需要等待 guest B handshake 的 early-response write，当前对应 Admin SQ doorbell。它不表示 SQE memory 已经可见。

### 3.5 INTx Registers (`0x050-0x058`)

| Contract field | Value |
| --- | --- |
| Register | `RP_INTX_CTRL`, `RP_INTX_STATUS`, `RP_INTX_COUNT` |
| AXI address | `0x11000050`, `0x11000054`, `0x11000058` |
| XDMA offset | `0x01000050`, `0x01000054`, `0x01000058` |
| Local offset | `0x050`, `0x054`, `0x058` |
| Access | CTRL RW; STATUS/COUNT RO |
| Reset | All zero |
| Producer | QEMU produces CTRL; FPGA produces STATUS/COUNT |
| Consumer | FPGA interrupt output consumes CTRL; QEMU/debug software consumes STATUS/COUNT |
| Fields | Aggregate level, sampled/output level, rising-edge count |
| Ordering | QEMU first recomputes all backend pending states, then writes one aggregate level |
| Invalid behavior | CTRL bits `[31:1]` ignored; writes to STATUS/COUNT ignored |

#### `RP_INTX_CTRL`

| Bits | Name | Meaning |
| --- | --- | --- |
| `[0]` | `LEVEL` | `1` 拉高 `interrupt_out`，`0` 拉低 |
| `[31:1]` | Reserved | 写入忽略，读取为 `0` |

QEMU 是唯一 producer。QEMU 写 aggregate pending level，而不是某个 backend 的局部中断状态。

#### `RP_INTX_STATUS`

| Bits | Name | Meaning |
| --- | --- | --- |
| `[0]` | `REQUESTED_LEVEL` | FPGA保存的INTx level |
| `[1]` | `OUTPUT_LEVEL` | 当前`interrupt_out` level |
| `[31:2]` | Reserved | `0` |

当前实现中两位由同一 `intx_level` 驱动，因此读值总是相同。

#### `RP_INTX_COUNT`

每次 `RP_INTX_CTRL.LEVEL` 从 `0` 变为 `1` 时加一。保持高电平或高到低变化不计数。计数器为32 bit，自然回绕，软件不得把回绕解释为硬件复位。

### 3.6 Route Error Registers (`0x060-0x06c`)

| Contract field | Value |
| --- | --- |
| Register | `ROUTE_ERROR_STATUS`, `ROUTE_ERROR_COUNT`, `ROUTE_ERROR_ADDR_LO/HI` |
| AXI address | `0x11000060`, `0x11000064`, `0x11000068`, `0x1100006c` |
| XDMA offset | `0x01000060`, `0x01000064`, `0x01000068`, `0x0100006c` |
| Local offset | `0x060`, `0x064`, `0x068`, `0x06c` |
| Access | STATUS bit0 W1C; remaining fields RO |
| Reset | All zero |
| Producer | FPGA route matcher |
| Consumer | Host debug/control software; QEMU may sample for diagnostics |
| Fields | Sticky collision, saturated last hit count, event count, last address |
| Ordering | Stable sample uses COUNT, STATUS/ADDR, COUNT; clear only after sample |
| Invalid behavior | Only byte0 bit0 clears sticky; other writes are ignored |

#### `ROUTE_ERROR_STATUS`

| Bits | Name | Meaning |
| --- | --- | --- |
| `[0]` | `STICKY` | 曾发生多route同时命中；byte0写`1`清除 |
| `[2:1]` | `LAST_HIT_COUNT` | 最近冲突的命中数，最大饱和为3 |
| `[31:3]` | Reserved | `0` |

清除 `STICKY` 不会清除 count、last hit count或last address。

#### `ROUTE_ERROR_COUNT`

每次 MMIO read或write同时命中两个及以上有效route时加一，32 bit自然回绕。MMIO无命中不计入route error。

#### `ROUTE_ERROR_ADDR_LO/HI`

保存最近一次多route命中的64-bit guest MMIO地址。读取时软件应先读LO再读HI，并结合`ROUTE_ERROR_COUNT`判断采样期间是否发生更新。

## 4. BAR Route Table

| Contract field | Value |
| --- | --- |
| Register | `BAR_ROUTE[0..12]` |
| AXI address | `0x11000100 + backend_id * 0x20` |
| XDMA offset | `0x01000100 + backend_id * 0x20` |
| Local offset | `0x100 + backend_id * 0x20` |
| Access | Defined fields RW; holes RO/ignored |
| Reset | All zero |
| Producer | QEMU config/route manager |
| Consumer | FPGA MMIO route matcher |
| Fields | BAR base, size, BDF, valid/MEM/64-bit/backend control |
| Ordering | Clear CTRL, update payload fields, write final CTRL; global ready is last |
| Invalid behavior | Invalid backend ID cannot match; zero/overflowing range cannot match; route collision returns SLVERR |

共有13项route entry：

```text
entry_base(i) = 0x100 + i * 0x20
i = backend_id = 0..12
```

| Entry offset | Register | Access | Reset | Meaning |
| ---: | --- | --- | ---: | --- |
| `+0x00` | `BAR_LO` | RW | `0` | 64-bit BAR base `[31:0]` |
| `+0x04` | `BAR_HI` | RW | `0` | 64-bit BAR base `[63:32]` |
| `+0x08` | `BAR_SIZE` | RW | `0` | 匹配窗口字节数 |
| `+0x0c` | `BDF` | RW | `0` | `[15:0]` virtual BDF；`[31:16]` 保留 |
| `+0x10` | `CTRL` | RW | `0` | route有效性与backend metadata |
| `+0x14-0x1f` | Reserved | RO/ignored | `0` | 无功能 |

`CTRL`字段：

| Bits | Name | Meaning |
| --- | --- | --- |
| `[0]` | `VALID` | entry可参与匹配 |
| `[1]` | `MEM_ENABLE` | endpoint PCI Command Memory Space Enable已置位 |
| `[2]` | `IS_64BIT` | BAR为64-bit memory BAR；作为配置metadata保存 |
| `[7:3]` | Reserved | `0` |
| `[11:8]` | `BACKEND_ID` | 必须等于entry索引`i` |
| `[31:12]` | Reserved | `0` |

FPGA仅在以下条件全部满足时认为entry命中：

- `PROXY_CTRL.BAR_ROUTE_READY=1`；
- `VALID=1`且`MEM_ENABLE=1`；
- `BACKEND_ID == entry index`；
- `BAR_SIZE != 0`；
- `BAR_BASE + BAR_SIZE`没有64-bit回绕；
- guest地址位于半开区间`[BAR_BASE, BAR_BASE + BAR_SIZE)`。

QEMU更新entry时必须执行：

1. 写`CTRL=0`使entry失效。
2. 写`BAR_LO`、`BAR_HI`、`BAR_SIZE`和`BDF`。
3. 最后写带`VALID`的`CTRL`。
4. 初始化阶段完成全表后才设置`PROXY_CTRL.BAR_ROUTE_READY`。

MMIO唯一命中时，FPGA使用该entry的BDF生成BAR packet。无命中时read返回全1且`OKAY`，write为no-op且`OKAY`。多重命中返回`SLVERR`并更新route error寄存器。

## 5. Compact ECAM Shadow Contract

| Contract field | Value |
| --- | --- |
| Register | `ECAM_SHADOW[0x00000..0x1ffff]` memory aperture |
| AXI address | `0x11010000-0x1102ffff` on host port; guest reads through `0x60000000-0x60ffffff` |
| XDMA offset | `0x01010000-0x0102ffff` |
| Local offset | `0x00000-0x1ffff` within shadow BRAM |
| Access | QEMU port RW; FPGA ECAM port read-only for normal reads |
| Reset | Undefined BRAM contents; hidden until ready |
| Producer | QEMU config manager |
| Consumer | FPGA ECAM read FSM |
| Fields | 28 compact 4KB PCI configuration slots |
| Ordering | Initialize all slots, fence, then set `ECAM_SHADOW_READY`; config write updates shadow before ACK |
| Invalid behavior | Inactive slots are all `0xff`; unsupported BDF reads all ones and writes are no-op |

ECAM shadow是内存窗口，不是寄存器组。QEMU通过BRAM Port B写入，FPGA通过Port A只读。

### 5.1 Slot Layout

每个slot为4KB：

| Slot | BDF | Purpose |
| ---: | --- | --- |
| `0` | `00:00.0` | Root Port config |
| `1` | `01:00.0` | Switch Upstream Port config |
| `2 + 2*i` | `02:(i+1).0` | Downstream Port `i` config |
| `3 + 2*i` | `(03+i):00.0` | NVMe endpoint `i` config |

其中`i=0..12`，共28个slot，占用`0x00000-0x1bfff`。`0x1c000-0x1ffff`为aperture尾部保留区，软件不得使用。

未启用的downstream/endpoint slot由QEMU填充为`0xff`。未定义BDF或`ECAM_SHADOW_READY=0`时，FPGA向guest返回`0xffffffff + AXI OKAY`。

### 5.2 Initialization Ordering

QEMU必须：

1. 清除本地`ECAM_SHADOW_READY`状态。
2. 初始化全部28个slot，包括inactive全1 slot。
3. 写入BRAM shadow。
4. 读取最后一个有效dword作为write fence。
5. 设置`PROXY_CTRL.ECAM_SHADOW_READY`。

### 5.3 Config Write Transaction

1. FPGA缓存guest ECAM AW/W并生成`CFG_WRITE` packet。
2. QEMU根据BDF选择config slot，并按`wmask/w1cmask`更新配置。
3. endpoint写入同时更新对应BAR route。
4. QEMU将修改写回BRAM并执行readback fence。
5. QEMU写`MBX_ACK=packet.seq`。
6. FPGA返回guest AXI B `OKAY`。

不支持的BDF write由FPGA直接返回`OKAY` no-op，不产生packet。

## 6. DMA32 Packet ABI

| Contract field | Value |
| --- | --- |
| Register | DMA32 packet stream/ring ABI |
| AXI address | N/A; AXI-Stream C2H source |
| XDMA offset | Driver-allocated cyclic DMA32 ring, not a fixed BAR offset |
| Local offset | 32-byte physical ring slot |
| Access | FPGA producer; QEMU consumer |
| Reset | Ring allocation initializes host memory; packet sequence zero is invalid |
| Producer | FPGA ECAM/MMIO FSMs |
| Consumer | QEMU vSwitch RX manager |
| Fields | magic, type, flags, len, seq, offset, two payload dwords |
| Ordering | FPGA publishes a complete slot through C2H; QEMU accepts a new stable `type + seq` for that physical slot |
| Invalid behavior | Bad magic/length/type/sequence is ignored and not dispatched |

vSwitch packet固定为32字节，由FPGA产生、QEMU manager消费：

| Byte offset | Field | Width | Meaning |
| ---: | --- | ---: | --- |
| `0x00` | `magic` | 32 | 固定`0x5844504b` |
| `0x04` | `type` | 32 | Packet type |
| `0x08` | `flags` | 32 | BDF/BAR/size/WSTRB |
| `0x0c` | `len` | 32 | 固定`32` |
| `0x10` | `seq` | 32 | FPGA全局递增sequence，`0`无效 |
| `0x14` | `bar_offset` | 32 | Config offset或BAR offset |
| `0x18` | `data` | 32 | Payload low dword |
| `0x1c` | `guest_addr_lo` | 32 | BAR 64-bit lane high dword；CFG时为0 |

### 6.1 Packet Types

| Value | Name | Producer | Consumer | Response |
| ---: | --- | --- | --- | --- |
| `1` | `CFG_WRITE` | FPGA ECAM FSM | QEMU config manager | `MBX_ACK` |
| `2` | `BAR_WRITE` | FPGA MMIO FSM | QEMU selected backend | BAR response mailbox |
| `3` | `BAR_READ` | FPGA MMIO FSM | QEMU selected backend | BAR response mailbox |
| `4` | `BAR_WRITE_DONE` | FPGA MMIO FSM | QEMU pending doorbell state | None |

共享旧proxy ABI中的type 5仅用于旧`scope-fpga-proxy`兼容路径。vSwitch producer和consumer均不生成、接收或分发type 5。

### 6.2 `flags`

| Bits | Name | Meaning |
| --- | --- | --- |
| `[15:0]` | `BDF` | `{bus[7:0], device[4:0], function[2:0]}` |
| `[18:16]` | `BAR` | BAR index；CFG packet固定为7 |
| `[19]` | Reserved | `0` |
| `[23:20]` | `SIZE` | 访问字节数：1、2、4或8 |
| `[31:24]` | `WSTRB` | BAR write byte strobe；read为0；CFG使用低4位 |

`BAR_WRITE_DONE`复用原BAR write的BDF、size、WSTRB、sequence和offset，使QEMU能够与唯一pending doorbell精确匹配。

### 6.3 Ring Consumption

QEMU按物理slot保存最后消费的`type + seq`。只有magic、len、type和sequence均合法且与slot历史不同的packet才会被分发。vSwitch允许的最大type为4。

## 7. Ownership Matrix

| Interface | Producer/owner | Consumer | Commit condition |
| --- | --- | --- | --- |
| ECAM shadow | QEMU | FPGA ECAM reader | `ECAM_SHADOW_READY` |
| `CFG_WRITE` packet | FPGA | QEMU | DMA32 slot稳定可读 |
| `MBX_ACK` | QEMU | FPGA ECAM write FSM | Sequence相等 |
| BAR request packet | FPGA | QEMU backend | DMA32 slot稳定可读 |
| BAR response data/seq | QEMU | FPGA MMIO FSM | CTRL toggle变化 |
| BAR route table | QEMU | FPGA route matcher | Entry CTRL最后写入 |
| `RP_INTX_CTRL` | QEMU | FPGA interrupt output | 32-bit register write |
| INTx status/count | FPGA | QEMU/debug software | FPGA level transition |
| Route diagnostics | FPGA | QEMU/debug software | 多route命中 |

## 8. Software Transaction Recipes

### 8.1 Initialize vSwitch

1. 初始化并写入全部ECAM slot。
2. readback fence后设置`ECAM_SHADOW_READY`。
3. 对13项route写`CTRL=0`。
4. 为active backend按disable-first顺序写route entry。
5. 设置`BAR_ROUTE_READY`。
6. 写`RP_INTX_CTRL=0`。
7. 启动DMA32 ring consumer。

### 8.2 Handle `CFG_WRITE`

1. 校验magic、type、len和BDF。
2. 应用PCI config writable/W1C语义。
3. 将变化写入对应ECAM slot。
4. 如Command/BAR变化，按disable-first规则更新route。
5. 执行shadow readback fence。
6. 写`MBX_ACK=seq`。

### 8.3 Return BAR Response

1. 处理BDF对应backend。
2. read请求先写DATA_LO/HI；write请求跳过data。
3. 写`BAR_RESP_SEQ`。
4. 生成AXI response和可选DONE request。
5. 翻转commit toggle并最后写`BAR_RESP_CTRL`。

### 8.4 Update Shared INTx

1. 重新计算所有backend的CQ pending与mask。
2. 对pending结果做OR。
3. aggregate level变化或需要显式重写时写`RP_INTX_CTRL`。
4. 可读`RP_INTX_STATUS/COUNT`用于诊断，不以count代替level语义。

### 8.5 Read and Clear Route Error

1. 读`ROUTE_ERROR_COUNT`作为采样起点。
2. 读status和last address。
3. 再读count；若变化则重新采样。
4. byte0写`1`到`ROUTE_ERROR_STATUS`清sticky。

## 9. Compile-Time Interface Constants

下列值不是运行时寄存器：

| Constant | Value | Producer | Consumer |
| --- | ---: | --- | --- |
| Coherent alias base | `0x100000000` | QEMU property default/Tcl address map | QEMU DMA translation, FPGA alias bridge |
| `ADDR_SUBTRACT` | `0x100000000` | RTL parameter | `axi_alias_attr_bridge` |
| `CACHE_VALUE` | `0xf` | RTL parameter | Alias bridge `AWCACHE/ARCACHE` output |
| Guest ECAM base | `0x60000000` | DTS/Tcl | Linux ECAM driver, FPGA ECAM decoder |
| Guest PCI MMIO base | `0x50000000` | DTS/Tcl | Linux PCI resource allocator, FPGA route matcher |

这些常量发生变化时必须同步更新QEMU属性、Tcl地址段和DTS；软件运行时不能通过mailbox修改。
