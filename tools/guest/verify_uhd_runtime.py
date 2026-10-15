#!/usr/bin/env python3
"""Check the packaged RV64 tools' loader/CLI using user-mode emulation only."""
import argparse
import json
from pathlib import Path
import subprocess


def verify(build, root):
    emulator = build / "host-tools/usr/bin/qemu-riscv64-static"
    prefix = [str(emulator), "-L", str(root), "-cpu",
              "rv64,v=false,zba=false,zbb=false,zbs=false", "-E",
              "LD_LIBRARY_PATH=/opt/uhd/lib"]
    # The official tools deliberately return different codes for --help.
    help_codes = {"uhd_find_devices": 0, "uhd_usrp_probe": 1,
                  "benchmark_rate": 255, "rx_samples_to_file": 255}
    records = []
    for name, expected in help_codes.items():
        command = prefix + [str(root / "opt/uhd/bin" / name), "--help"]
        result = subprocess.run(command, text=True, capture_output=True, timeout=60)
        output = result.stdout + result.stderr
        (build / "logs" / f"{name}-riscv-help.log").write_text(output)
        if result.returncode != expected or "Allowed options" not in output:
            raise RuntimeError(f"{name} CLI failed ({result.returncode}): {output}")
        records.append({"tool": name, "command": command, "exit": result.returncode,
                        "expected_help_exit": expected, "status": "CLI loaded"})
        print(f"PASS: {name} RISC-V loader and CLI")
    command = prefix + [str(root / "opt/uhd/bin/uhd_usrp_probe"), "--version"]
    result = subprocess.run(command, text=True, capture_output=True, timeout=60)
    if result.returncode or result.stdout.strip() != "4.11.0.0":
        raise RuntimeError(f"UHD version check failed: {result.stdout}{result.stderr}")
    records.append({"tool": "uhd_usrp_probe --version", "exit": 0,
                    "output": result.stdout, "root": str(root)})
    (build / "runtime-verification.json").write_text(json.dumps(records, indent=2) + "\n")
    print("PASS: UHD 4.11.0.0; physical USB not accessed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    verify(args.build.resolve(), args.root.resolve())
