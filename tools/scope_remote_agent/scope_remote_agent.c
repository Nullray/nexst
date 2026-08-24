/* SPDX-License-Identifier: GPL-2.0-or-later */
#define _GNU_SOURCE

#include "scope_remote_proto.h"

#include <arpa/inet.h>
#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <infiniband/verbs.h>
#include <linux/nvme_ioctl.h>
#include <rdma/rdma_cma.h>
#include <rdma/rdma_verbs.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define AGENT_DEFAULT_SERVICE "7471"
#define AGENT_DEFAULT_STAGING (4U * 1024U * 1024U)
#define AGENT_DEFAULT_CAP \
    ((1ULL << 37) | (30ULL << 24) | (1ULL << 16) | 1023ULL)
#define AGENT_DEFAULT_VS 0x00010400U
#define NVME_SC_INVALID_OPCODE (0x01U << 1)
#define NVME_SC_INVALID_FIELD  (0x02U << 1)
#define NVME_SC_DATA_XFER      (0x04U << 1)
#define NVME_SC_INTERNAL       (0x06U << 1)
#define NVME_FEAT_NUM_QUEUES   0x07U
#define NVME_FEAT_IRQ_COALESCE 0x08U
#define NVME_FEAT_IRQ_CONFIG   0x09U
#define NVME_FEAT_ASYNC_EVENT  0x0bU

struct agent_options {
    const char *listen_addr;
    const char *service;
    const char *rdma_device;
    const char *device_id;
    const char *controller;
    const char *namespace_path;
    uint32_t namespace_id;
    size_t staging_size;
};

struct agent_state {
    struct agent_options opt;
    struct rdma_cm_id *listen_id;
    struct rdma_cm_id *id;
    struct ibv_mr *rx_mr;
    struct ibv_mr *tx_mr;
    struct ibv_mr *staging_mr;
    struct scope_remote_message *rx;
    struct scope_remote_message *tx;
    void *staging;
    int ns_fd;
    int ctrl_fd;
    uint64_t session_id;
    uint64_t generation;
    uint64_t peer_base;
    uint64_t peer_length;
    uint32_t peer_rkey;
    uint64_t namespace_blocks;
    uint32_t lba_shift;
    uint32_t feat_irq_coalesce;
    uint32_t feat_async_event;
};

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s --listen ADDR --rdma-device DEV --device-id ID "
            "--controller /dev/nvmeX --namespace /dev/nvmeXnY "
            "[--service 7471] [--namespace-id 1] [--staging-size BYTES]\n",
            prog);
}

static bool parse_u32(const char *text, uint32_t *value)
{
    char *end = NULL;
    unsigned long parsed = strtoul(text, &end, 0);

    if (!text[0] || !end || *end || parsed > UINT32_MAX) {
        return false;
    }
    *value = parsed;
    return true;
}

static bool parse_size(const char *text, size_t *value)
{
    char *end = NULL;
    unsigned long long parsed = strtoull(text, &end, 0);

    if (!text[0] || !end || *end || parsed < 4096 ||
        parsed > UINT32_MAX || (parsed & 4095U)) {
        return false;
    }
    *value = parsed;
    return true;
}

