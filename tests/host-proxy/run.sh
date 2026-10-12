#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
qemu_binary=${1:-$repo_root/qemu-mount/build-nanhu-host/qemu-system-x86_64}
python3 "$repo_root/tests/host-proxy/test-tools.py"
bash "$repo_root/qemu-mount/tests/scope-usb/run.sh" "$qemu_binary"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
dtc -I dts -O dtb -o "$test_dir/nanhu.dtb" "$repo_root/nanhu-g/software/dt/XSTop_vpcie.dts"
[[ $(fdtget -t x "$test_dir/nanhu.dtb" /memory@80000000 reg) == "0 80000000 0 80000000" ]]
[[ $(fdtget "$test_dir/nanhu.dtb" /soc/pci@60000000 compatible) == "pci-host-ecam-generic" ]]
plic=$(fdtget -t x "$test_dir/nanhu.dtb" /soc/interrupt-controller@3c000000 phandle)
[[ $(fdtget -t x "$test_dir/nanhu.dtb" /soc/pci@60000000 interrupt-map) == "0 0 0 1 $plic 2 0 0 0 2 $plic 2 0 0 0 3 $plic 2 0 0 0 4 $plic 2" ]]
echo "PASS: original Nanhu-G 2 GiB memory, ECAM and PLIC INTx 2"
