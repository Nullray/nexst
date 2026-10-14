#!/usr/bin/env python3
"""Backport Linux a808925075fb: enable xHCI IRQs only at protected startup.

Upstream: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=a808925075fb750804a60ff0710614466c396db4
Retain the 5.16 shared_hcd state assignment when backporting. Linux 6.6
already protects startup; verify that implementation and leave it unchanged.
"""
import argparse
from pathlib import Path
import re


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


def protected_startup(source):
    """Recognize the upstream interrupter-based startup used by Linux 6.6."""
    match = re.search(r"static int xhci_run_finished\(struct xhci_hcd \*xhci\)\n"
                      r"\{.*?\n\}\n", source, flags=re.S)
    if not match:
        return False
    function = match.group()
    stages = ["spin_lock_irqsave(&xhci->lock, flags)", "CMD_EIE",
              "xhci_enable_interrupter(ir)", "xhci_start(xhci)",
              "xhci->cmd_ring_state = CMD_RING_STATE_RUNNING"]
    if not all(stage in function for stage in stages):
        return False
    positions = [function.index(stage) for stage in stages]
    return (positions == sorted(positions) and
            function.count("spin_lock_irqsave(&xhci->lock, flags)") == 1 and
            function.count("spin_unlock_irqrestore(&xhci->lock, flags)") == 2 and
            function.rindex("spin_unlock_irqrestore(&xhci->lock, flags)") >
            positions[-1] and EARLY_ENABLE not in source)


def fix_source(source):
    if source.count(NEW_FINISHED) == 1 and EARLY_ENABLE not in source:
        return source
    if protected_startup(source):
        return source
    if source.count(OLD_FINISHED) != 1 or source.count(EARLY_ENABLE) != 1:
        raise ValueError("unsupported xHCI startup source; inspect before backporting")
    return source.replace(OLD_FINISHED, NEW_FINISHED).replace(EARLY_ENABLE, "")


def install(kernel):
    path = kernel / "drivers/usb/host/xhci.c"
    original = path.read_text()
    if "/* SCOPE_DIAG_BEGIN" in original:
        raise ValueError("remove legacy xHCI diagnostics before applying this backport")
    clean = original
    updated = fix_source(clean)
    if updated != clean:
        path.write_text(updated)
    action = "Verified existing" if updated == clean else "Installed"
    print(f"{action} xHCI IRQ startup fix a808925075fb: {kernel}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel", type=Path)
    install(parser.parse_args().kernel.resolve())
