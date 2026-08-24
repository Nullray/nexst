# Vortex GPU-Initiated Storage Architecture

## 1. Scope and conclusion

This document defines a GPU-initiated storage mode for the repository-16
SCOPE/Vortex platform.  The target is deliberately stronger than the existing
GDS-like path:

- a Vortex kernel decides which block I/O to issue;
- Vortex owns a logical submission queue (LSQ) and logical completion queue
  (LCQ) in U280 HBM;
- XiangShan and the host application do not submit each request;
- the NVMe payload moves directly between the SSD and U280 HBM;
- SCOPE remains a trusted semantic proxy for validation, physical queue
  management, reset and error isolation.

The selected first implementation is a **mediated GPU-initiated queue**.  It is
not a direct mapping of the physical NVMe BAR into Vortex and it does not share
a Linux-owned NVMe queue.  Vortex owns the request policy and logical queue;
SCOPE translates batches of logical requests onto a QEMU-owned physical NVMe
queue.  The host CPU executes the transport proxy, but it is not the per-I/O
request scheduler and never copies payload.

This is the smallest safe design that satisfies the project goal with the
current Vortex and SCOPE interfaces.  A later trusted mode may place physical
SQ/CQ in HBM and map a doorbell to the GPU, as BaM does, but that is not assumed
by this design.

## 2. Terminology and related work

### 2.1 GPUDirect Storage

NVIDIA defines GPUDirect Storage (GDS) as a direct DMA data path between
storage and GPU memory that avoids a CPU-memory bounce buffer.  NVIDIA also
states that CPU-executed drivers establish and manage this data movement as
the control path.  GDS therefore does not, by itself, imply that a GPU kernel
constructs NVMe commands or rings an NVMe doorbell.

