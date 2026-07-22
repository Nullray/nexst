# vSwitch Vortex U280 Integration Design

## 1. Scope

This document specifies the repository 14 Vortex mediated backend. It maps a
Vortex accelerator implemented by an Alveo U280 xclbin into the XiangShan
virtual PCIe switch. The first supported workload is native Vortex `vecadd`.
OpenCL/PoCL, GPU virtual memory, profiling, interrupts, multiple command
queues, and direct device-to-device P2P are outside this phase.

The Vortex source tree is `/home/yanjiarun/Vortex`, branch
`scope-vswitch-u280`, based on upstream commit
`e2b9745b637ce8ac462be2f0e01b5d76542dc6c0`.

## 2. Deployed Components

| Component | Location | Responsibility |
| --- | --- | --- |
| XiangShan vSwitch bitstream | repository 14 | ECAM shadow, BAR packet transport, coherent alias |
| `scope-fpga-vswitch` | repository 14 QEMU | synthetic endpoint, CP register model, command translation |
| `scope-vortex-bridge` | Vortex host tools | isolated XRT owner and versioned RPC server |
| `libvortex-xrt.so` | Vortex host runtime | loads the U280 xclbin and accesses the physical CP |
| `vortex_afu.xclbin` | Vortex XRT build | physical Vortex GPU and command processor on U280 |
| `scope_vortex` | XiangShan Linux | BAR0 and coherent DMA character-device transport |
| static `vx-vecadd` | XiangShan rootfs | Vortex runtime, vSwitch callback backend, and test program |
| `kernel.vxbin` | XiangShan rootfs | RV32 Vortex vecadd kernel |

The U280 xclbin and the repository 14 FPGA bitstream target different FPGA
cards. A single FPGA cannot hold both complete designs at the same time.

## 3. Public Device Contract

The QEMU backend JSON entry is:

```json
{
  "type": "vortex",
  "bridge-socket": "/run/scope-vortex0.sock"
}
```

`bridge-socket` must be an absolute path. A Vortex entry must not contain
`real-host-bdf`. The resulting endpoint has:

| Property | Value |
| --- | --- |
| Vendor/device | `1b36:1310` |
| PCI class | `0x120000` Processing Accelerator |
| BAR0 | 4 KiB, 32-bit memory BAR |
| Completion | polling through `Q_SEQNUM` and `Q_ERROR` |
| Interrupts | none |

The guest Linux driver creates `/dev/scope-vortexN`. Opening one node is
exclusive. Closing the file descriptor releases every coherent DMA buffer
owned by that file.

## 4. Control and Data Path

```text
static XiangShan Vortex runtime
  -> /dev/scope-vortexN ioctl and mmap
  -> virtual CP BAR0 and guest coherent command ring
  -> FPGA BAR request packet
  -> QEMU Vortex backend
  -> per-backend worker and Unix RPC
  -> scope-vortex-bridge
  -> libvortex-xrt.so
  -> physical Vortex CP on U280
```

The shared QEMU RX thread never waits for U280 execution. It captures a stable
guest command-ring snapshot and queues a job. The per-backend worker is the
only QEMU thread that owns the bridge socket and may block on XRT/CP progress.

### 4.1 Submission

1. The guest runtime fills complete 64-byte command lines in a coherent DMA
   ring.
2. It writes `Q_TAIL_LO`, then writes `Q_TAIL_HI` as the atomic commit.
3. QEMU reads every new line twice through the coherent alias.
4. If both reads are identical, QEMU validates opcode, size, address range,
   ring delta, and wrap behavior.
5. QEMU queues the immutable command copy to the Vortex worker.
6. The worker patches host-memory operands and copies lines into the physical
   XRT command ring.
7. The worker commits the physical tail and polls physical `Q_SEQNUM`.
8. Download results are copied back through the guest coherent alias.
9. QEMU publishes virtual `Q_SEQNUM`; the guest runtime also reads `Q_ERROR`
   and reports a failed operation instead of accepting a synthetic success.

