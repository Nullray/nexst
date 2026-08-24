# Vortex GIDS Implementation Plan

## 1. Objective and acceptance boundary

Implement the mediated GPU-initiated storage architecture specified in
`VORTEX_GIDS_SCADA_ARCHITECTURE.md` while preserving all existing SCOPE paths.

The implementation is complete only when a Vortex kernel can:

1. produce READ and WRITE requests in an HBM logical SQ;
2. publish them without a per-request host or XiangShan call;
3. receive completions in an HBM logical CQ;
4. verify SSD READ data and SSD WRITE data;
5. keep payload entirely on the `NVMe <-> U280 P2P BAR <-> HBM` path.

The following does **not** satisfy the goal:

- calling `pread`, `pwrite`, `io_uring`, an ioctl or a runtime submit API once
  per GPU request;
- letting a CPU thread choose which LBA should be submitted next;
- copying payload through XiangShan DDR or host DRAM;
- relabeling the existing `vx_gds_arm_read()` flow as GIDS.

## 2. Delivery strategy

Implement in seven gates.  Each gate leaves existing GDS and local/remote
backends usable.  Do not expose a capability until all invariants for that gate
pass.

1. Define and test the logical queue ABI.
2. Add HBM queue allocation and batched Bridge transport.
3. Add a QEMU-exclusive NVMe controller and physical queue engine.
4. Connect logical submission/completion translation.
5. Add Vortex device-side READ and WRITE APIs.
6. Add end-to-end correctness and comparison tests.
7. Optimize notification/physical queue placement only after profiling.

## 3. ABI and shared definitions

### 3.1 New shared header

The implemented canonical QEMU-side headers are:

```text
qemu-mount/include/hw/misc/scope_vortex_gids_abi.h
qemu-mount/include/hw/misc/scope_vortex_gids_queue.h
```

Mirror it into Vortex through the existing synchronized-header workflow rather
than manually evolving two independent copies.  It defines:

- ABI magic and major/minor version;
- queue depth and alignment limits;
- `scope_gids_queue_header`;
- `scope_gids_sqe` and `scope_gids_cqe`;
- 32-bit producer/consumer counters and per-slot ready sequences;
- READ/WRITE opcodes and normalized completion flags;
- queue states: `RESET`, `READY`, `QUIESCING`, `FAILED`;
- feature bits for READ, WRITE, batched transport and direct P2P;
- compile-time `static_assert` checks for size and offset.

All structures are little-endian.  Producers must zero reserved fields.
Consumers reject unsupported major versions, invalid entry sizes and nonzero
reserved fields.

### 3.2 Bridge protocol

Modify both synchronized copies:

```text
qemu-mount/hw/misc/scope_vortex_bridge_proto.h
~/Vortex_16/tools/scope_vortex_bridge/scope_vortex_bridge_proto.h
```

Add protocol-v4 messages:

```text
GIDS_QUEUE_CREATE
GIDS_QUEUE_DESTROY
GIDS_FETCH_SQ
GIDS_COMMIT_SQ
GIDS_POST_CQ
GIDS_QUEUE_STATUS
GIDS_QUEUE_SET_STATE
```

`CREATE` returns queue handle, generation, HBM device addresses, queue depth and
P2P metadata. `FETCH_SQ` and `POST_CQ` carry bounded batches; `COMMIT_SQ`
advances consumption only after QEMU accepts entries. Every dataplane request
includes handle, generation and starting monotonic counter. `QUEUE_SET_STATE`
publishes `FAILED` plus a fatal status after timeout or transport failure.

Do not create a one-message-per-I/O request protocol.  The QEMU poll budget and
batch size are explicit counters exposed in logs/statistics.

## 4. U280/XRT Bridge

### 4.1 Files

Modify:

```text
~/Vortex_16/tools/scope_vortex_bridge/main.cpp
~/Vortex_16/tools/scope_vortex_bridge/scope_vortex_bridge_proto.h
~/Vortex_16/sw/runtime/xrt/vortex.cpp
```

### 4.2 Queue BO allocation

Extend the current GDS HBM0 allocator:

- allocate one P2P BO containing header, LSQ, LCQ and payload;
- page-align every region and expose each region's offset/size explicitly;
- align all regions to the platform cache line and NVMe page size;
- return only opaque handle, HBM device address, size and generation;
- keep P2P bus address private to Bridge/QEMU;
- fail if the BO is not HBM0, not P2P-capable or outside the configured BAR.

