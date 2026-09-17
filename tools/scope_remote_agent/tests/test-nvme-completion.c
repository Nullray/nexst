/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Execute the actual completion function with a simulated DMA visibility
 * boundary, not a copy of the completion implementation. */
#include <assert.h>
#include <endian.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "scope_remote_proto.h"
#include "nvme-types.inc"
#define NVME_SC_DATA_XFER (4U << 1)

struct shadow_agent {
    struct queue_state admin_q, io_q;
    struct pending_nvme pending;
};
static struct nvme_cqe dma_cq[2];
static struct nvme_cqe visible_cqe;
static unsigned int barrier_calls, dma_head, step, transfer_calls;
static bool transfer_fails;
static uint16_t expected_status;

static void visibility_barrier(void)
{
    barrier_calls++;
    /* The phase bit was visible first. Other DMA writes become visible here. */
    assert(dma_cq[dma_head].status == visible_cqe.status);
    dma_cq[dma_head] = visible_cqe;
}
#define __sync_synchronize() visibility_barrier()

static int transfer_segments(struct shadow_agent *s, struct pending_nvme *p,
                             bool write_to_peer)
{
    (void)s;
    assert(step++ == 0 && write_to_peer && p->data_len == 131072);
    transfer_calls++;
    return transfer_fails ? -1 : 0;
}
static void commit_admin_completion(struct shadow_agent *s,
                                    const struct pending_nvme *p, uint16_t status)
{
    (void)s;
    (void)p;
    (void)status;
    assert(!"unexpected admin completion");
}
static int send_nvme_completion(struct shadow_agent *s, struct pending_nvme *p,
                                const struct nvme_cqe *cqe, uint16_t status,
                                uint32_t transferred)
{
    (void)s;
    assert(step++ == transfer_calls);
    assert(p->cid == 5058 && le32toh(cqe->result) == 0x12345678);
    assert(status == expected_status);
    assert(transferred == ((expected_status & ~1U) ? 0U : 131072U));
    return 0;
}
static int ring_cq(struct shadow_agent *s, struct queue_state *q)
{
    (void)s;
    assert(step++ == transfer_calls + 1U);
    assert(q->cq_head == (dma_head + 1) % 2);
    return 0;
}

#include "nvme-completion.inc"

static void check_completion(bool phase, unsigned int head,
                              uint16_t device_status, bool rdma_error)
{
    struct shadow_agent s = {
        .io_q = { .qid = 1, .depth = 2, .cq_valid = true,
                  .cq_phase = phase, .cq_head = head, .cq = dma_cq },
        .pending = { .valid = true, .inflight = true, .qid = 1, .cid = 5058,
                     .direction = SCOPE_REMOTE_IO_FROM_DEVICE,
                     .data_len = 131072 },
    };
    step = transfer_calls = barrier_calls = 0;
    transfer_fails = rdma_error;
    dma_head = head;
    memset(dma_cq, 0, sizeof(dma_cq));
    dma_cq[head].status = htole16(!phase);
    assert(poll_physical_completion(&s) == 0);
    assert(barrier_calls == 0 && step == 0 && s.pending.valid);
    visible_cqe = (struct nvme_cqe){ .result = htole32(0x12345678),
        .sq_id = htole16(1), .cid = htole16(5058),
        .status = htole16(device_status | phase) };
    dma_cq[head].status = visible_cqe.status;
    expected_status = rdma_error ? NVME_SC_DATA_XFER : device_status | phase;
    /* send_nvme_completion receives the raw phase too; it strips it on wire. */
    assert(poll_physical_completion(&s) == 1);
    assert(!s.pending.valid && barrier_calls == 1);
    assert(transfer_calls == (device_status ? 0U : 1U));
    assert(s.io_q.cq_phase == (head == 1 ? !phase : phase));
}

int main(void)
{
    for (unsigned int phase = 0; phase < 2; phase++) {
        for (unsigned int head = 0; head < 2; head++) {
            check_completion(phase, head, 0, false);
            check_completion(phase, head, NVME_SC_DATA_XFER, false);
            check_completion(phase, head, 0, true);
        }
    }
    puts("PASS: 12 CQE visibility/phase/wrap/payload-order/error cases");
    return 0;
}