If the guest line is not stable yet, QEMU retries from manager polling without
sleeping in the shared RX thread. The visibility deadline is five seconds.

### 4.2 Address Ownership

| Address | Owner/meaning | May be sent to physical CP |
| --- | --- | --- |
| Guest command ring PA | XiangShan coherent DMA allocation | No |
| Guest staging PA in `MEM_WRITE/READ` | XiangShan coherent DMA allocation | No |
| Vortex device address | Physical U280 HBM logical address | Yes, after bounds check |
| XRT host-only BO address | Allocated by host bridge | Yes |
| QEMU coherent-alias offset | Host view of XiangShan memory | No |

For `MEM_WRITE`, QEMU reads the guest source, allocates a 64-byte-rounded XRT
host BO, zeroes its tail, uploads the requested bytes, and patches the command
source to the BO address. For `MEM_READ`, QEMU patches the command destination
to a BO and copies exactly the requested bytes back after completion. Long RPC
memory transfers are split into at most 64 KiB chunks.

Vortex device addresses are not translated, but QEMU verifies that the full
range is inside the memory capacity encoded by physical `GPU_DEV_CAPS`.

## 5. Supported CP Commands

The first implementation accepts `NOP`, `MEM_WRITE`, `MEM_READ`, `MEM_COPY`,
`DCR_WRITE`, `DCR_READ`, `LAUNCH`, `FENCE`, and `CACHE_FLUSH`.

`EVENT_SIGNAL`, `EVENT_WAIT`, profiling, `LAUNCH_QMD`, `DRAW`, and unknown
opcodes are rejected. `LAUNCH_QMD` and `DRAW` are rejected because the chosen
physical RTL CP does not implement those command forms. Rejection sets a
sticky backend failure rather than silently waiting forever.

## 6. Host Bridge RPC

The RPC header contains magic `VXRP`, protocol version, opcode, request ID,
payload length, and signed status. Supported operations are `HELLO`, CP
read/write, host-memory allocate/free, and host-memory read/write.

The bridge:

- loads the selected XRT callback driver with `dlopen()`;
- serves one QEMU client at a time;
- creates its Unix socket with mode `0600`;
- validates register alignment, payload lengths, BO handles, and BO bounds;
- limits an RPC message to 16 MiB and uses 64 KiB memory chunks in QEMU;
- stops the physical CP, frees every session BO, and resets handle numbering
  whenever the client disconnects;
- removes the socket on normal shutdown or SIGINT/SIGTERM.

Socket send/receive operations in QEMU have a five-second timeout. A bridge
disconnect or malformed response marks only that Vortex backend failed; NVMe
and IGB backends retain their independent state.

## 7. Guest Driver and Static Runtime

`scope_vortex` validates that BAR0 is memory space and at least 4 KiB. Its UAPI
provides aligned 32-bit CP reads/writes, coherent DMA allocation/free, and DMA
buffer mmap. A single allocation is capped at 16 MiB in this first phase.

`/home/yanjiarun/Vortex/tools/scope_vortex_guest` builds two statically linked
RISC-V executables:

- `vx-vecadd-static`, containing the common runtime and vSwitch transport;
- `scope-vortex-check`, which compares physical cores, threads, warps, memory
  banks, bank size, and ISA flags against the build configuration.

The static dispatcher binds `static_vx_dev_init()` directly; it does not call
`dlopen()` and has no `libvortex*.so` dependency. The rootfs wrapper runs the
capability checker before vecadd and records the Vortex commit, branch,
`VX_config.toml` SHA-256, the effective `VORTEX_CONFIGS`, and key `VX_CFG_*`
values in
`/usr/lib/vortex/build-info`.

The U280 xclbin, RV32 `kernel.vxbin`, static RISC-V runtime, and capability
checker must use the same Vortex configuration. For non-default builds, pass
the same `CONFIGS` value to the Vortex build script and as `VORTEX_CONFIGS`
when building the rootfs. A mismatch is a deployment error and is rejected
before vecadd submission.

