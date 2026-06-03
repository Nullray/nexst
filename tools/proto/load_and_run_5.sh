#!/bin/bash

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

    if [ -n "$GUEST_DDR_SIZE" ]; then
        fw_payload_size=$(stat -c%s "$fw_payload")
        if [ $((load_addr + fw_payload_size)) -gt $((GUEST_DDR_SIZE)) ]; then
            echo "ERROR: payload exceeds guest DDR range: addr=$load_addr size=$fw_payload_size guest_ddr_size=$GUEST_DDR_SIZE"
            exit 1
        fi
    fi

    echo "Assert reset"
    ./pcie-util $xdma_user write 0x100000 1

    echo "Load $bootrom"
    ./pcie-util $xdma_user load 0x0 0x10000 $bootrom

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