Source: [NVIDIA GPUDirect Storage Design Guide](https://docs.nvidia.com/gpudirect-storage/design-guide/index.html).

### 2.2 BaM

BaM is a GPU self-orchestrated storage architecture.  Its GPU threads generate
requests through high-throughput queues and a GPU software cache.  The open
source implementation allows GPU threads to independently access NVMe data;
its trusted setup provisions storage resources before kernels run.

Sources:

- [BaM paper](https://arxiv.org/abs/2203.04910)
- [BaM source](https://github.com/ZaidQureshi/bam)

BaM is the closest architectural reference for a future direct physical-queue
SCOPE mode.  The repository-16 first implementation differs because SCOPE
retains a semantic translation boundary instead of exposing the real NVMe
queue and doorbell to arbitrary Vortex code.

### 2.3 GIDS

GIDS means **GPU Initiated Direct Storage Access** in the PVLDB work by Park et
al.  It is a GNN dataloader built on BaM.  GPU threads fetch feature vectors
from storage, while GIDS adds GNN-specific access accumulation, CPU-memory
placement and GPU caching/window-buffering policies.  GIDS is not a generic
name for every SSD-to-GPU DMA path.

Sources:

- [GIDS paper](https://www.vldb.org/pvldb/vol17/p1227-park.pdf)
- [GIDS source](https://github.com/jeongminpark417/GIDS)

This project borrows the GPU-initiated property, not the GNN-specific
dataloader or its claimed performance results.

### 2.4 GPUfs

GPUfs exposes a POSIX-like file API to GPU programs and extends the host CPU
buffer cache into GPU memory.  It coordinates with the host OS and is useful
as a programming-model reference, but it is not evidence of GPU-managed NVMe
SQ/CQ or a direct SSD-to-HBM payload path.

Source: [GPUfs, ASPLOS 2013](https://dedis.cs.yale.edu/2010/det/papers/asplos13-gpufs-abs/).

### 2.5 NVIDIA SCADA

NVIDIA publicly expands SCADA as **Scaled Accelerated Data Access** and
describes GPUs directly initiating and controlling fine-grained storage
operations.  NVIDIA's Nsight Systems documentation states that this removes
the CPU from both control and data paths and identifies a GPU-side client plus
a storage-managing server daemon.  Public material still does not define a
stable queue ABI, protection contract or NVMe submission interface that SCOPE
can implement verbatim.

Sources:

- [NVIDIA storage/SCADA overview](https://blogs.nvidia.com/blog/ai-storage-fms/)
- [NVIDIA Nsight Systems SCADA metrics documentation](https://docs.nvidia.com/nsight-systems/UserGuide/index.html#scada-metrics-profiling)
- [NVIDIA GTC 2026 SCADA session](https://www.nvidia.com/en-us/on-demand/session/gtc26-s81840/)

Accordingly, this document uses "SCADA-like" only for the broad GPU-initiated,
fine-grained access goal.  SCOPE v1 still executes trusted batched validation
and physical-queue translation on the host CPU, so it is not claimed to be an
implementation of NVIDIA SCADA.  The normative implementation name is
**SCOPE Vortex GIDS**.

## 3. Current repository-16 GDS implementation

The current implementation is documented in
`VORTEX_NVME_GDS_DESIGN.md` and implemented across:

- `qemu-mount/hw/misc/scope_fpga_vswitch.c`;
- `qemu-mount/hw/misc/scope_fpga_vswitch_vortex_backend.c`;
- `work_farm/software/linux/drivers/misc/scope_vortex.c`;
- `~/Vortex_16/tools/scope_vortex_bridge/main.cpp`;
- `~/Vortex_16/sw/runtime/common/device.cpp`;
- `~/Vortex_16/sw/runtime/vswitch/vortex.cpp`;
- `~/Vortex_16/tests/regression/gds_read/main.cpp`.

### 3.1 Current ownership

| Question | Current answer |
|---|---|
| Who decides to issue storage I/O? | XiangShan userspace test running on the CPU |
| Who creates/manages NVMe SQ/CQ? | Linux `nvme-pci`; QEMU observes and patches them |
| Who constructs the SQE? | Linux NVMe driver |
| Who writes the virtual doorbell? | Linux NVMe driver |
| Who writes the real doorbell? | QEMU after SQE/PRP validation and patching |
| Who consumes the NVMe CQE? | Linux NVMe driver; QEMU also observes it for GDS state |
| Who decides that the GPU kernel may start? | CPU runtime after `vx_gds_wait()` |
| Who decides kernel completion? | Existing Vortex host/runtime command path |
| Where does READ payload move? | Real NVMe directly to U280 P2P BAR and HBM0 |

The test proves this ownership directly: it calls `vx_gds_arm_read()`, opens
the block device and executes `pread(O_DIRECT)`.  QEMU matches that CPU-issued
READ by NSID, SLBA and length, rewrites its data PRP to the registered HBM P2P
address, then restores the guest SQE/PRP list after completion.

The current state machine is:

```text
IDLE -> GPU_OWNED -> ARMED -> NVME_INFLIGHT -> GPU_READY/FAILED
```

`GPU_OWNED` means ownership of an HBM data buffer, not ownership of an NVMe
queue.  The current implementation is valid GDS-like direct payload DMA, but
it is not GPU-initiated storage.

### 3.2 Current request sequence

The complete current sequence is:

```text
XiangShan CPU test calls vx_gds_query()/vx_gds_alloc()
  -> libvortex vswitch runtime uses /dev/scope-vortex0
  -> QEMU asks scope-vortex-bridge to allocate/query an XRT HBM0 P2P BO
  -> CPU test calls vx_gds_arm_read(NSID, SLBA, bytes, handle)
  -> CPU test executes pread(O_DIRECT) on /dev/nvmeXnY
  -> Linux nvme-pci allocates CID, constructs SQE/PRP and advances SQ tail
  -> QEMU recognizes the armed request and patches only data PRPs to U280 HBM
  -> QEMU writes the real NVMe doorbell
  -> NVMe writes payload directly to the U280 P2P BAR/HBM
  -> NVMe writes CQE; QEMU restores metadata and marks GPU_READY
  -> Linux consumes CQE and pread returns
  -> CPU test calls vx_gds_wait() and launches the Vortex checksum kernel
  -> existing Vortex CP/runtime reports kernel completion to the CPU
```

`scope-vortex-bridge` currently provides allocation/capability services and
the XRT backend owns the P2P BO.  It does not currently consume a GPU-produced
storage queue.  `libvortex-xrt.so` and the vswitch runtime are therefore setup
and execution transports in the current path, not storage request initiators.

## 4. Three storage modes

| Property | A. CPU-memory path | B. Current GDS path | C. Target Vortex GIDS |
|---|---|---|---|
| Request initiator | CPU application | CPU application | Vortex kernel |
| Request policy | CPU | CPU | GPU work-items |
| Queue owner | Linux NVMe driver | Linux NVMe driver | GPU owns LSQ/LCQ; SCOPE owns physical queue |
| SQE producer | Linux | Linux, then QEMU patches PRP | GPU produces logical command; SCOPE builds physical SQE |
| Physical doorbell owner | Linux/QEMU | Linux/QEMU | SCOPE semantic doorbell proxy |
| Completion consumer | CPU/Linux | CPU/Linux, then CPU launches GPU | SCOPE translates CQE; GPU consumes LCQ |
| Payload path | SSD -> CPU DRAM -> HBM | SSD -> U280 P2P BAR -> HBM | SSD <-> U280 P2P BAR <-> HBM |
| CPU payload copy | Yes | No | No |
| CPU action per request | Submit, complete and copy | Submit and complete | Validate/translate dataplane only; no scheduling or payload |

Mode C is GPU-initiated because the GPU publishes each request and consumes
its completion without a guest ioctl, `pread`, `pwrite`, signal or host callback
for that request.  SCOPE's per-request validation does not select the LBA,
buffer, direction or issue time; those are already committed by the GPU.

## 5. Design alternatives

### 5.1 Direct physical NVMe SQ/CQ and doorbell

This is closest to BaM: place physical SQ/CQ in HBM, let Vortex write SQEs and
poll CQEs, and map the real NVMe doorbell into GPU-visible MMIO.

It is not selected for the first implementation because:

- current Vortex kernel memory traffic targets HBM and has no trusted general
  path to the real NVMe BAR;
- exposing the doorbell does not stop a kernel from putting arbitrary host
  DMA addresses in PRP/SGL fields;
- sharing a Linux-owned queue would race queue head/tail, CID and reset state;
- controller reset and namespace ownership need a dedicated userspace driver;
- the current SCOPE backend must validate P2P ranges and generations.

It remains a possible optimized mode after queue isolation and hardware
protection are demonstrated.

### 5.2 GPU logical SQ/CQ with SCOPE physical translation

This is the selected mode.  Vortex writes compact logical requests to HBM.
The Bridge and QEMU consume them in batches, validate them, assign physical
CIDs, submit through a QEMU-exclusive physical queue, translate CQEs back to
logical completions and publish them to HBM.

Advantages:

- GPU is the request initiator and logical queue owner;
- no XiangShan or host application call is required per request;
- SCOPE preserves buffer bounds, generation and namespace isolation;
- current P2P BO, Bridge, QEMU NVMe and HBM mechanisms are reusable;
- physical queue implementation can change without changing the GPU API;
- READ and WRITE use the same control path and opposite P2P DMA directions.

The cost is host proxy work per descriptor.  It should be batched and measured
honestly; this mode must not be described as CPU-free or as direct physical
queue ownership.

## 6. Selected architecture

### 6.1 Components

```text
Vortex kernel
  -> HBM logical SQ (request descriptors)
  -> release fence + publish producer counter

scope-vortex-bridge
  -> observes HBM producer counter
  -> transfers a bounded batch of descriptors to QEMU

QEMU SCOPE GIDS service
  -> validates handle/generation/namespace/LBA/HBM range/opcode
  -> maps logical CID to physical CID
  -> builds physical NVMe SQE and PRP/SGL
  -> publishes physical SQ tail and writes real doorbell

real NVMe
  <-> U280 P2P BAR/HBM payload
  -> physical CQE

QEMU SCOPE GIDS service
  -> consumes physical CQE
  -> writes logical CQE batch through Bridge into HBM
  -> release fence + publish completion producer counter

Vortex kernel
  -> acquire-loads LCQ producer and per-slot ready sequence
  -> consumes completion and reuses logical CID
```

The Bridge and QEMU are a trusted dataplane proxy, not an application-level
scheduler.  They may reject, backpressure or fail requests, but must preserve
GPU submission order within a queue and may not invent requests.

### 6.2 Physical controller ownership

The GIDS physical queue must not be shared with XiangShan Linux.  The preferred
first deployment uses a dedicated real NVMe controller (or a controller mode
that is not simultaneously exposed as a normal virtual NVMe endpoint):

- QEMU exclusively disables/enables and initializes the controller;
- QEMU owns ASQ/ACQ and at least one physical I/O SQ/CQ;
- queue memory resides in a dedicated, registered control allocation;
- Vortex never sees admin commands or unrestricted physical DMA addresses.

If the same controller is needed for the current GDS mode, startup must select
one owner.  Simultaneous current-GDS and GIDS operation on one controller is
forbidden until a proven queue-reservation protocol exists.  Different
controllers may run the two modes concurrently.

### 6.3 Logical queue placement and transport

The LSQ, LCQ, indices and payload buffers reside in one registered HBM0 P2P
arena.  They are addressed by Vortex device addresses; only trusted Bridge and
QEMU code learn corresponding P2P bus addresses.

The initial transport reuses the Bridge connection:

- Bridge maps the queue BO and watches monotonic producer counters;
- it returns bounded batches rather than one RPC per request;
- QEMU returns completion batches;
- the guest CPU and host application are absent from this loop.

The current XRT implementation reserves one 16 MiB HBM0 P2P arena at
`0x0f000000..0x0fffffff`. Header, LSQ, LCQ and payload are page-aligned
regions in that one BO. Vortex marks the complete aperture as I/O memory in
`VX_lsu_slice`, bypassing L1 data cache. This is required so Bridge/QEMU
updates become visible to a resident kernel without a host-driven cache flush
for every I/O.

A later RTL notification queue may replace polling without changing the ABI.
The first implementation must record poll wakeups and batch size so CPU proxy
overhead remains measurable.

## 7. Logical queue ABI

All fields are little-endian.  Structures are versioned, naturally aligned and
have reserved fields that must be zero.  Queue depth is a power of two from 2
through 1024.  The current U280 Vortex build is XLEN=32 with the A extension
disabled, so the first ABI must not require 64-bit atomics.  Producer and
consumer values are monotonic 32-bit counters and each slot has a 32-bit ready
sequence; ring slot is `counter & (depth - 1)`.  Unsigned counter differences
are valid while the producer-consumer distance never exceeds the queue depth.

### 7.1 Queue header

```c
struct scope_gids_queue_header {
    uint32_t magic;
    uint16_t abi_major;
    uint16_t abi_minor;
    uint16_t header_size;
    uint16_t sqe_size;
    uint16_t cqe_size;
    uint16_t reserved0;
    uint32_t depth;
    uint32_t features;
    uint32_t state;
    uint32_t generation;
    uint32_t sq_producer;
    uint32_t sq_consumer;
    uint32_t cq_producer;
    uint32_t cq_consumer;
    uint32_t fatal_error;
    uint32_t reserved1;
    uint64_t session_cookie;
};
```

### 7.2 Logical submission entry

```c
struct scope_gids_sqe {
    uint32_t ready_sequence;
    uint32_t logical_cid;
    uint8_t  opcode;
    uint8_t  flags;
    uint16_t reserved0;
    uint32_t nsid;
    uint64_t slba;
    uint32_t block_count;
    uint32_t buffer_handle;
    uint64_t buffer_generation;
    uint64_t buffer_offset;
    uint32_t byte_count;
    uint32_t reserved1;
    uint64_t user_token;
};
```

The GPU supplies a handle and offset, never a PCIe bus address.  SCOPE derives
the PRP/SGL address from the registered P2P BO and validates `nlb`, LBA size,
overflow, alignment and direction.

### 7.3 Logical completion entry

```c
struct scope_gids_cqe {
    uint32_t ready_sequence;
    uint32_t logical_cid;
    uint16_t status;
    uint16_t flags;
    uint16_t nvme_status;
    uint16_t reserved0;
    uint32_t completed_bytes;
    uint32_t reserved1;
    uint64_t user_token;
    uint64_t submit_timestamp;
    uint64_t complete_timestamp;
    uint32_t generation;
    uint32_t reserved2;
    uint64_t reserved3;
};
```

The explicit alignment fields avoid host/device compiler padding differences;
the canonical header must assert every size and offset on both x86 and
Vortex/RISC-V builds. The LCQ uses the ready sequence followed by the producer
counter as its publication boundary. Correctness does not depend on a wrapped
16-bit index or a physical NVMe phase bit.

## 8. Vortex device-side API

The API is callable by Vortex kernel code, not just host runtime code:

```c
int vx_gids_submit(vx_gids_queue_t *q, const vx_gids_request_t *request);
int vx_gids_read(vx_gids_queue_t *q, uint32_t cid, uint32_t nsid,
                 uint64_t slba, uint32_t blocks, uint64_t buffer_offset,
                 uint32_t bytes, uint64_t token);
int vx_gids_write(vx_gids_queue_t *q, uint32_t cid, uint32_t nsid,
                  uint64_t slba, uint32_t blocks, uint64_t buffer_offset,
                  uint32_t bytes, uint64_t token);
int vx_gids_poll(vx_gids_queue_t *q, struct scope_gids_cqe *completion);
int vx_gids_wait(vx_gids_queue_t *q, uint32_t cid, uint32_t max_polls,
                 struct scope_gids_cqe *completion);
```

The current host runtime has one setup query and no per-request submit API:

```c
vx_gids_query(device, &queue_info);
```

No host API submits an individual GIDS request.

The initial kernel library has exactly one designated producer/consumer lane
inside the persistent Vortex kernel.  That GPU lane chooses requests, writes
entries and advances queue state without any CPU request call.  Other work
items may feed it through kernel-local work distribution, but they do not
concurrently update the HBM ring.  Multi-warp producers are a later feature
that requires an AMO-enabled Vortex build plus a hole-safe reservation and
publication algorithm.

## 9. Ordering and visibility

### 9.1 Submission

1. The designated GPU control lane allocates a logical CID and LSQ slot.
2. GPU writes all descriptor fields.
3. GPU performs an HBM/system-scope release fence supported by the platform.
4. GPU writes the slot ready sequence last, then advances `sq_producer`.
5. Bridge performs the corresponding ownership sync/acquire before reading.
6. SCOPE validates the complete descriptor before acknowledging consumption.

Advancing `sq_producer` before descriptor visibility is a protocol violation.

### 9.2 READ completion

1. NVMe completes all PCIe writes into HBM.
2. Physical CQE becomes visible to SCOPE.
3. SCOPE performs required XRT/P2P ownership synchronization.
4. SCOPE writes LCQ entry, executes a release fence and advances
   `cq_producer`.
5. GPU acquire-loads `cq_producer` before reading payload or LCQ fields.

The physical NVMe CQE is the data-DMA completion boundary; LCQ publication is
the GPU-visible handoff boundary.

### 9.3 WRITE submission

GPU payload stores must be visible through the P2P BAR before SCOPE rings the
physical doorbell. The complete GIDS arena, including payload, is therefore
inside the Vortex non-cacheable I/O aperture. GPU store ordering plus LSQ
release publication makes the HBM bytes visible before Bridge fetches the
descriptor; QEMU never copies or cache-syncs payload through host memory.

## 10. CID, wrap, timeout and reset

- Logical CIDs are queue-local and cannot be reused until an LCQ entry is
  consumed or the queue generation changes.
- SCOPE maintains `(queue_id, generation, logical_cid) -> physical_cid` and the
  reverse mapping.  Duplicate live CIDs are rejected.
- At most `depth - 1` requests may be outstanding.  Counter arithmetic is
  modulo 2^32; an unsigned producer-consumer distance greater than depth is a
  fatal overrun.
- Physical CID exhaustion applies backpressure without consuming more LSQ
  entries.
- A physical-I/O timeout is controller-wide uncertainty: SCOPE sets
  `fatal_error=TIMEOUT`, moves the logical queue to `FAILED` through
  `GIDS_QUEUE_SET_STATE`, and requires service restart. It does not fabricate a
  successful or safely attributable completion after the physical CID has
  timed out.
- Recreating the Bridge allocation produces a new generation and invalidates
  old handles and entries. QEMU restart also assigns a new session cookie.
- Current teardown is fail-stop: it stops consumption, disables the exclusive
  controller and releases mappings. It does not claim to cancel or attribute
  arbitrary in-flight NVMe requests safely.
- Queue-local recovery after timeout/reset is not supported. QEMU and Bridge
  must be restarted before the controller and physical CIDs are reused.
- When Bridge communication is still available, fatal state is synchronized
  to HBM. After complete Bridge loss, the kernel's finite poll bound is the
  fallback because QEMU has no remaining path to update HBM.

## 11. Address validation and isolation

SCOPE accepts only READ/WRITE requests whose:

- namespace is explicitly allowlisted;
- LBA range is within the configured test/tenant extent;
- buffer handle belongs to this queue/session and generation;
- offset and byte count fit the P2P BO without overflow;
- byte count is an exact multiple of namespace LBA size;
- direction is permitted by the buffer registration;
- generated PRP/SGL entries stay inside the registered U280 P2P aperture.

The GPU never supplies a raw PRP, SGL, host physical address or real doorbell
offset.  This is the primary reason for retaining semantic translation.

## 12. READ and WRITE paths

### 12.1 READ

```text
GPU LSQ READ
  -> SCOPE validates and builds physical SQE
  -> SCOPE writes real SQ doorbell
  -> SSD/NVMe PCIe MWr
  -> U280 P2P BAR -> HBM
  -> physical CQE -> logical CQE
  -> GPU polls LCQ and consumes HBM data
```

### 12.2 WRITE

```text
GPU prepares HBM data and LSQ WRITE
  -> release/acquire P2P visibility handshake
  -> SCOPE validates and builds physical SQE
  -> SCOPE writes real SQ doorbell
  -> NVMe PCIe MRd U280 P2P BAR/HBM
  -> SSD media write
  -> physical CQE -> logical CQE
  -> GPU polls LCQ
```

Neither direction uses XiangShan DDR or host DRAM for payload.  Queue metadata
may be inspected and copied by trusted CPU software; that is control traffic,
not payload.

## 13. Completion notification

Polling is the normative first mode: a resident Vortex kernel polls LCQ in
HBM.  This avoids routing each completion through XiangShan interrupts.

Optional notification may wake a sleeping kernel or host monitor, but it is
only a hint.  Correctness remains based on LCQ producer/generation.  Lost or
coalesced hints cannot lose completions.

## 14. Compatibility and coexistence

- Existing local-p2p NVMe, remote-rdma, IGB, IXGBE and Vortex paths retain
  their current ABI when GIDS is absent from backend configuration.
- Existing `vx_gds_*` CPU-controlled GDS APIs remain available and are not
  silently redirected to GIDS.
- GIDS uses new capability bits and a new queue ABI; unsupported Bridge/QEMU
  versions fail queue creation.
- Current GDS and GIDS may use different NVMe controllers concurrently.
- They are mutually exclusive on one physical controller in the first
  implementation.
- GIDS does not require XiangShan Linux to bind a virtual NVMe endpoint for the
  dedicated physical controller.

## 15. Relationship to prior work

| System | GPU initiates request | GPU owns physical NVMe queue | Direct payload | Host CPU role |
|---|---:|---:|---:|---|
| NVIDIA GDS | Not required | No | Yes | Control path |
| GPUfs | GPU API | No | Not necessarily | Host FS coordination |
| BaM | Yes | Yes | Yes | Setup/management |
| GIDS paper | Yes, via BaM | Via BaM | Yes | Hybrid placement/setup |
| Public SCADA description | Yes | Not publicly specified | Yes | No per-I/O CPU control/data role; server implementation and ABI are not public |
| SCOPE Vortex GIDS v1 | Yes | Logical queue only | Yes | Trusted batched translation, no scheduling/payload |

SCOPE v1 therefore advances beyond the current GDS path but does not claim the
strongest BaM property.  Its distinctive contribution is GPU-initiated storage
through a virtualized, address-validating semantic queue that can coexist with
SCOPE's heterogeneous device framework.

## 16. Design self-audit

1. **Does the GPU produce the I/O request?** Yes.  A Vortex kernel writes every
   logical request and publishes LSQ producer state.
2. **Who manages SQ?** Vortex manages the logical SQ; QEMU exclusively manages
   the physical NVMe SQ and translation map.
3. **Who consumes CQ?** QEMU consumes the physical CQ; Vortex consumes the
   logical CQ.
4. **Who rings the doorbell?** A thin SCOPE semantic proxy writes the physical
   doorbell only for already published and validated GPU requests.
5. **Is CPU in the per-request scheduling path?** No.  CPU proxy code validates
   and forwards batches, but cannot choose request timing, LBA, direction or
   buffer and receives no per-request application call.
6. **Does payload pass through CPU memory?** No.  PRP/SGL targets only the
   registered U280 P2P HBM aperture.
7. **Are READ and WRITE possible?** Yes, with opposite NVMe P2P DMA directions
   and different pre/post visibility fences.
8. **Can current GDS coexist?** Yes across different controllers; same-controller
   concurrency is deliberately rejected in v1.
9. **Is this identical to BaM/GIDS/SCADA?** No.  It is mediated logical-queue
   GPU-initiated storage.  BaM directly exposes physical queue mechanisms;
   GIDS adds GNN-specific policies; public SCADA removes CPU involvement from
   the I/O paths, while SCOPE v1 retains a trusted CPU-executed batch proxy and
   therefore cannot claim SCADA equivalence.

The design would fail its own goal if a host thread called `pread`, `pwrite`,
an ioctl or a runtime submit function for every request.  Such a path is the
existing GDS mode and must not be labeled GIDS.
