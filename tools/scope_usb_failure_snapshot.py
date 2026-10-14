#!/usr/bin/env python3
"""Read-only snapshot of current NM37/B650 command/event DMA state.

Uses the audited pcie-util read command (one volatile 32-bit MMIO load).
Never writes PCI config, MMIO, FPGA memory, or driver bindings.
"""
import argparse
from datetime import datetime, timezone
import json
import mmap
import os
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PCI = Path('/sys/bus/pci/devices')
FPGA = PCI / '0000:2a:00.0'
XHCI = PCI / '0000:c2:00.0'
UTIL = ROOT / 'tools/proto/pcie-util'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def capture_transport(record):
    require(os.geteuid() == 0, '--capture requires sudo.')
    require(FPGA.resolve() in Path('/sys/class/xdma/xdma0_control').resolve().parents,
            'XDMA control instance is not the expected NM37.')
    require((FPGA / 'vendor').read_text().strip() == '0x10ee' and
            (FPGA / 'device').read_text().strip() == '0x903f', 'NM37 identity changed.')
    require(not (XHCI / 'driver').exists(), 'Capture the guest-owned failure state before rebinding B650.')
    # Existing launch uses a 64 KiB ring. Map the driver's read-only view of
    # the already allocated coherent host buffer; no ALLOC/FREE/PUT ioctl.
    fd = os.open('/dev/xdma0_control', os.O_RDONLY | os.O_CLOEXEC)
    try:
        with mmap.mmap(fd, 0x10000, flags=mmap.MAP_SHARED, prot=mmap.PROT_READ,
                       offset=0x100000000) as view:
            first, second = view[:], view[:]
    finally:
        os.close(fd)
    frames = []
    unstable = []
    for offset in range(0, len(second), 32):
        if first[offset:offset + 32] != second[offset:offset + 32]:
            unstable.append(offset // 32)
            continue
        magic, kind, flags, length, seq, bar_offset, data, high = struct.unpack_from('<8I', second, offset)
        if magic != 0x5844504b or length != 32 or kind not in (1, 2, 3, 4) or not seq:
            continue
        frames.append({'slot': offset // 32, 'type': kind, 'flags': hex(flags),
                       'seq': seq, 'bar_offset': hex(bar_offset),
                       'data': hex(data), 'high': hex(high)})
    done = [frame for frame in frames if frame['type'] == 4]
    doorbells = [frame for frame in frames if frame['type'] == 2 and
                0x1800 <= int(frame['bar_offset'], 16) < 0x1a00]
    for frame in doorbells:
        frame['matching_done_slots'] = [other['slot'] for other in done
            if other['seq'] == frame['seq'] and other['bar_offset'] == frame['bar_offset']
            and (int(other['flags'], 16) & 0xffff) == (int(frame['flags'], 16) & 0xffff)]
    record['transport'] = {'bytes': len(second), 'valid_frames': len(frames),
                           'unstable_slots': unstable, 'doorbells': doorbells,
                           'done_packets': done, 'frames': frames}
    record['note'] = 'Read-only copy of existing 64 KiB DMA32 host buffer; stable slots retained. Ring contents do not include arrival timestamps and older packets may have been overwritten.'
    print('Transport frames:', len(frames), 'doorbells:', json.dumps(doorbells),
          'DONE packets:', len(done), flush=True)


def capture(record):
    require(os.geteuid() == 0, '--capture requires sudo for physical register reads.')
    for path, vendor, device in ((FPGA, '0x10ee', '0x903f'), (XHCI, '0x1022', '0x43fd')):
        require((path / 'vendor').read_text().strip() == vendor and
                (path / 'device').read_text().strip() == device, 'PCI identity changed: ' + path.name)
    require(not (XHCI / 'driver').exists(), 'B650 is owned by a host driver; snapshot only the guest-owned failure state.')
    require(FPGA.resolve() in Path('/sys/class/xdma/xdma0_bypass').resolve().parents,
            'XDMA instance is not the expected NM37.')
    require(UTIL.is_file(), 'Build tools/proto/pcie-util first.')
    resources = [(tuple(int(field, 16) for field in line.split()))
                 for line in (FPGA / 'resource').read_text().splitlines()[:6]]
    bars = [(index, start, end) for index, (start, end, flags) in enumerate(resources)
            if flags & 0x200 and start and end >= start]
    require(bars and bars[-1][0] == 2, 'Expected NM37 BAR2.')
    _, bar_base, bar_end = bars[-1]
    size = bar_end - bar_base + 1
    record['fpga_bar2'] = {'base': hex(bar_base), 'size': hex(size)}
    config = (XHCI / 'config').read_bytes()
    record['physical_pci_command'] = hex(int.from_bytes(config[4:6], 'little'))
    record['physical_bme'] = bool(int.from_bytes(config[4:6], 'little') & 4)
    registers = record.setdefault('registers', {})

    def word(device, offset):
        print(f'READ {device} + {offset:#x}', flush=True)
        result = subprocess.run([str(UTIL), str(device), 'read', hex(offset)],
                                text=True, capture_output=True, timeout=8, check=True)
        return int(result.stdout.strip(), 16)

    def reg(name, offset):
        value = word(XHCI / 'resource0', offset)
        registers[name] = {'offset': hex(offset), 'value': hex(value)}
        return value

    cap = reg('CAPLENGTH_HCIVERSION', 0)
    require(cap != 0xffffffff, 'Physical BAR reads return all ones.')
    op = cap & 0xff
    x_start, x_end, _ = map(lambda value: int(value, 16), (XHCI / 'resource').read_text().splitlines()[0].split())
    x_size = x_end - x_start + 1
    require(0x20 <= op <= x_size - 0x440, 'Invalid xHCI operational offset.')
    ports = reg('HCSPARAMS1', 4) >> 24
    require(op + 0x400 + min(ports, 18) * 0x10 <= x_size, 'Port registers exceed BAR0.')
    reg('HCCPARAMS1', 0x10)
    runtime = reg('RTSOFF', 0x18) & ~31
    reg('DBOFF', 0x14)
    require(runtime >= 0x20 and runtime + 0x40 <= x_size, 'Invalid runtime offset.')
    command = reg('USBCMD', op)
    status = reg('USBSTS', op + 4)
    crcr = reg('CRCR_LO', op + 0x18) | reg('CRCR_HI', op + 0x1c) << 32
    dcbaa = reg('DCBAAP_LO', op + 0x30) | reg('DCBAAP_HI', op + 0x34) << 32
    reg('CONFIG', op + 0x38)
    reg('IMAN0', runtime + 0x20)
    reg('IMOD0', runtime + 0x24)
    entries = reg('ERSTSZ0', runtime + 0x28) & 0xffff
    erst = reg('ERSTBA0_LO', runtime + 0x30) | reg('ERSTBA0_HI', runtime + 0x34) << 32
    erdp = reg('ERDP0_LO', runtime + 0x38) | reg('ERDP0_HI', runtime + 0x3c) << 32
    record['controller'] = {'run': bool(command & 1), 'interrupt_enable': bool(command & 4),
                            'halted': bool(status & 1), 'host_system_error': bool(status & 4),
                            'host_controller_error': bool(status & (1 << 12)),
                            'command_ring_running': bool(crcr & 8)}
    for port in range(1, min(ports, 18) + 1):
        reg(f'PORTSC{port}', op + 0x400 + (port - 1) * 0x10)

    def dma(label, bus, count):
        bus &= ~0xf
        offset = bus - bar_base
        if not (0x180000000 <= offset and offset + count * 4 <= min(size, 0x200000000)):
            record.setdefault('skipped', []).append({'label': label, 'bus': hex(bus),
                'reason': 'DMA pointer outside configured coherent guest RAM; CRCR pointer reads may be unavailable.'})
            return []
        values = [word('/dev/xdma0_bypass', offset + index * 4) for index in range(count)]
        record.setdefault('memory', {})[label] = {'bus': hex(bus), 'bypass_offset': hex(offset),
                                                'words': [f'{value:08x}' for value in values]}
        return values

    dma('command_ring', crcr & ~0x3f, 16)
    dma('dcbaa', dcbaa & ~0x3f, 8)
    table = dma('erst', erst & ~0x3f, min(entries, 4) * 4) if entries else []
    for index in range(len(table) // 4):
        base = table[index * 4] | table[index * 4 + 1] << 32
        dma(f'event_segment_{index}', base, 16)
    dma('event_dequeue', erdp & ~0xf, 16)
    record['note'] = 'Post-failure, non-atomic reads; guest recovery may have stopped rings or changed registers. No hardware writes issued.'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', action='store_true')
    parser.add_argument('--transport-only', action='store_true',
                        help='copy the existing DMA32 host ring without any physical BAR reads')
    args = parser.parse_args()
    if not args.capture:
        print('With sudo --capture: read B650 PCI command, dynamic xHCI registers/ports, and bounded command/event DDR words; save JSON. Add --transport-only to copy the existing DMA32 host ring instead. No writes/resets/unbinds.')
        return 0
    record = {'captured_utc': datetime.now(timezone.utc).isoformat()}
    output = ROOT / 'build/nanhu-host' / f'usb-failure-{datetime.now():%Y%m%d-%H%M%S}-{os.getpid()}.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        if args.transport_only:
            capture_transport(record)
        else:
            capture(record)
        return 0
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        record['error'] = str(error)
        print('Capture stopped:', error, flush=True)
        return 1
    finally:
        output.write_text(json.dumps(record, indent=2) + '\n')
        output.chmod(0o644)
        print('Snapshot:', output, flush=True)


if __name__ == '__main__':
    raise SystemExit(main())
