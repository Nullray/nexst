#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run_storage_path_comparison.sh \
  --mode cpu|gds|gids|all [--cpu-cmd CMD] [--gds-cmd CMD] [--gids-cmd CMD] \
  --io-bytes N --io-count N [--repeats N] [--warmup N] \
  [--output FILE] [--append]

Each command runs with SCOPE_IO_BYTES, SCOPE_IO_COUNT, SCOPE_RUN_INDEX and
SCOPE_SAMPLE_CSV exported. Commands that can report per-I/O latency should
write CSV with a latency_ns column, or GIDS write_service_ns/read_service_ns
columns, to $SCOPE_SAMPLE_CSV. Missing latency samples are recorded as NA.

Use one mode per hardware/QEMU session when the modes require mutually
exclusive ownership of the physical NVMe. Run the first mode without
--append, then use --append for the remaining modes.
EOF
}

SELECTED_MODE=all
CPU_CMD=
GDS_CMD=
GIDS_CMD=
IO_BYTES=
IO_COUNT=
REPEATS=3
WARMUP=1
OUTPUT=storage_path_results.csv
APPEND=0

while (($#)); do
  case "$1" in
    --mode) SELECTED_MODE=$2; shift 2 ;;
    --cpu-cmd) CPU_CMD=$2; shift 2 ;;
    --gds-cmd) GDS_CMD=$2; shift 2 ;;
    --gids-cmd) GIDS_CMD=$2; shift 2 ;;
    --io-bytes) IO_BYTES=$2; shift 2 ;;
    --io-count) IO_COUNT=$2; shift 2 ;;
    --repeats) REPEATS=$2; shift 2 ;;
    --warmup) WARMUP=$2; shift 2 ;;
    --output) OUTPUT=$2; shift 2 ;;
    --append) APPEND=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $SELECTED_MODE =~ ^(cpu|gds|gids|all)$ &&
   $IO_BYTES =~ ^[1-9][0-9]*$ && $IO_COUNT =~ ^[1-9][0-9]*$ &&
   $REPEATS =~ ^[1-9][0-9]*$ && $WARMUP =~ ^[0-9]+$ ]] || {
  usage >&2
  exit 2
}
for required_mode in cpu gds gids; do
  if [[ $SELECTED_MODE == all || $SELECTED_MODE == "$required_mode" ]]; then
    case "$required_mode" in
      cpu) required_cmd=$CPU_CMD ;;
      gds) required_cmd=$GDS_CMD ;;
      gids) required_cmd=$GIDS_CMD ;;
    esac
    [[ -n $required_cmd ]] || {
      echo "--${required_mode}-cmd is required for mode $SELECTED_MODE" >&2
      exit 2
    }
  fi
done
command -v /usr/bin/time >/dev/null || {
  echo "/usr/bin/time is required" >&2
  exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
RESULT_DIR=${OUTPUT%.*}.artifacts
mkdir -p "$RESULT_DIR"
HEADER='mode,run,bytes,ios,elapsed_s,bandwidth_MBps,iops,user_s,sys_s,cpu_pct,p50_ns,p95_ns,p99_ns,rc,log'
if ((APPEND)); then
  [[ -s $OUTPUT && $(head -n 1 "$OUTPUT") == "$HEADER" ]] || {
    echo "--append requires an existing result file with the expected header: $OUTPUT" >&2
    exit 2
  }
else
  printf '%s\n' "$HEADER" >"$OUTPUT"
fi

summarize_latency() {
  python3 - "$1" <<'PY'
import csv, math, os, sys
path = sys.argv[1]
if not os.path.isfile(path) or os.path.getsize(path) == 0:
    print("NA,NA,NA")
    raise SystemExit
values = []
with open(path, newline="") as stream:
    for row in csv.DictReader(stream):
        if row.get("latency_ns") not in (None, ""):
            values.append(int(float(row["latency_ns"])))
        else:
            for key in ("write_service_ns", "read_service_ns"):
                if row.get(key) not in (None, ""):
                    values.append(int(float(row[key])))
if not values:
    print("NA,NA,NA")
    raise SystemExit
values.sort()
def pct(p):
    return values[min(len(values) - 1, math.ceil(p * len(values)) - 1)]
print(f"{pct(.50)},{pct(.95)},{pct(.99)}")
PY
}

run_one() {
  local mode=$1 run=$2 command=$3 measured=$4
  local artifact_dir=$TMP
  if ((measured)); then
    artifact_dir=$RESULT_DIR
  fi
  local sample="$artifact_dir/${mode}-${run}.samples.csv"
  local timing="$TMP/${mode}-${run}.time"
  local log="$artifact_dir/${mode}-${run}.log"
  local rc=0

  export SCOPE_IO_BYTES=$IO_BYTES SCOPE_IO_COUNT=$IO_COUNT
  export SCOPE_RUN_INDEX=$run SCOPE_SAMPLE_CSV=$sample
  /usr/bin/time -f '%e,%U,%S,%P' -o "$timing" \
    bash -o pipefail -lc "$command" >"$log" 2>&1 || rc=$?
  IFS=, read -r elapsed user sys cpu <"$timing"
  local total_bytes=$((IO_BYTES * IO_COUNT))
  local bw iops latency
  bw=$(awk -v b="$total_bytes" -v t="$elapsed" 'BEGIN {printf "%.6f", b/t/1000000}')
  iops=$(awk -v n="$IO_COUNT" -v t="$elapsed" 'BEGIN {printf "%.6f", n/t}')
  latency=$(summarize_latency "$sample")
  if ((measured)); then
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$mode" "$run" "$total_bytes" "$IO_COUNT" "$elapsed" "$bw" \
      "$iops" "$user" "$sys" "$cpu" ${latency//,/ } "$rc" "$log" \
      | tr ' ' ',' >>"$OUTPUT"
  fi
  if ((measured && rc)); then
    echo "$mode run $run failed (rc=$rc), log=$log" >&2
    return "$rc"
  fi
}

for mode in cpu gds gids; do
  [[ $SELECTED_MODE == all || $SELECTED_MODE == "$mode" ]] || continue
  case "$mode" in
    cpu) command=$CPU_CMD ;;
    gds) command=$GDS_CMD ;;
    gids) command=$GIDS_CMD ;;
  esac
  for ((i = 0; i < WARMUP; ++i)); do
    run_one "$mode" "warmup-$i" "$command" 0 || true
  done
  for ((i = 0; i < REPEATS; ++i)); do
    run_one "$mode" "$i" "$command" 1
  done
done

echo "Storage path comparison complete: $OUTPUT"
