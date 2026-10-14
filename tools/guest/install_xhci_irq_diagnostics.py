#!/usr/bin/env python3
"""Enable/remove bounded logs in the real guest xHCI driver (no test traffic)."""
import argparse
from pathlib import Path
import re


def block(name, body):
    return f"/* SCOPE_DIAG_BEGIN {name} */\n{body}\n/* SCOPE_DIAG_END {name} */\n"


def clean(source):
    return re.sub(r"/\* SCOPE_DIAG_BEGIN (\w+) \*/\n.*?"
                  r"/\* SCOPE_DIAG_END \1 \*/\n", "", source, flags=re.S)


def insert(source, anchor, addition, before=False):
    if source.count(anchor) != 1:
        raise ValueError(f"unsupported xHCI source at {anchor!r}")
    return source.replace(anchor, addition + anchor if before else anchor + addition)


HELPER = r'''static void scope_diag_event(struct xhci_hcd *xhci,
                             unsigned int id, const char *stage, u32 status)
{
    struct xhci_ring *ring = xhci->event_ring;
    union xhci_trb *trb;
    dma_addr_t bus;

    if (!ring || !ring->dequeue) {
        xhci_info(xhci, "SCOPE-DIAG irq=%u %s status=%08x no-event-ring\n",
                  id, stage, status);
        return;
    }
    trb = ring->dequeue;
    bus = xhci_trb_virt_to_dma(ring->deq_seg, trb);
    xhci_info(xhci,
              "SCOPE-DIAG irq=%u %s status=%08x xhc_state=%x bus=%pad cycle=%u words=%08x,%08x,%08x,%08x\n",
              id, stage, status, xhci->xhc_state, &bus, ring->cycle_state,
              le32_to_cpu(READ_ONCE(trb->generic.field[0])),
              le32_to_cpu(READ_ONCE(trb->generic.field[1])),
              le32_to_cpu(READ_ONCE(trb->generic.field[2])),
              le32_to_cpu(READ_ONCE(trb->generic.field[3])));
}'''


def install(kernel, disable=False):
    directory = kernel / "drivers/usb/host"
    ring_path, start_path = directory / "xhci-ring.c", directory / "xhci.c"
    originals = {path: path.read_text() for path in (ring_path, start_path)}
    sources = {path: clean(source) for path, source in originals.items()}
    if not disable:
        ring = insert(sources[ring_path], "irqreturn_t xhci_irq(struct usb_hcd *hcd)\n",
                      block("event_helper", HELPER), before=True)
        ring = insert(ring, "\tint event_loop = 0;\n",
                      block("irq_locals", "    unsigned int scope_diag_id = 0;\n"
                            "    static unsigned int scope_diag_pending;\n"
                            "    static unsigned int scope_diag_spurious;"))
        ring = insert(ring, "\tstatus = readl(&xhci->op_regs->status);\n",
                      block("irq_entry", '''    if (IS_ENABLED(CONFIG_SCOPE_PCIE_P2P_DMA)) {
        /* Log at most eight pending and two spurious interrupts per boot. */
        if ((status & STS_EINT) && scope_diag_pending < 8)
            scope_diag_id = ++scope_diag_pending;
        else if (!(status & STS_EINT) && scope_diag_spurious < 2)
            scope_diag_id = 100 + ++scope_diag_spurious;
        if (scope_diag_id)
            scope_diag_event(xhci, scope_diag_id, "enter", status);
    }'''))
        ring = insert(ring, "out:\n\tspin_unlock(&xhci->lock);\n",
                      block("irq_exit", '''    if (scope_diag_id)
        scope_diag_event(xhci, scope_diag_id, "exit", status);'''), before=True)
        # The exit log must run on every goto out path, while the lock is held.
        exit_block = block("irq_exit", '''    if (scope_diag_id)
        scope_diag_event(xhci, scope_diag_id, "exit", status);''')
        ring = ring.replace(exit_block + "out:\n", "out:\n" + exit_block)
        sources[ring_path] = ring
        start_anchor = "static int xhci_run_finished(struct xhci_hcd *xhci)\n{\n"
        declarations = "\tunsigned long flags;\n\tu32 temp;\n"
        if start_anchor + declarations in sources[start_path]:
            start_anchor += declarations
        start = insert(sources[start_path], start_anchor,
                       block("start_enter", r'''    if (IS_ENABLED(CONFIG_SCOPE_PCIE_P2P_DMA))
        xhci_info(xhci, "SCOPE-DIAG before xhci_start USB3\n");'''))
        start = insert(start, "\txhci->cmd_ring_state = CMD_RING_STATE_RUNNING;\n",
                       block("start_exit", r'''    if (IS_ENABLED(CONFIG_SCOPE_PCIE_P2P_DMA))
        xhci_info(xhci, "SCOPE-DIAG after xhci_start USB3\n");'''))
        sources[start_path] = start
    # Validate both sources before changing either one.
    for path, source in sources.items():
        if source != originals[path]:
            path.write_text(source)
    print(f"xHCI IRQ diagnostics {'disabled' if disable else 'enabled'}: {kernel}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel", type=Path)
    parser.add_argument("--disable", action="store_true")
    args = parser.parse_args()
    install(args.kernel.resolve(), args.disable)
