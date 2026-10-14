#!/usr/bin/env python3
"""Install per-function xHCI DMA mapping into an existing RISC-V Linux tree."""
import argparse
from pathlib import Path
import re

KCONFIG = '''config SCOPE_PCIE_P2P_DMA
\tbool "SCOPE per-function coherent PCIe P2P DMA window"
\tdepends on RISCV && 64BIT
\thelp
\t  Read the SCOPE vendor capability and configure a coherent FPGA DMA
\t  aperture for a physical xHCI function before its driver probes.
\t  Other PCI functions keep their existing DMA mappings.

'''


def install(kernel):
    directory = kernel / "drivers/pci"
    driver_path = directory / "pci-driver.c"
    kconfig_path = directory / "Kconfig"
    header_path = directory / "scope-p2p-dma.h"
    mm_init_path = kernel / "arch/riscv/mm/init.c"
    mm_init = mm_init_path.read_text() if mm_init_path.is_file() else None
    if mm_init is not None:
        # This Nanhu kernel initializes phys_ram_base only for RV32, but
        # derives min_low_pfn from it on RV64 too.  Preserve the actual DRAM
        # lower bound so the per-device DMA coverage check remains strict.
        old = ('\tphys_ram_end = memblock_end_of_DRAM();\n'
               '#ifndef CONFIG_64BIT\n#ifndef CONFIG_XIP_KERNEL\n'
               '\tphys_ram_base = memblock_start_of_DRAM();\n#endif\n')
        new = ('\tphys_ram_end = memblock_end_of_DRAM();\n'
               '#ifndef CONFIG_XIP_KERNEL\n'
               '\tphys_ram_base = memblock_start_of_DRAM();\n#endif\n'
               '#ifndef CONFIG_64BIT\n')
        if old in mm_init:
            if mm_init.count(old) != 1:
                raise ValueError("ambiguous RISC-V boot memory initialization")
            mm_init = mm_init.replace(old, new)
    driver, kconfig = driver_path.read_text(), kconfig_path.read_text()
    header = (Path(__file__).parent / "include/scope-p2p-dma.h").read_text()
    match = re.search(r"static int pci_dma_configure\(struct device \*dev\)\n\{.*?\n\}",
                      driver, flags=re.S)
    if not match:
        raise ValueError("unsupported kernel: pci_dma_configure() was not found")
    function = match.group()
    call = "\tif (!ret)\n\t\tret = scope_p2p_dma_configure(to_pci_dev(dev));\n"
    if "scope_p2p_dma_configure" not in function:
        if function.count("\treturn ret;\n") != 1:
            raise ValueError("unsupported kernel: inspect pci_dma_configure() before patching")
        function = function.replace("\treturn ret;\n", call + "\treturn ret;\n")
        driver = driver[:match.start()] + function + driver[match.end():]
    if '#include "scope-p2p-dma.h"' not in driver:
        marker = '#include "pci.h"\n'
        if driver.count(marker) != 1:
            raise ValueError("unsupported kernel: pci.h include was not found")
        driver = driver.replace(marker, marker + '#include "scope-p2p-dma.h"\n')
    if "config SCOPE_PCIE_P2P_DMA" not in kconfig:
        if kconfig.count("if PCI\n") != 1:
            raise ValueError("unsupported kernel: PCI Kconfig section was not found")
        kconfig = kconfig.replace("if PCI\n", "if PCI\n\n" + KCONFIG)
    if header_path.exists() and header_path.read_text() != header:
        raise ValueError("existing scope-p2p-dma.h differs; review it before replacement")
    # All compatibility checks above finish before writing any files.
    driver_path.write_text(driver)
    kconfig_path.write_text(kconfig)
    header_path.write_text(header)
    if mm_init is not None and mm_init_path.read_text() != mm_init:
        mm_init_path.write_text(mm_init)
    print(f"Installed SCOPE PCI DMA helper: {kernel}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel", type=Path)
    install(parser.parse_args().kernel.resolve())