static bool parse_options(int argc, char **argv, struct agent_options *opt)
{
    static const struct option long_opts[] = {
        { "listen", required_argument, NULL, 'l' },
        { "service", required_argument, NULL, 's' },
        { "rdma-device", required_argument, NULL, 'r' },
        { "device-id", required_argument, NULL, 'd' },
        { "controller", required_argument, NULL, 'c' },
        { "namespace", required_argument, NULL, 'n' },
        { "namespace-id", required_argument, NULL, 'i' },
        { "staging-size", required_argument, NULL, 'z' },
        { "help", no_argument, NULL, 'h' },
        { NULL, 0, NULL, 0 },
    };
    int ch;

    *opt = (struct agent_options) {
        .service = AGENT_DEFAULT_SERVICE,
        .namespace_id = 1,
        .staging_size = AGENT_DEFAULT_STAGING,
    };
    while ((ch = getopt_long(argc, argv, "l:s:r:d:c:n:i:z:h",
                             long_opts, NULL)) != -1) {
        switch (ch) {
        case 'l': opt->listen_addr = optarg; break;
        case 's': opt->service = optarg; break;
        case 'r': opt->rdma_device = optarg; break;
        case 'd': opt->device_id = optarg; break;
        case 'c': opt->controller = optarg; break;
        case 'n': opt->namespace_path = optarg; break;
        case 'i':
            if (!parse_u32(optarg, &opt->namespace_id) ||
                !opt->namespace_id) {
                return false;
            }
            break;
        case 'z':
            if (!parse_size(optarg, &opt->staging_size)) {
                return false;
            }
            break;
        default:
            return false;
        }
    }
    return opt->listen_addr && opt->rdma_device && opt->device_id &&
           opt->controller && opt->namespace_path &&
           strlen(opt->device_id) < SCOPE_REMOTE_MAX_DEVICE_ID;
}

static int poll_wc(struct ibv_cq *cq, enum ibv_wc_opcode expected)
{
    struct ibv_wc wc;

    for (;;) {
        int ret = ibv_poll_cq(cq, 1, &wc);

        if (ret < 0) {
            return -1;
        }
        if (!ret) {
            usleep(20);
            continue;
        }
        if (wc.status != IBV_WC_SUCCESS || wc.opcode != expected) {
            fprintf(stderr, "RDMA completion failed: opcode=%u status=%s\n",
                    wc.opcode, ibv_wc_status_str(wc.status));
            return -1;
        }
        return 0;
    }
}

static int post_recv(struct agent_state *s)
{
    memset(s->rx, 0, sizeof(*s->rx));
    return rdma_post_recv(s->id, s->rx, s->rx, sizeof(*s->rx), s->rx_mr);
}

static int wait_recv(struct agent_state *s)
{
    return poll_wc(s->id->recv_cq, IBV_WC_RECV);
}

static void init_response(struct agent_state *s, uint16_t opcode,
                          uint64_t request_id, uint32_t payload_len,
                          int32_t status)
{
    memset(s->tx, 0, sizeof(*s->tx));
    s->tx->hdr.magic = htole32(SCOPE_REMOTE_MAGIC);
    s->tx->hdr.major = htole16(SCOPE_REMOTE_PROTO_MAJOR);
    s->tx->hdr.minor = htole16(SCOPE_REMOTE_PROTO_MINOR);
    s->tx->hdr.opcode = htole16(opcode);
    s->tx->hdr.payload_len = htole32(payload_len);
    s->tx->hdr.session_id = htole64(s->session_id);
    s->tx->hdr.request_id = htole64(request_id);
    s->tx->hdr.generation = htole64(s->generation);
    s->tx->hdr.status = htole32(status);
}

static int send_response(struct agent_state *s, size_t payload_len)
{
    size_t length = sizeof(s->tx->hdr) + payload_len;

    if (rdma_post_send(s->id, s->tx, s->tx, length, s->tx_mr,
                       IBV_SEND_SIGNALED)) {
        return -1;
    }
    return poll_wc(s->id->send_cq, IBV_WC_SEND);
}

static bool validate_header(struct agent_state *s,
                            const struct scope_remote_message *msg,
                            bool first)
{
    if (le32toh(msg->hdr.magic) != SCOPE_REMOTE_MAGIC ||
        le16toh(msg->hdr.major) != SCOPE_REMOTE_PROTO_MAJOR ||
        le16toh(msg->hdr.minor) > SCOPE_REMOTE_PROTO_MINOR ||
        le32toh(msg->hdr.payload_len) > sizeof(msg->payload) ||
        le32toh(msg->hdr.reserved)) {
        return false;
    }
    if (!first && (le64toh(msg->hdr.session_id) != s->session_id ||
                   le64toh(msg->hdr.generation) != s->generation)) {
        return false;
    }
    return true;
}

