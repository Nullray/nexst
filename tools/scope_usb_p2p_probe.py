#!/usr/bin/env python3
"""Pre-boot NM37/B650 No-op P2P test. Default prints a plan; --run changes hardware."""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
PCI = Path('/sys/bus/pci/devices')
BDF = re.compile(r'[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]')


def require(ok, message):
    if not ok:
        raise ValueError(message)


def check_busy(paths):
    if not paths:
        return
    result = subprocess.run(['fuser', '-s', *map(str, paths)], check=False)
    require(result.returncode == 1, 'A selected FPGA/USB device is open, or fuser could not check it.')


def check_storage_unmounted(controller, sysfs=Path('/sys'), proc=Path('/proc')):
    devices = {}
    for block in (sysfs / 'class/block').iterdir():
        if controller.resolve() in block.resolve().parents:
            devices[(block / 'dev').read_text().strip()] = block.name
            require(not any((block / 'holders').iterdir()), f'{block.name} has a block-device holder.')
    for mountinfo in proc.glob('[0-9]*/mountinfo'):
        try:
            rows = mountinfo.read_text().splitlines()
        except FileNotFoundError:
            continue
        for row in rows:
            fields = row.split()
            if len(fields) > 2 and fields[2] in devices:
                raise ValueError(f'{devices[fields[2]]} is mounted in a process mount namespace.')
    for row in (proc / 'swaps').read_text().splitlines()[1:]:
        path = Path(row.split()[0])
        if path.exists():
            info = path.stat()
            if stat.S_ISBLK(info.st_mode):
                require(f'{os.major(info.st_rdev)}:{os.minor(info.st_rdev)}' not in devices,
                        'A B650 block device is used as swap.')
    nodes = [Path('/dev') / name for name in devices]
    return [node for node in nodes if node.exists()]


def stop_child(child, disable_bme):
    if child is None or child.poll() is not None:
        return
    child.terminate()
    try:
        child.wait(timeout=8)
    except subprocess.TimeoutExpired:
        disable_bme()
        child.kill()
        child.wait(timeout=8)


def recover(unbound, quiesce, reset, bind):
    """Keep test RAM alive and the controller unbound if DMA shutdown fails."""
    if unbound:
        quiesce()
        try:
            reset()
        finally:
            bind()
    else:
        reset()


