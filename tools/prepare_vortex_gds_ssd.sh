#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_BDF="0000:e1:00.0"
readonly DEFAULT_SERIAL="PHLJ3252006F1P0UGN"
readonly TEST_BYTES=4096
readonly MIN_SAFE_OFFSET=$((1024 * 1024))

bdf="$DEFAULT_BDF"
expected_serial="$DEFAULT_SERIAL"
slba=""
write_pattern=0
confirmation=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  sudo tools/prepare_vortex_gds_ssd.sh --slba SLBA
  sudo tools/prepare_vortex_gds_ssd.sh --slba SLBA --write \
    --confirm ERASE-4096-BYTES-AT-SLBA-SLBA

Options:
  --bdf BDF         NVMe controller BDF (default: 0000:e1:00.0).
  --serial SERIAL   Required controller serial (default: PHLJ3252006F1P0UGN).
  --slba SLBA       4 KiB namespace LBA used by the test; required.
  --write           Write and read back the deterministic 4 KiB pattern.
  --confirm TOKEN   Exact destructive-write confirmation shown by audit mode.

Without --write the script performs all safety checks and prints the checksum
and exact confirmation token. It never partitions or formats the namespace.
EOF
}

while (( "$#" )); do
  case "$1" in
    --bdf)
      (( "$#" >= 2 )) || die "--bdf requires an argument"
      bdf="$2"
      shift 2
      ;;
    --serial)
      (( "$#" >= 2 )) || die "--serial requires an argument"
      expected_serial="$2"
      shift 2
      ;;
    --slba)
      (( "$#" >= 2 )) || die "--slba requires an argument"
      slba="$2"
      shift 2
      ;;
    --write)
      write_pattern=1
      shift
      ;;
    --confirm)
      (( "$#" >= 2 )) || die "--confirm requires an argument"
      confirmation="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run this safety check with sudo"