## 8. Build and Start Sequence

1. Install a U280 development platform matching Vitis 2022.2. The required
   `.xpfm` is not supplied by XRT or the deployment package.
2. Generate `vortex_afu.xclbin`:

```bash
cd /home/yanjiarun/Vortex
VITIS_SETUP=/opt/Xilinx_2022.2/Vitis/2022.2/settings64.sh \
tools/scope_vortex_bridge/build_u280.sh \
  --platform /path/to/xilinx_u280_gen3x16_xdma_1_202211_1.xpfm \
  --target hw --num-cores 1 --kernel-freq 250 --jobs 8
```

3. Build the XRT runtime and bridge, then run bridge tests:

```bash
source /opt/xilinx/xrt/setup.sh
make -C /home/yanjiarun/Vortex/sw/runtime/xrt TARGET=hw
make -C /home/yanjiarun/Vortex/tools/scope_vortex_bridge check
```

4. Install the Vortex RV32 kernel toolchain and build guest artifacts:

```bash
cd /home/yanjiarun/Vortex
./ci/toolchain_install.sh --llvm --riscv32 --libcrt32 --libc32
tools/scope_vortex_bridge/build_vecadd_riscv64.sh
```

5. Build repository 14 rootfs with `VORTEX_ENABLE=1`; for a non-default
   xclbin also pass the matching `VORTEX_CONFIGS` value.
6. Enable U280 host memory, start `scope-vortex-bridge`, start QEMU, then boot
   XiangShan.
7. In the guest, inspect build metadata and run:

```bash
cat /usr/lib/vortex/build-info
scope-vortex-check
vortex-vecadd -n 16
vortex-vecadd -n 1024
```

## 9. Error Semantics

| `Q_ERROR` | Meaning |
| ---: | --- |
| 0 | no error |
| 1 | bridge, RPC, physical job, or data-copy failure |
| 2 | guest tail moved backwards |
| 3 | tail delta is unaligned or exceeds the ring |
| 4 | a new tail was committed before the prior tail became visible |
| 5 | guest command ring did not become stable before the deadline |

Errors 1 and 5 retire the affected virtual target sequence so userspace can
observe an error instead of hanging. A failed backend remains sticky for the
QEMU process lifetime; a guest queue reset does not conceal a dead bridge.

## 10. Verification Contract

- Bridge unit test: protocol, CP access, BO read/write/free, socket mode, and
  disconnect cleanup using a fake callback driver.
- QEMU build: the Vortex backend must compile as part of
  `qemu-system-x86_64` with no high-frequency RPC in the shared RX thread.
- Static guest check: both RISC-V executables must have no ELF `NEEDED` entry.
- Guest driver: `lspci -nnk` reports `1b36:1310`, and
  `/dev/scope-vortex0` exists.
- Workload: vecadd sizes 16, 1024, and a larger multiple of 16 must pass
  element-by-element validation, including a transfer with a non-64-byte
  final cacheline.
- Mixed regression: NVMe, IGB, and Vortex workloads run concurrently without
  backend-state or route-table contamination.
- Failure tests: missing bridge, bad xclbin, bridge termination, physical CP
  timeout, invalid opcode, and ring visibility timeout all produce explicit
  errors without hanging QEMU's shared RX thread.

## 11. Current External Dependencies

The source, bridge tests, QEMU build, guest driver object, RV32
`kernel.vxbin`, static guest executables, and rootfs component installation all
pass. This server currently lacks the U280 development `.xpfm`; therefore
Vitis cannot link the final xclbin yet. The installed XRT is also a build for
an older distribution and expects Boost 1.71, while AMD's Jammy XRT download
currently times out from this server. These are deployment-environment
dependencies, not repository interface or compile failures. Install the
official Ubuntu 22.04 XRT package; do not replace Boost 1.71 with an unverified
ABI symlink.
