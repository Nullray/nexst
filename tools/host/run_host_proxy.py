#!/usr/bin/env python3
"""Generate or run the VP1902 host NIC/USB proxy command."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex


def command(args):
    if not re.fullmatch(r"[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]", args.fpga_bdf):
        raise ValueError("--fpga-bdf must use domain:bus:device.function format")
    backends = args.backends.resolve()
    if "," in str(backends):
        raise ValueError("backend configuration path cannot contain a comma")
    configuration = json.loads(backends.read_text())
    devices = configuration.get("devices", [])
    if not devices:
        raise ValueError("backend configuration must contain at least one device")
    if any(device.get("type") == "xhci" for device in devices) and not args.xhci_p2p:
        raise ValueError("physical xHCI requires --xhci-p2p after its P2P preflight")
    resource = Path("/sys/bus/pci/devices") / args.fpga_bdf
    # BAR offsets agree across pdas (NoC remap) and uvhs2 (AXI base 0x10000000).
    properties = [
        "scope-fpga-vswitch,id=scope,bus=scope-rp",
        f"backend-config={backends}", f"fpga-host-bdf={args.fpga_bdf}",
        f"xdma-user-dev={resource / 'resource1'}",
        f"xdma-bypass-dev={resource / 'resource2'}",
        "control-transport=qdma-bridge", "user-bar-size=0x1000000",
        f"qdma-notify-dev=/dev/scope-qdma-{args.fpga_bdf}",
        "qdma-ring-entries=4096",
        "mailbox-offset=0x200000", "ecam-shadow-offset=0x220000",
        "fifo-offset=0x240000", "guest-ddr-base=0x80000000",
        "guest-ddr-size=0x80000000", "bypass-coherent-alias-base=0x100000000",
        "guest-mem-raw-fallback=off",
    ]
    if args.xhci_p2p:
        properties.append("allow-unsafe-xhci-p2p=on")
    return [str(args.qemu.resolve()), "-L", str(Path(__file__).resolve().parent / "qemu/pc-bios"),
            "-machine", "q35", "-S", "-m", "128M",
            "-display", "none", "-monitor", "none", "-serial", "none",
            "-device", "pcie-root-port,id=scope-rp", "-device", ",".join(properties)]


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--board", choices=["pdas", "uvhs2"], required=True)
    parser.add_argument("--fpga-bdf", required=True)
    parser.add_argument("--backends", type=Path, required=True)
    parser.add_argument("--qemu", type=Path, default=root / "tools/host/qemu/build-kunminghu-scope/qemu-system-x86_64")
    parser.add_argument("--xhci-p2p", action="store_true")
    parser.add_argument("--run", action="store_true", help="run QEMU; default prints the command")
    args = parser.parse_args()
    try:
        argv = command(args)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    if args.run:
        if not Path(argv[0]).is_file():
            parser.error("build the host QEMU first with tools/host/build.sh")
        os.execv(argv[0], argv)
    else:
        print(shlex.join(argv))
