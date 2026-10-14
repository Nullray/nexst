#!/bin/bash
set -e

if [ $# -ge 1 ]; then

    xdma_user=/dev/${1}_user
    xdma_bypass=/dev/${1}_bypass

    if [ ! -c $xdma_user ]; then
        echo "ERROR: not a character device: $xdma_user"
        exit 1
    fi

    if [ ! -c $xdma_bypass ]; then
        echo "ERROR: not a character device: $xdma_bypass"
        exit 1
    fi

fi

if [ $# -eq 1 ]; then

    ./pcie-util $xdma_user uart 0x11000

elif [ $# -eq 3 ]; then

    bootrom=$2
    fw_payload=$3
    load_addr=0x80000000
    linux_entry_addr=0x80200000

    if [ ! -f $bootrom ]; then
        echo "ERROR: file not found: $bootrom"
        exit 1
    fi

    if [ ! -f $fw_payload ]; then
        echo "ERROR: file not found: $fw_payload"
        exit 1
    fi

    if [ -n "${GUEST_DDR_SIZE:-}" ]; then
        fw_payload_size=$(stat -c%s "$fw_payload")
        if [ "$fw_payload_size" -gt $((GUEST_DDR_SIZE)) ]; then
            echo "ERROR: payload exceeds guest DDR range: addr=$load_addr size=$fw_payload_size guest_ddr_size=$GUEST_DDR_SIZE"
            exit 1
        fi
    fi

    expected_heads=$(python3 - "$bootrom" "$fw_payload" <<'PY'
import sys

def word(path, offset):
    with open(path, 'rb') as stream:
        stream.seek(offset)
        data = stream.read(4)
    if len(data) != 4:
        raise SystemExit(f'ERROR: image too short: {path} at {offset:#x}')
    return f'{int.from_bytes(data, "little"):08x}'

print(word(sys.argv[1], 0), word(sys.argv[2], 0), word(sys.argv[2], 0x200000))
PY
    )
    read -r expected_boot_head expected_fw_head expected_linux_head <<< "$expected_heads"

    echo "Assert reset"
    ./pcie-util $xdma_user write 0x100000 1

    echo "Load $bootrom"
    ./pcie-util $xdma_user load 0x0 0x10000 $bootrom
    boot_head=$(./pcie-util $xdma_user read 0x0)
    if [ "$boot_head" != "$expected_boot_head" ]; then
        echo "ERROR: bootrom readback mismatch: got=$boot_head expected=$expected_boot_head; keeping reset asserted"
        exit 1
    fi

    echo "Load $fw_payload"
    echo "Using flat DDR bypass mapping, load address is a raw DDR offset: $load_addr"
    ./pcie-util $xdma_bypass load $load_addr 0x10000000 $fw_payload

    echo "Drain DDR bypass posted writes"
    if ! fw_head=$(./pcie-util $xdma_bypass read $load_addr); then
        echo "ERROR: failed to read back firmware load address $load_addr"
        exit 1
    fi
    if ! linux_head=$(./pcie-util $xdma_bypass read $linux_entry_addr); then
        echo "ERROR: failed to read back Linux entry address $linux_entry_addr"
        exit 1
    fi
    echo "Readback fence: [$load_addr]=$fw_head [$linux_entry_addr]=$linux_head"
    if [ "$fw_head" != "$expected_fw_head" ] || [ "$linux_head" != "$expected_linux_head" ]; then
        echo "ERROR: DDR readback mismatch: expected [$load_addr]=$expected_fw_head [$linux_entry_addr]=$expected_linux_head; keeping reset asserted"
        exit 1
    fi

    echo "Deassert reset"
    ./pcie-util $xdma_user write 0x100000 0

    echo "Start serial connection"
    ./pcie-util $xdma_user uart 0x11000

else

cat <<EOF
Usage: $0 <xdmaN> <bootrom.bin> <fw_payload.bin>    Load images & run from reset state
   Or: $0 <xdmaN>                                   Continue from last state
EOF
exit 1

fi
