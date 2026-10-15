#!/usr/bin/env python3
"""Compile production stop/free functions with a simulated XDMA engine.

No kernel module or physical device is accessed. Check retention on a busy
engine, retry after it becomes idle, and protection of another transfer.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "shell/software/xdma_drv/XDMA/linux-kernel/xdma/cdev_ctrl.c"


def function(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    # Skip forward declarations.
    if ";" in source[start:opening]:
        start = source.index(signature, source.index(";", start) + 1)
        opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


fixture = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
typedef uint64_t dma_addr_t;
struct xdma_desc { unsigned int words[8]; };
struct xdma_transfer {
    struct xdma_desc *desc_virt;
    unsigned int desc_num;
    dma_addr_t desc_bus;
};
struct engine_regs { unsigned int status; };
struct xdma_engine {
    int lock, running;
    struct xdma_transfer *transfer_list;
    struct engine_regs *regs;
};
struct pci_device { int dev; };
struct xdma_dev {
    int c2h_channel_max;
    struct xdma_engine engine_c2h[2];
    struct pci_device *pdev;
};
struct file { void *private_data; };
struct inode { int unused; };
struct xdma_pci_dev;
struct xdma_cdev {
    unsigned long magic;
    struct xdma_dev *xdev;
    struct xdma_pci_dev *xpdev;
    int lock;
    void *dma32_db_cpu;
    dma_addr_t dma32_db_dma;
    size_t dma32_db_size;
    unsigned int dma32_db_seq;
    struct xdma_transfer *dma32_transfer;
    struct file *dma32_owner;
    bool dma32_removing;
};
struct xdma_pci_dev {
    struct xdma_cdev ctrl_cdev, user_cdev;
    struct xdma_dev *xdev;
    struct pci_device *pdev;
};
static unsigned long jiffies;
static int freed, stops, polls, held_device_refs, nexst_dma32_mutex;
static int *expected_device;
static int xpdev_cnt, master_disabled, interfaces_destroyed, device_closed;
#define XDMA_STAT_BUSY 1U
#define MAGIC_CHAR 0x1234UL
#define msecs_to_jiffies(ms) (ms)
#define time_after_eq(a, b) ((long)((a) - (b)) >= 0)
#define spin_lock_irqsave(lock, flags) do { (flags)=0; assert(!*(lock)); ++*(lock); } while (0)
#define spin_unlock_irqrestore(lock, flags) do { (void)(flags); assert(*(lock)==1); --*(lock); } while (0)
#define spin_lock(lock) do { assert(!*(lock)); ++*(lock); } while (0)
#define spin_unlock(lock) do { assert(*(lock)==1); --*(lock); } while (0)
#define mutex_lock(lock) spin_lock(lock)
#define mutex_unlock(lock) spin_unlock(lock)
#define list_empty(head) (*(head) == NULL)
#define list_first_entry(head, type, member) (*(head))
#define pr_info(...) ((void)0)
#define kfree(pointer) free(pointer)
static void get_device(int *dev) { assert(dev); ++held_device_refs; }
static int char_close(struct inode *inode, struct file *file) {
    (void)inode; (void)file; return 0;
}
static unsigned int read_register(unsigned int *status) { ++polls; return *status; }
static void usleep_range(int low, int high) { (void)low; (void)high; ++jiffies; }
static struct xdma_transfer *engine_cyclic_stop(struct xdma_engine *engine) {
    assert(engine->lock == 1);
    ++stops;
    struct xdma_transfer *transfer = engine->transfer_list;
    engine->transfer_list = NULL;
    engine->running = 0;
    return transfer;
}
static void dma_free_coherent(int *dev, size_t size, void *cpu, dma_addr_t dma) {
    (void)size; (void)dma;
    assert(dev == expected_device);
    ++freed;
    free(cpu);
}
static void pci_clear_master(struct pci_device *pdev) { assert(pdev); master_disabled = 1; }
static int pci_wait_for_pending_transaction(struct pci_device *pdev) {
    assert(pdev && master_disabled); return 1;
}
static void xpdev_destroy_interfaces(struct xdma_pci_dev *parent) {
    assert(master_disabled && !parent->ctrl_cdev.dma32_transfer);
    assert(!parent->ctrl_cdev.dma32_db_cpu); ++interfaces_destroyed;
}
static void xpdev_destroy_uart(struct xdma_pci_dev *parent) { assert(parent); }
static void xdma_device_close(struct pci_device *pdev, struct xdma_dev *device) {
    assert(pdev && device && interfaces_destroyed); ++device_closed;
}
'''
source = SOURCE.read_text()
for signature in ("static int nexst_cyclic_dma_stop(", "static long dma32_db_free_ioctl(",
                  "void cdev_ctrl_cleanup(", "static int char_ctrl_close(",
                  "static int dma32_db_access("):
    fixture += function(source, signature) + "\n"
fixture += function((SOURCE.parent / "xdma_mod.c").read_text(),
                    "static void xpdev_free(") + "\n"
fixture += r'''
static void allocate(struct xdma_cdev *cdev, struct file *owner) {
    cdev->magic = MAGIC_CHAR;
    cdev->dma32_db_size = 65536;
    cdev->dma32_db_dma = 0x12340000;
    cdev->dma32_db_seq = 7;
    cdev->dma32_db_cpu = calloc(1, cdev->dma32_db_size);
    cdev->dma32_owner = owner;
    cdev->dma32_transfer = calloc(1, sizeof(*cdev->dma32_transfer));
    assert(cdev->dma32_db_cpu && cdev->dma32_transfer);
    cdev->dma32_transfer->desc_virt = calloc(1024, sizeof(struct xdma_desc));
    cdev->dma32_transfer->desc_num = 1024;
    cdev->xdev->engine_c2h[1].transfer_list = cdev->dma32_transfer;
    cdev->xdev->engine_c2h[1].running = 1;
}
int main(void) {
    struct engine_regs regs = {.status = XDMA_STAT_BUSY}, regs2 = {0};
    struct pci_device pci = {1}, pci2 = {2};
    struct xdma_dev device = {.c2h_channel_max = 2, .pdev = &pci};
    struct xdma_dev device2 = {.c2h_channel_max = 2, .pdev = &pci2};
    struct xdma_pci_dev parent = {0}, parent2 = {0};
    struct xdma_cdev *cdev = &parent.ctrl_cdev;
    struct xdma_cdev *fresh = &parent2.ctrl_cdev;
    struct file owner = {.private_data = cdev}, stranger = {.private_data = cdev};
    struct file owner2 = {.private_data = fresh};
    struct inode inode = {0};
    cdev->xdev = &device; cdev->xpdev = &parent;
    fresh->xdev = &device2; fresh->xpdev = &parent2;
    device.engine_c2h[1].regs = &regs;
    device2.engine_c2h[1].regs = &regs2;
    expected_device = &pci.dev;
    allocate(cdev, &owner);
    void *buffer = cdev->dma32_db_cpu;
    struct xdma_transfer *transfer = cdev->dma32_transfer;
    assert(dma32_db_access(cdev, &owner, false) == 0);
    assert(dma32_db_access(cdev, &stranger, false) == -EBUSY);
    assert(dma32_db_access(cdev, &stranger, true) == 0);
    assert(char_ctrl_close(&inode, &stranger) == 0 && freed == 0);
    assert(dma32_db_free_ioctl(cdev) == -ETIMEDOUT);
    assert(stops == 1 && freed == 0 && jiffies == 100);
    assert(cdev->dma32_db_cpu == buffer && cdev->dma32_db_size == 65536);
    assert(cdev->dma32_db_seq == 7 && cdev->dma32_transfer == transfer);
    assert(!device.engine_c2h[1].lock);
    /* A fresh probe cannot discover, free or inherit the previous device. */
    assert(dma32_db_free_ioctl(fresh) == 0 && freed == 0);
    assert(cdev->dma32_transfer == transfer);
    regs.status = 0;
    assert(char_ctrl_close(&inode, &owner) == 0);
    assert(freed == 2 && stops == 1);
    assert(!cdev->dma32_db_cpu && !cdev->dma32_transfer && !cdev->dma32_owner);
    assert(dma32_db_free_ioctl(cdev) == 0 && freed == 2);
    /* remove frees each device through its original allocation device. */
    allocate(cdev, &owner);
    cdev_ctrl_cleanup(cdev);
    assert(freed == 4 && cdev->dma32_removing && !cdev->dma32_transfer);
    assert(dma32_db_access(cdev, &owner, true) == -ENODEV);
    expected_device = &pci2.dev;
    allocate(fresh, &owner2);
    cdev_ctrl_cleanup(fresh);
    assert(freed == 6 && !fresh->dma32_db_cpu && !held_device_refs);
    /* Failed owner close retains memory and clears the closing file ptr. */
    cdev->dma32_removing = false;
    expected_device = &pci.dev;
    allocate(cdev, &owner);
    regs.status = XDMA_STAT_BUSY;
    assert(char_ctrl_close(&inode, &owner) == -ETIMEDOUT);
    assert(!cdev->dma32_owner && cdev->dma32_db_cpu && freed == 6);
    cdev_ctrl_cleanup(cdev);
    assert(held_device_refs == 1 && cdev->dma32_db_cpu && freed == 6);
    /* Test fixture cleanup after simulated hardware becomes idle. */
    regs.status = 0;
    assert(dma32_db_free_ioctl(cdev) == 0 && freed == 8);
    /* Reject a different transfer in the selected engine. */
    struct xdma_transfer other = {0}, retained = {0};
    cdev->dma32_transfer = &retained;
    device.engine_c2h[1].transfer_list = &other;
    assert(dma32_db_free_ioctl(cdev) == -EBUSY);
    assert(device.engine_c2h[1].transfer_list == &other && cdev->dma32_transfer == &retained);
    assert(freed == 8 && !device.engine_c2h[1].lock);
    /* Exercise the real PCI remove helper, not just its cleanup callee. */
    device.engine_c2h[1].transfer_list = NULL;
    struct xdma_pci_dev *removed = calloc(1, sizeof(*removed));
    removed->xdev = &device; removed->pdev = &pci;
    removed->ctrl_cdev.xdev = &device;
    removed->ctrl_cdev.xpdev = removed;
    allocate(&removed->ctrl_cdev, NULL);
    xpdev_cnt = 1;
    xpdev_free(removed);
    assert(freed == 10 && !xpdev_cnt && interfaces_destroyed == 1 && device_closed == 1);
    puts("PASS: production DMA32 lifecycle: stop timeout retention, close ownership, remove/reprobe isolation, original allocation device, failed-remove retention, foreign queue protection");
}
'''
with tempfile.TemporaryDirectory(prefix="scope-dma32-lifecycle-") as directory:
    test = Path(directory) / "test.c"
    binary = Path(directory) / "test"
    test.write_text(fixture)
    subprocess.run(["cc", "-std=gnu11", "-O2", "-g", "-Wall", "-Wextra",
                    "-Werror", "-fsanitize=address,undefined",
                    "-fno-omit-frame-pointer", str(test), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
