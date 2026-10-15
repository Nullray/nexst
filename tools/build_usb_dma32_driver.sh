#!/usr/bin/env bash
# Build the USB packet-ring driver in an isolated directory; never load it.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
source_root="$repo_root/shell/software/xdma_drv/XDMA/linux-kernel"
output_root=${1:-$repo_root/build/usb-dma32-driver}
kernel_release=$(uname -r)
test -d "/lib/modules/$kernel_release/build"
test -f "$source_root/xdma/nexst_dma32_ring.h"
python3 - "$source_root" "$output_root/linux-kernel" <<'PY'
from pathlib import Path
import shutil
import sys
source, output = map(Path, sys.argv[1:])
shutil.copytree(source, output, dirs_exist_ok=True,
                ignore=shutil.ignore_patterns('.git', '*.ko', '*.o', '*.mod',
                                             '*.mod.c', '*.cmd', 'Module.symvers',
                                             'modules.order', '.tmp_versions'))
PY
output_root=$(cd "$output_root" && pwd)
make -C "/lib/modules/$kernel_release/build" M="$output_root/linux-kernel/xdma" -j8 modules
python3 - "$output_root" "$source_root" "$kernel_release" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys
output, source = map(Path, sys.argv[1:3])
module = output / 'linux-kernel/xdma/xdma.ko'
record = {'kernel': sys.argv[3], 'module': str(module),
          'module_sha256': hashlib.sha256(module.read_bytes()).hexdigest(),
          'module_srcversion': subprocess.check_output(['modinfo', '-F', 'srcversion', str(module)], text=True).strip(),
          'sources': {name: hashlib.sha256((source / 'xdma' / name).read_bytes()).hexdigest()
                      for name in ('cdev_ctrl.c', 'nexst_dma32_ring.h',
                                   'xdma_mod.c', 'xdma_mod.h', 'xdma_cdev.h')},
          'status': 'Built only; not loaded into the host kernel.'}
(output / 'manifest.json').write_text(json.dumps(record, indent=2) + '\n')
print('Built module:', module)
print('Manifest:', output / 'manifest.json')
PY
