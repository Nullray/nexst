/* SPDX-License-Identifier: GPL-2.0-or-later */
#define _GNU_SOURCE

#include "scope_xdma_peer_uapi.h"

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <infiniband/verbs.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

struct options {
    const char *rdma_device;
    const char *peer_device;
    uint64_t bar_offset;
    uint64_t length;
    uint64_t guest_iova;
};

static bool parse_u64(const char *text, uint64_t *value)
{
    char *end = NULL;
    unsigned long long parsed;

    errno = 0;
    parsed = strtoull(text, &end, 0);
    if (errno || !text[0] || !end || *end) {
        return false;
    }
    *value = parsed;
    return true;
}

static bool parse_options(int argc, char **argv, struct options *opt)
{
    static const struct option long_opts[] = {
        { "rdma-device", required_argument, NULL, 'r' },
        { "peer-memory-device", required_argument, NULL, 'p' },
        { "bar-offset", required_argument, NULL, 'b' },
        { "length", required_argument, NULL, 'l' },
        { "guest-iova", required_argument, NULL, 'i' },
        { NULL, 0, NULL, 0 },
    };
    int ch;

    *opt = (struct options) {
        .peer_device = "/dev/xdma0_peer",
        .bar_offset = 0x180000000ULL,
        .length = 0x80000000ULL,
        .guest_iova = 0x80000000ULL,
    };
    while ((ch = getopt_long(argc, argv, "r:p:b:l:i:", long_opts, NULL)) != -1) {
        switch (ch) {
        case 'r': opt->rdma_device = optarg; break;
        case 'p': opt->peer_device = optarg; break;
        case 'b':
            if (!parse_u64(optarg, &opt->bar_offset)) return false;
            break;
        case 'l':
            if (!parse_u64(optarg, &opt->length)) return false;
            break;
        case 'i':
            if (!parse_u64(optarg, &opt->guest_iova)) return false;
            break;
        default:
            return false;
        }
    }
    return opt->rdma_device && opt->length;
}

int main(int argc, char **argv)
{
    struct options opt;
    struct ibv_device **devices = NULL;
    struct ibv_context *context = NULL;
    struct ibv_pd *pd = NULL;
    struct ibv_mr *mr = NULL;
    struct xdma_peer_export export;
    int peer_fd = -1;
    int dmabuf_fd = -1;
    int count = 0;
    int ret = EXIT_FAILURE;
    int i;

    if (!parse_options(argc, argv, &opt)) {
        fprintf(stderr, "Usage: %s --rdma-device DEV "
                "[--peer-memory-device /dev/xdma0_peer] "
                "[--bar-offset 0x180000000] [--length 0x80000000] "
                "[--guest-iova 0x80000000]\n", argv[0]);
        return EXIT_FAILURE;
    }
    devices = ibv_get_device_list(&count);
    for (i = 0; devices && i < count; i++) {
        if (!strcmp(ibv_get_device_name(devices[i]), opt.rdma_device)) {
            context = ibv_open_device(devices[i]);
            break;
        }
    }
    if (!context) {
        fprintf(stderr, "cannot open RDMA device %s\n", opt.rdma_device);
        goto out;
    }
    pd = ibv_alloc_pd(context);
    if (!pd) {
        perror("ibv_alloc_pd");
        goto out;
    }
    peer_fd = open(opt.peer_device, O_RDWR | O_CLOEXEC);
    if (peer_fd < 0) {
        perror("open peer-memory device");
        goto out;
    }
    export = (struct xdma_peer_export) {
        .abi_version = XDMA_PEER_ABI_VERSION,
        .flags = XDMA_PEER_F_READ | XDMA_PEER_F_WRITE,
        .bar_offset = opt.bar_offset,
        .length = opt.length,
        .guest_iova = opt.guest_iova,
        .dmabuf_fd = -1,
    };
    if (ioctl(peer_fd, XDMA_PEER_IOC_EXPORT, &export)) {
        perror("XDMA_PEER_IOC_EXPORT");
        goto out;
    }
    dmabuf_fd = export.dmabuf_fd;
    mr = ibv_reg_dmabuf_mr(pd, 0, export.length, export.guest_iova,
                           dmabuf_fd,
                           IBV_ACCESS_LOCAL_WRITE |
                           IBV_ACCESS_REMOTE_READ |
                           IBV_ACCESS_REMOTE_WRITE);
    if (!mr) {
        perror("ibv_reg_dmabuf_mr");
        fprintf(stderr, "The RNIC provider must implement reg_user_mr_dmabuf "
                "and permit PCI P2P to the XDMA function.\n");
        goto out;
    }
    printf("peer MR ready: rdma=%s iova=0x%llx length=0x%llx "
           "lkey=0x%x rkey=0x%x generation=%llu\n",
           opt.rdma_device, (unsigned long long)export.guest_iova,
           (unsigned long long)export.length, mr->lkey, mr->rkey,
           (unsigned long long)export.generation);
    ret = EXIT_SUCCESS;

out:
    if (mr) ibv_dereg_mr(mr);
    if (dmabuf_fd >= 0) close(dmabuf_fd);
    if (peer_fd >= 0) close(peer_fd);
    if (pd) ibv_dealloc_pd(pd);
    if (context) ibv_close_device(context);
    if (devices) ibv_free_device_list(devices);
    return ret;
}