def run(args):
    out = ROOT / 'build/nanhu-host'
    binary = out / 'xhci-p2p-noop'
    util = ROOT / 'tools/proto/pcie-util'
    fpga, xhci = PCI / args.fpga_bdf, PCI / args.xhci_bdf
    require(os.geteuid() == 0, '--run requires sudo.')
    require(binary.is_file() and util.is_file(), 'Build xhci-p2p-noop and tools/proto/pcie-util first.')
    require((fpga / 'vendor').read_text().strip() == '0x10ee' and
            (fpga / 'device').read_text().strip() == '0x903f', 'Expected NM37 10ee:903f.')
    require((xhci / 'vendor').read_text().strip() == '0x1022' and
            (xhci / 'device').read_text().strip() == '0x43fd', 'Expected B650 1022:43fd.')
    driver = (xhci / 'driver').resolve()
    require((xhci / 'driver').exists() and driver.name == 'xhci_hcd',
            'Start with B650 bound to xhci_hcd so its ownership can be restored.')
    group = xhci / 'iommu_group'
    require(not group.exists() or (group / 'type').read_text().strip() == 'identity',
            'Identity/no-IOMMU is required.')
    spec = importlib.util.spec_from_file_location('scope_launch', ROOT / 'tools/host/run_host_proxy.py')
    launch = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(launch)
    launch.check_xdma_owner(args.xdma_prefix, args.fpga_bdf)
    fpga_nodes = [Path(args.xdma_prefix + '_' + suffix) for suffix in ('user', 'control', 'bypass')]
    check_busy(fpga_nodes + [xhci / 'resource0'])
    usb_nodes = []
    for usb in Path('/sys/bus/usb/devices').iterdir():
        if xhci.resolve() not in usb.resolve().parents:
            continue
        interface = usb / 'bInterfaceClass'
        require(not interface.exists() or interface.read_text().strip() != '03',
                'A HID device is connected to the selected B650 controller.')
        if (usb / 'busnum').exists() and (usb / 'devnum').exists():
            usb_nodes.append(Path('/dev/bus/usb') / f'{int((usb / "busnum").read_text()):03d}' /
                             f'{int((usb / "devnum").read_text()):03d}')
    check_busy(check_storage_unmounted(xhci) + usb_nodes)
    stem = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + f'-{os.getpid()}'
    record_path = out / f'p2p-probe-{stem}.json'
    record = {'fpga_bdf': args.fpga_bdf, 'xhci_bdf': args.xhci_bdf,
              'physical_p2p_verified': False, 'cleanup_ok': False,
              'scratch_pa': hex(args.scratch_pa), 'started_utc': stem,
              'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
              'fpga_resources': (fpga / 'resource').read_text(),
              'xhci_resources': (xhci / 'resource').read_text()}
    park = out / 'park-bootrom.bin'
    park.write_bytes(bytes.fromhex('6f000000')) # jal zero, 0; CPU spins in bootrom, DMA/L3 runs.
    user = args.xdma_prefix + '_user'
    base = [str(binary), args.fpga_bdf, args.xhci_bdf,
            args.xdma_prefix + '_bypass', hex(args.scratch_pa)]

    def reset():
        subprocess.run([str(util), user, 'write', '0x100000', '1'], check=True, timeout=10)

    def disable_bme():
        fd = os.open(xhci / 'config', os.O_RDWR)
        try:
            command = int.from_bytes(os.pread(fd, 2, 4), 'little')
            require(os.pwrite(fd, ((command | 0x402) & ~4).to_bytes(2, 'little'), 4) == 2,
                    'Cannot disable xHCI BME.')
            require(not int.from_bytes(os.pread(fd, 2, 4), 'little') & 4,
                    'xHCI BME readback remains enabled.')
        finally:
            os.close(fd)

    def quiesce():
        disable_bme()
        subprocess.run([*base, 'stop'], check=True, timeout=12)

    def bind():
        if not (xhci / 'driver').exists():
            (driver / 'bind').write_text(args.xhci_bdf)
        require((xhci / 'driver').exists() and (xhci / 'driver').resolve() == driver,
                'B650 did not rebind to its original host driver.')

    unbound, touched, child = False, False, None
    error = None
    try:
        touched = True
        print('1/4: Park XiangShan CPU in bootrom with SoC/DMA running.', flush=True)
        reset()
        subprocess.run([str(util), user, 'load', '0', '0x10000', str(park)], check=True, timeout=10)
        subprocess.run([str(util), user, 'write', '0x100000', '0'], check=True, timeout=10)
        time.sleep(0.1)
        # Validate the bitstream's coherent alias before releasing host USB ownership.
        print('2/4: Check FPGA coherent-alias CPU read/write; host USB remains bound.', flush=True)
        subprocess.run([*base, 'alias'], check=True, timeout=20)
        record['alias_cpu_rw_verified'] = True
        print('3/4: Temporarily release B650 USB and test physical xHCI No-op DMA.', flush=True)
        unbound = True # Cover errors after unbind has already taken effect.
        (driver / 'unbind').write_text(args.xhci_bdf)
        require(not (xhci / 'driver').exists(), 'B650 unbind did not complete.')
        child = subprocess.Popen([*base, 'noop'])
        require(child.wait(timeout=45) == 0, 'No-op DMA probe failed; P2P remains unverified.')
        record['physical_p2p_verified'] = True
    except BaseException as exception:
        error = exception
        record['error'] = str(exception) or type(exception).__name__
    finally:
        if touched:
            try:
                print('4/4: Stop test DMA, hold XiangShan reset, restore original host USB driver.', flush=True)
                stop_child(child, disable_bme)
                # An unbind write may fail while the original driver is still present.
                actually_unbound = unbound and not (xhci / 'driver').exists()
                recover(actually_unbound, quiesce, reset, bind)
                record['cleanup_ok'] = True
            except BaseException as exception:
                record['cleanup_error'] = str(exception) or type(exception).__name__
                error = exception
                record['physical_p2p_verified'] = False
        record['scope_protocol_and_cache_coherency_verified'] = False
        record_path.write_text(json.dumps(record, indent=2) + '\n')
        print(f'Probe record: {record_path}', flush=True)
    if error is not None:
        raise RuntimeError(f'Probe failed: {error}; see {record_path}') from error
    print('PASS: physical P2P verified; B650 restored to host xhci_hcd; XiangShan held in reset.', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fpga-bdf', default='0000:2a:00.0')
    parser.add_argument('--xhci-bdf', default='0000:c2:00.0')
    parser.add_argument('--xdma-prefix', default='/dev/xdma0')
    parser.add_argument('--scratch-pa', type=lambda value: int(value, 0), default=0x88000000)
    parser.add_argument('--run', action='store_true')
    args = parser.parse_args()
    require(BDF.fullmatch(args.fpga_bdf) and BDF.fullmatch(args.xhci_bdf), 'Invalid PCI BDF.')
    require(re.fullmatch(r'/dev/xdma[0-9]+', args.xdma_prefix), 'Invalid XDMA prefix.')
    require(0x80000000 <= args.scratch_pa <= 0xff800000 and args.scratch_pa % 0x10000 == 0,
            'Scratch must be 64 KiB aligned inside the 2 GiB guest RAM.')
    if not args.run:
        print(f'FPGA {args.fpga_bdf}, xHCI {args.xhci_bdf}, {args.xdma_prefix}, scratch PA {args.scratch_pa:#x}')
        print('With --run: reset SoC, install CPU spin loop, release SoC, check coherent alias,')
        print('temporarily unbind B650, run 8 xHCI No-op DMA commands, halt/reset xHCI,')
        print('hold SoC reset and restore host USB driver. No USB storage commands are sent.')
        return
    def interrupted(*_):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupted)
    lock_path = ROOT / 'build/nanhu-host/p2p-probe.lock'
    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run(args)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exception:
        raise SystemExit(str(exception))
