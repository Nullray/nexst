#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
qemu_root="$repo_root/qemu-mount"
baseline=6a30be82ace2bb045fc75ab1a8815e8f56dd9ba5
usb_published=ca732b08d6fa2805c0fc81d56d295690155e3003
previous_published=bbc8bbb7c1c7a2963a7e274f0ba1ad0df2e7c916
published=4489d38ce7d0c91efff252d2229de297b50b9aad
if [[ ! -d "$qemu_root/.git" ]]; then
    git clone --no-checkout https://github.com/Nullray/qemu.git "$qemu_root"
    git -C "$qemu_root" checkout --detach "$published"
fi
current=$(git -C "$qemu_root" rev-parse HEAD)
case "$current" in
    "$baseline"|"$usb_published"|"$previous_published"|"$published") ;;
    *) echo "Unsupported QEMU revision; expected $published or a supported USB baseline" >&2; exit 1 ;;
esac
apply_once() {
    local patch_file=$1
    if git -C "$qemu_root" apply --reverse --check "$patch_file" 2>/dev/null; then
        echo "QEMU patch already present: $(basename "$patch_file")"
    elif git -C "$qemu_root" apply --check "$patch_file" 2>/dev/null; then
        git -C "$qemu_root" apply "$patch_file"
    else
        echo "QEMU edits differ from $(basename "$patch_file"); inspect before applying." >&2
        exit 1
    fi
}
restart_patch="$repo_root/tools/host/patches/qemu-restart-lifecycle.patch"
# The restart fix changes the old USB patch's manager postimage. Once the
# restart patch is present, verify final source hashes instead of reapplying
# the earlier patch against its changed postimage.
if git -C "$qemu_root" apply --reverse --check "$restart_patch" 2>/dev/null; then
    echo "QEMU restart lifecycle fixes are already present."
else
    case "$current" in
        "$baseline"|"$previous_published")
            apply_once "$repo_root/tools/host/patches/qemu-host-proxy.patch" ;;
        "$usb_published")
            apply_once "$repo_root/tools/host/patches/qemu-xhci-usb-fixes.patch" ;;
        "$published")
            echo "Published QEMU restart fix was modified; inspect the worktree." >&2
            exit 1 ;;
    esac
    apply_once "$restart_patch"
fi
python3 - "$repo_root/doc/nanhu-host-proxy-import.json" "$qemu_root" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
manifest = json.loads(Path(sys.argv[1]).read_text())
root = Path(sys.argv[2])
expected = dict(manifest['unchanged_qemu'])
expected.update({path: entry['current_sha256']
                 for path, entry in manifest['modified_qemu'].items()})
for path, digest in expected.items():
    source = root / path.removeprefix('qemu-mount/')
    if hashlib.sha256(source.read_bytes()).hexdigest() != digest:
        raise SystemExit(f'QEMU source differs from recorded fixes: {source}')
print('QEMU USB/restart source hashes verified.')
PY
