#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
qdma_dir="$repo_root/tools/driver/xdma_drv/QDMA/linux-kernel/driver"
qdma_kernel_dir=${KDIR:-/lib/modules/$(uname -r)/build}
[[ -f "$qdma_kernel_dir/Makefile" ]] || {
    echo "缺少运行中内核的构建目录；请用 KDIR=/path/to/kernel/build 指定。" >&2
    exit 1
}
mkdir -p "$repo_root/build/software-logs"
qdma_log="$repo_root/build/software-logs/qdma-driver-$(date +%Y%m%d_%H%M%S).log"
make -C "$qdma_dir" pf "KDIR=$qdma_kernel_dir" -j "${JOBS:-4}" 2>&1 | tee "$qdma_log"
printf '驱动：%s/src/qdma-pf.ko\n日志：%s\n' "$qdma_dir" "$qdma_log"
