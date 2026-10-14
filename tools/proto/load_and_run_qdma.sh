#!/usr/bin/env bash
# Ordinary Kunminghu SCOPE boot: raw DDR while reset, coherent alias at runtime.
set -euo pipefail
proto_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ $# != 1 && $# != 3 ]]; then
    echo "Usage: $0 <domain:bus:device.function|qdmaBB00F> [bootrom.bin fw_payload.bin]" >&2
    exit 1
fi
if [[ $1 =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
    qdma_boot_bdf=$1
elif [[ $1 =~ ^qdma([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-7])$ ]]; then
    qdma_boot_bdf="0000:${BASH_REMATCH[1]}:${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
else
    echo "Invalid FPGA BDF: $1" >&2; exit 1
fi
qdma_user="/sys/bus/pci/devices/$qdma_boot_bdf/resource1"
qdma_bypass="/sys/bus/pci/devices/$qdma_boot_bdf/resource2"
pcie_util=${PCIE_UTIL:-$proto_dir/pcie-util}
[[ -e $qdma_user && -e $qdma_bypass && -x $pcie_util ]] || {
    echo "Missing FPGA BAR resources or $pcie_util (make -C $proto_dir)." >&2; exit 1;
}
if [[ $# == 3 ]]; then
    [[ -f $2 && -f $3 ]] || { echo "Boot image does not exist." >&2; exit 1; }
    # The reset-vector GPIO's second channel is at +8; the CPU boots at 0x10000000.
    "$pcie_util" "$qdma_user" write 0x11000 1
    "$pcie_util" "$qdma_user" write 0x11008 0x10000000
    "$pcie_util" "$qdma_user" load 0x0 0x10000 "$2"
    "$pcie_util" "$qdma_bypass" load 0x80000000 0x10000000 "$3"
    "$pcie_util" "$qdma_user" write 0x11000 0
fi
exec "$pcie_util" "$qdma_user" uart 0x12000
