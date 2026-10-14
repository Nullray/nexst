#!/usr/bin/env python3
"""Package an existing SCOPE Linux Image with profile-specific DT/OpenSBI."""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from prepare_profile_dt import render


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--num-cores', type=int, choices=(1, 2), required=True)
    parser.add_argument('--image', type=Path, required=True, help='SCOPE-configured Linux Image; an SMP image supports either profile')
    parser.add_argument('--source', type=Path, default=root / 'kmh/hardware/xs-gen/build/XSTop.dts')
    args = parser.parse_args()
    image = args.image.resolve()
    if not image.is_file() or image.stat().st_size < 4096:
        parser.error('Linux Image is missing or empty')
    dt = render(args.source.read_text(), args.num_cores)
    out = root / f'build/guest-{args.num_cores}core'
    out.mkdir(parents=True, exist_ok=True)
    (out / 'kunminghu-scope.dts').write_text(dt)
    if image != out / 'Image':
        shutil.copy2(image, out / 'Image')
    logdir = root / 'build/software-logs'
    logdir.mkdir(exist_ok=True)
    logpath = logdir / f'firmware-{args.num_cores}core-{datetime.now():%Y%m%d_%H%M%S}.log'
    print(f'Firmware build log: {logpath}', flush=True)
    with logpath.open('w') as log:
        def run(command):
            log.write(repr(command) + '\n')
            log.flush()
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
        run(['dtc', '-I', 'dts', '-O', 'dtb', '-o', str(out / 'kunminghu-scope.dtb'), str(out / 'kunminghu-scope.dts')])
        cross = os.environ.get('CROSS_COMPILE', 'riscv64-linux-gnu-')
        run(['make', '-C', str(root / 'kmh/software/opensbi'), f'O={out / "opensbi"}',
             f'CROSS_COMPILE={cross}', 'PLATFORM=ict', 'SERVE_PLAT=scope', 'RV_TARGET=kunminghu_scope',
             f'HART_COUNT={args.num_cores}', 'WITH_SM=n', f'FW_FDT_PATH={out / "kunminghu-scope.dtb"}',
             f'OPENSBI_PAYLOAD={out / "Image"}', '-j', os.environ.get('JOBS', '4')])
        shutil.copy2(out / 'opensbi/platform/ict/firmware/fw_payload.bin', out / 'RV_BOOT.bin')
        run(['make', '-C', str(root / 'kmh/software/zsbl'), f'O={out}', f'CROSS_COMPILE={cross}'])
    artifacts = {name: sha(out / name) for name in ('Image', 'RV_BOOT.bin', 'bootrom.bin', 'kunminghu-scope.dtb')}
    (out / 'SHA256SUMS').write_text(''.join(f'{value}  {name}\n' for name, value in artifacts.items()))
    (out / 'FIRMWARE_BUILD.json').write_text(json.dumps({
        'num_cores': args.num_cores, 'cpu_kind': 'kunminghu', 'status': 'compiled',
        'input_linux_image': str(image), 'native_dt': str(args.source.resolve()),
        'artifacts': artifacts, 'log': str(logpath), 'board_validated': False,
    }, indent=2) + '\n')
    print(f'Firmware complete: {out}')


if __name__ == '__main__':
    main()
