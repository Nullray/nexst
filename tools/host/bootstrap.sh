#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"
git submodule update --init tools/host/qemu tools/driver/xdma_drv kmh/software/opensbi
# The QEMU patch includes Nullray/qemu bbc8bbb's xHCI fixes and the local
# SCB1 slave-bridge transport, relative to the pinned 6a30be8 gitlink.
# Source revisions and applicability are recorded in doc/host-proxy-import.json.
apply_patch_if_needed() {
    local repository=$1 patch_file=$2
    if git -C "$repository" apply --check "$patch_file" 2>/dev/null; then
        git -C "$repository" apply "$patch_file"
    elif git -C "$repository" apply --reverse --check "$patch_file" 2>/dev/null; then
        printf '%s: patch already applied.\n' "$repository"
    else
        printf '%s has different edits; review %s before applying.\n' "$repository" "$patch_file" >&2
        exit 1
    fi
}
apply_patch_if_needed tools/host/qemu "$repo_root/tools/host/patches/qemu-host-proxy.patch"
apply_patch_if_needed tools/driver/xdma_drv "$repo_root/tools/host/patches/qdma-hostbuf.patch"
apply_patch_if_needed work_farm "$repo_root/tools/host/patches/work-farm-native-logs.patch"

apply_patch_if_needed kmh/software/opensbi "$repo_root/tools/host/patches/opensbi-scope.patch"