static int rdma_payload(struct agent_state *s, bool write_to_peer,
                        uint64_t remote_addr, void *local, uint32_t length)
{
    struct ibv_sge sge = {
        .addr = (uintptr_t)local,
        .length = length,
        .lkey = s->staging_mr->lkey,
    };
    struct ibv_send_wr wr = {
        .wr_id = (uintptr_t)local,
        .sg_list = &sge,
        .num_sge = 1,
        .opcode = write_to_peer ? IBV_WR_RDMA_WRITE : IBV_WR_RDMA_READ,
        .send_flags = IBV_SEND_SIGNALED,
        .wr.rdma = {
            .remote_addr = remote_addr,
            .rkey = s->peer_rkey,
        },
    };
    struct ibv_send_wr *bad = NULL;

    if (remote_addr < s->peer_base || length > s->peer_length ||
        remote_addr - s->peer_base > s->peer_length - length) {
        errno = ERANGE;
        return -1;
    }
    if (ibv_post_send(s->id->qp, &wr, &bad)) {
        return -1;
    }
    return poll_wc(s->id->send_cq,
                   write_to_peer ? IBV_WC_RDMA_WRITE : IBV_WC_RDMA_READ);
}

static int transfer_segments(struct agent_state *s,
                             const struct scope_remote_nvme_submit *req,
                             bool write_to_peer)
{
    uint32_t count = le32toh(req->segment_count);
    uint32_t total = le32toh(req->data_len);
    uint32_t offset = 0;
    uint32_t i;

    if (count > SCOPE_REMOTE_MAX_SEGMENTS || total > s->opt.staging_size) {
        errno = E2BIG;
        return -1;
    }
    for (i = 0; i < count; i++) {
        uint64_t guest_pa = le64toh(req->segments[i].guest_pa);
        uint32_t length = le32toh(req->segments[i].length);

        if (!length || length > total - offset ||
            rdma_payload(s, write_to_peer, guest_pa,
                         (uint8_t *)s->staging + offset, length)) {
            return -1;
        }
        offset += length;
    }
    return offset == total ? 0 : -1;
}

static int identify_namespace(struct agent_state *s)
{
    struct nvme_admin_cmd cmd = {
        .opcode = 0x06,
        .nsid = s->opt.namespace_id,
        .addr = (uintptr_t)s->staging,
        .data_len = 4096,
        .cdw10 = 0,
    };
    uint8_t *id = s->staging;
    uint8_t flbas;
    uint8_t lbaf;
    int ret = ioctl(s->ctrl_fd, NVME_IOCTL_ADMIN_CMD, &cmd);

    if (ret) {
        return -1;
    }
    memcpy(&s->namespace_blocks, id, sizeof(s->namespace_blocks));
    s->namespace_blocks = le64toh(s->namespace_blocks);
    flbas = id[26] & 0x0f;
    lbaf = id[128 + flbas * 4 + 2];
    if (lbaf < 9 || lbaf > 30 || !s->namespace_blocks) {
        errno = EPROTO;
        return -1;
    }
    s->lba_shift = lbaf;
    return 0;
}

static bool run_virtual_feature(struct agent_state *s, uint8_t opcode,
                                uint32_t cdw10, uint32_t cdw11,
                                uint32_t *result, uint16_t *status)
{
    uint8_t fid = cdw10 & 0xff;
    uint8_t select = (cdw10 >> 8) & 0x7;

    if (opcode != 0x09 && opcode != 0x0a) {
        return false;
    }
    switch (fid) {
    case NVME_FEAT_NUM_QUEUES:
        /* One I/O submission queue and one I/O completion queue. */
        *result = 0;
        break;
    case NVME_FEAT_IRQ_COALESCE:
        if (opcode == 0x09) {
            s->feat_irq_coalesce = cdw11;
        }
        *result = s->feat_irq_coalesce;
        break;
    case NVME_FEAT_IRQ_CONFIG:
        /* The mediated endpoint exposes aggregate INTx, not MSI vectors. */
        *result = 0;
        break;
    case NVME_FEAT_ASYNC_EVENT:
        if (opcode == 0x09) {
            s->feat_async_event = cdw11;
        }
        *result = s->feat_async_event;
        break;
    default:
        return false;
    }
    if (opcode == 0x0a && select > 1) {
        *status = NVME_SC_INVALID_FIELD;
    }
    return true;
}

