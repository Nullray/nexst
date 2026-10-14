#!/usr/bin/env bash
set -euo pipefail
qemu_root=$(cd "$(dirname "$0")/qemu" && pwd)
repo_root=$(cd "$qemu_root/../../.." && pwd)
mkdir -p "$repo_root/build/software-logs"
qemu_build_log="$repo_root/build/software-logs/qemu-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$qemu_build_log") 2>&1
echo "QEMU build log: $qemu_build_log"
mkdir -p "$qemu_root/build-kunminghu-scope"
cd "$qemu_root/build-kunminghu-scope"
if [[ ! -f build.ninja ]]; then
    qemu_build_python=${QEMU_BUILD_PYTHON:-python3}
    if ! "$qemu_build_python" -c 'import sys; __import__("tomllib" if sys.version_info >= (3, 11) else "tomli")' 2>/dev/null; then
        qemu_python_cache="$repo_root/build/tool-cache/qemu-python"
        "$qemu_build_python" -m venv --system-site-packages "$qemu_python_cache"
        "$qemu_python_cache/bin/python" -m pip install 'tomli>=1.2.1'
        qemu_build_python="$qemu_python_cache/bin/python"
    fi
    ../configure --python="$qemu_build_python" --target-list=x86_64-softmmu --enable-rdma --disable-docs
fi
ninja -j "${JOBS:-8}" qemu-system-x86_64