### 4.3 Batched dataplane

Bridge owns the CPU mapping/ownership synchronization of the queue BO.

For LSQ fetch:

1. synchronize the header/entry range for CPU visibility;
2. acquire-load `sq_producer`;
3. validate `producer - consumer <= depth`;
4. copy a bounded contiguous/wrapped batch of complete entries;
5. return the starting counter and entries to QEMU;
6. update `sq_consumer` only after QEMU explicitly accepts the batch.

For LCQ post:

1. verify free slots from `cq_producer - cq_consumer`;
2. write completion entries;
3. synchronize the entry range for device visibility;
4. release-store and synchronize `cq_producer` last.

Never copy payload.  Track queue metadata bytes separately from payload bytes.

### 4.4 Session lifecycle

On client disconnect, xclbin reload or U280 reset:

- stop queue polling;
- increment generation;
- mark queue failed when still accessible;
- refuse stale batch/post requests;
- keep BOs pinned until QEMU acknowledges physical request drain or timeout.

## 5. QEMU vSwitch manager

### 5.1 Files

Modify:

```text
qemu-mount/hw/misc/scope_fpga_vswitch.c
qemu-mount/hw/misc/scope_fpga_vswitch_vortex_backend.c
qemu-mount/hw/misc/scope_vortex_bridge_proto.h
qemu-mount/hw/misc/meson.build
```

Add:

```text
qemu-mount/hw/misc/scope_fpga_vswitch_gids.c
qemu-mount/include/hw/misc/scope_vortex_gids_abi.h
qemu-mount/include/hw/misc/scope_vortex_gids_queue.h
```

Keep queue translation out of the generic vSwitch packet loop.  The manager
owns only lifecycle, polling budget and association between one Vortex backend
and one exclusive GIDS NVMe service.

### 5.2 Configuration

Extend the Vortex backend JSON with an explicit object or equivalent strict
fields:

```json
{
  "type": "vortex",
  "gids-mode": "mediated",
  "gids-nvme-bdf": "0000:e1:00.0",
  "gids-nsid": 1,
  "gids-slba-base": 1048576,
  "gids-block-count": 262144,
  "gids-control-base": "0xffe00000",
  "gids-control-size": "0x200000"
}
```

Exact JSON syntax should follow the existing parser style.  Required checks:

- physical BDF is not used by another local or remote backend;
- controller is unbound from the host NVMe driver;
- LBA allowlist is nonempty and within Identify Namespace capacity;
- control range is page aligned and is outside Linux-managed RAM;
- GIDS and current GDS cannot claim the same controller;
- absent GIDS fields preserve old behavior exactly.

Do not silently fall back to current GDS or CPU staging.

### 5.3 Manager state

Add `ScopeGidsService` containing:

- negotiated logical queue handle/depth/generation;
- physical controller state and generation;
- physical SQ/CQ addresses, depth, head/tail and CQ phase;
- logical-to-physical and physical-to-logical CID maps;
- inflight count and timeout deadlines;
- pending completion batch;
- counters for accepted/rejected requests, metadata bytes, payload bytes,
  batches, retries, stale CQEs and resets;
- fatal error and teardown state.

Poll with a fixed work budget so GIDS cannot starve NVMe, IXGBE, RDMA or Vortex
command processing.  Never sleep in the shared QEMU poll thread.

## 6. QEMU-exclusive NVMe physical queue engine

### 6.1 Files

Modify shared helpers in:

```text
qemu-mount/hw/misc/scope_fpga_vswitch_nvme_backend.c
qemu-mount/hw/misc/scope_fpga_vswitch.c
```

Implement service-specific logic in
`scope_fpga_vswitch_gids.c`.  Extract only helpers that are genuinely shared:

- BAR0 read/write and controller disable/reset;
- CAP/VS parsing and MPS selection;
- Identify Controller/Namespace parsing;
- PRP/SGL construction and range checks;
- NVMe status decoding.

Do not couple the GIDS engine to guest Linux queue state.

### 6.2 Controller initialization

The selected real controller is exclusive to QEMU:

1. verify PCI command and map BAR0;
2. disable controller and wait for `CSTS.RDY=0`;
3. create ASQ/ACQ in the reserved coherent control range;
4. enable controller and issue Identify;
5. negotiate queue count;
6. create one physical I/O CQ/SQ in the control range;
7. publish GIDS capability only after all readbacks succeed.

