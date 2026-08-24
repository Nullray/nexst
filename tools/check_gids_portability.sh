#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check_gids_portability.sh [--repo PATH] [--vortex-home PATH]

Read-only preflight for moving the SCOPE GIDS source tree to another host.
It checks repository identity, submodule pins, generated-build source paths,
toolchains, required GIDS files, and the shared queue ABI.
EOF
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$SCRIPT_DIR/.." && pwd)
VORTEX_HOME=${VORTEX_HOME:-/home/yanjiarun/Vortex_16}

while (($#)); do
  case "$1" in
    --repo) REPO=$(cd -- "$2" && pwd); shift 2 ;;
    --vortex-home) VORTEX_HOME=$(cd -- "$2" && pwd); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

require_file() {
  [[ -f $1 ]] || fail "missing required file: $1"
}

for tree in "$REPO" "$REPO/qemu-mount" "$VORTEX_HOME"; do
  git -C "$tree" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    fail "not a Git worktree: $tree"
done

echo "Source revisions:"
printf '  nexst  %s %s\n' \
  "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" \
  "$(git -C "$REPO" rev-parse HEAD)"
printf '  qemu   %s %s\n' \
  "$(git -C "$REPO/qemu-mount" rev-parse --abbrev-ref HEAD)" \
  "$(git -C "$REPO/qemu-mount" rev-parse HEAD)"
printf '  vortex %s %s\n' \
  "$(git -C "$VORTEX_HOME" rev-parse --abbrev-ref HEAD)" \
  "$(git -C "$VORTEX_HOME" rev-parse HEAD)"

while IFS= read -r status; do
  [[ -z $status ]] && continue
  case ${status:0:1} in
    -|+|U) fail "top-level submodule is not at its recorded commit: $status" ;;
  esac
done < <(git -C "$REPO" submodule status --recursive 2>/dev/null || true)

require_file "$REPO/qemu-mount/hw/misc/scope_fpga_vswitch_gids.c"
require_file "$REPO/qemu-mount/include/hw/misc/scope_vortex_gids_abi.h"
require_file "$VORTEX_HOME/sw/kernel/include/vx_gids.h"
require_file "$VORTEX_HOME/tests/regression/gids_io/main.cpp"
require_file "$REPO/vswitch-backends-vortex-gids.json"

if [[ -f $REPO/qemu-mount/build/build.ninja ]] &&
   ! grep -Fq "$REPO/qemu-mount" "$REPO/qemu-mount/build/build.ninja"; then
  fail "qemu-mount/build was configured from another source tree; remove it and rerun configure"
fi

if [[ -f $VORTEX_HOME/config.mk ]] &&
   grep -Eq '^VORTEX_HOME[[:space:]]*\?=' "$VORTEX_HOME/config.mk" &&
   ! grep -Fq "$VORTEX_HOME" "$VORTEX_HOME/config.mk"; then
  fail "Vortex config.mk records a different VORTEX_HOME; regenerate it or pass VORTEX_HOME explicitly"
fi

if [[ -x /opt/riscv64-linux/bin/riscv64-unknown-linux-gnu-g++ ]]; then
  echo "RISC-V compiler: /opt/riscv64-linux/bin/riscv64-unknown-linux-gnu-g++"
elif command -v riscv64-linux-gnu-g++ >/dev/null; then
  echo "RISC-V compiler: $(command -v riscv64-linux-gnu-g++)"
else
  fail "RISC-V Linux cross compiler not found"
fi

for tool in git ninja python3; do
  command -v "$tool" >/dev/null || fail "required tool not found: $tool"
done

if [[ -x $REPO/tools/check-gids-abi.sh ]]; then
  VORTEX_HOME="$VORTEX_HOME" "$REPO/tools/check-gids-abi.sh" ||
    fail "GIDS ABI check failed"
else
  fail "GIDS ABI checker is missing or not executable"
fi

if ((failures)); then
  echo "GIDS portability preflight failed: $failures issue(s)" >&2
  exit 1
fi

echo "GIDS portability preflight passed"
