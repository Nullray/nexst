#!/usr/bin/env python3
"""Check the imported RV64 bounds fix and version-aware xHCI installer."""
from contextlib import redirect_stdout
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


DMA = module("pci_dma", "tools/guest/install_pci_dma.py")
XHCI = module("xhci_start", "tools/guest/install_xhci_start_fix.py")


class GuestTools(unittest.TestCase):
    def test_rv64_bounds_and_repeat_install(self):
        with tempfile.TemporaryDirectory() as directory:
            kernel = Path(directory)
            pci = kernel / "drivers/pci"
            pci.mkdir(parents=True)
            (pci / "pci-driver.c").write_text(
                '#include "pci.h"\nstatic int pci_dma_configure(struct device *dev)\n'
                '{\n\tint ret = 0;\n\treturn ret;\n}\n')
            (pci / "Kconfig").write_text('if PCI\nendif\n')
            mm = kernel / "arch/riscv/mm/init.c"
            mm.parent.mkdir(parents=True)
            mm.write_text('\tphys_ram_end = memblock_end_of_DRAM();\n'
                          '#ifndef CONFIG_64BIT\n#ifndef CONFIG_XIP_KERNEL\n'
                          '\tphys_ram_base = memblock_start_of_DRAM();\n#endif\n'
                          '#endif\n'
                          '\tmin_low_pfn = phys_ram_base >> 12;\n'
                          '\tmax_pfn = phys_ram_end >> 12;\n')

            def bounds():
                source = kernel / "bounds.c"
                source.write_text('#include <stdio.h>\n#define CONFIG_64BIT 1\n'
                                  'static unsigned long memblock_start_of_DRAM(void) '
                                  '{ return 0x80000000UL; }\n'
                                  'static unsigned long memblock_end_of_DRAM(void) '
                                  '{ return 0x100000000UL; }\n'
                                  'int main(void) { unsigned long phys_ram_base = 0, '
                                  'phys_ram_end, min_low_pfn, max_pfn;\n' + mm.read_text() +
                                  'printf("%lx %lx\\n", min_low_pfn << 12, max_pfn << 12); }\n')
                binary = kernel / "bounds"
                subprocess.run(["cc", str(source), "-o", str(binary)], check=True)
                return subprocess.check_output([str(binary)], text=True).strip()

            self.assertEqual(bounds(), "0 100000000")
            with redirect_stdout(io.StringIO()):
                DMA.install(kernel)
            self.assertEqual(bounds(), "80000000 100000000")
            paths = [mm, pci / "pci-driver.c", pci / "Kconfig", pci / "scope-p2p-dma.h"]
            before = {path: path.read_bytes() for path in paths}
            with redirect_stdout(io.StringIO()):
                DMA.install(kernel)
            self.assertEqual(before, {path: path.read_bytes() for path in paths})

    def test_current_linux_startup_is_already_protected(self):
        # Verify the actual 6.6 implementation, without changing its sources.
        source = (ROOT / "work_farm/software/linux/drivers/usb/host/xhci.c").read_text()
        self.assertTrue(XHCI.protected_startup(source))
        self.assertEqual(XHCI.fix_source(source), source)

    def test_startup_backport_preserves_sources_on_unknown_version(self):
        with tempfile.TemporaryDirectory() as directory:
            kernel = Path(directory)
            path = kernel / "drivers/usb/host/xhci.c"
            path.parent.mkdir(parents=True)
            source = "/* unsupported xHCI version */\n"
            path.write_text(source)
            with self.assertRaisesRegex(ValueError, "unsupported xHCI"):
                XHCI.install(kernel)
            self.assertEqual(path.read_text(), source)


if __name__ == "__main__":
    unittest.main()