Queue memory must not be pageable host userspace memory with guessed physical
addresses.  It uses a reserved NM37 coherent-alias range whose PCIe DMA address
is known and whose CPU/QEMU access uses the existing coherent path.

### 6.3 Reserved control memory

Modify only if required by the final memory map:

```text
nanhu-g/software/dt/XSTop_vpcie.dts
doc/PROJECT_ARCHITECTURE.md
```

Reserve a small top-of-DDR region for GIDS ASQ/ACQ/physical SQ/CQ and PRP-list
pages.  Linux must not allocate it.  QEMU validates the configured range
against guest DDR and coherent-alias limits.  The exact address is selected
after checking the current DT memory and all existing reserved regions; the
example `0xffe00000` is not authoritative until then.

This region contains control metadata only.  Payload remains in HBM.

### 6.4 Submission translation

For each accepted LSQ entry:

1. validate ABI, queue generation and unique logical CID;
2. validate NSID and allowlisted LBA extent using namespace LBA shift;
3. resolve buffer handle/generation/offset through the Vortex registry;
4. validate READ/WRITE direction and P2P range without overflow;
5. allocate physical CID and save both-direction mapping;
6. construct NVM READ/WRITE SQE;
7. build PRP1/PRP2/list or SGL from the trusted P2P bus range;
8. write SQE and PRP list to the coherent control pool;
9. execute the required write/readback fence;
10. advance physical SQ tail and write the real doorbell;
11. acknowledge logical SQ consumption.

Validation failure creates a logical error CQE without touching the physical
controller.  Backpressure due to CID/queue exhaustion does not consume the LSQ
entry.

### 6.5 Completion translation

Poll physical CQ with phase semantics.  For each CQE:

- reject stale generation, unknown CID or impossible SQID;
- release physical CID and PRP-list allocation exactly once;
- normalize status and completed byte count;
- perform READ-side P2P ownership sync before publication;
- append logical CQE to a bounded Bridge batch;
- ring physical CQ head doorbell after entries are consumed;
- retain completions on Bridge backpressure without reusing logical CIDs.

For WRITE, completion is not published until the controller reports command
completion.  For READ, completion is not published until HBM visibility is
established.

### 6.6 Reset and errors

Implement one ordered reset path:

```text
stop LSQ intake
 -> mark queue QUIESCING
 -> drain or time out inflight commands
 -> publish terminal logical CQEs when safe
 -> disable/reset NVMe
 -> increment controller and queue generation
 -> clear CID maps/control allocator
 -> reinitialize or leave FAILED
```

Bridge disconnect, U280 reset, P2P mapping loss, NVMe `CFS`, timeout and PCI
remove all enter this path.  No error may redirect payload to CPU memory.

## 7. Vortex runtime and guest driver

### 7.1 Host runtime files

Modify:

```text
~/Vortex_16/sw/runtime/include/vortex2.h
~/Vortex_16/sw/runtime/common/callbacks.h
~/Vortex_16/sw/runtime/common/device.cpp
~/Vortex_16/sw/runtime/vswitch/vortex.cpp
```

The implemented host runtime exposes one setup-only API:

```text
vx_gids_query
```

It returns an opaque queue identity plus HBM addresses needed by the kernel. Queue
creation and teardown follow the QEMU/Bridge session lifetime. Do not
add host `vx_gids_read()` or `vx_gids_submit()` functions; those names belong
to the device-side library.

Keep existing `vx_gds_*` APIs unchanged and separately capability-gated.

### 7.2 XiangShan Linux driver

Modify:

```text
work_farm/software/linux/include/uapi/linux/scope_vortex.h
work_farm/software/linux/drivers/misc/scope_vortex.c
```

No new XiangShan ioctl is needed by the implemented direct-vSwitch runtime.
`vx_gids_query()` uses the existing vSwitch transport; the Linux driver must not
expose a per-request submit ioctl and does not poll GIDS completions on behalf
of the kernel.

Close/release triggers queue quiesce and invalidation.  Existing CP and GDS
ioctls retain their numbers and behavior.

### 7.3 Rootfs integration

Update the existing Vortex guest build manifests only after binaries exist:

```text
nanhu-g/software/rootfs/Makefile
nanhu-g/software/rootfs/scripts/gen-initramfs-list.sh
tools/build_vortex_guest_single_bank.sh
```

Do not run GIDS automatically during boot or `vortex-run-all`; it operates on
an explicitly reserved destructive-test LBA range.

## 8. Vortex device-side library

### 8.1 Files

Add:

