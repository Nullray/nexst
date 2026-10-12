#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
qemu_root="$repo_root/qemu-mount"
baseline=6a30be82ace2bb045fc75ab1a8815e8f56dd9ba5
published=ca732b08d6fa2805c0fc81d56d295690155e3003
if [[ ! -d "$qemu_root/.git" ]]; then
    git clone --no-checkout https://github.com/Nullray/qemu.git "$qemu_root"
    git -C "$qemu_root" checkout --detach "$published"
fi
current=$(git -C "$qemu_root" rev-parse HEAD)
if [[ "$current" != "$baseline" && "$current" != "$published" ]]; then
    echo "Unsupported QEMU revision; expected $published or original baseline $baseline" >&2
    exit 1
fi
patch_file="$repo_root/tools/host/patches/qemu-host-proxy.patch"
if git -C "$qemu_root" apply --reverse --check "$patch_file" 2>/dev/null; then
    echo "Original Nanhu-G xHCI support is already present; NIC backends are unchanged."
elif git -C "$qemu_root" apply --check "$patch_file" 2>/dev/null; then
    git -C "$qemu_root" apply "$patch_file"
else
    echo "QEMU edits differ from the saved xHCI patch; inspect before applying." >&2
    exit 1
fi
