#!/usr/bin/env python3
"""Backport Linux a808925075fb: enable xHCI IRQs only at protected startup.

Upstream: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=a808925075fb750804a60ff0710614466c396db4
Retain the 5.16 shared_hcd state assignment. No DMA or event handling changes.
"""
import argparse
from pathlib import Path
import install_xhci_irq_diagnostics as diagnostics


OLD_FINISHED = '''static int xhci_run_finished(struct xhci_hcd *xhci)
{
\tif (xhci_start(xhci)) {
\t\txhci_halt(xhci);
\t\treturn -ENODEV;
\t}
\txhci->shared_hcd->state = HC_STATE_RUNNING;
\txhci->cmd_ring_state = CMD_RING_STATE_RUNNING;

\tif (xhci->quirks & XHCI_NEC_HOST)
\t\txhci_ring_cmd_db(xhci);

\txhci_dbg_trace(xhci, trace_xhci_dbg_init,
\t\t\t"Finished xhci_run for USB3 roothub");
\treturn 0;
}
'''

NEW_FINISHED = '''static int xhci_run_finished(struct xhci_hcd *xhci)
{
\tunsigned long flags;
\tu32 temp;

\t/* Backport a808925075fb: keep IRQs disabled until protected startup. */
\tspin_lock_irqsave(&xhci->lock, flags);

\txhci_dbg_trace(xhci, trace_xhci_dbg_init, "Enable interrupts");
\ttemp = readl(&xhci->op_regs->command);
\ttemp |= CMD_EIE;
\twritel(temp, &xhci->op_regs->command);

\txhci_dbg_trace(xhci, trace_xhci_dbg_init, "Enable primary interrupter");
\ttemp = readl(&xhci->ir_set->irq_pending);
\twritel(ER_IRQ_ENABLE(temp), &xhci->ir_set->irq_pending);

\tif (xhci_start(xhci)) {
\t\txhci_halt(xhci);
\t\tspin_unlock_irqrestore(&xhci->lock, flags);
\t\treturn -ENODEV;
\t}
\txhci->shared_hcd->state = HC_STATE_RUNNING;
\txhci->cmd_ring_state = CMD_RING_STATE_RUNNING;

\tif (xhci->quirks & XHCI_NEC_HOST)
\t\txhci_ring_cmd_db(xhci);

\tspin_unlock_irqrestore(&xhci->lock, flags);
\txhci_dbg_trace(xhci, trace_xhci_dbg_init,
\t\t\t"Finished xhci_run for USB3 roothub");
\treturn 0;
}
'''

EARLY_ENABLE = '''\t/* Set the HCD state before we enable the irqs */
\ttemp = readl(&xhci->op_regs->command);
\ttemp |= (CMD_EIE);
\txhci_dbg_trace(xhci, trace_xhci_dbg_init,
\t\t\t"// Enable interrupts, cmd = 0x%x.", temp);
\twritel(temp, &xhci->op_regs->command);

\ttemp = readl(&xhci->ir_set->irq_pending);
\txhci_dbg_trace(xhci, trace_xhci_dbg_init,
\t\t\t"// Enabling event ring interrupter %p by writing 0x%x to irq_pending",
\t\t\txhci->ir_set, (unsigned int) ER_IRQ_ENABLE(temp));
\twritel(ER_IRQ_ENABLE(temp), &xhci->ir_set->irq_pending);

'''


def fix_source(source):
    if source.count(NEW_FINISHED) == 1 and EARLY_ENABLE not in source:
        return source
    if source.count(OLD_FINISHED) != 1 or source.count(EARLY_ENABLE) != 1:
        raise ValueError("unsupported xHCI startup source; inspect before backporting")
    return source.replace(OLD_FINISHED, NEW_FINISHED).replace(EARLY_ENABLE, "")


def install(kernel):
    path = kernel / "drivers/usb/host/xhci.c"
    original = path.read_text()
    clean = diagnostics.clean(original)
    updated = fix_source(clean)
    if updated != clean:
        had_diagnostics = "/* SCOPE_DIAG_BEGIN start_enter */" in original
        path.write_text(updated)
        if had_diagnostics:
            diagnostics.install(kernel)
    print(f"Installed xHCI IRQ startup fix a808925075fb: {kernel}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel", type=Path)
    install(parser.parse_args().kernel.resolve())