```text
~/Vortex_16/sw/kernel/include/vx_gids.h
~/Vortex_16/sw/kernel/src/vx_gids.c
```

If the kernel library is header-only by local convention, keep the algorithms
in the header and add compile tests.  Provide:

```text
vx_gids_submit
vx_gids_read
vx_gids_write
vx_gids_poll
vx_gids_wait
```

### 8.2 Queue algorithm

Initial correctness mode follows the actual U280 build (`XLEN=32`,
`EXT_A_ENABLED=0`):

- one designated producer/consumer lane in one persistent GPU kernel;
- one logical queue, with no atomic slot reservation requirement;
- 32-bit monotonic producer/consumer counters using unsigned modulo
  arithmetic;
- per-slot ready sequence written last, so a partially visible descriptor is
  never accepted;
- release fence before ready sequence/producer publication;
- acquire fence after completion publication;
- queue-full and timeout return codes, never indefinite silent spinning;
- logical CID bitmap or generation-tagged freelist;
- one completion owner per CID.

Multiple warps may publish concurrently only after enabling and verifying the
Vortex A extension on the target bitstream.  Even then, a raw atomic tail
increment followed by descriptor stores is incorrect because a later producer
can expose an incomplete earlier slot; a ready-sequence or warp-batched commit
protocol remains mandatory.

### 8.3 Vortex RTL

No custom instruction or notification RTL is required, but cache visibility
does require one targeted LSU decode change. `VX_lsu_slice` classifies the
reserved `0x0f000000..0x0fffffff` GIDS arena as I/O memory, so LSQ/LCQ and
payload accesses bypass the Vortex data cache and remain visible to Bridge/XRT
without a host cache-flush call per request.

After the software queue is correct, an optional notification accelerator may
be added under:

```text
~/Vortex_16/hw/rtl/cp/VX_gids_notify.sv
~/Vortex_16/hw/rtl/cp/VX_cp_core.sv
```

It may observe a GPU-written notification word and notify the Bridge/host
command path, but it must not parse NVMe commands, own queue policy or carry
payload.  LCQ polling remains the correctness mechanism.  This optional RTL is
not a prerequisite for claiming GPU initiation; it is a latency/CPU-use
optimization.

## 9. Tests

### 9.1 ABI and host-only tests

The QEMU unit target `test-scope-vortex-gids` covers:

- structure size and field offsets;
- producer/consumer wrap near `UINT32_MAX`;
- full/empty/overrun detection;
- ring slot wrap and ready-sequence wrap;
- range overflow and aligned queue layout bounds;
- invalid ABI headers and reserved fields;
- SQE reserved-field contract.

Bridge tests additionally cover queue create/fetch/commit/post, stale
generation rejection, queue-state failure publication and disconnect cleanup.
Physical PRP-list construction, NVMe timeout propagation, HBM P2P visibility
and completion backpressure remain covered by source/build review and require hardware
gates below; they are not claimed as unit-tested by this helper-only test.

### 9.2 Vortex regression

Implemented regression:

```text
~/Vortex_16/tests/regression/gids_io/Makefile
~/Vortex_16/tests/regression/gids_io/common.h
~/Vortex_16/tests/regression/gids_io/main.cpp
~/Vortex_16/tests/regression/gids_io/kernel.cpp
```

The host program performs setup only, launches one persistent kernel and waits
for kernel completion. In `--mode read`, the kernel issues non-destructive
READs and verifies an expected FNV-1a checksum in HBM. In `--mode roundtrip`,
it generates data, submits WRITE, clears the HBM payload, submits READ, and
compares every returned word. Both modes record GPU cycles and QEMU physical
service timestamps per request in machine-readable CSV.

Instrumentation must prove:

- host submit-call count is zero while the kernel is running;
- LSQ requests equal physical NVMe submissions;
- LCQ completions equal successful/error requests exactly once;
- `payload_cpu_bytes=0` and `payload_nm37_bytes=0`;
- all physical PRPs/SGLs fall inside registered U280 P2P ranges.

### 9.3 Compatibility tests

Run unchanged regressions for:

- local-p2p NVMe and multi-NVMe;
- remote-rdma NVMe and IXGBE;
- local IGB/IXGBE;
- Vortex CP and direct-P2P tests;
- current `vortex-gds_read`;
- aggregate INTx and any later MSI/MSI-X path.

GIDS-disabled configuration must produce no queue polling or controller claim.

## 10. Scripts and runbook

Implemented:

