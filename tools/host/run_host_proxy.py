#!/usr/bin/env python3
"""Print or start the existing Nanhu-G SCOPE proxy with automatic logging."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shlex
import stat

BDF_RE = re.compile(r"[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]")


def command(args):
    if not BDF_RE.fullmatch(args.fpga_bdf):
        raise ValueError("--fpga-bdf must use domain:bus:device.function")
    if not re.fullmatch(r"/dev/xdma[0-9]+", args.xdma_prefix):
        raise ValueError("--xdma-prefix must be /dev/xdmaN")
    backends = args.backends.resolve()
    if "," in str(backends):
        raise ValueError("backend configuration path cannot contain a comma")
    configuration = json.loads(backends.read_text())
    devices = configuration.get("devices") if isinstance(configuration, dict) else None
    if not isinstance(configuration, dict) or configuration.get("version") != 1 or not isinstance(devices, list) or not devices or len(devices) > 13:
        raise ValueError("backend config must contain version 1 and 1..13 devices")
    if not all(isinstance(device, dict) for device in devices):
        raise ValueError("each backend must be an object")
    if any(device.get("type") == "xhci" for device in devices) and not args.xhci_p2p:
        raise ValueError("physical xHCI requires --xhci-p2p after its P2P preflight")
    properties = [
        "scope-fpga-vswitch,id=scope,bus=scope-rp",
        f"backend-config={backends}", f"fpga-host-bdf={args.fpga_bdf.lower()}",
        f"xdma-user-dev={args.xdma_prefix}_user",
        f"xdma-ctrl-dev={args.xdma_prefix}_control",
        f"xdma-bypass-dev={args.xdma_prefix}_bypass",
        "guest-ddr-base=0x80000000", "guest-ddr-size=0x80000000",
        "bypass-coherent-alias-base=0x100000000",
        "guest-mem-raw-fallback=off", "dma32-ring-size=0x10000",
    ]
    if args.xhci_p2p:
        properties.append("allow-unsafe-xhci-p2p=on")
    if args.intx_retry_pulse:
        properties.append("intx-retry-pulse=on")
    return [str(args.qemu.resolve()), "-machine", "q35", "-S", "-m", "128M",
            "-display", "none", "-monitor", "none", "-serial", "none",
            "-device", "pcie-root-port,id=scope-rp", "-device", ",".join(properties)]


def check_xdma_owner(prefix, fpga_bdf, sysfs=Path("/sys")):
    for suffix in ("user", "control", "bypass"):
        node = Path(f"{prefix}_{suffix}")
        info = node.stat()
        if not stat.S_ISCHR(info.st_mode):
            raise ValueError(f"{node} is not an XDMA character device")
        entry = sysfs / "dev/char" / f"{os.major(info.st_rdev)}:{os.minor(info.st_rdev)}"
        if not entry.exists():
            raise ValueError(f"cannot verify PCI owner of {node}")
        bdfs = [part.lower() for part in entry.resolve().parts if BDF_RE.fullmatch(part)]
        if not bdfs or bdfs[-1] != fpga_bdf.lower():
            raise ValueError(f"{node} does not belong to FPGA {fpga_bdf}")


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fpga-bdf", required=True)
    parser.add_argument("--xdma-prefix", default="/dev/xdma0")
    parser.add_argument("--backends", type=Path, required=True)
    parser.add_argument("--qemu", type=Path, default=root / "qemu-mount/build-nanhu-host/qemu-system-x86_64")
    parser.add_argument("--xhci-p2p", action="store_true")
    parser.add_argument("--intx-retry-pulse", action="store_true", help="retain this option if used by the existing NIC deployment")
    parser.add_argument("--log", type=Path)
    parser.add_argument("--run", action="store_true", help="run QEMU; default only prints the command")
    args = parser.parse_args()
    try:
        argv = command(args)
        if args.run:
            if not Path(argv[0]).is_file():
                raise ValueError("build QEMU with bash tools/host/build.sh first")
            check_xdma_owner(args.xdma_prefix, args.fpga_bdf)
            log = args.log or root / "build/host-proxy-logs" / f"{datetime.now():%Y%m%d_%H%M%S}_{os.getpid()}.log"
            log.parent.mkdir(parents=True, exist_ok=True)
            with log.open("x") as output:
                print(f"Proxy log: {log.resolve()}", flush=True)
                output.write(shlex.join(argv) + "\n")
                output.flush()
                os.dup2(output.fileno(), 1)
                os.dup2(output.fileno(), 2)
            os.execv(argv[0], argv)
        else:
            print(shlex.join(argv))
    except (ValueError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
