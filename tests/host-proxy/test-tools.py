#!/usr/bin/env python3
"""Check relocation, existing-backend preservation and XDMA PCI ownership."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import stat
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


class IntegrationChecks(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
