#!/usr/bin/env python3
"""Check relocation, existing-backend preservation and XDMA PCI ownership."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


CONFIG = module("usb_config", "tools/host/add_usb_backend.py")
LAUNCH = module("launch", "tools/host/run_host_proxy.py")
RAMFS = module("ramfs", "tools/guest/prepare_initramfs.py")
INSTALL = module("install", "tools/guest/install_pci_dma.py")


class IntegrationChecks(unittest.TestCase):
    def test_runtime_overlay_keeps_console_and_rejects_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            overlay = Path(directory)
            tool = overlay / 'opt/uhd/bin/uhd_usrp_probe'
            tool.parent.mkdir(parents=True)
            tool.write_text('fixture')
            tool.chmod(0o755)
            (overlay / 'usr/bin').mkdir(parents=True)
            (overlay / 'usr/bin/uhd_usrp_probe').symlink_to('/opt/uhd/bin/uhd_usrp_probe')
            original = 'dir /usr 755 0 0\ndir /usr/bin 755 0 0\nfile /init /saved/init 755 0 0\n'
            result = RAMFS.add_overlay(original, overlay)
            self.assertEqual(result.count('dir /usr/bin '), 1)
            self.assertIn('file /init /saved/init 755 0 0', result)
            self.assertIn(f'file /opt/uhd/bin/uhd_usrp_probe {tool} 755 0 0', result)
            self.assertIn('slink /usr/bin/uhd_usrp_probe /opt/uhd/bin/uhd_usrp_probe', result)
            (overlay / 'init').write_text('replacement')
            with self.assertRaisesRegex(ValueError, 'conflicts.* /init'):
                RAMFS.add_overlay(original, overlay)

    def test_rv64_dma_ram_bounds_and_repeat_install(self):
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
                source = kernel / 'bounds.c'
                source.write_text('#include <stdio.h>\n#define CONFIG_64BIT 1\n'
                                  'static unsigned long memblock_start_of_DRAM(void) '
                                  '{ return 0x80000000UL; }\n'
                                  'static unsigned long memblock_end_of_DRAM(void) '
                                  '{ return 0x100000000UL; }\n'
                                  'int main(void) { unsigned long phys_ram_base = 0, '
                                  'phys_ram_end, min_low_pfn, max_pfn;\n' + mm.read_text() +
                                  'printf("%lx %lx\\n", min_low_pfn << 12, max_pfn << 12); }\n')
                binary = kernel / 'bounds'
                subprocess.run(['cc', str(source), '-o', str(binary)], check=True)
                return subprocess.check_output([str(binary)], text=True).strip()
            self.assertEqual(bounds(), '0 100000000')
            INSTALL.install(kernel)
            self.assertEqual(bounds(), '80000000 100000000')
            before = {p: p.read_bytes() for p in [mm, pci / 'pci-driver.c',
                                                  pci / 'Kconfig', pci / 'scope-p2p-dma.h']}
            INSTALL.install(kernel)
            self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_existing_configs_preserved(self):
        for path in sorted(ROOT.glob("vswitch-backends*.json")):
            config = json.loads(path.read_text())
            before = json.dumps(config, sort_keys=True)
            result = CONFIG.add_usb(config, "FFFF:00:02.0")
            self.assertEqual(result["devices"][:-1], config["devices"])
            self.assertEqual(before, json.dumps(config, sort_keys=True))
            self.assertEqual(result["devices"][-1]["real-host-bdf"], "ffff:00:02.0")
            self.assertEqual(CONFIG.add_usb(result, "ffff:00:02.0"), result)

    def test_duplicate_bdf_and_capacity(self):
        with self.assertRaises(ValueError):
            CONFIG.add_usb({"version": 1, "devices": [{"type": "igb", "real-host-bdf": "ffff:00:02.0"}]}, "ffff:00:02.0")
        with self.assertRaises(ValueError):
            CONFIG.add_usb({"version": 1, "devices": [{}] * 13}, "ffff:00:02.0")

    def test_original_backend_bytes(self):
        manifest = json.loads((ROOT / "doc/nanhu-host-proxy-import.json").read_text())
        for group in ("unchanged_qemu", "unchanged_hardware"):
            for name, digest in manifest[group].items():
                self.assertEqual(hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), digest)
        for name, record in manifest.get("modified_qemu", {}).items():
            self.assertEqual(hashlib.sha256((ROOT / name).read_bytes()).hexdigest(),
                             record["current_sha256"])

    def test_launch_uses_original_transport(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "backends.json"
            config.write_text(json.dumps({"version": 1, "devices": [{"type": "igb", "real-host-bdf": "ffff:00:03.0"}]}))
            args = argparse.Namespace(fpga_bdf="ffff:00:01.0", xdma_prefix="/dev/xdma3", backends=config, qemu=ROOT / "qemu-mount/build-nanhu-host/qemu-system-x86_64", xhci_p2p=False, intx_retry_pulse=False)
            command = LAUNCH.command(args)
            self.assertIn("xdma-ctrl-dev=/dev/xdma3_control", command[-1])
            self.assertNotIn("bar-fifo", command[-1])
            self.assertNotIn("tap", command[-1])
            config.write_text(json.dumps(CONFIG.add_usb(json.loads(config.read_text()), "ffff:00:02.0")))
            with self.assertRaises(ValueError):
                LAUNCH.command(args)
            args.xhci_p2p = True
            self.assertIn("allow-unsafe-xhci-p2p=on", LAUNCH.command(args)[-1])
            config.write_text("[]")
            with self.assertRaises(ValueError):
                LAUNCH.command(args)

    def test_owner_check_rejects_other_fpga(self):
        with tempfile.TemporaryDirectory() as directory:
            sysfs = Path(directory)
            owner = sysfs / "devices/pci0000:00/ffff:00:01.0/xdma/xdma0_user"
            owner.mkdir(parents=True)
            (sysfs / "dev/char").mkdir(parents=True)
            (sysfs / "dev/char/1:3").symlink_to(owner)
            info = argparse.Namespace(st_mode=stat.S_IFCHR, st_rdev=259)
            with patch.object(Path, "stat", return_value=info):
                LAUNCH.check_xdma_owner("/dev/xdma0", "ffff:00:01.0", sysfs)
                with self.assertRaises(ValueError):
                    LAUNCH.check_xdma_owner("/dev/xdma0", "ffff:00:02.0", sysfs)

    def test_manifest_relocation_and_missing_input(self):
        with tempfile.TemporaryDirectory() as directory:
            rootfs = Path(directory)
            (rootfs / "initramfs/bin").mkdir(parents=True)
            (rootfs / "initramfs/bin/busybox").write_text("fixture")
            manifest = "file /bin/busybox /old/nexst/nanhu-g/software/rootfs/initramfs/bin/busybox 755 0 0\n"
            relocated = RAMFS.relocate(manifest, rootfs)
            self.assertNotIn("/old/nexst", relocated)
            self.assertIn(str(rootfs), relocated)
            with self.assertRaises(ValueError):
                RAMFS.relocate(manifest.replace("busybox", "missing"), rootfs)

    def test_usb_console_uses_tracked_inputs_instead_of_missing_copied_files(self):
        with tempfile.TemporaryDirectory() as directory:
            rootfs = Path(directory)
            manifest = ("dir /etc 755 0 0\n"
                        "file /init /old/nexst/nanhu-g/software/rootfs/initramfs/init 755 0 0\n"
                        "file /etc/inittab /old/nexst/nanhu-g/software/rootfs/initramfs/etc/inittab 664 0 0\n")
            result = RAMFS.relocate(RAMFS.usb_console_inputs(manifest), rootfs)
            self.assertNotIn("/old/nexst", result)
            inputs = {fields[1]: Path(fields[2]) for line in result.splitlines()
                      if (fields := line.split())[0] == "file"}
            init = inputs["/init"].read_text()
            self.assertIn("exec </dev/hvc0 >/dev/hvc0 2>&1", init)
            self.assertIn("exec /bin/busybox init", init)
            self.assertIn("hvc0::respawn:-/bin/ash", inputs["/etc/inittab"].read_text())
            subprocess.run(["sh", "-n", str(inputs["/init"])], check=True)
            with self.assertRaises(ValueError):
                RAMFS.usb_console_inputs(manifest + manifest)


if __name__ == "__main__":
    unittest.main()
