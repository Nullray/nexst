#!/usr/bin/env python3
"""Compile the production descriptor builder with the actual libxdma helpers.

No kernel module is loaded and no PCI device is opened. Check destination
separation, cyclic links, C2H length granularity, and bounded metadata DMA.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DRIVER = ROOT / "shell/software/xdma_drv/XDMA/linux-kernel/xdma"


def function(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


source = (DRIVER / "libxdma.c").read_text()
helpers = "\n".join(function(source, signature) for signature in (
    "int transfer_desc_init(", "void xdma_desc_link(",
    "int xdma_desc_control_set(", "void xdma_desc_set("))
fixture = r'''
#include <assert.h>
#include <endian.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
typedef uint32_t u32;
typedef uint64_t u64;
typedef uint64_t dma_addr_t;
#define cpu_to_le32(v) htole32(v)
#define le32_to_cpu(v) le32toh(v)
#define PCI_DMA_L(v) ((uint32_t)(v))
#define PCI_DMA_H(v) ((uint32_t)((uint64_t)(v) >> 32))
#define DESC_MAGIC 0xad4b0000U
#define LS_BYTE_MASK 0xffU
#define DMA_TO_DEVICE 1
#define DMA_FROM_DEVICE 2
#define WARN_ON(v) assert(!(v))
#define pr_err(...) fprintf(stderr, __VA_ARGS__)
struct xdma_desc {
    u32 control, bytes, src_addr_lo, src_addr_hi;
    u32 dst_addr_lo, dst_addr_hi, next_lo, next_hi;
};
struct xdma_transfer {
    struct xdma_desc *desc_virt;
    dma_addr_t desc_bus;
    int desc_num, dir;
};
'''
fixture += helpers + '\n#include "nexst_dma32_ring.h"\n'
fixture += r'''
static uint64_t address(u32 low, u32 high) {
    return le32toh(low) | (uint64_t)le32toh(high) << 32;
}
static void check_ring(size_t bytes) {
    const dma_addr_t buffer_bus = 0x12340000;
    const dma_addr_t desc_bus = 0x23450000;
    int count = bytes / NEXST_PROXY_RX_SLOT_BYTES;
    struct xdma_desc *descriptors = calloc(count, sizeof(*descriptors));
    struct xdma_transfer transfer = {descriptors, desc_bus, count, DMA_FROM_DEVICE};
    unsigned char *buffer = calloc(1, bytes);
    assert(descriptors && buffer);
    nexst_dma32_ring_init(&transfer, buffer_bus);
    for (int i = 0; i < count; i++) {
        struct xdma_desc *d = descriptors + i;
        uint64_t target = address(d->dst_addr_lo, d->dst_addr_hi);
        uint64_t metadata = address(d->src_addr_lo, d->src_addr_hi);
        uint64_t next = address(d->next_lo, d->next_hi);
        assert(le32toh(d->bytes) == 64);
        assert(target == buffer_bus + (size_t)i * 64);
        assert(metadata == target + 32 && metadata + 8 <= target + 64);
        assert((metadata & 4095) <= 4096 - 8);
        assert(next == desc_bus + (size_t)((i + 1) % count) * sizeof(*d));
        assert(le32toh(d->control) == DESC_MAGIC);
        /* Each TLAST advances to the next descriptor, rather than keeping
         * a write pointer within the current descriptor's unused buffer.
         */
        ((u32 *)(buffer + target - buffer_bus))[0] = i + 1;
        ((u32 *)(buffer + metadata - buffer_bus))[0] = 0x52b40001;
    }
    for (int i = 0; i < count; i++) {
        assert(((u32 *)(buffer + (size_t)i * 64))[0] == (u32)i + 1);
        assert(((u32 *)(buffer + (size_t)i * 64 + 32))[0] == 0x52b40001);
    }
    free(buffer);
    free(descriptors);
}
int main(void) {
    check_ring(4096);
    check_ring(65536);
    check_ring(0x400000);
    puts("PASS: production DMA32 descriptor rings: distinct TLAST slots, cyclic links, 64-byte buffers, bounded metadata");
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix="scope-dma32-ring-") as tmp:
    test = Path(tmp) / "test.c"
    binary = Path(tmp) / "test-ring"
    test.write_text(fixture)
    subprocess.run(["cc", "-std=gnu11", "-O2", "-g", "-Wall", "-Wextra",
                    "-Werror", "-fsanitize=address,undefined",
                    "-fno-omit-frame-pointer", "-I", str(DRIVER),
                    str(test), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
