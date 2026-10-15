#!/usr/bin/env bash
# Reproduce inherited USB changes without changing existing NIC or FPGA code.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
kernel_only=0
case "${1:-}" in
    "") ;;
    --kernel-only) kernel_only=1 ;;
    *) echo "Usage: $0 [--kernel-only]" >&2; exit 2 ;;
esac
if (( $# > 1 )); then
    echo "Usage: $0 [--kernel-only]" >&2
    exit 2
fi
apply_saved_patch() {
    local repository=$1 baseline=$2 patch_file=$3
    local toplevel
    toplevel=$(git -C "$repository" rev-parse --show-toplevel 2>/dev/null || true)
    if [[ ! -d "$repository" ]]; then
        echo "Missing dependency source: $repository" >&2
        exit 1
    fi
    if [[ "$toplevel" != "$(cd "$repository" && pwd -P)" ]]; then
        python3 "$repo_root/tools/guest/apply_source_snapshot.py" \
            "$repository" "$patch_file" "$baseline" \
            "$repo_root/build/dependency-restore"
        return
    fi
    if [[ $(git -C "$repository" rev-parse HEAD) != "$baseline" ]]; then
        echo "Unsupported dependency baseline: $repository (expected $baseline)" >&2
        exit 1
    fi
    if git -C "$repository" apply --reverse --check "$patch_file" 2>/dev/null; then
        echo "USB dependency patch already present: $(basename "$patch_file")"
    elif git -C "$repository" apply --check "$patch_file" 2>/dev/null; then
        git -C "$repository" apply "$patch_file"
    else
        echo "Dependency differs from saved USB patch: $repository; inspect before applying." >&2
        exit 1
    fi
}
apply_saved_patch "$repo_root/work_farm/software/linux" \
    60f53740f75964f4313e84c6fa19ecf5ae64d8f2 \
    "$repo_root/tools/guest/patches/linux-nanhu-usb.patch"
if (( ! kernel_only )); then
    apply_saved_patch "$repo_root/shell/software/xdma_drv" \
        e63f5a117a5a2cd83738105ea6c7c4b5ac16f6a3 \
        "$repo_root/tools/guest/patches/xdma-uart-kernel-api.patch"
    lifecycle_patch="$repo_root/tools/guest/patches/xdma-dma32-lifecycle.patch"
    if git -C "$repo_root/shell/software/xdma_drv" apply \
        --reverse --check "$lifecycle_patch" 2>/dev/null; then
        # The lifecycle patch changes the packet-ring postimage. Verify its
        # saved hashes rather than rejecting the earlier patch's new blob.
        apply_saved_patch "$repo_root/shell/software/xdma_drv" \
            e63f5a117a5a2cd83738105ea6c7c4b5ac16f6a3 "$lifecycle_patch"
    else
        apply_saved_patch "$repo_root/shell/software/xdma_drv" \
            e63f5a117a5a2cd83738105ea6c7c4b5ac16f6a3 \
            "$repo_root/tools/guest/patches/xdma-dma32-packet-ring.patch"
        apply_saved_patch "$repo_root/shell/software/xdma_drv" \
            e63f5a117a5a2cd83738105ea6c7c4b5ac16f6a3 "$lifecycle_patch"
    fi
fi
