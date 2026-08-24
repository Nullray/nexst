# SCOPE Vortex GIDS Validation Runbook

## 1. Purpose and acceptance criteria

This runbook validates three distinct storage paths and the failure semantics
of the mediated Vortex GIDS implementation. It does not treat successful PCI
enumeration or queue creation as proof of GPU-initiated I/O.

The GIDS path passes only when all of the following hold:

- a Vortex kernel publishes each logical request and consumes each logical
  completion without a per-request CPU syscall or runtime submission call;
- the real NVMe controller is exclusively owned by QEMU;
- READ data reaches U280 HBM through the P2P BAR and is checked by Vortex;
- destructive mode writes from HBM to a reserved SSD extent, reads it back,
  and verifies every word in Vortex;
- QEMU counters show no rejection, timeout or transport failure;
- physical-I/O timeout moves the queue to `FAILED`; complete Bridge loss is
  bounded by the GPU test's poll limit rather than leaving it waiting forever.

The commands below use the repository-16 defaults. Re-discover every PCI BDF
after a reboot and change the variables rather than editing source files.

## 2. Moving the implementation to another server

Move GIDS by Git commit, not by copying a populated source directory. A whole
directory copy also transfers Meson/Ninja source paths, generated Vortex
`config.mk` files, host-architecture objects, and sometimes dereferenced
submodule symlinks. Those files caused the earlier cross-server build and
runtime mismatches.

On the source server, record the three repository commits:

```bash
git -C "$SCOPE_REPO" rev-parse HEAD
git -C "$SCOPE_REPO/qemu-mount" rev-parse HEAD
git -C "$VORTEX_HOME" rev-parse HEAD
git -C "$SCOPE_REPO" submodule status --recursive
```

On the destination server, clone or fetch those exact branches/commits. Run
`git submodule update --init --recursive` from the nexst tree. Do not transfer
`qemu-mount/build`, Vortex generated headers/libraries, `config.mk`, Vivado
output, initramfs contents, or host binaries. Recreate all of them locally.

Before building, run the read-only portability gate:

```bash
export SCOPE_REPO=/path/to/nexst_proxy_16
export VORTEX_HOME=/path/to/Vortex_16
"$SCOPE_REPO/tools/check_gids_portability.sh" \
  --repo "$SCOPE_REPO" --vortex-home "$VORTEX_HOME"
```

The gate prints all three commits and rejects a stale QEMU source directory,
wrong Vortex home, missing cross compiler, submodule pin mismatch, missing
GIDS source, or QEMU/Vortex ABI drift. Only proceed when it passes. Then make
a fresh QEMU build directory and rebuild the Vortex bridge, runtime, kernels,
and XiangShan image on the destination host. Hardware-specific BDFs, serial
numbers, xclbin path, XRT path, SSD extent, and P2P BAR layout remain deployment
configuration and must be rediscovered rather than copied from the source
server.

## 3. Fixed test contract

```bash
export SCOPE_REPO=/home/yanjiarun/nexst_proxy_16
export VORTEX_HOME=/home/yanjiarun/Vortex_16
export NM37_BDF=0000:2a:00.0
export U280_BDF=0000:ab:00.1
export GIDS_NVME_BDF=0000:e1:00.0
export GIDS_NVME_SERIAL=PHLJ3252006F1P0UGN
export GIDS_SLBA=262144
export GIDS_CHECKSUM=0xb348a9c5
export IO_BYTES=4096
export IO_COUNT=100
export XCLBIN=/home/yanjiarun/Vortex_16/hw/syn/xilinx/xrt/\
build1_p2p_xilinx_u280_gen3x16_xdma_1_202211_1_hw/bin/vortex_afu.xclbin
```

Verify the identities before touching the SSD:

```bash
lspci -nn -s "$NM37_BDF"
lspci -nnk -s "$U280_BDF"
lspci -nnk -s "$GIDS_NVME_BDF"
test -e "$XCLBIN"
```

Expected: NM37 is the `10ee:903f` XDMA function, U280 is bound to `xocl`, and
the selected storage function is an NVMe controller. Stop if a BDF or serial
does not match the intended hardware.

