#!/usr/bin/env python3
"""Append physical xHCI to an existing SCOPE config, preserving device order."""
import argparse
import copy
import json
from pathlib import Path
import re

BDF_RE = re.compile(r"[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]")


def add_usb(configuration, xhci_bdf):
    if not BDF_RE.fullmatch(xhci_bdf):
        raise ValueError("xHCI BDF must use domain:bus:device.function")
    if not isinstance(configuration, dict) or configuration.get("version") != 1:
        raise ValueError("expected SCOPE backend config version 1")
    devices = configuration.get("devices")
    if not isinstance(devices, list) or not devices or not all(isinstance(d, dict) for d in devices):
        raise ValueError("base config must contain an existing devices list")
    result = copy.deepcopy(configuration)
    xhci_bdf = xhci_bdf.lower()
    for device in devices:
        bdf = str(device.get("real-host-bdf", "")).lower()
        if bdf == xhci_bdf:
            if device.get("type") == "xhci":
                return result
            raise ValueError("selected xHCI BDF is already used by another backend")
    if len(devices) >= 13:
        raise ValueError("SCOPE supports at most 13 endpoints")
    result["devices"].append({"type": "xhci", "real-host-bdf": xhci_bdf})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-backends", type=Path, required=True)
    parser.add_argument("--xhci-bdf", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.output.resolve() == args.base_backends.resolve():
            raise ValueError("output must be a new file; preserve the original NIC config")
        result = add_usb(json.loads(args.base_backends.read_text()), args.xhci_bdf)
        if args.output.exists():
            if json.loads(args.output.read_text()) != result:
                raise ValueError("output already contains different settings")
        else:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(result, indent=2) + "\n")
    except (ValueError, OSError) as error:
        parser.error(str(error))
    print(args.output.resolve())


if __name__ == "__main__":
    main()
