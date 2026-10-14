#!/usr/bin/env python3
"""Replay an early pending port IRQ against the actual startup C functions."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/guest"))
import install_xhci_start_fix as fix
import install_xhci_irq_diagnostics as diag

SHIM = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
typedef uint32_t u32;
#define CMD_RUN 1
#define CMD_EIE 4
#define XHCI_NEC_HOST 1
#define HC_STATE_RUNNING 1
#define CMD_RING_STATE_RUNNING 1
#define ER_IRQ_ENABLE(v) ((v) | 2)
#define xhci_dbg_trace(...) ((void)0)
struct usb_hcd { int state; };
struct ops { u32 command; };
struct ir { u32 irq_pending; };
struct xhci_hcd {
    struct ops *op_regs;
    struct ir *ir_set;
    struct usb_hcd *shared_hcd;
    int lock, quirks, cmd_ring_state, xhc_state;
};
static struct xhci_hcd *controller;
static bool irq_disabled, port_event_pending, fail_start;
static int ignored, consumed;
static void deliver_irq(void)
{
    if (irq_disabled || !port_event_pending ||
        !(controller->op_regs->command & CMD_EIE) ||
        !(controller->ir_set->irq_pending & 2))
        return;
    if (controller->xhc_state) {
        ignored++;
        /* Old driver ACKs EHB but leaves this port event unconsumed. */
    } else {
        consumed++;
        port_event_pending = false;
    }
}
static u32 readl(u32 *reg) { return *reg; }
static void writel(u32 value, u32 *reg) { *reg = value; deliver_irq(); }
#define spin_lock_irqsave(lock, flags) do { \
    (void)(lock); (flags) = irq_disabled; irq_disabled = true; \
} while (0)
#define spin_unlock_irqrestore(lock, flags) do { \
    (void)(lock); irq_disabled = (flags); deliver_irq(); \
} while (0)
static int xhci_start(struct xhci_hcd *xhci)
{
    writel(xhci->op_regs->command | CMD_RUN, &xhci->op_regs->command);
    if (fail_start)
        return -ETIMEDOUT;
    xhci->xhc_state = 0;
    return 0;
}
static void xhci_halt(struct xhci_hcd *xhci)
{
    xhci->op_regs->command &= ~(CMD_RUN | CMD_EIE);
    xhci->xhc_state = 2;
}
static void xhci_ring_cmd_db(struct xhci_hcd *xhci)
{
    (void)xhci;
    deliver_irq();
}
'''

MAIN = r'''
int main(void)
{
    for (int masked = 0; masked <= 1; masked++) {
        for (int failure = 0; failure <= 1; failure++) {
            struct ops op = {0};
            struct ir ir = {0};
            struct usb_hcd shared = {0};
            struct xhci_hcd xhci = {
                .op_regs = &op, .ir_set = &ir, .shared_hcd = &shared,
                .quirks = XHCI_NEC_HOST, .xhc_state = 2
            };
            controller = &xhci;
            irq_disabled = masked;
            port_event_pending = true;
            fail_start = failure;
            ignored = consumed = 0;
            primary_start(&xhci);
            int ret = xhci_run_finished(&xhci);
            assert(irq_disabled == (bool)masked);
            assert(ret == (failure ? -ENODEV : 0));
            if (!masked && EXPECT_EARLY_IRQS)
                assert(ignored > 0);
            else
                assert(ignored == 0);
            if (!EXPECT_EARLY_IRQS && !masked && !failure) {
                assert(consumed == 1 && !port_event_pending);
                assert(shared.state == HC_STATE_RUNNING);
                assert(xhci.cmd_ring_state == CMD_RING_STATE_RUNNING);
            }
            if (failure)
                assert(!(op.command & (CMD_RUN | CMD_EIE)));
        }
    }
}
'''


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    for old in (True, False):
        finished = fix.OLD_FINISHED if old else fix.NEW_FINISHED
        kernel = os.environ.get("SCOPE_GUEST_KERNEL")
        if kernel and not old:
            source = diag.clean((Path(kernel) / "drivers/usb/host/xhci.c").read_text())
            assert fix.fix_source(source) == source
            finished = re.search(r"static int xhci_run_finished\(.*?\n}\n",
                                 source, re.S).group()
        primary = "static void primary_start(struct xhci_hcd *xhci)\n{\n"
        primary += "u32 temp __attribute__((unused));\n(void)xhci;\n"
        primary += fix.EARLY_ENABLE if old else ""
        primary += "}\n"
        path = root / "startup.c"
        path.write_text(SHIM + finished + primary + MAIN)
        binary = root / "startup"
        subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                        f"-DEXPECT_EARLY_IRQS={int(old)}", str(path), "-o", str(binary)],
                       check=True)
        subprocess.run([str(binary)], check=True)
        print("PASS: " + ("old startup reproduces ignored early IRQs" if old else
                          "fixed startup consumes event after RUN; failure restores IRQ mask"))
