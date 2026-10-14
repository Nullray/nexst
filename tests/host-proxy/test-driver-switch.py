#!/usr/bin/env python3
"""Verify module switch ordering and rollback without opening hardware."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('driver_switch', ROOT / 'tools/switch_usb_dma32_driver.py')
switch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(switch)


class SwitchChecks(unittest.TestCase):
    def sequence(self, failing=None):
        calls = []
        def step(name):
            def action():
                calls.append(name)
                if name == failing:
                    raise RuntimeError(name + ' failed')
            return action
        actions = [step(name) for name in ('stop USB DMA', 'hold reset', 'unload', 'load new', 'verify', 'restore old')]
        return calls, lambda: switch.switch_sequence(*actions)

    def test_success_stops_dma_before_reset_and_reloads_in_order(self):
        calls, operation = self.sequence()
        operation()
        self.assertEqual(calls, ['stop USB DMA', 'hold reset', 'unload', 'load new', 'verify'])

    def test_dma_stop_failure_preserves_reset_and_old_module(self):
        calls, operation = self.sequence('stop USB DMA')
        with self.assertRaisesRegex(RuntimeError, 'stop USB DMA failed'):
            operation()
        self.assertEqual(calls, ['stop USB DMA'])

    def test_reset_failure_does_not_unload_driver(self):
        calls, operation = self.sequence('hold reset')
        with self.assertRaises(RuntimeError):
            operation()
        self.assertEqual(calls, ['stop USB DMA', 'hold reset'])

    def test_unload_failure_does_not_attempt_insmod(self):
        calls, operation = self.sequence('unload')
        with self.assertRaises(RuntimeError):
            operation()
        self.assertEqual(calls, ['stop USB DMA', 'hold reset', 'unload'])

    def test_load_failure_restores_old_module(self):
        calls, operation = self.sequence('load new')
        with self.assertRaisesRegex(RuntimeError, 'load new failed'):
            operation()
        self.assertEqual(calls[-2:], ['load new', 'restore old'])

    def test_verification_failure_restores_old_module(self):
        calls, operation = self.sequence('verify')
        with self.assertRaisesRegex(RuntimeError, 'verify failed'):
            operation()
        self.assertEqual(calls[-2:], ['verify', 'restore old'])


if __name__ == '__main__':
    unittest.main()
