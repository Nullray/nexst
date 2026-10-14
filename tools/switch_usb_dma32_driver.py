#!/usr/bin/env python3
"""Report USB driver state; --switch stops old DMA and loads the built module.

Does not start XiangShan, load DDR, write SD data, or install a system module.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PCI = Path('/sys/bus/pci/devices')
FPGA_BDF = '0000:2a:00.0'
USB_BDF = '0000:c2:00.0'
MODULE = Path('/sys/module/xdma')


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def run(*command):
    print('RUN:', ' '.join(map(str, command)), flush=True)
    result = subprocess.run(list(map(str, command)), text=True, capture_output=True, timeout=15)
    for output in (result.stdout, result.stderr):
        if output.strip():
            print(output.rstrip(), flush=True)
    require(result.returncode == 0, f'Command failed ({result.returncode}): {command[0]}')
    return result.stdout.strip()


def modinfo(field, path):
    return subprocess.check_output(['modinfo', '-F', field, str(path)], text=True).strip()


def driver(device):
    link = device / 'driver'
    return link.resolve(strict=True).name if link.exists() else None


def pci_command(device):
    with (device / 'config').open('rb') as handle:
        handle.seek(4)
        value = handle.read(2)
        require(len(value) == 2, 'Short PCI config read: ' + device.name)
        return int.from_bytes(value, 'little')


def switch_sequence(stop_usb, hold_reset, unload, load_new, verify_new,
                    restore_old):
    """Never reset/reload before DMA shutdown; restore on load/verify failure."""
    stop_usb()
    hold_reset()
    unload()
    try:
        load_new()
        verify_new()
    except Exception:
        restore_old()
        raise


def inspect():
    new = ROOT / 'build/usb-dma32-driver/linux-kernel/xdma/xdma.ko'
    old = ROOT / 'shell/software/xdma_drv/XDMA/linux-kernel/xdma/xdma.ko'
    record = json.loads((ROOT / 'build/usb-dma32-driver/manifest.json').read_text())
    require(record['kernel'] == platform.release(), 'Kernel changed; rebuild with tools/build_usb_dma32_driver.sh.')
    require(Path(record['module']).resolve() == new.resolve(), 'Manifest names a different module.')
    require(hashlib.sha256(new.read_bytes()).hexdigest() == record['module_sha256'], 'New module hash differs from manifest.')
    expected = modinfo('srcversion', new)
    require(expected and modinfo('vermagic', new).startswith(platform.release() + ' '), 'New module does not match running kernel.')
    loaded = (MODULE / 'srcversion').read_text().strip()
    fpga, usb = PCI / FPGA_BDF, PCI / USB_BDF
    print(f'loaded={loaded}\nexpected={expected}', flush=True)
    print(f'FPGA: {driver(fpga)}, PCI COMMAND={pci_command(fpga):#06x}', flush=True)
    print(f'B650: {driver(usb) or "unbound"}, PCI COMMAND={pci_command(usb):#06x}', flush=True)
    return new, old, expected, loaded, fpga, usb


def switch(new, old, expected, loaded, fpga, usb):
    require(os.geteuid() == 0, '--switch requires sudo.')
    require(loaded == modinfo('srcversion', old), 'Loaded driver differs from the saved rollback module; keep current driver.')
    require(modinfo('vermagic', old).startswith(platform.release() + ' '), 'Rollback module does not match kernel.')
    for device, vendor, identity in ((fpga, '0x10ee', '0x903f'), (usb, '0x1022', '0x43fd')):
        require((device / 'vendor').read_text().strip() == vendor and
                (device / 'device').read_text().strip() == identity, 'PCI identity changed: ' + device.name)
    bound = sorted(p.name for p in Path('/sys/bus/pci/drivers/xdma').glob('????:??:??.?'))
    require(bound == [FPGA_BDF], f'XDMA also binds other devices: {bound}; keep driver.')
    require(driver(usb) in (None, 'xhci_hcd'), 'B650 is owned by another driver; keep driver.')
    for name in ('user', 'control', 'bypass'):
        require(fpga.resolve() in Path(f'/sys/class/xdma/xdma0_{name}').resolve().parents,
                'xdma0 belongs to another FPGA.')
    parameters = {p.name: p.read_text().strip() for p in (MODULE / 'parameters').iterdir()}
    require(parameters.get('enable_st_c2h_credit') == '0', 'Credit mode differs from tested ring setup.')
    require(not any((MODULE / 'holders').iterdir()), 'Another kernel module holds XDMA.')
    util = ROOT / 'tools/proto/pcie-util'
    stop = ROOT / 'build/nanhu-host/xhci-p2p-noop'
    require(os.access(util, os.X_OK) and os.access(stop, os.X_OK), 'Build pcie-util and xhci-p2p-noop first.')
    devices = sorted(Path('/dev').glob('xdma0_*')) + sorted(Path('/dev').glob('ttyUL*'))
    if not driver(usb):
        devices.append(usb / 'resource0')
    busy = subprocess.run(['fuser', '-v', *map(str, devices)], timeout=10)
    require(busy.returncode == 1, 'An FPGA/USB/UART device is open or occupancy check failed; exit QEMU/UART first.')
    require((MODULE / 'refcnt').read_text().strip() == '0', 'XDMA reference count is not zero; keep driver.')
    print('PASS: identities, rollback, single FPGA, parameters and occupancy checks', flush=True)

    def stop_usb():
        if driver(usb) is None:
            print('1/4: B650 is unbound; halt/reset old xHCI and disable its DMA.', flush=True)
            run(stop, FPGA_BDF, USB_BDF, '/dev/xdma0_bypass', '0x88000000', 'stop')
            require(not pci_command(usb) & 4, 'B650 DMA remains enabled; preserve guest RAM and old driver.')
        else:
            print('1/4: B650 belongs to host xhci_hcd; host USB ownership is retained.', flush=True)

    def hold_reset():
        command = pci_command(fpga)
        if not command & 2:
            print(f'2/4: Enable FPGA MMIO decoding only: {command:#06x} -> {command | 2:#06x}.', flush=True)
            with (fpga / 'config').open('r+b', buffering=0) as handle:
                handle.seek(4)
                handle.write(struct.pack('<H', command | 2))
            require(pci_command(fpga) == command | 2, 'FPGA MMIO decoding did not enable; keep old driver.')
        print('2/4: Hold XiangShan in reset after USB DMA shutdown.', flush=True)
        run(util, '/dev/xdma0_user', 'write', '0x100000', '1')
        require(run(util, '/dev/xdma0_user', 'read', '0x100000') == '00000001',
                'SoC reset readback failed; keep old driver.')

    def unload():
        require((MODULE / 'refcnt').read_text().strip() == '0', 'XDMA became busy; keep old driver.')
        print('3/4: Unload old XDMA module.', flush=True)
        run('rmmod', 'xdma')

    def load_new():
        print('4/4: Load new module with saved parameters.', flush=True)
        run('insmod', new, *(f'{key}={value}' for key, value in parameters.items()))

    def verify_new():
        require((MODULE / 'srcversion').read_text().strip() == expected, 'Loaded module version differs from expected.')
        require(driver(fpga) == 'xdma', 'New module did not bind NM37.')
        require(sorted(p.name for p in Path('/sys/bus/pci/drivers/xdma').glob('????:??:??.?')) == [FPGA_BDF],
                'New module bound unexpected PCI devices.')
        for name in ('user', 'control', 'bypass'):
            require(Path(f'/dev/xdma0_{name}').exists(), 'New driver device node missing: ' + name)
            require(fpga.resolve() in Path(f'/sys/class/xdma/xdma0_{name}').resolve().parents,
                    'New xdma0 nodes belong to another FPGA.')
        require(run(util, '/dev/xdma0_user', 'read', '0x100000') == '00000001', 'Reset changed after driver probe.')

    def restore_old():
        print('New module load/verification failed; restore saved old module.', flush=True)
        if MODULE.exists():
            run('rmmod', 'xdma')
        run('insmod', old, *(f'{key}={value}' for key, value in parameters.items()))
        require((MODULE / 'srcversion').read_text().strip() == loaded, 'Rollback version verification failed.')
        require(run(util, '/dev/xdma0_user', 'read', '0x100000') == '00000001', 'Reset readback failed after rollback.')
        print('PASS: old module restored; XiangShan remains in reset.', flush=True)

    switch_sequence(stop_usb, hold_reset, unload, load_new, verify_new, restore_old)
    print(f'PASS: loaded={expected}; XiangShan remains in reset. B650 driver={driver(usb) or "unbound"}.', flush=True)
    print('Create a new experiment session and follow Runbook steps 1-6.', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--switch', action='store_true')
    args = parser.parse_args()
    try:
        new, old, expected, loaded, fpga, usb = inspect()
        if loaded == expected:
            print('PASS: new module is already loaded; no hardware changes.', flush=True)
        elif args.switch:
            switch(new, old, expected, loaded, fpga, usb)
        else:
            print('No changes. With sudo --switch: require idle devices, stop unbound B650 DMA,')
            print('enable FPGA MMIO if needed, hold SoC reset, replace module and verify; rollback on load failure.')
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print('STOP:', error, flush=True)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