## 4. Build gates

### 4.1 QEMU and ABI tests

```bash
cd "$SCOPE_REPO/qemu-mount"
ninja -C build qemu-system-x86_64 test-scope-vortex-gids
./build/tests/unit/test-scope-vortex-gids

cd "$SCOPE_REPO"
./tools/check-gids-abi.sh
```

Both commands must exit zero. The ABI check compares QEMU and Vortex protocol
copies and rejects layout drift.

### 4.2 Bridge, runtime and guest image

```bash
make -C "$VORTEX_HOME/tools/scope_vortex_bridge" check
make -C "$VORTEX_HOME/tests/regression/gds_read" -j2 \
  VORTEX_HOME="$VORTEX_HOME"
make -C "$VORTEX_HOME/tests/regression/gids_io" -j2 \
  VORTEX_HOME="$VORTEX_HOME"

cd "$SCOPE_REPO"
VORTEX_HOME="$VORTEX_HOME" ./tools/build_vortex_guest_single_bank.sh
```

The generated image must contain `vortex-gds_read`, `vortex-gids_io`, their
matching RV32 kernels, and the one-bank Vortex build information.

## 5. Prepare U280 and the reserved SSD extent

The pattern must be prepared while the NVMe remains bound to the host `nvme`
driver. First perform the read-only audit:

```bash
cd "$SCOPE_REPO"
sudo ./tools/prepare_vortex_gds_ssd.sh \
  --bdf "$GIDS_NVME_BDF" --serial "$GIDS_NVME_SERIAL" --slba "$GIDS_SLBA"
```

Only after checking the exact device, serial, offset and absence of mounts,
partitions, signatures, holders and open users, write the single 4 KiB test
pattern:

```bash
sudo ./tools/prepare_vortex_gds_ssd.sh \
  --bdf "$GIDS_NVME_BDF" --serial "$GIDS_NVME_SERIAL" \
  --slba "$GIDS_SLBA" --write \
  --confirm "ERASE-4096-BYTES-AT-SLBA-$GIDS_SLBA"
```

Initialize U280 direct P2P and its inbound HBM aperture:

```bash
sudo "$SCOPE_REPO/tools/u280_xrt_start.sh" \
  --vortex-p2p --vortex-gds \
  --u280-bdf "$U280_BDF" --peer-bdf "$NM37_BDF" \
  --gds-nvme-bdf "$GIDS_NVME_BDF" --xclbin "$XCLBIN"
source "$SCOPE_REPO/tools/u280_xrt_env.sh"
```

Expected topology: HBM0 is 256 MiB, the P2P BAR is 512 MiB, and the inbound
remapper uses 2 MiB slots. A pending BAR resize requires the instructed warm
reboot; do not continue with a partially configured P2P aperture.

## 6. Start the Bridge

In terminal A:

```bash
sudo env \
  XILINX_XRT=/home/yanjiarun/xrt-u280-2.16 \
  LD_LIBRARY_PATH=/home/yanjiarun/xrt-u280-2.16/lib \
  "$VORTEX_HOME/tools/scope_vortex_bridge/scope-vortex-bridge" \
    --socket /run/scope-vortex0.sock \
    --driver-lib "$VORTEX_HOME/sw/runtime/libvortex-xrt.so" \
    --device-index 0 \
    --allow-peer-bdf "$NM37_BDF" \
    --allow-gds-nvme-bdf "$GIDS_NVME_BDF" \
    --xclbin "$XCLBIN"
```

Keep it running. In another terminal verify:

```bash
sudo test -S /run/scope-vortex0.sock
pgrep -af scope-vortex-bridge
```

Recheck `/sys/bus/pci/devices/$U280_BDF/p2p.u.*/{p2p_enable,config,bar_map}`.
Loading the xclbin must not silently change the validated P2P layout.

## 7. Start QEMU in GIDS mode

Confirm that the JSON uses the intended BDF, reserved LBA range and control
aperture:

```bash
cat "$SCOPE_REPO/vswitch-backends-vortex-gids.json"
```

