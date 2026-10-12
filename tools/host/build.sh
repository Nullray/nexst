#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
bash "$repo_root/tools/host/bootstrap.sh"
qemu_root="$repo_root/qemu-mount"
mkdir -p "$qemu_root/build-nanhu-host" "$repo_root/build/software-logs"
log="$repo_root/build/software-logs/qemu-$(date +%Y%m%d_%H%M%S)-$$.log"
echo "Build log: $log"
(
    cd "$qemu_root/build-nanhu-host"
    if [[ ! -f build.ninja ]]; then
        ../configure --target-list=x86_64-softmmu --enable-rdma --disable-docs
    fi
    ninja -j "${JOBS:-8}" qemu-system-x86_64
) 2>&1 | tee "$log"
