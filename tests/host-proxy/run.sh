#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
qemu_root="$repo_root/tools/host/qemu"
qemu_binary=${1:-$qemu_root/build-kunminghu-scope/qemu-system-x86_64}
python3 "$repo_root/tests/host-proxy/test-guest-tools.py"
SCOPE_GUEST_KERNEL="$repo_root/work_farm/software/linux" \
    python3 "$repo_root/tests/host-proxy/test-xhci-start.py"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
iverilog -g2012 -Wall -s tb_bar_packet_fifo -o "$test_dir/fifo" \
    "$repo_root/tests/host-proxy/tb_bar_packet_fifo.sv" \
    "$repo_root/shell/common/fpga/scope_bar_packet_fifo.v"
vvp "$test_dir/fifo"
iverilog -g2012 -Wall -s tb_qdma_notifications -o "$test_dir/qdma" \
    "$repo_root/tests/host-proxy/tb_qdma_notifications.sv" \
    "$repo_root/shell/common/fpga/scope_qdma_control.v" \
    "$repo_root/shell/common/fpga/scope_qdma_cmpt.v"
vvp "$test_dir/qdma"
cmp "$qemu_root/hw/misc/scope_qdma_hostbuf_uapi.h" \
    "$repo_root/tools/driver/xdma_drv/QDMA/linux-kernel/driver/src/scope_qdma_hostbuf_uapi.h"
iverilog -g2012 -Wall -s tb_qdma_bridge_ring -o "$test_dir/bridge" \
    "$repo_root/tests/host-proxy/tb_qdma_bridge_ring.sv" \
    "$repo_root/shell/common/fpga/scope_qdma_bridge_ring.v"
vvp "$test_dir/bridge"
cmp "$qemu_root/hw/misc/scope_qdma_bridge_uapi.h" \
    "$repo_root/tools/driver/xdma_drv/QDMA/linux-kernel/driver/src/scope_qdma_bridge_uapi.h"
cc -shared -fPIC -Wall -Wextra -Werror -I"$qemu_root" -I"$qemu_root/include" \
    "$qemu_root/tests/scope-usb/fake-xdma.c" -ldl -o "$test_dir/fake-xdma.so"
python3 "$repo_root/tests/host-proxy/test-host-proxy.py" "$qemu_binary" "$test_dir/fake-xdma.so"
python3 "$repo_root/tests/host-proxy/test-host-proxy.py" "$qemu_binary" "$test_dir/fake-xdma.so" qdma-cmpt
python3 "$repo_root/tests/host-proxy/test-host-proxy.py" "$qemu_binary" "$test_dir/fake-xdma.so" qdma-bridge
for transport in xdma-dma32 bar-fifo qdma-cmpt qdma-bridge; do
    python3 "$qemu_root/tests/scope-usb/test-physical-xhci.py" \
        "$qemu_binary" "$test_dir/fake-xdma.so" "$transport"
done
mkdir -p "$test_dir/linux"
touch "$test_dir/linux/dma-direct.h"
for enabled in 1 0; do
    cc -std=gnu11 -O2 -g -Wall -Wextra -Werror \
        -fsanitize=address,undefined -fno-omit-frame-pointer \
        -DCONFIG_SCOPE_PCIE_P2P_DMA="$enabled" \
        -DSCOPE_DMA_HEADER="\"$repo_root/tools/guest/include/scope-p2p-dma.h\"" \
        -I"$test_dir" "$qemu_root/tests/scope-usb/test-dma-window.c" \
        -o "$test_dir/test-dma-window"
    "$test_dir/test-dma-window"
done
cpp -DFPGA_UVHS2 -I "$repo_root/kmh/software/dt" -E -P -x assembler-with-cpp \
    "$repo_root/kmh/software/dt/xiangshan-host-proxy.dts" > "$test_dir/proxy.dts"
dtc -I dts -O dtb -o "$test_dir/proxy.dtb" "$test_dir/proxy.dts"
[[ $(fdtget -t x "$test_dir/proxy.dtb" /memory@80000000 reg) == "0 80000000 0 80000000" ]]
[[ $(fdtget "$test_dir/proxy.dtb" /soc/pcie@60000000 compatible) == "pci-host-ecam-generic" ]]
echo "PASS: guest DT memory and ECAM profile"