Stop all host users of the test SSD, then unbind it:

```bash
findmnt -rn -S /dev/nvme0n1
sudo fuser -v /dev/nvme0 /dev/nvme0n1
echo "$GIDS_NVME_BDF" | sudo tee /sys/bus/pci/drivers/nvme/unbind
test ! -e "/sys/bus/pci/devices/$GIDS_NVME_BDF/driver"
```

The first two commands must have no user of this SSD. In terminal B:

```bash
cd "$SCOPE_REPO/qemu-mount/build"
sudo ./qemu-system-x86_64 \
  -machine q35 -m 128M -display none -monitor null -serial null \
  -device pcie-root-port,id=rp1,bus=pcie.0 \
  -device scope-fpga-vswitch,bus=rp1,\
backend-config="$SCOPE_REPO/vswitch-backends-vortex-gids.json",\
fpga-host-bdf="$NM37_BDF",\
xdma-user-dev=/dev/xdma0_user,\
xdma-ctrl-dev=/dev/xdma0_control,\
xdma-bypass-dev=/dev/xdma0_bypass,\
guest-ddr-base=0x80000000,guest-ddr-size=0x80000000,\
dma32-ring-size=0x10000,vortex-log=on \
  2>&1 | tee gids-qemu.log
```

Required startup line: `[SCOPE GIDS] ready` with the expected physical NVMe,
NSID, LBA range, queue depth, HBM address and P2P bus address. The physical
NVMe is owned by the GIDS service and is intentionally not exposed as a guest
NVMe endpoint in this configuration.

## 8. Boot XiangShan

In terminal C:

```bash
cd "$SCOPE_REPO/tools/proto"
sudo ./load_and_run_5.sh xdma0 \
  "$SCOPE_REPO/nanhu-g/ready_for_download/proto_nm37_vu37p/bootrom.bin" \
  "$SCOPE_REPO/nanhu-g/ready_for_download/proto_nm37_vu37p/RV_BOOT_vortex_1bank.bin"
```

Inside XiangShan:

```sh
lspci -nnk
ls -l /dev/scope-vortex0
cat /usr/lib/vortex/build-info
scope-vortex-check
vortex-vecadd -n 64
```

The Vortex endpoint must bind to `scope-vortex`; capability check and vecadd
must pass before storage testing.

## 9. GIDS correctness tests

### 9.1 Non-destructive GPU-initiated READ

```sh
vortex-gids_io --mode read --slba 262144 \
  --expected-checksum 0xb348a9c5 --bytes 4096 --iterations 100 \
  --csv /tmp/gids-read.csv
cat /tmp/gids-read.csv
```

Expected final line contains:

```text
GIDS PASSED mode=read ... cpu_per_io_submit=0 data_verified=1
```

The CSV must contain 100 successful READ rows. After QEMU exits, its summary
must satisfy:

```text
accepted=100 submitted=100 physical_completed=100 logical_completed=100
read_bytes=409600 write_bytes=0 rejected=0 failed=0 fatal_error=0
```

### 9.2 Destructive GPU WRITE followed by GPU READ

This test is permitted only in the reserved extent prepared in section 4:

```sh
vortex-gids_io --mode roundtrip --slba 262144 --destructive \
  --bytes 4096 --iterations 100 --csv /tmp/gids-roundtrip.csv
cat /tmp/gids-roundtrip.csv
```

Vortex generates the pattern, submits WRITE and READ logical SQEs, and checks
the readback in HBM. Expected final line contains `data_verified=1`. The QEMU
summary must show 200 accepted/submitted/completed requests, 409600 read bytes,
409600 write bytes, and zero rejected/failed/fatal fields.

## 10. Failure and ordering tests

### 10.1 Bridge disconnect

Start a long GIDS test, then terminate the Bridge. QEMU must stop fetching and
submitting requests and report a transport failure. If the socket remains
usable long enough, it also publishes queue state `FAILED`; after complete
transport loss no component can update HBM, so the Vortex test must terminate
through its finite `--max-polls` bound. It must not wait forever. Restart QEMU
and the Bridge before further tests because the queue is not recoverable in
place.

