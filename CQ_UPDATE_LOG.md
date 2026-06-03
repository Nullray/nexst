# CQ Update Log

This document records the recent Admin CQ/CQE related changes in
`nexst_proxy_9`.  The goal is to make the CQ path easier to reason about
while debugging the XiangShan NVMe proxy flow.

## 2026-06-01: Stop Clearing Guest Admin CQ From QEMU

### Background

The current proxy flow translates the guest NVMe Admin queue registers and
forwards them to the real NVMe controller:

- Guest writes `AQA`, `ASQ`, and `ACQ` through the proxied BAR.
- QEMU records the guest queue addresses and translates them to the FPGA
  bypass BAR address used by the real NVMe controller.
- The real NVMe controller DMA writes CQEs into FPGA DDR.
- XiangShan Linux reads CQEs from its own Admin CQ buffer in FPGA DDR.

During debugging, ILA showed writes to `0x845c9000`, the Admin CQ base:

- several zero writes,
- then a non-zero CQE-looking write,
- then another zero write.

This can make the guest NVMe driver see an all-zero CQE even though QEMU has
observed a real completion.

### Design Decision

QEMU must not clear the guest Admin CQ when the guest writes `ACQ`.

`ACQ` is only a controller register that tells the device where the Admin CQ
lives.  The CQ memory belongs to the guest driver.  The guest driver is
responsible for initializing that memory before enabling the queue.  QEMU
clearing the CQ through `/dev/xdma0_bypass` can race with real NVMe DMA writes
and can overwrite a valid CQE with zeros.

Correct behavior:

- QEMU may update its internal queue shadow state when `AQA`, `ASQ`, `ACQ`, or
  `CC.EN` changes.
- QEMU may translate `ASQ` and `ACQ` and write the translated values to the
  real NVMe BAR registers.
- QEMU must not mutate guest CQ memory as part of normal `ACQ` handling.
- Real NVMe DMA is the producer of CQEs.
- XiangShan Linux is the consumer of CQEs.

### Code Changes

File:

- `qemu-mount/hw/misc/scope_fpga_proxy.c`

Changes:

- Removed the Admin CQ zeroing helper from the QEMU proxy path.
- Removed the call that cleared guest Admin CQ memory from
  `scope_refresh_admin_queue_state()`.
- Left a code comment explaining why `ACQ/AQA/ASQ` refresh must not clear CQ
  memory.
- Kept QEMU internal CQ shadow state reset, because that only affects QEMU's
  bookkeeping and does not write guest memory.

Expected log change:

- The log should no longer contain `[SCOPE PROXY][CQ][ZERO]`.

### CQE Debug Logging

QEMU now includes raw CQE logging when it observes a completion in the guest
CQ shadow scan.

Expected log shape:

```text
[SCOPE PROXY][CQ][SEEN] qid=0 tail=0 phase=1 guest_pa=0x00000000845c9000 ...
[SCOPE PROXY][CQ][SEEN][DW] qid=0 tail=0 guest_pa=0x00000000845c9000 dw00=... dw01=... dw02=... dw03=...
[SCOPE PROXY][CQ][SEEN][HEX] qid=0 tail=0 guest_pa=0x00000000845c9000 bytes: ...
```

This helps distinguish two cases:

- QEMU sees a valid CQE but Linux reads zeros.
- QEMU itself reads zeros or stale data.

### Validation Plan

After rebuilding QEMU:

1. Confirm QEMU logs no longer show `[CQ][ZERO]`.
2. Use ILA `SLOT_0` to watch writes to the Admin CQ base, for example
   `0x845c9000`.
3. Check whether any zero write still occurs after the real CQE write.
4. If a post-CQE zero write still exists, it is no longer from QEMU's removed
   CQ clear path and should be traced to another writer.
5. Compare QEMU `[CQ][SEEN][DW]` with the guest Linux CQE debug dump.

### Remaining Questions

- If QEMU sees a valid CQE but Linux repeatedly reads an all-zero CQE, the next
  checks are the guest read path, interrupt timing, and DDR/cache visibility.
- If ILA still sees a zero write after the valid CQE, identify the writer on
  `SLOT_0` or any other path that can reach `0x845c9000`.
- If Linux receives an interrupt before the CQE is visible on its read path,
  the interrupt assertion may need to be delayed until CQE visibility is proven.


## 2026-06-01: Reject Stale Admin CQEs Before Any Outstanding Command

### Background

After removing QEMU-side Admin CQ zeroing, QEMU could still see old data in the
Admin CQ buffer.  Some stale CQ entries can have `status.phase == 1`, so the old
CQ scanner treated them as valid completions immediately after `CC.EN`, before
any Admin SQ doorbell had been processed.

An example stale entry looked like this:

```text
[SCOPE PROXY][CQ][SEEN] ... sq_head=2049 sq_id=0 cid=21012 status=0x0001
[SCOPE PROXY][CQ][SEEN][DW] ... dw02=00000801 dw03=00015214
```

The phase bit matched, but `sq_head=2049` is impossible for a depth-32 Admin SQ,
and the CID did not correspond to a command QEMU had forwarded in this boot.

### Code Changes

File:

- `qemu-mount/hw/misc/scope_fpga_proxy.c`

Changes:

- Added `admin_cid_outstanding[]` tracking in `ScopeProxyState`.
- QEMU marks an Admin CID outstanding only after it has read, patched, written
  back, and accepted an Admin SQE for forwarding.
- Admin CQ scan now rejects stale entries before advancing the CQ shadow tail.
- Rejection checks include:
  - `sq_id == 0` for Admin CQ,
  - `sq_head < admin_sq_depth` when the Admin SQ is valid,
  - `cid` must be outstanding.
- Accepted Admin CQEs clear the corresponding outstanding CID.

Expected stale-data log shape:

```text
[SCOPE PROXY][CQ][STALE] qid=0 tail=0 cid=... sq_head=... no_outstanding_cmd status=...
```

Expected valid flow:

```text
[SCOPE PROXY][CMD][ADMIN][TRACK] qid=0 slot=0 cid=...
[SCOPE PROXY][CQ][SEEN] qid=0 tail=0 ... cid=... status=...
```

### Why This Is Needed

Phase-bit matching alone is not enough when QEMU does not own CQ memory
initialization.  CQ memory can contain old values until the real NVMe controller
writes a fresh CQE.  QEMU should not advance CQ shadow state or assert INTx for
entries that cannot belong to a command it has actually forwarded.

## Related Files

- `qemu-mount/hw/misc/scope_fpga_proxy.c`
- `work_farm/software/linux/drivers/nvme/host/pci.c`
- `shell/nm37_vu37p/fpga/scripts/xiangshan.tcl`
- `shell/nm37_vu37p/fpga/sources/hdl/recorder/.v`
sqe_write_done_monitor