[[ "$bdf" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] ||
  die "invalid BDF: ${bdf}"
[[ "$slba" =~ ^[0-9]+$ ]] || die "--slba must be a non-negative decimal integer"

pci_dir="/sys/bus/pci/devices/${bdf}"
[[ -d "$pci_dir" ]] || die "PCI function ${bdf} is absent"
[[ "$(<"${pci_dir}/class")" == "0x010802" ]] ||
  die "${bdf} is not an NVMe controller"
[[ -L "${pci_dir}/driver" ]] || die "${bdf} has no bound driver"
[[ "$(basename "$(readlink -f "${pci_dir}/driver")")" == "nvme" ]] ||
  die "${bdf} must still be bound to nvme while preparing the test pattern"

shopt -s nullglob
namespace_dirs=("${pci_dir}"/nvme/nvme*/nvme*n*)
shopt -u nullglob
(( ${#namespace_dirs[@]} == 1 )) ||
  die "expected exactly one namespace below ${bdf}, found ${#namespace_dirs[@]}"
namespace="$(basename "${namespace_dirs[0]}")"
device="/dev/${namespace}"
[[ -b "$device" ]] || die "namespace block device is absent: ${device}"

controller="$(basename "$(dirname "${namespace_dirs[0]}")")"
actual_serial="$(tr -d '[:space:]' < "/sys/class/nvme/${controller}/serial")"
[[ "$actual_serial" == "$expected_serial" ]] ||
  die "${bdf} serial is ${actual_serial}, expected ${expected_serial}"

lba_size="$(<"/sys/class/block/${namespace}/queue/logical_block_size")"
nsid="$(<"${namespace_dirs[0]}/nsid")"
[[ "$lba_size" == "$TEST_BYTES" ]] ||
  die "${device} logical block size is ${lba_size}, expected ${TEST_BYTES}"
[[ "$nsid" == 1 ]] || die "${device} NSID is ${nsid}, expected 1"

offset=$((slba * lba_size))
namespace_bytes=$(( $(<"/sys/class/block/${namespace}/size") * 512 ))
(( offset >= MIN_SAFE_OFFSET )) ||
  die "refusing an offset below 1 MiB; choose a deliberately reserved test LBA"
(( offset <= namespace_bytes - TEST_BYTES )) || die "test range exceeds namespace"

mapfile -t block_nodes < <(lsblk -nrpo NAME "$device")
(( ${#block_nodes[@]} >= 1 )) || die "lsblk did not find ${device}"

if lsblk -nrpo TYPE "$device" | grep -qx part; then
  die "${device} has a partition; refusing to use it as a raw GDS test disk"
fi

for node in "${block_nodes[@]}"; do
  if findmnt -rn -S "$node" >/dev/null; then
    findmnt -rn -S "$node" >&2 || true
    die "${node} is mounted"
  fi
  if swapon --show=NAME --noheadings --raw | grep -Fxq "$node"; then
    die "${node} is active swap"
  fi
  name="$(basename "$node")"
  if [[ -d "/sys/class/block/${name}/holders" ]] &&
     find "/sys/class/block/${name}/holders" -mindepth 1 -maxdepth 1 | grep -q .; then
    die "${node} has a device-mapper/MD holder"
  fi
done

if fuser "${block_nodes[@]}" >/dev/null 2>&1; then
  fuser -v "${block_nodes[@]}" >&2 || true
  die "the namespace is open by another process"
fi

signature_report="$(wipefs -n "$device")"
[[ -z "$signature_report" ]] || {
  echo "$signature_report" >&2
  die "${device} contains a recognized signature"
}

# This is intentionally displayed as a second, independent read-only check.
fdisk -l "$device"

if command -v pvs >/dev/null &&
   pvs --noheadings -o pv_name 2>/dev/null | awk '{$1=$1};1' | grep -Fxq "$device"; then
  die "${device} is an LVM physical volume"
fi
if grep -Eq "(^|[[:space:]])${namespace}([[:space:]]|$)" /proc/mdstat; then
  die "${device} is referenced by MD"
fi

checksum="$(perl -e '
  use integer;
  my $h = 2166136261;
  for (my $i = 0; $i < 1024; ++$i) {
    my $word = 0x47534400 ^ $i;
    $h = (($h ^ $word) * 16777619) & 0xffffffff;
  }
  printf "0x%08x", $h;
')"
confirm_token="ERASE-${TEST_BYTES}-BYTES-AT-SLBA-${slba}"

cat <<EOF
GDS SSD safety audit passed:
  controller : ${bdf}
  namespace  : ${device} (NSID ${nsid}, serial ${actual_serial})
  test range : SLBA ${slba}, byte offset ${offset}, bytes ${TEST_BYTES}
  checksum   : ${checksum}
EOF

if (( ! write_pattern )); then
  cat <<EOF
No data was written. To overwrite exactly this 4 KiB range, rerun with:
  sudo $0 --bdf ${bdf} --serial ${actual_serial} --slba ${slba} \\
    --write --confirm ${confirm_token}
EOF
  exit 0
fi

[[ "$confirmation" == "$confirm_token" ]] ||
  die "destructive confirmation must be exactly: ${confirm_token}"

tmp_dir="$(mktemp -d /tmp/vortex-gds-pattern.XXXXXX)"
pattern_file="${tmp_dir}/pattern.bin"
readback_file="${tmp_dir}/readback.bin"
cleanup() {
  [[ -n "${pattern_file:-}" ]] && rm -f -- "$pattern_file"
  [[ -n "${readback_file:-}" ]] && rm -f -- "$readback_file"
  [[ -n "${tmp_dir:-}" ]] && rmdir -- "$tmp_dir" 2>/dev/null || true
}
trap cleanup EXIT

perl -e '
  for (my $i = 0; $i < 1024; ++$i) {
    print pack("V", 0x47534400 ^ $i);
  }
' > "$pattern_file"
[[ "$(stat -c %s "$pattern_file")" == "$TEST_BYTES" ]] ||
  die "internal pattern generation produced the wrong size"

dd if="$pattern_file" of="$device" bs="$TEST_BYTES" seek="$slba" count=1 \
  oflag=direct conv=fsync,notrunc status=none
dd if="$device" of="$readback_file" bs="$TEST_BYTES" skip="$slba" count=1 \
  iflag=direct status=none
cmp -s "$pattern_file" "$readback_file" || die "SSD readback differs from pattern"

cat <<EOF
Pattern write and direct readback passed.
Run inside Xiangshan Linux:
  vortex-gds_read -l ${slba} -e ${checksum} -d /dev/nvme0n1 -b ${lba_size} -i ${nsid}
EOF
