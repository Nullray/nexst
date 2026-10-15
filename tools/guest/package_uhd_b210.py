#!/usr/bin/env python3
"""Package cross-built B210 tools and their ELF dependency closure for initramfs."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


TOOLS = {
    "uhd_find_devices": "utils",
    "uhd_usrp_probe": "utils",
    "benchmark_rate": "examples",
    "rx_samples_to_file": "examples",
}


def elf_info(path):
    header = subprocess.check_output(["readelf", "-h", str(path)], text=True)
    if "ELF64" not in header or "RISC-V" not in header or "double-float ABI" not in header:
        raise ValueError(f"Expected RV64 LP64D ELF: {path}")
    dynamic = subprocess.check_output(["readelf", "-d", str(path)], text=True)
    program = subprocess.check_output(["readelf", "-l", str(path)], text=True)
    needed = re.findall(r"\(NEEDED\).*\[([^\]]+)\]", dynamic)
    interp = re.search(r"Requesting program interpreter: ([^\]]+)", program)
    return needed, interp.group(1) if interp else None


def package(build, output):
    if output.exists() and any(output.iterdir()):
        raise ValueError(f"Output must be empty to avoid stale dependencies: {output}")
    sources = [build / "uhd-build/lib", build / "rootfs/opt/uhd/lib",
               build / "sysroot/usr/lib/riscv64-linux-gnu",
               Path("/usr/riscv64-linux-gnu/lib")]
    records = {}

    def copy(source, relative):
        destination = output / relative.lstrip("/")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination, follow_symlinks=True)
        records[relative] = {"source": str(source.resolve()),
                             "sha256": hashlib.sha256(destination.read_bytes()).hexdigest()}
        return destination

    pending = []
    for name, directory in TOOLS.items():
        pending.append(copy(build / "uhd-build" / directory / name,
                            f"/opt/uhd/bin/{name}"))
        wrapper = output / "usr/bin" / name
        wrapper.parent.mkdir(parents=True, exist_ok=True)
        wrapper.write_text(
            '#!/bin/sh\n'
            'export LD_LIBRARY_PATH=/opt/uhd/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\n'
            'export UHD_IMAGES_DIR=${UHD_IMAGES_DIR:-/opt/uhd/share/uhd/images}\n'
            f'exec /opt/uhd/bin/{name} "$@"\n')
        wrapper.chmod(0o755)

    seen = set()
    dependency_map = {}
    while pending:
        path = pending.pop()
        needed, interp = elf_info(path)
        dependency_map[str(path.relative_to(output))] = needed
        if interp and interp not in records:
            source = Path("/usr/riscv64-linux-gnu/lib") / Path(interp).name
            pending.append(copy(source, interp))
        for name in needed:
            if name in seen:
                continue
            source = next((directory / name for directory in sources
                           if (directory / name).is_file()), None)
            if source is None:
                raise ValueError(f"Missing ELF dependency {name} for {path}")
            # Keep the compiler's GNU runtime at standard loader locations.
            directory = "/lib" if source.parent == sources[-1] else "/opt/uhd/lib"
            pending.append(copy(source, f"{directory}/{name}"))
            seen.add(name)

    image_source = build / "rootfs/opt/uhd/share/uhd/images"
    for name in ["usrp_b200_fw.hex", "usrp_b210_fpga.bin"]:
        copy(image_source / name, f"/opt/uhd/share/uhd/images/{name}")
    for name in ["inventory.json", "manifest.txt"]:
        if (image_source / name).is_file():
            copy(image_source / name, f"/opt/uhd/share/uhd/images/{name}")
    manifest = {"uhd_version": "4.11.0.0", "libusb_version": "1.0.30",
                "architecture": "RV64 LP64D", "tools": list(TOOLS),
                "files": records, "elf_dependencies": dependency_map,
                "status": "Packaged only; physical B210 initialization not tested."}
    (build / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Guest root: {output}")
    print(f"Runtime manifest: {build / 'runtime-manifest.json'}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package(args.build.resolve(), args.output.resolve())
