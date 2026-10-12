#!/usr/bin/env python3
"""Read-only inventory and preflight for physical xHCI ownership by XiangShan."""
import argparse
import json
from pathlib import Path
import re
import sys

BDF_RE = re.compile(r"[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$")


def bdf(value):
    if not BDF_RE.fullmatch(value):
        raise argparse.ArgumentTypeError("expected domain:bus:device.function")
    return value.lower()


def read(path):
    return path.read_text().strip()


def resources(device):
    return [tuple(int(v, 16) for v in line.split())
            for line in read(device / "resource").splitlines()[:6]]


def hierarchy(device):
    nodes = [p for p in device.resolve().parts if BDF_RE.fullmatch(p)]
    return nodes, nodes[0] if nodes else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xhci-bdf", type=bdf)
    parser.add_argument("--fpga-bdf", type=bdf)
    parser.add_argument("--guest-base", type=lambda v: int(v, 0), default=0x80000000)
    parser.add_argument("--guest-size", type=lambda v: int(v, 0), default=0x80000000)
    parser.add_argument("--coherent-alias", type=lambda v: int(v, 0), default=0x100000000)
    parser.add_argument("--allow-cross-root", action="store_true",
                        help="acknowledge that cross-root P2P was verified separately")
    parser.add_argument("--config-out", type=Path)
    parser.add_argument("--sysfs-root", type=Path, default=Path("/sys"))
    args = parser.parse_args()
    pci_root = args.sysfs_root / "bus/pci/devices"
    controllers = [d for d in sorted(pci_root.iterdir())
                   if (d / "class").exists() and read(d / "class") == "0x0c0330"]
    for device in controllers:
        driver = (device / "driver").resolve().name if (device / "driver").exists() else "unbound"
        usb_root = args.sysfs_root / "bus/usb/devices"
        buses = [u.name for u in sorted(usb_root.glob("usb*"))
                 if device.resolve() in u.resolve().parents]
        print(f"{device.name} {read(device / 'vendor')}:{read(device / 'device')} "
              f"driver={driver} USB-buses={','.join(buses) or '-'}")
    if not args.xhci_bdf:
        if args.config_out or args.fpga_bdf:
            parser.error("--xhci-bdf is required for preflight/config output")
        return 0
    if not args.fpga_bdf:
        parser.error("--fpga-bdf is required for preflight")
    target = pci_root / args.xhci_bdf
    fpga = pci_root / args.fpga_bdf
    errors = []
    if target not in controllers:
        errors.append("selected PCI function is not an enumerated xHCI controller")
    if (target / "driver").exists():
        errors.append("target function remains bound; release it before QEMU ownership")
    group = target / "iommu_group"
    if group.exists() and (not (group / "type").exists() or read(group / "type") != "identity"):
        errors.append("host IOMMU domain is translated or unknown; identity/no-IOMMU required")
    if not fpga.exists():
        errors.append("FPGA PCI function is absent")
    if not target.exists() or not fpga.exists():
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    x_path, x_root = hierarchy(target)
    f_path, f_root = hierarchy(fpga)
    print(f"xHCI PCI hierarchy: {' -> '.join(x_path)}")
    print(f"FPGA PCI hierarchy: {' -> '.join(f_path)}")
    if (not x_root or x_root != f_root) and not args.allow_cross_root:
        errors.append("devices have no verified common root port; "
                      "--allow-cross-root requires a separately tested P2P route")
    bars = [(i, start, end) for i, (start, end, flags) in enumerate(resources(fpga))
            if flags & 0x200 and start and end >= start]
    if not bars:
        errors.append("FPGA has no assigned memory BAR")
    else:
        index, start, end = bars[-1]  # same selection rule as current QEMU manager
        needed = args.coherent_alias + args.guest_base + args.guest_size
        if args.guest_base < 0 or args.guest_size <= 0 or args.coherent_alias <= 0 or \
                start + needed > 2**64 - 1 or needed > end - start + 1:
            errors.append("FPGA BAR does not cover the coherent guest DDR aperture")
        else:
            print(f"DMA: guest PA -> {start + args.coherent_alias:#x} + guest PA "
                  f"using FPGA BAR{index}")
    for node in sorted(set(x_path[:-1] + f_path[:-1])):
        try:
            cfg = (pci_root / node / "config").read_bytes()
            off = 0x100
            seen = set()
            while off and off + 8 <= len(cfg) and off not in seen:
                seen.add(off)
                header = int.from_bytes(cfg[off:off + 4], "little")
                if header & 0xffff == 0x0d:
                    control = int.from_bytes(cfg[off + 6:off + 8], "little")
                    print(f"ACS {node}: control={control:#x}")
                    if control & 0x0c and not args.allow_cross_root:
                        errors.append(f"ACS request/completion redirect on {node}; "
                                      "P2P route requires separate validation")
                    break
                off = header >> 20
        except (OSError, ValueError):
            print(f"ACS {node}: unavailable (inspect with sudo lspci -vv)")
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    if errors:
        return 1
    print("Software preflight passed; physical P2P DMA/USB behavior remains to be tested.")
    if args.config_out:
        args.config_out.write_text(json.dumps({
            "version": 1,
            "devices": [{"type": "xhci", "real-host-bdf": args.xhci_bdf}],
        }, indent=2) + "\n")
        print(f"Wrote {args.config_out}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as exc:
        print(f"Preflight failed: {exc}", file=sys.stderr)
        sys.exit(1)