### 10.2 Physical completion timeout

With a debug-only environment that can suppress physical completion, submit
one request and wait longer than the 30 s service timeout. QEMU must report a
timeout, publish `FAILED`, and print `fatal_error` in its summary. Do not use
this injection on a production filesystem or shared controller.

### 10.3 Queue wrap and backpressure

Run more requests than the configured depth (64), for example 1024 READs.
Every logical CID must complete exactly once, producer/consumer counters must
cross multiple wraps, and accepted/submitted/completed counts must remain
equal. Any stale generation, duplicate completion or permanent full queue is
a failure.

## 11. Fair CPU/GDS/GIDS comparison

Use one 4 KiB READ range, checksum, request count and repeat count for all
modes. The comparison is READ-only because the current CPU-initiated GDS path
does not implement WRITE. The destructive roundtrip in section 8.2 separately
proves GIDS WRITE correctness.

Modes A and B require the standard GDS JSON, which exposes both the virtual
NVMe and Vortex. Mode C requires the exclusive GIDS JSON. Therefore collect
the modes in separate sessions and append to one result file:

```bash
RESULT=$SCOPE_REPO/storage_path_results.csv

# Session A/B: run these commands through the XiangShan command transport.
CPU_CMD='vortex-gds_read --mode cpu --device /dev/nvme0n1 --slba 262144 --expected-checksum 0xb348a9c5 --bytes "$SCOPE_IO_BYTES" --iterations "$SCOPE_IO_COUNT" --csv "$SCOPE_SAMPLE_CSV"'
GDS_CMD='vortex-gds_read --mode gds --device /dev/nvme0n1 --slba 262144 --expected-checksum 0xb348a9c5 --bytes "$SCOPE_IO_BYTES" --iterations "$SCOPE_IO_COUNT" --csv "$SCOPE_SAMPLE_CSV"'

$SCOPE_REPO/tools/run_storage_path_comparison.sh \
  --mode cpu --cpu-cmd "$CPU_CMD" --io-bytes 4096 --io-count 100 \
  --repeats 5 --warmup 1 --output "$RESULT"
$SCOPE_REPO/tools/run_storage_path_comparison.sh \
  --mode gds --gds-cmd "$GDS_CMD" --io-bytes 4096 --io-count 100 \
  --repeats 5 --warmup 1 --output "$RESULT" --append

# Session C: reboot with the exclusive GIDS JSON, then append this mode.
GIDS_CMD='vortex-gids_io --mode read --slba 262144 --expected-checksum 0xb348a9c5 --bytes "$SCOPE_IO_BYTES" --iterations "$SCOPE_IO_COUNT" --csv "$SCOPE_SAMPLE_CSV"'
$SCOPE_REPO/tools/run_storage_path_comparison.sh \
  --mode gids --gids-cmd "$GIDS_CMD" --io-bytes 4096 --io-count 100 \
  --repeats 5 --warmup 1 --output "$RESULT" --append
```

The command strings must be executed by a real XiangShan command transport
(for example an existing serial automation wrapper). The host script itself
does not make guest binaries executable on x86. If commands are entered
manually on UART, retain each program CSV and QEMU summary instead of claiming
host `/usr/bin/time` CPU utilization.

The result CSV reports bytes, IOPS, end-to-end bandwidth, wall-clock CPU time,
CPU percentage and P50/P95/P99 request latency. A row is valid only when its
test log reports `data_verified=1` and return code zero. Do not compare a GIDS
roundtrip row against READ-only CPU/GDS rows.

## 12. Teardown

Exit QEMU first, then stop the Bridge. Rebind the SSD only after QEMU has
restored and released the physical function:

```bash
echo "$GIDS_NVME_BDF" | sudo tee /sys/bus/pci/drivers/nvme/bind
lspci -nnk -s "$GIDS_NVME_BDF"
```

Preserve the QEMU log, per-request CSV files, exact JSON, xclbin hash, guest
image hash and BDF map with every result. Hardware results are not valid if
the tested binaries or ownership configuration cannot be reconstructed.