```text
tools/prepare_vortex_gids_ssd.sh
doc/VORTEX_GIDS_RUNBOOK.md
tools/check-gids-abi.sh
tools/run_storage_path_comparison.sh
```

The preparation script identifies NVMe by BDF/serial, checks mounts, holders,
swap, LVM and partitions, and records an explicit test extent.  It never infers
safety merely from an absent mount.

The runbook must include:

- XRT/xocl and U280 P2P BAR setup;
- xclbin and HBM0 topology verification;
- dedicated NVMe unbind and reset procedure;
- FPGA/XiangShan/QEMU/Bridge startup ordering;
- GIDS JSON configuration;
- queue capability checks;
- READ/WRITE correctness commands;
- counters proving no CPU payload and no host per-request submit;
- recovery from Bridge, U280, NVMe and QEMU failures.

## 11. Comparison experiment preparation

The comparison harness accepts three explicit commands and exports identical
I/O size/count/run-index variables for three paths:

1. CPU memory bounce path;
2. current CPU-initiated GDS path;
3. Vortex GIDS path.

The first fair comparison is READ-only because the current CPU-initiated GDS
API supports READ but not WRITE. Use identical LBA extent, I/O size, request
count, direction and checksum validation; do not label GIDS roundtrip numbers
as a fair comparison against read-only GDS. Record bytes, IOPS, bandwidth,
P50/P95/P99 latency, CPU utilization, errors and checksum result. The separate
GIDS roundtrip test proves WRITE correctness and records GPU cycles. Report
metadata proxy CPU cost separately from payload movement.

## 12. Build and verification gates

### Gate A: static ABI

```bash
git diff --check
```

- both protocol copies are byte-identical;
- all structures have compile-time size/offset checks;
- the default XLEN32/non-AMO build uses the single-producer queue path and
  rejects any multi-producer feature request;
- no host per-request GIDS API exists;
- no raw P2P bus address appears in GPU-visible request fields.

### Gate B: software builds

- build RDMA-enabled QEMU and normal QEMU;
- build `scope-vortex-bridge` and `libvortex-xrt.so`;
- build Vortex kernel/runtime and `gids_io`;
- build XiangShan kernel/rootfs with updated UAPI.

### Gate C: emulated queue tests

Use a fake physical backend to inject completion order, errors, timeouts,
duplicate/stale CQEs and reset at every state.  Verify exact-once logical
completion and no CID reuse.

### Gate D: hardware READ

One queue, depth 16, 4 KiB READs; then increase size/depth.  Confirm data and
P2P counters before enabling WRITE.

### Gate E: hardware WRITE

Use only the reserved destructive-test extent.  Write GPU-generated patterns,
read back through GIDS and compare entirely in HBM; separately verify from the
host after teardown.

### Gate F: concurrency and recovery

Exercise queue wrap, maximum depth, mixed READ/WRITE, Bridge restart, U280
reset, NVMe reset and QEMU teardown.  No stale request may reach a new
generation.

## 13. Implementation self-review checklist

Before describing the result as GIDS/SCADA-like, answer from traces and source:

1. **Request origin:** Does the first request descriptor come from Vortex
   kernel code?
2. **Logical SQ owner:** Can requests proceed without a CPU application call?
3. **Logical CQ owner:** Does the GPU observe completion directly in HBM?
4. **Doorbell:** Is SCOPE only forwarding already committed GPU requests?
5. **CPU role:** Are QEMU/Bridge validating and batching rather than selecting
   the next application I/O?
6. **Payload:** Do PCIe traces and counters show only SSD/U280 HBM payload?
7. **READ/WRITE:** Are both directions correct under visibility fences?
8. **Isolation:** Can a malformed GPU request reach arbitrary host memory?
9. **Reset:** Can an old CQE complete a new generation request?
10. **Compatibility:** Do existing GDS, NVMe, network and Vortex paths still
    pass unchanged?

If any per-request `pread`, `pwrite`, guest ioctl or host runtime submit remains
in the GIDS test, the implementation has regressed to CPU-initiated GDS and the
gate fails.

## 14. Deliberately deferred optimizations

- direct GPU access to the physical NVMe doorbell;
- physical SQ/CQ in HBM;
- multiple physical queues and multi-controller striping;
- GPU software cache and application-specific aggregation like GIDS;
- file-system extent API;
- Vortex RTL notification accelerator;
- remote-rdma GIDS transport.

These may be added without changing the logical queue contract.  None may be
claimed as implemented by the first mediated version.
