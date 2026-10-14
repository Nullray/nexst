#!/usr/bin/env python3
"""No hardware: verify probe ownership recovery and mounted-storage rejection."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('p2p_probe', ROOT / 'tools/scope_usb_p2p_probe.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ProbeRecovery(unittest.TestCase):
    def test_dma_is_quiesced_before_ram_reset_and_host_bind(self):
        calls = []
        probe.recover(True, lambda: calls.append('halt'), lambda: calls.append('reset'),
                      lambda: calls.append('bind'))
        self.assertEqual(calls, ['halt', 'reset', 'bind'])

    def test_failed_dma_shutdown_preserves_test_ram_and_unbound_controller(self):
        reset, bind = Mock(), Mock()
        with self.assertRaises(RuntimeError):
            probe.recover(True, Mock(side_effect=RuntimeError('halt failed')), reset, bind)
        reset.assert_not_called()
        bind.assert_not_called()

    def test_reset_failure_still_restores_host_after_successful_shutdown(self):
        bind = Mock()
        with self.assertRaises(RuntimeError):
            probe.recover(True, Mock(), Mock(side_effect=RuntimeError('reset failed')), bind)
        bind.assert_called_once()

    def test_alias_failure_before_unbind_keeps_usb_owned_by_host(self):
        halt, reset, bind = Mock(), Mock(), Mock()
        probe.recover(False, halt, reset, bind)
        halt.assert_not_called()
        reset.assert_called_once()
        bind.assert_not_called()

    def test_forced_child_kill_disables_bme_first(self):
        calls = []
        child = Mock()
        child.poll.return_value = None
        child.terminate.side_effect = lambda: calls.append('terminate')
        child.wait.side_effect = [subprocess.TimeoutExpired('probe', 8), 0]
        child.kill.side_effect = lambda: calls.append('kill')
        probe.stop_child(child, lambda: calls.append('BME off'))
        self.assertEqual(calls, ['terminate', 'BME off', 'kill'])

    def test_mount_in_another_process_namespace_blocks_controller_takeover(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sys, proc = root / 'sys', root / 'proc'
            controller = sys / 'devices/pci0000:bc/0000:c2:00.0'
            block = controller / 'usb3/disk/block/sdg1'
            (block / 'holders').mkdir(parents=True)
            (block / 'dev').write_text('8:97\n')
            (sys / 'class/block').mkdir(parents=True)
            (sys / 'class/block/sdg1').symlink_to(block)
            (proc / '123').mkdir(parents=True)
            (proc / '123/mountinfo').write_text('42 20 8:97 / /disk ro - ext4 /dev/sdg1 ro\n')
            (proc / 'swaps').write_text('Filename Type Size Used Priority\n')
            with self.assertRaisesRegex(ValueError, 'mounted'):
                probe.check_storage_unmounted(controller, sys, proc)


if __name__ == '__main__':
    unittest.main()
