#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo prepare_vortex_gids_ssd.sh --device /dev/nvmeXnY \
  --slba-base N --block-count N --confirm-destructive [--output FILE]

Performs safety and bounds checks and writes a GIDS extent manifest. It does
not write the SSD and must be run while the host NVMe driver is still bound.
EOF
}

DEVICE=
SLBA_BASE=
BLOCK_COUNT=
OUTPUT=gids-extent.json
CONFIRM=0
while (($#)); do
  case "$1" in
    --device) DEVICE=$2; shift 2 ;;
    --slba-base) SLBA_BASE=$2; shift 2 ;;
    --block-count) BLOCK_COUNT=$2; shift 2 ;;
    --output) OUTPUT=$2; shift 2 ;;
    --confirm-destructive) CONFIRM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -b $DEVICE && $DEVICE =~ /dev/nvme[0-9]+n[0-9]+$ &&
   $SLBA_BASE =~ ^[0-9]+$ && $BLOCK_COUNT =~ ^[1-9][0-9]*$ &&
   $CONFIRM -eq 1 ]] || { usage >&2; exit 2; }

NAME=${DEVICE##*/}
CTRL=${NAME%n*}
[[ -e /sys/class/nvme/$CTRL/device ]] || {
  echo "cannot locate controller for $DEVICE" >&2
  exit 1
}
BDF=$(basename "$(readlink -f "/sys/class/nvme/$CTRL/device")")
[[ $BDF =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]] || {
  echo "invalid PCI BDF resolved for $DEVICE: $BDF" >&2
  exit 1
}

if lsblk -nrpo NAME,MOUNTPOINT "$DEVICE" |
   awk 'NF > 1 && $2 != "" {found=1} END {exit !found}'; then
  echo "$DEVICE or one of its partitions is mounted" >&2
  lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS "$DEVICE" >&2
  exit 1
fi
if awk -v d="$DEVICE" '$1 == d || index($1, d "p") == 1 {found=1} END {exit !found}' /proc/swaps; then
  echo "$DEVICE is used as swap" >&2
  exit 1
fi
if find "/sys/class/block/$NAME/holders" -mindepth 1 -maxdepth 1 -print -quit |
   grep -q .; then
  echo "$DEVICE has block holders" >&2
  ls -l "/sys/class/block/$NAME/holders" >&2
  exit 1
fi

LBA_SIZE=$(blockdev --getss "$DEVICE")
BYTES=$(blockdev --getsize64 "$DEVICE")
TOTAL_BLOCKS=$((BYTES / LBA_SIZE))
((SLBA_BASE <= TOTAL_BLOCKS && BLOCK_COUNT <= TOTAL_BLOCKS - SLBA_BASE)) || {
  echo "extent [$SLBA_BASE,+$BLOCK_COUNT) exceeds $TOTAL_BLOCKS blocks" >&2
  exit 1
}
SERIAL=$(cat "/sys/class/nvme/$CTRL/serial" 2>/dev/null || true)
MODEL=$(cat "/sys/class/nvme/$CTRL/model" 2>/dev/null || true)
NSID=$(cat "/sys/class/block/$NAME/nsid" 2>/dev/null || echo 1)

cat >"$OUTPUT" <<EOF
{
  "device": "$DEVICE",
  "pci_bdf": "$BDF",
  "serial": "${SERIAL//\"/}",
  "model": "${MODEL//\"/}",
  "nsid": $NSID,
  "lba_size": $LBA_SIZE,
  "namespace_blocks": $TOTAL_BLOCKS,
  "gids_slba_base": $SLBA_BASE,
  "gids_block_count": $BLOCK_COUNT
}
EOF

echo "Validated destructive GIDS extent; no data was written."
cat "$OUTPUT"
echo "Next: unbind $BDF from the host nvme driver before starting QEMU."