static uint16_t run_admin(struct agent_state *s,
                          const struct scope_remote_nvme_submit *req,
                          uint32_t *result, uint32_t *transferred)
{
    const uint8_t *raw = req->command;
    uint8_t opcode = raw[0];
    uint32_t data_len = le32toh(req->data_len);
    uint32_t direction = le32toh(req->direction);
    uint32_t segment_count = le32toh(req->segment_count);
    uint32_t cdw10;
    uint32_t cdw11;
    struct nvme_admin_cmd cmd = { 0 };
    uint16_t virtual_status = 0;
    int ret;

    if ((!data_len && (direction != SCOPE_REMOTE_IO_NONE || segment_count)) ||
        (data_len && direction != SCOPE_REMOTE_IO_FROM_DEVICE)) {
        return NVME_SC_INVALID_FIELD;
    }
    if (opcode == 0x05 || opcode == 0x01 || opcode == 0x04 || opcode == 0x00) {
        return 0; /* Queue topology is virtual and maintained by Host A. */
    }
    if (opcode != 0x06 && opcode != 0x02 && opcode != 0x09 && opcode != 0x0a) {
        return NVME_SC_INVALID_OPCODE;
    }
    memcpy(&cdw10, raw + 40, sizeof(cdw10));
    memcpy(&cdw11, raw + 44, sizeof(cdw11));
    cdw10 = le32toh(cdw10);
    cdw11 = le32toh(cdw11);
    if (run_virtual_feature(s, opcode, cdw10, cdw11,
                            result, &virtual_status)) {
        return virtual_status;
    }
    cmd.opcode = opcode;
    memcpy(&cmd.nsid, raw + 4, sizeof(cmd.nsid));
    memcpy(&cmd.cdw10, raw + 40, sizeof(cmd.cdw10));
    memcpy(&cmd.cdw11, raw + 44, sizeof(cmd.cdw11));
    memcpy(&cmd.cdw12, raw + 48, sizeof(cmd.cdw12));
    memcpy(&cmd.cdw13, raw + 52, sizeof(cmd.cdw13));
    memcpy(&cmd.cdw14, raw + 56, sizeof(cmd.cdw14));
    memcpy(&cmd.cdw15, raw + 60, sizeof(cmd.cdw15));
    cmd.nsid = le32toh(cmd.nsid);
    cmd.cdw10 = cdw10;
    cmd.cdw11 = cdw11;
    cmd.cdw12 = le32toh(cmd.cdw12);
    cmd.cdw13 = le32toh(cmd.cdw13);
    cmd.cdw14 = le32toh(cmd.cdw14);
    cmd.cdw15 = le32toh(cmd.cdw15);
    if (data_len) {
        if (data_len > s->opt.staging_size) {
            return NVME_SC_INVALID_FIELD;
        }
        memset(s->staging, 0, data_len);
        cmd.addr = (uintptr_t)s->staging;
        cmd.data_len = data_len;
    }
    ret = ioctl(s->ctrl_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
    if (ret < 0) {
        return NVME_SC_INTERNAL;
    }
    if (ret > 0) {
        return (uint16_t)ret << 1;
    }
    *result = cmd.result;
    if (data_len && transfer_segments(s, req, true)) {
        return NVME_SC_DATA_XFER;
    }
    *transferred = data_len;
    return 0;
}

static uint16_t run_io(struct agent_state *s,
                       const struct scope_remote_nvme_submit *req,
                       uint32_t *transferred)
{
    const uint8_t *raw = req->command;
    uint8_t opcode = raw[0];
    uint32_t direction = le32toh(req->direction);
    uint32_t nsid;
    uint64_t slba;
    uint16_t nlb;
    uint32_t data_len = le32toh(req->data_len);
    uint64_t expected;
    off_t offset;
    ssize_t ret;

    memcpy(&nsid, raw + 4, sizeof(nsid));
    memcpy(&slba, raw + 40, sizeof(slba));
    memcpy(&nlb, raw + 48, sizeof(nlb));
    nsid = le32toh(nsid);
    slba = le64toh(slba);
    nlb = le16toh(nlb);
    if (opcode == 0x00) {
        if (direction != SCOPE_REMOTE_IO_NONE || data_len ||
            le32toh(req->segment_count)) {
            return NVME_SC_INVALID_FIELD;
        }
        return fsync(s->ns_fd) ? NVME_SC_INTERNAL : 0;
    }
    expected = ((uint64_t)nlb + 1U) << s->lba_shift;
    if (nsid != s->opt.namespace_id || expected != data_len ||
        data_len > s->opt.staging_size ||
        slba > (UINT64_MAX >> s->lba_shift) ||
        slba >= s->namespace_blocks ||
        (uint64_t)nlb + 1U > s->namespace_blocks - slba) {
        return NVME_SC_INVALID_FIELD;
    }
    offset = slba << s->lba_shift;
    switch (opcode) {
    case 0x01:
        if (direction != SCOPE_REMOTE_IO_TO_DEVICE) {
            return NVME_SC_INVALID_FIELD;
        }
        if (transfer_segments(s, req, false)) {
            return NVME_SC_DATA_XFER;
        }
        ret = pwrite(s->ns_fd, s->staging, data_len, offset);
        break;
    case 0x02:
        if (direction != SCOPE_REMOTE_IO_FROM_DEVICE) {
            return NVME_SC_INVALID_FIELD;
        }
        ret = pread(s->ns_fd, s->staging, data_len, offset);
        if (ret == (ssize_t)data_len && transfer_segments(s, req, true)) {
            return NVME_SC_DATA_XFER;
        }
        break;
    default:
        return NVME_SC_INVALID_OPCODE;
    }
    if (ret != (ssize_t)data_len) {
        return NVME_SC_DATA_XFER;
    }
    *transferred = data_len;
    return 0;
}

static int handle_hello(struct agent_state *s)
{
    const struct scope_remote_hello *hello = (const void *)s->rx->payload;
    struct scope_remote_hello *rsp;
    uint64_t features = le64toh(hello->features);
    bool direct = (features & SCOPE_REMOTE_DIRECT_FEATURES) ==
                  SCOPE_REMOTE_DIRECT_FEATURES;
    bool host_staging = (features & SCOPE_REMOTE_STAGING_FEATURES) ==
                        SCOPE_REMOTE_STAGING_FEATURES;

    if (le32toh(s->rx->hdr.payload_len) != sizeof(*hello) ||
        direct == host_staging) {
        return -1;
    }
    s->session_id = le64toh(s->rx->hdr.session_id);
    s->generation = le64toh(s->rx->hdr.generation);
    s->peer_base = le64toh(hello->peer_base);
    s->peer_length = le64toh(hello->peer_length);
    s->peer_rkey = le32toh(hello->peer_rkey);
    if (!s->session_id || !s->generation || !s->peer_length ||
        !s->peer_rkey) {
        return -1;
    }
    init_response(s, SCOPE_REMOTE_OP_HELLO_RSP,
                  le64toh(s->rx->hdr.request_id), sizeof(*rsp), 0);
    rsp = (void *)s->tx->payload;
    rsp->features = htole64(direct ? SCOPE_REMOTE_DIRECT_FEATURES :
                            SCOPE_REMOTE_STAGING_FEATURES);
    rsp->max_inflight = htole32(1);
    rsp->max_segments = htole32(SCOPE_REMOTE_MAX_SEGMENTS);
    return send_response(s, sizeof(*rsp));
}

static int handle_open(struct agent_state *s)
{
    const struct scope_remote_device_open *open_req =
        (const void *)s->rx->payload;
    struct scope_remote_device_info *info;

    init_response(s, SCOPE_REMOTE_OP_DEVICE_OPEN_RSP,
                  le64toh(s->rx->hdr.request_id), sizeof(*info), 0);
    info = (void *)s->tx->payload;
    if (le32toh(s->rx->hdr.payload_len) != sizeof(*open_req) ||
        strnlen(open_req->device_id, sizeof(open_req->device_id)) ==
            sizeof(open_req->device_id) ||
        strcmp(open_req->device_id, s->opt.device_id) ||
        le32toh(open_req->device_type) != SCOPE_REMOTE_DEVICE_NVME ||
        le32toh(open_req->namespace_id) != s->opt.namespace_id) {
        s->tx->hdr.status = htole32(SCOPE_REMOTE_STATUS_DEVICE);
    } else {
        info->vendor_id = htole16(0x8086);
        info->device_id = htole16(0x4802);
        info->class_code = htole32(0x010802);
        info->bar0_size = htole64(0x4000);
        info->nvme_cap = htole64(AGENT_DEFAULT_CAP);
        info->nvme_vs = htole32(AGENT_DEFAULT_VS);
        info->controller_page_size = htole32(4096);
        info->namespace_blocks = htole64(s->namespace_blocks);
        info->lba_shift = htole32(s->lba_shift);
        info->max_transfer_bytes = htole32(s->opt.staging_size);
        info->max_inflight = htole32(1);
        info->device_type = htole32(SCOPE_REMOTE_DEVICE_NVME);
    }
    return send_response(s, sizeof(*info));
}

static int handle_nvme(struct agent_state *s)
{
    const struct scope_remote_nvme_submit *req = (const void *)s->rx->payload;
    struct scope_remote_nvme_complete *cpl;
    uint16_t qid;
    uint16_t cid;
    uint16_t status;
    uint32_t result = 0;
    uint32_t transferred = 0;

    if (le32toh(s->rx->hdr.payload_len) != sizeof(*req) ||
        le32toh(req->segment_count) > SCOPE_REMOTE_MAX_SEGMENTS) {
        return -1;
    }
    qid = le32toh(req->qid);
    memcpy(&cid, req->command + 2, sizeof(cid));
    cid = le16toh(cid);
    status = qid == 0 ? run_admin(s, req, &result, &transferred) :
                        run_io(s, req, &transferred);
    init_response(s, SCOPE_REMOTE_OP_NVME_COMPLETE,
                  le64toh(s->rx->hdr.request_id), sizeof(*cpl), 0);
    cpl = (void *)s->tx->payload;
    cpl->result = htole32(result);
    cpl->sq_id = htole16(qid);
    cpl->cid = htole16(cid);
    cpl->status = htole16(status);
    cpl->transferred = htole32(transferred);
    return send_response(s, sizeof(*cpl));
}

static int serve(struct agent_state *s)
{
    bool first = true;

    if (post_recv(s) || rdma_accept(s->id, NULL)) {
        return -1;
    }
    for (;;) {
        uint16_t opcode;
        int ret;

        if (wait_recv(s) || !validate_header(s, s->rx, first)) {
            return -1;
        }
        opcode = le16toh(s->rx->hdr.opcode);
        if (first) {
            if (opcode != SCOPE_REMOTE_OP_HELLO || handle_hello(s)) {
                return -1;
            }
            first = false;
        } else if (opcode == SCOPE_REMOTE_OP_DEVICE_OPEN) {
            if (handle_open(s)) {
                return -1;
            }
        } else if (opcode == SCOPE_REMOTE_OP_NVME_SUBMIT) {
            if (handle_nvme(s)) {
                return -1;
            }
        } else if (opcode == SCOPE_REMOTE_OP_KEEPALIVE) {
            init_response(s, SCOPE_REMOTE_OP_KEEPALIVE,
                          le64toh(s->rx->hdr.request_id), 0, 0);
            if (send_response(s, 0)) {
                return -1;
            }
        } else if (opcode == SCOPE_REMOTE_OP_CLOSE) {
            return 0;
        } else {
            init_response(s, SCOPE_REMOTE_OP_ERROR,
                          le64toh(s->rx->hdr.request_id), 0,
                          SCOPE_REMOTE_STATUS_UNSUPPORTED);
            if (send_response(s, 0)) {
                return -1;
            }
        }
        ret = post_recv(s);
        if (ret) {
            return -1;
        }
    }
}

static void cleanup(struct agent_state *s)
{
    if (s->id) rdma_disconnect(s->id);
    if (s->staging_mr) ibv_dereg_mr(s->staging_mr);
    if (s->tx_mr) rdma_dereg_mr(s->tx_mr);
    if (s->rx_mr) rdma_dereg_mr(s->rx_mr);
    if (s->id) rdma_destroy_ep(s->id);
    if (s->listen_id) rdma_destroy_ep(s->listen_id);
    if (s->ns_fd >= 0) close(s->ns_fd);
    if (s->ctrl_fd >= 0) close(s->ctrl_fd);
    free(s->staging);
    free(s->tx);
    free(s->rx);
}

int main(int argc, char **argv)
{
    struct agent_state s = { .ns_fd = -1, .ctrl_fd = -1 };
    struct rdma_addrinfo hints = {
        .ai_flags = RAI_PASSIVE,
        .ai_port_space = RDMA_PS_TCP,
        .ai_qp_type = IBV_QPT_RC,
    };
    struct rdma_addrinfo *res = NULL;
    struct ibv_qp_init_attr qp_attr = {
        .cap = {
            .max_send_wr = 128,
            .max_recv_wr = 128,
            .max_send_sge = 1,
            .max_recv_sge = 1,
        },
        .qp_type = IBV_QPT_RC,
    };
    int ret = EXIT_FAILURE;

    if (!parse_options(argc, argv, &s.opt)) {
        usage(argv[0]);
        return EXIT_FAILURE;
    }
    s.ns_fd = open(s.opt.namespace_path, O_RDWR | O_DIRECT | O_CLOEXEC);
    s.ctrl_fd = open(s.opt.controller, O_RDWR | O_CLOEXEC);
    if (s.ns_fd < 0 || s.ctrl_fd < 0 ||
        posix_memalign(&s.staging, 4096, s.opt.staging_size) ||
        identify_namespace(&s)) {
        perror("open/identify remote NVMe");
        goto out;
    }
    s.rx = aligned_alloc(64, sizeof(*s.rx));
    s.tx = aligned_alloc(64, sizeof(*s.tx));
    if (!s.rx || !s.tx) {
        perror("allocate control buffers");
        goto out;
    }
    if (rdma_getaddrinfo((char *)s.opt.listen_addr, (char *)s.opt.service,
                         &hints, &res) ||
        rdma_create_ep(&s.listen_id, res, NULL, &qp_attr) ||
        rdma_listen(s.listen_id, 1)) {
        perror("create RDMA listener");
        goto out;
    }
    rdma_freeaddrinfo(res);
    res = NULL;
    fprintf(stderr, "scope-remote-agent listening on %s:%s for %s\n",
            s.opt.listen_addr, s.opt.service, s.opt.device_id);
    if (rdma_get_request(s.listen_id, &s.id)) {
        perror("rdma_get_request");
        goto out;
    }
    if (strcmp(ibv_get_device_name(s.id->verbs->device), s.opt.rdma_device)) {
        fprintf(stderr, "RDMA route selected %s, expected %s\n",
                ibv_get_device_name(s.id->verbs->device), s.opt.rdma_device);
        goto out;
    }
    s.rx_mr = rdma_reg_msgs(s.id, s.rx, sizeof(*s.rx));
    s.tx_mr = rdma_reg_msgs(s.id, s.tx, sizeof(*s.tx));
    s.staging_mr = ibv_reg_mr(s.id->pd, s.staging, s.opt.staging_size,
                              IBV_ACCESS_LOCAL_WRITE);
    if (!s.rx_mr || !s.tx_mr || !s.staging_mr) {
        perror("register RDMA memory");
        goto out;
    }
    ret = serve(&s) ? EXIT_FAILURE : EXIT_SUCCESS;

out:
    if (res) rdma_freeaddrinfo(res);
    cleanup(&s);
    return ret;
}
