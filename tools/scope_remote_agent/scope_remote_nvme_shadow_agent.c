/* SPDX-License-Identifier: GPL-2.0-or-later */
#define _GNU_SOURCE

#include "scope_remote_proto.h"

#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <infiniband/verbs.h>
#include <inttypes.h>
#include <linux/magic.h>
#include <limits.h>
#include <rdma/rdma_cma.h>
#include <rdma/rdma_verbs.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/vfs.h>
#include <time.h>
#include <unistd.h>

#define AGENT_DEFAULT_SERVICE              "7473"
#define NVME_MIN_BAR0_SIZE                  0x4000U
#define NVME_POOL_SIZE                      (2U * 1024U * 1024U)
#define NVME_PAGE_SIZE                      4096U
#define NVME_MAX_Q_DEPTH                    1024U
#define NVME_ADMIN_SQ_OFFSET                0x00000U
#define NVME_ADMIN_SQ_SIZE                  0x10000U
#define NVME_ADMIN_CQ_OFFSET                0x10000U
#define NVME_ADMIN_CQ_SIZE                  0x04000U
#define NVME_IO_SQ_OFFSET                   0x14000U
#define NVME_IO_SQ_SIZE                     0x10000U
#define NVME_IO_CQ_OFFSET                   0x24000U
#define NVME_IO_CQ_SIZE                     0x04000U
#define NVME_PRP_LIST_OFFSET                0x28000U
#define NVME_PRP_LIST_SIZE                  0x01000U
#define NVME_DATA_OFFSET                    0x40000U
#define NVME_DATA_SIZE                      (NVME_POOL_SIZE - NVME_DATA_OFFSET)
#define NVME_ADMIN_BOOT_DEPTH               64U
#define NVME_PHASE1_IO_QID                  1U
#define NVME_POLL_US                        20U
#define NVME_AGENT_BUILD_ID                 "nvme-shadow-cqe-order-v3"
#define RDMA_COMPLETION_TIMEOUT_MS        5000U
#define NVME_CC_EN                          (1U << 0)
#define NVME_CC_MPS_SHIFT                   7U
#define NVME_CC_MPS_MASK                    (0xfU << NVME_CC_MPS_SHIFT)
#define NVME_CC_IOSQES_SHIFT                16U
#define NVME_CC_IOSQES_MASK                 (0xfU << NVME_CC_IOSQES_SHIFT)
#define NVME_CC_IOCQES_SHIFT                20U
#define NVME_CC_IOCQES_MASK                 (0xfU << NVME_CC_IOCQES_SHIFT)
#define NVME_CC_SHN_MASK                    (0x3U << 14U)
#define NVME_CC_IOSQES_64B                  (6U << NVME_CC_IOSQES_SHIFT)
#define NVME_CC_IOCQES_16B                  (4U << NVME_CC_IOCQES_SHIFT)
#define NVME_CSTS_RDY                       (1U << 0)
#define NVME_CSTS_CFS                       (1U << 1)
#define NVME_REG_CAP                        0x0000U
#define NVME_REG_VS                         0x0008U
#define NVME_REG_INTMS                      0x000cU
#define NVME_REG_INTMC                      0x0010U
#define NVME_REG_CC                         0x0014U
#define NVME_REG_CSTS                       0x001cU
#define NVME_REG_NSSR                       0x0020U
#define NVME_REG_AQA                        0x0024U
#define NVME_REG_ASQ                        0x0028U
#define NVME_REG_ACQ                        0x0030U
#define NVME_DOORBELL_BASE                  0x1000U
#define PCI_COMMAND                         0x04U
#define PCI_COMMAND_MEMORY                  0x0002U
#define PCI_COMMAND_MASTER                  0x0004U
#define PAGEMAP_PRESENT                     (1ULL << 63)
#define PAGEMAP_PFN_MASK                    ((1ULL << 55) - 1U)
#define NVME_ADMIN_DELETE_SQ                0x00U
#define NVME_ADMIN_CREATE_SQ                0x01U
#define NVME_ADMIN_GET_LOG                  0x02U
#define NVME_ADMIN_DELETE_CQ                0x04U
#define NVME_ADMIN_CREATE_CQ                0x05U
#define NVME_ADMIN_IDENTIFY                 0x06U
#define NVME_ADMIN_SET_FEATURES             0x09U
#define NVME_ADMIN_ASYNC_EVENT              0x0cU
#define NVME_FEAT_NUM_QUEUES                0x07U
#define NVME_IDENTIFY_CNS_NAMESPACE         0x00U
#define NVME_SC_INVALID_OPCODE              (0x01U << 1)
#define NVME_SC_DATA_XFER                   (0x04U << 1)
#define NVME_SC_INTERNAL                    (0x06U << 1)

struct shadow_options {
    const char *listen_addr;
    const char *service;
    const char *rdma_device;
    const char *device_id;
    const char *pci_bdf;
    const char *hugepage_file;
    uint32_t namespace_id;
    bool allow_identity_dma;
};

struct nvme_cqe {
    uint32_t result;
    uint32_t dw1;
    uint16_t sq_head;
    uint16_t sq_id;
    uint16_t cid;
    uint16_t status;
} __attribute__((packed));

struct queue_state {
    uint16_t qid;
    uint16_t depth;
    uint16_t sq_tail;
    uint16_t cq_head;
    bool cq_phase;
    bool sq_valid;
    bool cq_valid;
    uint8_t *sq;
    volatile struct nvme_cqe *cq;
    uint64_t sq_bus;
    uint64_t cq_bus;
};

enum pending_admin_kind {
    PENDING_ADMIN_NONE = 0,
    PENDING_ADMIN_CREATE_CQ,
    PENDING_ADMIN_CREATE_SQ,
    PENDING_ADMIN_DELETE_CQ,
    PENDING_ADMIN_DELETE_SQ,
};

struct pending_nvme {
    bool valid;
    bool inflight;
    uint64_t request_id;
    uint32_t qid;
    uint32_t direction;
    uint32_t data_len;
    uint32_t segment_count;
    struct scope_remote_segment segments[SCOPE_REMOTE_MAX_SEGMENTS];
    uint8_t command[64];
    uint16_t cid;
    enum pending_admin_kind admin_kind;
    uint16_t admin_qid;
    uint16_t admin_depth;
};

struct shadow_agent {
    struct shadow_options opt;
    struct rdma_cm_id *listen_id;
    struct rdma_cm_id *id;
    struct ibv_mr *rx_mr;
    struct ibv_mr *tx_mr;
    struct ibv_mr *pool_mr;
    struct scope_remote_message *rx;
    struct scope_remote_message *tx;
    int bar_fd;
    int config_fd;
    int pool_fd;
    volatile uint8_t *bar0;
    size_t bar0_size;
    uint8_t *pool;
    uint64_t pool_bus;
    bool pool_file_created;
    uint16_t saved_pci_command;
    bool pci_command_saved;
    bool pci_enabled;
    uint16_t vendor_id;
    uint16_t device_id;
    uint32_t class_code;
    uint64_t cap;
    uint32_t vs;
    uint32_t doorbell_stride;
    uint64_t namespace_blocks;
    uint32_t lba_shift;
    uint64_t session_id;
    uint64_t generation;
    uint64_t peer_base;
    uint64_t peer_length;
    uint32_t peer_rkey;
    bool opened;
    bool first;
    bool recv_posted;
    uint32_t guest_aqa;
    uint64_t guest_asq;
    uint64_t guest_acq;
    uint32_t guest_cc;
    uint32_t guest_int_mask;
    uint32_t guest_bar_shadow[NVME_MIN_BAR0_SIZE / sizeof(uint32_t)];
    struct queue_state admin_q;
    struct queue_state io_q;
    struct pending_nvme pending;
};

static volatile sig_atomic_t stop_requested;

_Static_assert(sizeof(struct nvme_cqe) == 16, "NVMe CQE size changed");
_Static_assert(NVME_DATA_OFFSET < NVME_POOL_SIZE, "NVMe pool layout invalid");

static uint16_t get_le16(const void *p)
{
    uint16_t v;
    memcpy(&v, p, sizeof(v));
    return le16toh(v);
}

static uint32_t get_le32(const void *p)
{
    uint32_t v;
    memcpy(&v, p, sizeof(v));
    return le32toh(v);
}

static uint64_t get_le64(const void *p)
{
    uint64_t v;
    memcpy(&v, p, sizeof(v));
    return le64toh(v);
}

static void put_le32(void *p, uint32_t v)
{
    v = htole32(v);
    memcpy(p, &v, sizeof(v));
}

static void put_le64(void *p, uint64_t v)
{
    v = htole64(v);
    memcpy(p, &v, sizeof(v));
}

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000U + ts.tv_nsec / 1000000U;
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s --listen ADDR --rdma-device DEV --device-id ID "
            "--pci-bdf DDDD:BB:DD.F --hugepage-file PATH "
            "--allow-unsafe-identity-dma [--namespace-id 1] [--service 7473]\n",
            prog);
}

static void request_stop(int signo)
{
    (void)signo;
    stop_requested = 1;
}

static int install_signal_handlers(void)
{
    struct sigaction action = { .sa_handler = request_stop };
    sigemptyset(&action.sa_mask);
    return sigaction(SIGINT, &action, NULL) ||
           sigaction(SIGTERM, &action, NULL);
}

static bool valid_bdf(const char *bdf)
{
    unsigned int domain, bus, dev, fn;
    char tail;
    return bdf && sscanf(bdf, "%x:%x:%x.%x%c", &domain, &bus, &dev, &fn,
                         &tail) == 4 && domain <= 0xffffU && bus <= 0xffU &&
           dev <= 0x1fU && fn <= 7U;
}

static bool parse_u32(const char *text, uint32_t *value)
{
    char *end = NULL;
    unsigned long parsed = strtoul(text, &end, 0);
    if (!text[0] || !end || *end || parsed > UINT32_MAX) {
        return false;
    }
    *value = (uint32_t)parsed;
    return true;
}

static bool parse_options(int argc, char **argv, struct shadow_options *opt)
{
    static const struct option options[] = {
        { "listen", required_argument, NULL, 'l' },
        { "service", required_argument, NULL, 's' },
        { "rdma-device", required_argument, NULL, 'r' },
        { "device-id", required_argument, NULL, 'd' },
        { "pci-bdf", required_argument, NULL, 'p' },
        { "hugepage-file", required_argument, NULL, 'H' },
        { "namespace-id", required_argument, NULL, 'n' },
        { "allow-unsafe-identity-dma", no_argument, NULL, 'I' },
        { "help", no_argument, NULL, 'h' },
        { NULL, 0, NULL, 0 },
    };
    int ch;

    *opt = (struct shadow_options) {
        .service = AGENT_DEFAULT_SERVICE,
        .namespace_id = 1,
    };
    while ((ch = getopt_long(argc, argv, "l:s:r:d:p:H:n:Ih", options,
                             NULL)) != -1) {
        switch (ch) {
        case 'l': opt->listen_addr = optarg; break;
        case 's': opt->service = optarg; break;
        case 'r': opt->rdma_device = optarg; break;
        case 'd': opt->device_id = optarg; break;
        case 'p': opt->pci_bdf = optarg; break;
        case 'H': opt->hugepage_file = optarg; break;
        case 'n':
            if (!parse_u32(optarg, &opt->namespace_id) ||
                !opt->namespace_id || opt->namespace_id == UINT32_MAX) {
                return false;
            }
            break;
        case 'I': opt->allow_identity_dma = true; break;
        default: return false;
        }
    }
    return opt->listen_addr && opt->rdma_device && opt->device_id &&
           opt->pci_bdf && valid_bdf(opt->pci_bdf) && opt->hugepage_file &&
           opt->hugepage_file[0] == '/' && opt->allow_identity_dma &&
           strlen(opt->device_id) < SCOPE_REMOTE_MAX_DEVICE_ID;
}

static int read_hex_file(const char *path, unsigned int *value)
{
    FILE *f = fopen(path, "r");
    int ret = -1;
    if (f) {
        ret = fscanf(f, "%x", value) == 1 ? 0 : -1;
        fclose(f);
    }
    return ret;
}

static int verify_pci_identity_and_owner(struct shadow_agent *s)
{
    char path[PATH_MAX];
    struct stat st;
    unsigned int vendor, device, subsystem_vendor, subsystem_device;
    unsigned int class_code;

    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/vendor", s->opt.pci_bdf);
    if (read_hex_file(path, &vendor)) return -1;
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/device", s->opt.pci_bdf);
    if (read_hex_file(path, &device)) return -1;
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/subsystem_vendor",
             s->opt.pci_bdf);
    if (read_hex_file(path, &subsystem_vendor)) return -1;
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/subsystem_device",
             s->opt.pci_bdf);
    if (read_hex_file(path, &subsystem_device)) return -1;
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/class", s->opt.pci_bdf);
    if (read_hex_file(path, &class_code)) return -1;
    if (vendor != 0x8086U || device != 0x0a54U ||
        subsystem_vendor != 0x8086U || subsystem_device != 0x4802U ||
        (class_code & 0xffffffU) != 0x010802U) {
        fprintf(stderr, "%s is %04x:%04x subsystem=%04x:%04x "
                "class=%06x; expected 8086:0a54 subsystem=8086:4802 "
                "NVMe class 010802\n",
                s->opt.pci_bdf, vendor, device, subsystem_vendor,
                subsystem_device, class_code & 0xffffffU);
        errno = ENODEV;
        return -1;
    }
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/driver", s->opt.pci_bdf);
    errno = 0;
    if (!lstat(path, &st)) {
        fprintf(stderr, "%s is still bound to a kernel driver\n", s->opt.pci_bdf);
        errno = EBUSY;
        return -1;
    }
    if (errno != ENOENT) return -1;
    s->vendor_id = (uint16_t)vendor;
    s->device_id = (uint16_t)device;
    s->class_code = class_code & 0xffffffU;
    return 0;
}

static uint32_t reg_read32(struct shadow_agent *s, uint32_t offset)
{
    volatile uint32_t *p;
    if (!s->bar0 || offset > s->bar0_size - sizeof(*p)) return 0;
    p = (volatile uint32_t *)(s->bar0 + offset);
    return le32toh(*p);
}

static void reg_write32(struct shadow_agent *s, uint32_t offset, uint32_t value)
{
    volatile uint32_t *p;
    if (!s->bar0 || offset > s->bar0_size - sizeof(*p)) return;
    p = (volatile uint32_t *)(s->bar0 + offset);
    *p = htole32(value);
    (void)reg_read32(s, NVME_REG_CSTS);
}

static uint64_t reg_read64(struct shadow_agent *s, uint32_t offset)
{
    uint64_t lo = reg_read32(s, offset);
    uint64_t hi = reg_read32(s, offset + 4U);
    return lo | (hi << 32);
}

static void reg_write64(struct shadow_agent *s, uint32_t offset, uint64_t value)
{
    reg_write32(s, offset, (uint32_t)value);
    reg_write32(s, offset + 4U, (uint32_t)(value >> 32));
}

static int open_pci_resources(struct shadow_agent *s)
{
    char path[PATH_MAX];
    struct stat st;

    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource0", s->opt.pci_bdf);
    s->bar_fd = open(path, O_RDWR | O_SYNC | O_CLOEXEC);
    if (s->bar_fd < 0 || fstat(s->bar_fd, &st)) return -1;
    if (st.st_size < NVME_MIN_BAR0_SIZE) {
        fprintf(stderr, "NVMe BAR0 is only %jd bytes\n", (intmax_t)st.st_size);
        errno = ERANGE;
        return -1;
    }
    s->bar0_size = (size_t)st.st_size;
    s->bar0 = mmap(NULL, s->bar0_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                   s->bar_fd, 0);
    if (s->bar0 == MAP_FAILED) {
        s->bar0 = NULL;
        return -1;
    }
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/config", s->opt.pci_bdf);
    s->config_fd = open(path, O_RDWR | O_CLOEXEC);
    return s->config_fd < 0 ? -1 : 0;
}

static int enable_pci_memory_busmaster(struct shadow_agent *s)
{
    uint16_t cmd;
    if (pread(s->config_fd, &cmd, sizeof(cmd), PCI_COMMAND) != sizeof(cmd)) return -1;
    s->saved_pci_command = le16toh(cmd);
    s->pci_command_saved = true;
    cmd = htole16(s->saved_pci_command | PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER);
    if (pwrite(s->config_fd, &cmd, sizeof(cmd), PCI_COMMAND) != sizeof(cmd)) return -1;
    if (pread(s->config_fd, &cmd, sizeof(cmd), PCI_COMMAND) != sizeof(cmd)) return -1;
    if ((le16toh(cmd) & (PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER)) !=
        (PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER)) {
        errno = EIO;
        return -1;
    }
    s->pci_enabled = true;
    return 0;
}

static int pool_physical_base(void *pool, size_t length, uint64_t *base)
{
    const uint64_t page_size = (uint64_t)sysconf(_SC_PAGESIZE);
    uintptr_t addr = (uintptr_t)pool;
    int fd = -1;
    uint64_t first = 0;
    size_t off;

    if (!page_size || (addr & (page_size - 1U))) {
        errno = EINVAL;
        return -1;
    }
    fd = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    for (off = 0; off < length; off += page_size) {
        uint64_t entry, pfn, expected;
        off_t pos = (off_t)(((addr + off) / page_size) * sizeof(entry));
        if (pread(fd, &entry, sizeof(entry), pos) != sizeof(entry) ||
            !(entry & PAGEMAP_PRESENT)) {
            close(fd);
            errno = EFAULT;
            return -1;
        }
        pfn = entry & PAGEMAP_PFN_MASK;
        if (!pfn) {
            close(fd);
            errno = EPERM;
            return -1;
        }
        if (!off) first = pfn;
        expected = first + off / page_size;
        if (pfn != expected) {
            close(fd);
            errno = ENXIO;
            return -1;
        }
    }
    close(fd);
    *base = first * page_size;
    return 0;
}

static int allocate_dma_pool(struct shadow_agent *s)
{
    struct statfs fs;
    struct stat st;

    if (stat(s->opt.hugepage_file, &st) && errno == ENOENT) {
        s->pool_file_created = true;
    }
    s->pool_fd = open(s->opt.hugepage_file, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (s->pool_fd < 0 || fstatfs(s->pool_fd, &fs)) return -1;
    if ((unsigned long)fs.f_type != HUGETLBFS_MAGIC) {
        fprintf(stderr, "%s is not on hugetlbfs\n", s->opt.hugepage_file);
        errno = EINVAL;
        return -1;
    }
    if (ftruncate(s->pool_fd, NVME_POOL_SIZE)) return -1;
    s->pool = mmap(NULL, NVME_POOL_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
                   s->pool_fd, 0);
    if (s->pool == MAP_FAILED) {
        s->pool = NULL;
        return -1;
    }
    memset(s->pool, 0, NVME_POOL_SIZE);
    if (mlock(s->pool, NVME_POOL_SIZE) ||
        pool_physical_base(s->pool, NVME_POOL_SIZE, &s->pool_bus)) {
        return -1;
    }
    return 0;
}

static uint64_t controller_timeout_ms(struct shadow_agent *s)
{
    uint64_t to = (s->cap >> 24) & 0xffU;
    return to ? to * 500U : 5000U;
}

static int wait_csts(struct shadow_agent *s, bool ready)
{
    uint64_t deadline = now_ms() + controller_timeout_ms(s);
    uint32_t last_csts = 0;

    while (now_ms() < deadline) {
        uint32_t csts = reg_read32(s, NVME_REG_CSTS);

        last_csts = csts;
        if (!!(csts & NVME_CSTS_RDY) == ready) return 0;
        if (csts & NVME_CSTS_CFS) {
            fprintf(stderr,
                    "NVMe CSTS fatal while waiting for RDY=%u: "
                    "CC=%08x CSTS=%08x\n",
                    ready, reg_read32(s, NVME_REG_CC), csts);
            errno = EIO;
            return -1;
        }
        usleep(1000);
    }
    fprintf(stderr,
            "NVMe CSTS timeout while waiting for RDY=%u: CC=%08x "
            "CSTS=%08x timeout_ms=%" PRIu64 "\n",
            ready, reg_read32(s, NVME_REG_CC), last_csts,
            controller_timeout_ms(s));
    errno = ETIMEDOUT;
    return -1;
}

static int stop_controller(struct shadow_agent *s)
{
    uint32_t cc = reg_read32(s, NVME_REG_CC);

    if (cc & NVME_CC_EN) reg_write32(s, NVME_REG_CC, cc & ~NVME_CC_EN);
    return 0;
}

static int disable_controller(struct shadow_agent *s)
{
    if (stop_controller(s)) return -1;
    return wait_csts(s, false);
}

static void reset_queue_state(struct shadow_agent *s, uint16_t admin_depth)
{
    memset(s->pool + NVME_ADMIN_SQ_OFFSET, 0, NVME_ADMIN_SQ_SIZE);
    memset(s->pool + NVME_ADMIN_CQ_OFFSET, 0, NVME_ADMIN_CQ_SIZE);
    memset(s->pool + NVME_IO_SQ_OFFSET, 0, NVME_IO_SQ_SIZE);
    memset(s->pool + NVME_IO_CQ_OFFSET, 0, NVME_IO_CQ_SIZE);
    memset(s->pool + NVME_PRP_LIST_OFFSET, 0, NVME_PRP_LIST_SIZE);
    memset(&s->admin_q, 0, sizeof(s->admin_q));
    memset(&s->io_q, 0, sizeof(s->io_q));
    s->admin_q.qid = 0;
    s->admin_q.depth = admin_depth;
    s->admin_q.cq_phase = true;
    s->admin_q.sq_valid = true;
    s->admin_q.cq_valid = true;
    s->admin_q.sq = s->pool + NVME_ADMIN_SQ_OFFSET;
    s->admin_q.cq = (volatile struct nvme_cqe *)(s->pool + NVME_ADMIN_CQ_OFFSET);
    s->admin_q.sq_bus = s->pool_bus + NVME_ADMIN_SQ_OFFSET;
    s->admin_q.cq_bus = s->pool_bus + NVME_ADMIN_CQ_OFFSET;
    s->io_q.sq = s->pool + NVME_IO_SQ_OFFSET;
    s->io_q.cq = (volatile struct nvme_cqe *)(s->pool + NVME_IO_CQ_OFFSET);
    s->io_q.sq_bus = s->pool_bus + NVME_IO_SQ_OFFSET;
    s->io_q.cq_bus = s->pool_bus + NVME_IO_CQ_OFFSET;
    memset(&s->pending, 0, sizeof(s->pending));
}

static int start_controller(struct shadow_agent *s, uint32_t guest_cc)
{
    uint16_t asq_depth = (uint16_t)((s->guest_aqa & 0x0fffU) + 1U);
    uint16_t acq_depth = (uint16_t)(((s->guest_aqa >> 16) & 0x0fffU) + 1U);
    uint16_t depth = asq_depth < acq_depth ? asq_depth : acq_depth;

    if (!depth || depth > NVME_MAX_Q_DEPTH || asq_depth != acq_depth ||
        !s->guest_asq || !s->guest_acq ||
        (guest_cc & NVME_CC_MPS_MASK) != 0 ||
        (guest_cc & NVME_CC_IOSQES_MASK) != NVME_CC_IOSQES_64B ||
        (guest_cc & NVME_CC_IOCQES_MASK) != NVME_CC_IOCQES_16B) {
        errno = EINVAL;
        return -1;
    }
    if (disable_controller(s)) return -1;
    reset_queue_state(s, depth);
    reg_write32(s, NVME_REG_AQA,
                ((uint32_t)(depth - 1U) << 16) | (depth - 1U));
    reg_write64(s, NVME_REG_ASQ, s->admin_q.sq_bus);
    reg_write64(s, NVME_REG_ACQ, s->admin_q.cq_bus);
    __sync_synchronize();
    reg_write32(s, NVME_REG_INTMS, 0xffffffffU);
    reg_write32(s, NVME_REG_CC, guest_cc);
    return 0;
}

static uint32_t doorbell_offset(struct shadow_agent *s, uint16_t qid, bool cq)
{
    uint64_t index = (uint64_t)qid * 2U + (cq ? 1U : 0U);
    uint64_t off = NVME_DOORBELL_BASE + index * s->doorbell_stride;
    return off <= UINT32_MAX ? (uint32_t)off : UINT32_MAX;
}

static int ring_sq(struct shadow_agent *s, struct queue_state *q)
{
    uint32_t off = doorbell_offset(s, q->qid, false);
    if (off == UINT32_MAX || off > s->bar0_size - 4U) {
        errno = ERANGE;
        return -1;
    }
    __sync_synchronize();
    reg_write32(s, off, q->sq_tail);
    return 0;
}

static int ring_cq(struct shadow_agent *s, struct queue_state *q)
{
    uint32_t off = doorbell_offset(s, q->qid, true);
    if (off == UINT32_MAX || off > s->bar0_size - 4U) {
        errno = ERANGE;
        return -1;
    }
    reg_write32(s, off, q->cq_head);
    return 0;
}

static int build_data_prps(struct shadow_agent *s, uint8_t command[64],
                           uint32_t data_len)
{
    uint64_t data_bus = s->pool_bus + NVME_DATA_OFFSET;
    uint32_t first_len;
    uint32_t remaining;
    uint64_t next_page;
    uint64_t *list;
    uint32_t pages;
    uint32_t i;

    if (!data_len) {
        put_le64(command + 24, 0);
        put_le64(command + 32, 0);
        return 0;
    }
    if (data_len > NVME_DATA_SIZE) {
        errno = E2BIG;
        return -1;
    }
    put_le64(command + 24, data_bus);
    first_len = NVME_PAGE_SIZE - (uint32_t)(data_bus & (NVME_PAGE_SIZE - 1U));
    if (first_len > data_len) first_len = data_len;
    remaining = data_len - first_len;
    if (!remaining) {
        put_le64(command + 32, 0);
        return 0;
    }
    next_page = (data_bus + first_len + NVME_PAGE_SIZE - 1U) &
                ~(uint64_t)(NVME_PAGE_SIZE - 1U);
    if (remaining <= NVME_PAGE_SIZE) {
        put_le64(command + 32, next_page);
        return 0;
    }
    pages = (remaining + NVME_PAGE_SIZE - 1U) / NVME_PAGE_SIZE;
    if (pages > NVME_PRP_LIST_SIZE / sizeof(uint64_t)) {
        errno = E2BIG;
        return -1;
    }
    list = (uint64_t *)(s->pool + NVME_PRP_LIST_OFFSET);
    memset(list, 0, NVME_PRP_LIST_SIZE);
    for (i = 0; i < pages; i++) list[i] = htole64(next_page + (uint64_t)i * NVME_PAGE_SIZE);
    __sync_synchronize();
    put_le64(command + 32, s->pool_bus + NVME_PRP_LIST_OFFSET);
    return 0;
}

static int raw_admin_identify_namespace(struct shadow_agent *s)
{
    uint8_t cmd[64] = { 0 };
    struct queue_state *q = &s->admin_q;
    volatile struct nvme_cqe *cqe;
    uint64_t deadline;
    uint16_t status;
    uint8_t *id = s->pool + NVME_DATA_OFFSET;
    uint8_t flbas, lbaf;

    memset(id, 0, 4096);
    cmd[0] = NVME_ADMIN_IDENTIFY;
    cmd[2] = 0xa5;
    cmd[3] = 0x5a;
    put_le32(cmd + 4, s->opt.namespace_id);
    put_le64(cmd + 24, s->pool_bus + NVME_DATA_OFFSET);
    put_le32(cmd + 40, NVME_IDENTIFY_CNS_NAMESPACE);
    memcpy(q->sq + (uint64_t)q->sq_tail * 64U, cmd, sizeof(cmd));
    q->sq_tail = (q->sq_tail + 1U) % q->depth;
    if (ring_sq(s, q)) return -1;
    deadline = now_ms() + controller_timeout_ms(s);
    for (;;) {
        cqe = &q->cq[q->cq_head];
        status = le16toh(cqe->status);
        if (!!(status & 1U) == q->cq_phase) break;
        if (now_ms() >= deadline) {
            errno = ETIMEDOUT;
            return -1;
        }
        usleep(100);
    }
    __sync_synchronize();
    if (le16toh(cqe->sq_id) != 0 || le16toh(cqe->cid) != 0x5aa5U ||
        (status & ~1U)) {
        errno = EIO;
        return -1;
    }
    q->cq_head++;
    if (q->cq_head == q->depth) {
        q->cq_head = 0;
        q->cq_phase = !q->cq_phase;
    }
    if (ring_cq(s, q)) return -1;
    memcpy(&s->namespace_blocks, id, sizeof(s->namespace_blocks));
    s->namespace_blocks = le64toh(s->namespace_blocks);
    flbas = id[26] & 0x0fU;
    lbaf = id[128U + (uint32_t)flbas * 4U + 2U];
    if (!s->namespace_blocks || lbaf < 9U || lbaf > 30U) {
        errno = EPROTO;
        return -1;
    }
    s->lba_shift = lbaf;
    return 0;
}

static int bootstrap_identify(struct shadow_agent *s)
{
    uint32_t cc = NVME_CC_IOSQES_64B | NVME_CC_IOCQES_16B | NVME_CC_EN;
    if (disable_controller(s)) return -1;
    s->guest_aqa = ((NVME_ADMIN_BOOT_DEPTH - 1U) << 16) |
                   (NVME_ADMIN_BOOT_DEPTH - 1U);
    reset_queue_state(s, NVME_ADMIN_BOOT_DEPTH);
    reg_write32(s, NVME_REG_AQA, s->guest_aqa);
    reg_write64(s, NVME_REG_ASQ, s->admin_q.sq_bus);
    reg_write64(s, NVME_REG_ACQ, s->admin_q.cq_bus);
    reg_write32(s, NVME_REG_CC, cc);
    if (wait_csts(s, true)) return -1;
    reg_write32(s, NVME_REG_INTMS, 0xffffffffU);
    if (raw_admin_identify_namespace(s) || disable_controller(s)) {
        return -1;
    }
    s->guest_aqa = 0;
    reset_queue_state(s, NVME_ADMIN_BOOT_DEPTH);
    return 0;
}

static int poll_wc(struct ibv_cq *cq, enum ibv_wc_opcode expected)
{
    struct ibv_wc wc;
    uint64_t deadline = now_ms() + RDMA_COMPLETION_TIMEOUT_MS;

    while (now_ms() < deadline) {
        int ret = ibv_poll_cq(cq, 1, &wc);
        if (ret < 0) return -1;
        if (!ret) {
            usleep(NVME_POLL_US);
            continue;
        }
        if (wc.status != IBV_WC_SUCCESS || wc.opcode != expected) {
            fprintf(stderr, "RDMA completion failed: opcode=%u status=%s\n",
                    wc.opcode, ibv_wc_status_str(wc.status));
            errno = EIO;
            return -1;
        }
        return 0;
    }
    fprintf(stderr,
            "RDMA completion timeout: expected_opcode=%u timeout_ms=%u\n",
            expected, RDMA_COMPLETION_TIMEOUT_MS);
    errno = ETIMEDOUT;
    return -1;
}

static int post_recv(struct shadow_agent *s)
{
    int ret;

    if (s->recv_posted) return 0;
    memset(s->rx, 0, sizeof(*s->rx));
    ret = rdma_post_recv(s->id, s->rx, s->rx, sizeof(*s->rx), s->rx_mr);
    if (!ret) s->recv_posted = true;
    return ret;
}

static void init_response(struct shadow_agent *s, uint16_t opcode,
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

static int send_response(struct shadow_agent *s, size_t payload_len)
{
    size_t length = sizeof(s->tx->hdr) + payload_len;

    /* Keep an RQ entry available before the peer observes this response and
     * sends its next ordered request.  The agent processes that entry only
     * after the current response SEND has completed. */
    if (!stop_requested && post_recv(s)) return -1;
    if (rdma_post_send(s->id, s->tx, s->tx, length, s->tx_mr,
                       IBV_SEND_SIGNALED)) return -1;
    return poll_wc(s->id->send_cq, IBV_WC_SEND);
}

static bool validate_header(struct shadow_agent *s,
                            const struct scope_remote_message *msg,
                            bool first)
{
    if (le32toh(msg->hdr.magic) != SCOPE_REMOTE_MAGIC ||
        le16toh(msg->hdr.major) != SCOPE_REMOTE_PROTO_MAJOR ||
        le16toh(msg->hdr.minor) > SCOPE_REMOTE_PROTO_MINOR ||
        le32toh(msg->hdr.payload_len) > sizeof(msg->payload) ||
        le32toh(msg->hdr.reserved)) return false;
    if (!first && (le64toh(msg->hdr.session_id) != s->session_id ||
                   le64toh(msg->hdr.generation) != s->generation)) return false;
    return true;
}

static int rdma_payload(struct shadow_agent *s, bool write_to_peer,
                        uint64_t remote_addr, void *local, uint32_t length)
{
    struct ibv_sge sge = {
        .addr = (uintptr_t)local,
        .length = length,
        .lkey = s->pool_mr->lkey,
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

    if (!length || remote_addr < s->peer_base || length > s->peer_length ||
        remote_addr - s->peer_base > s->peer_length - length) {
        errno = ERANGE;
        return -1;
    }
    if (ibv_post_send(s->id->qp, &wr, &bad)) return -1;
    return poll_wc(s->id->send_cq,
                   write_to_peer ? IBV_WC_RDMA_WRITE : IBV_WC_RDMA_READ);
}

static int transfer_segments(struct shadow_agent *s,
                             struct pending_nvme *p, bool write_to_peer)
{
    uint32_t total = p->data_len;
    uint32_t offset = 0;
    uint32_t i;

    if (p->segment_count > SCOPE_REMOTE_MAX_SEGMENTS || total > NVME_DATA_SIZE) {
        errno = E2BIG;
        return -1;
    }
    for (i = 0; i < p->segment_count; i++) {
        uint64_t remote = p->segments[i].guest_pa;
        uint32_t length = p->segments[i].length;
        if (!length || length > total - offset ||
            rdma_payload(s, write_to_peer, remote,
                         s->pool + NVME_DATA_OFFSET + offset, length)) {
            return -1;
        }
        offset += length;
    }
    return offset == total ? 0 : -1;
}

static int handle_hello(struct shadow_agent *s)
{
    const struct scope_remote_hello *hello = (const void *)s->rx->payload;
    struct scope_remote_hello *rsp;
    uint64_t features = le64toh(hello->features);
    bool direct = (features & SCOPE_REMOTE_NVME_SHADOW_DIRECT_FEATURES) ==
                  SCOPE_REMOTE_NVME_SHADOW_DIRECT_FEATURES;
    bool staging = (features & SCOPE_REMOTE_NVME_SHADOW_STAGING_FEATURES) ==
                   SCOPE_REMOTE_NVME_SHADOW_STAGING_FEATURES;

    if (le32toh(s->rx->hdr.payload_len) != sizeof(*hello) || direct == staging) {
        return -1;
    }
    s->session_id = le64toh(s->rx->hdr.session_id);
    s->generation = le64toh(s->rx->hdr.generation);
    s->peer_base = le64toh(hello->peer_base);
    s->peer_length = le64toh(hello->peer_length);
    s->peer_rkey = le32toh(hello->peer_rkey);
    if (!s->session_id || !s->generation || !s->peer_length || !s->peer_rkey) return -1;
    init_response(s, SCOPE_REMOTE_OP_HELLO_RSP,
                  le64toh(s->rx->hdr.request_id), sizeof(*rsp), 0);
    rsp = (void *)s->tx->payload;
    rsp->features = htole64(direct ? SCOPE_REMOTE_NVME_SHADOW_DIRECT_FEATURES :
                            SCOPE_REMOTE_NVME_SHADOW_STAGING_FEATURES);
    rsp->max_inflight = htole32(1);
    rsp->max_segments = htole32(SCOPE_REMOTE_MAX_SEGMENTS);
    return send_response(s, sizeof(*rsp));
}

static int handle_open(struct shadow_agent *s)
{
    const struct scope_remote_device_open *open_req = (const void *)s->rx->payload;
    struct scope_remote_device_info *info;
    int32_t status = SCOPE_REMOTE_STATUS_OK;

    if (le32toh(s->rx->hdr.payload_len) != sizeof(*open_req) ||
        strnlen(open_req->device_id, sizeof(open_req->device_id)) == sizeof(open_req->device_id) ||
        strcmp(open_req->device_id, s->opt.device_id) ||
        le32toh(open_req->device_type) != SCOPE_REMOTE_DEVICE_NVME ||
        le32toh(open_req->namespace_id) != s->opt.namespace_id) {
        status = SCOPE_REMOTE_STATUS_DEVICE;
    }
    init_response(s, SCOPE_REMOTE_OP_DEVICE_OPEN_RSP,
                  le64toh(s->rx->hdr.request_id), sizeof(*info), status);
    info = (void *)s->tx->payload;
    if (status == SCOPE_REMOTE_STATUS_OK) {
        info->vendor_id = htole16(s->vendor_id);
        info->device_id = htole16(s->device_id);
        info->class_code = htole32(s->class_code);
        info->bar0_size = htole64(s->bar0_size);
        info->nvme_cap = htole64(s->cap);
        info->nvme_vs = htole32(s->vs);
        info->controller_page_size = htole32(NVME_PAGE_SIZE);
        info->namespace_blocks = htole64(s->namespace_blocks);
        info->lba_shift = htole32(s->lba_shift);
        info->max_transfer_bytes = htole32(NVME_DATA_SIZE);
        info->max_inflight = htole32(1);
        info->device_type = htole32(SCOPE_REMOTE_DEVICE_NVME);
        s->opened = true;
    }
    return send_response(s, sizeof(*info));
}

static int stage_nvme(struct shadow_agent *s)
{
    const struct scope_remote_nvme_submit *req = (const void *)s->rx->payload;
    struct pending_nvme *p = &s->pending;
    uint32_t total = 0;
    uint32_t i;

    if (!s->opened || p->valid ||
        le32toh(s->rx->hdr.payload_len) != sizeof(*req)) {
        errno = EBUSY;
        return -1;
    }
    memset(p, 0, sizeof(*p));
    p->request_id = le64toh(s->rx->hdr.request_id);
    p->qid = le32toh(req->qid);
    p->direction = le32toh(req->direction);
    p->data_len = le32toh(req->data_len);
    p->segment_count = le32toh(req->segment_count);
    if (p->segment_count > SCOPE_REMOTE_MAX_SEGMENTS || p->data_len > NVME_DATA_SIZE ||
        (p->qid != 0 && (!s->io_q.sq_valid || p->qid != s->io_q.qid))) {
        errno = EINVAL;
        return -1;
    }
    memcpy(p->command, req->command, sizeof(p->command));
    p->cid = get_le16(p->command + 2);
    for (i = 0; i < p->segment_count; i++) {
        p->segments[i].guest_pa = le64toh(req->segments[i].guest_pa);
        p->segments[i].length = le32toh(req->segments[i].length);
        if (!p->segments[i].length || p->segments[i].length > p->data_len - total) {
            errno = EINVAL;
            return -1;
        }
        total += p->segments[i].length;
    }
    if (total != p->data_len ||
        (!p->data_len && (p->segment_count || p->direction != SCOPE_REMOTE_IO_NONE)) ||
        (p->data_len && p->direction == SCOPE_REMOTE_IO_NONE)) {
        errno = EINVAL;
        return -1;
    }
    if (p->direction == SCOPE_REMOTE_IO_TO_DEVICE &&
        transfer_segments(s, p, false)) {
        return -1;
    }
    p->valid = true;
    return 0;
}

static int prepare_physical_command(struct shadow_agent *s,
                                    struct pending_nvme *p)
{
    uint8_t opcode = p->command[0];
    uint32_t cdw10 = get_le32(p->command + 40);
    uint32_t cdw11 = get_le32(p->command + 44);
    uint16_t qid;
    uint16_t depth;

    if (get_le64(p->command + 16)) {
        errno = ENOTSUP;
        return -1;
    }
    p->admin_kind = PENDING_ADMIN_NONE;
    p->admin_qid = 0;
    p->admin_depth = 0;
    if (p->qid == 0 && opcode == NVME_ADMIN_CREATE_CQ) {
        qid = (uint16_t)(cdw10 & 0xffffU);
        depth = (uint16_t)((cdw10 >> 16) + 1U);
        if (qid != NVME_PHASE1_IO_QID || depth < 2U ||
            depth > NVME_MAX_Q_DEPTH || !(cdw11 & 0x1U) ||
            s->io_q.cq_valid || s->io_q.sq_valid) {
            errno = EINVAL;
            return -1;
        }
        put_le64(p->command + 24, s->io_q.cq_bus);
        put_le64(p->command + 32, 0);
        /* Keep PC, suppress physical interrupts; completions are polled. */
        put_le32(p->command + 44, 0x1U);
        p->admin_kind = PENDING_ADMIN_CREATE_CQ;
        p->admin_qid = qid;
        p->admin_depth = depth;
        return 0;
    }
    if (p->qid == 0 && opcode == NVME_ADMIN_CREATE_SQ) {
        qid = (uint16_t)(cdw10 & 0xffffU);
        depth = (uint16_t)((cdw10 >> 16) + 1U);
        if (qid != NVME_PHASE1_IO_QID || depth < 2U ||
            depth > NVME_MAX_Q_DEPTH || !(cdw11 & 0x1U) ||
            !s->io_q.cq_valid || s->io_q.qid != NVME_PHASE1_IO_QID ||
            ((cdw11 >> 16) & 0xffffU) != NVME_PHASE1_IO_QID ||
            s->io_q.sq_valid) {
            errno = EINVAL;
            return -1;
        }
        put_le64(p->command + 24, s->io_q.sq_bus);
        put_le64(p->command + 32, 0);
        p->admin_kind = PENDING_ADMIN_CREATE_SQ;
        p->admin_qid = qid;
        p->admin_depth = depth;
        return 0;
    }
    if (p->qid == 0 && (opcode == NVME_ADMIN_DELETE_CQ ||
                        opcode == NVME_ADMIN_DELETE_SQ)) {
        qid = (uint16_t)(cdw10 & 0xffffU);
        if (qid != NVME_PHASE1_IO_QID || qid != s->io_q.qid ||
            (opcode == NVME_ADMIN_DELETE_SQ && !s->io_q.sq_valid) ||
            (opcode == NVME_ADMIN_DELETE_CQ &&
             (!s->io_q.cq_valid || s->io_q.sq_valid))) {
            errno = EINVAL;
            return -1;
        }
        p->admin_kind = opcode == NVME_ADMIN_DELETE_CQ ?
            PENDING_ADMIN_DELETE_CQ : PENDING_ADMIN_DELETE_SQ;
        p->admin_qid = qid;
    }
    if (p->qid == 0 && opcode == NVME_ADMIN_SET_FEATURES &&
        (cdw10 & 0xffU) == NVME_FEAT_NUM_QUEUES) {
        put_le32(p->command + 44, 0); /* exactly one I/O SQ/CQ pair */
    }
    return build_data_prps(s, p->command, p->data_len);
}

static int complete_virtual_admin(struct shadow_agent *s, uint16_t status)
{
    struct pending_nvme *p = &s->pending;
    struct scope_remote_nvme_complete *cpl;

    init_response(s, SCOPE_REMOTE_OP_NVME_COMPLETE, p->request_id,
                  sizeof(*cpl), SCOPE_REMOTE_STATUS_OK);
    cpl = (void *)s->tx->payload;
    cpl->sq_id = htole16(0);
    cpl->cid = htole16(p->cid);
    cpl->status = htole16(status & ~1U);
    if (send_response(s, sizeof(*cpl))) {
        return -1;
    }
    memset(p, 0, sizeof(*p));
    return 0;
}

static int submit_pending_to_physical(struct shadow_agent *s, uint16_t qid)
{
    struct pending_nvme *p = &s->pending;
    struct queue_state *q;
    uint8_t *slot;

    if (!p->valid || p->inflight || p->qid != qid ||
        !(s->guest_cc & NVME_CC_EN) || !(reg_read32(s, NVME_REG_CSTS) & NVME_CSTS_RDY)) {
        errno = EBUSY;
        return -1;
    }
    /* AER is long-lived.  With the intentionally single-inflight Phase-1
     * transport, submitting it to hardware would block every later command.
     * Match the existing semantic agent and reject it promptly instead. */
    if (qid == 0 && p->command[0] == NVME_ADMIN_ASYNC_EVENT) {
        return complete_virtual_admin(s, NVME_SC_INVALID_OPCODE);
    }
    q = qid == 0 ? &s->admin_q : &s->io_q;
    if (!q->sq_valid || !q->depth) {
        errno = EINVAL;
        return -1;
    }
    if (prepare_physical_command(s, p)) return -1;
    slot = q->sq + (uint64_t)q->sq_tail * 64U;
    memcpy(slot, p->command, sizeof(p->command));
    q->sq_tail++;
    if (q->sq_tail == q->depth) q->sq_tail = 0;
    if (ring_sq(s, q)) return -1;
    p->inflight = true;
    return 0;
}

static void commit_admin_completion(struct shadow_agent *s,
                                    const struct pending_nvme *p,
                                    uint16_t status)
{
    if (status & ~1U) return;
    switch (p->admin_kind) {
    case PENDING_ADMIN_CREATE_CQ:
        s->io_q.qid = p->admin_qid;
        s->io_q.depth = p->admin_depth;
        s->io_q.cq_head = 0;
        s->io_q.cq_phase = true;
        s->io_q.cq_valid = true;
        memset((void *)s->io_q.cq, 0, NVME_IO_CQ_SIZE);
        break;
    case PENDING_ADMIN_CREATE_SQ:
        s->io_q.qid = p->admin_qid;
        s->io_q.depth = p->admin_depth;
        s->io_q.sq_tail = 0;
        s->io_q.sq_valid = true;
        memset(s->io_q.sq, 0, NVME_IO_SQ_SIZE);
        break;
    case PENDING_ADMIN_DELETE_SQ:
        s->io_q.sq_valid = false;
        s->io_q.sq_tail = 0;
        break;
    case PENDING_ADMIN_DELETE_CQ:
        s->io_q.cq_valid = false;
        s->io_q.cq_head = 0;
        s->io_q.cq_phase = true;
        if (!s->io_q.sq_valid) s->io_q.qid = 0;
        break;
    default:
        break;
    }
}

static int send_nvme_completion(struct shadow_agent *s,
                                struct pending_nvme *p,
                                const struct nvme_cqe *raw,
                                uint16_t status, uint32_t transferred)
{
    struct scope_remote_nvme_complete *cpl;
    init_response(s, SCOPE_REMOTE_OP_NVME_COMPLETE, p->request_id,
                  sizeof(*cpl), SCOPE_REMOTE_STATUS_OK);
    cpl = (void *)s->tx->payload;
    cpl->result = raw->result;
    cpl->sq_head = raw->sq_head;
    cpl->sq_id = htole16((uint16_t)p->qid);
    cpl->cid = htole16(p->cid);
    cpl->status = htole16(status & ~1U);
    cpl->transferred = htole32(transferred);
    return send_response(s, sizeof(*cpl));
}

static int poll_physical_completion(struct shadow_agent *s)
{
    struct pending_nvme *p = &s->pending;
    struct queue_state *q;
    struct nvme_cqe cqe;
    uint16_t status;
    uint32_t transferred = 0;

    if (!p->valid || !p->inflight) return 0;
    q = p->qid == 0 ? &s->admin_q : &s->io_q;
    if (!q->cq_valid || !q->depth) {
        errno = EIO;
        return -1;
    }
    /* Observe the DMA ownership bit before reading the remaining CQE fields. */
    status = le16toh(q->cq[q->cq_head].status);
    if (!!(status & 1U) != q->cq_phase) return 0;
    __sync_synchronize();
    memcpy(&cqe, (const void *)&q->cq[q->cq_head], sizeof(cqe));
    if (le16toh(cqe.sq_id) != p->qid || le16toh(cqe.cid) != p->cid) {
        fprintf(stderr,
                "unexpected NVMe CQE sqid=%u/cid=%u expected=%u/%u\n",
                le16toh(cqe.sq_id), le16toh(cqe.cid), p->qid, p->cid);
        errno = EPROTO;
        return -1;
    }
    if (!(status & ~1U)) {
        if (p->direction == SCOPE_REMOTE_IO_FROM_DEVICE && p->data_len) {
            if (transfer_segments(s, p, true)) {
                status = NVME_SC_DATA_XFER;
            } else {
                transferred = p->data_len;
            }
        } else if (p->direction == SCOPE_REMOTE_IO_TO_DEVICE) {
            transferred = p->data_len;
        }
    }
    if (p->qid == 0) commit_admin_completion(s, p, status);
    if (send_nvme_completion(s, p, &cqe, status, transferred)) return -1;
    q->cq_head++;
    if (q->cq_head == q->depth) {
        q->cq_head = 0;
        q->cq_phase = !q->cq_phase;
    }
    if (ring_cq(s, q)) return -1;
    memset(p, 0, sizeof(*p));
    return 1;
}

static uint32_t apply_wstrb32(uint32_t old, uint32_t value, uint32_t wstrb)
{
    uint32_t i;
    for (i = 0; i < 4; i++) {
        if (wstrb & (1U << i)) {
            uint32_t mask = 0xffU << (i * 8U);
            old = (old & ~mask) | (value & mask);
        }
    }
    return old;
}

static uint64_t apply_wstrb64(uint64_t old, uint64_t value, uint32_t wstrb)
{
    uint32_t i;
    for (i = 0; i < 8; i++) {
        if (wstrb & (1U << i)) {
            uint64_t mask = 0xffULL << (i * 8U);
            old = (old & ~mask) | (value & mask);
        }
    }
    return old;
}

static uint32_t extract_dword(uint64_t value, uint32_t offset)
{
    return (uint32_t)(value >> ((offset & 4U) ? 32U : 0U));
}

static uint32_t extract_wstrb4(uint32_t wstrb, uint32_t offset)
{
    return (wstrb >> ((offset & 4U) ? 4U : 0U)) & 0xfU;
}

static int handle_bar(struct shadow_agent *s, bool write)
{
    const struct scope_remote_bar *req = (const void *)s->rx->payload;
    struct scope_remote_bar *rsp;
    uint64_t request_id;
    uint32_t offset, size, wstrb;
    uint32_t dword, dword_wstrb;
    uint64_t value;
    int32_t status = SCOPE_REMOTE_STATUS_OK;
    uint32_t aligned;

    if (!s->opened || le32toh(s->rx->hdr.payload_len) != sizeof(*req)) return -1;
    request_id = le64toh(s->rx->hdr.request_id);
    offset = le32toh(req->offset);
    size = le32toh(req->size);
    value = le64toh(req->value);
    wstrb = le32toh(req->wstrb);
    fprintf(stderr,
            "NVMe BAR RX request=%" PRIu64 " op=%s off=%04x size=%u "
            "wstrb=%x value=%016" PRIx64 "\n",
            request_id, write ? "write" : "read", offset, size, wstrb,
            value);
    fflush(stderr);
    if (!size || size > 8 || offset > s->bar0_size - size ||
        ((offset & 7U) + size > 8U)) {
        status = SCOPE_REMOTE_STATUS_RANGE;
        goto respond;
    }
    aligned = offset & ~3U;
    dword = extract_dword(value, offset);
    dword_wstrb = extract_wstrb4(wstrb, offset);
    if (!write) {
        if ((offset & ~7U) == NVME_REG_CAP) {
            value = s->cap;
        } else if (aligned == NVME_REG_VS) {
            value = reg_read32(s, NVME_REG_VS);
        } else if (aligned == NVME_REG_CSTS) {
            value = reg_read32(s, NVME_REG_CSTS);
        } else if (aligned == NVME_REG_CC) {
            value = s->guest_cc;
        } else if (aligned == NVME_REG_AQA) {
            value = s->guest_aqa;
        } else if ((offset & ~7U) == NVME_REG_ASQ) {
            value = s->guest_asq;
        } else if ((offset & ~7U) == NVME_REG_ACQ) {
            value = s->guest_acq;
        } else if (aligned == NVME_REG_INTMS || aligned == NVME_REG_INTMC) {
            value = s->guest_int_mask;
        } else if (aligned < NVME_MIN_BAR0_SIZE) {
            value = s->guest_bar_shadow[aligned >> 2];
        } else {
            value = 0;
        }
        goto respond;
    }

    if ((offset & ~7U) == NVME_REG_ASQ) {
        if (s->guest_cc & NVME_CC_EN) {
            status = SCOPE_REMOTE_STATUS_BUSY;
        } else {
            s->guest_asq = apply_wstrb64(s->guest_asq, value, wstrb);
        }
    } else if ((offset & ~7U) == NVME_REG_ACQ) {
        if (s->guest_cc & NVME_CC_EN) {
            status = SCOPE_REMOTE_STATUS_BUSY;
        } else {
            s->guest_acq = apply_wstrb64(s->guest_acq, value, wstrb);
        }
    } else if (aligned == NVME_REG_AQA) {
        if (s->guest_cc & NVME_CC_EN) {
            status = SCOPE_REMOTE_STATUS_BUSY;
        } else {
            s->guest_aqa = apply_wstrb32(s->guest_aqa, dword, dword_wstrb);
        }
    } else if (aligned == NVME_REG_INTMS) {
        s->guest_int_mask |= apply_wstrb32(0, dword, dword_wstrb);
    } else if (aligned == NVME_REG_INTMC) {
        s->guest_int_mask &= ~apply_wstrb32(0, dword, dword_wstrb);
    } else if (aligned == NVME_REG_CC) {
        uint32_t old_cc = s->guest_cc;
        uint32_t new_cc = apply_wstrb32(old_cc, dword, dword_wstrb);
        bool old_en = !!(old_cc & NVME_CC_EN);
        bool new_en = !!(new_cc & NVME_CC_EN);
        bool commit_cc = false;

        if (!old_en && new_en) {
            /*
             * Do not wait for CSTS.RDY here.  This handler owns the only RDMA
             * receive loop, so waiting would prevent the guest's subsequent
             * CSTS reads from reaching the physical controller.  The guest
             * already implements the CAP.TO readiness loop.
             */
            if (start_controller(s, new_cc)) {
                status = errno == ETIMEDOUT ? SCOPE_REMOTE_STATUS_TIMEOUT :
                         SCOPE_REMOTE_STATUS_IO;
            } else {
                commit_cc = true;
            }
        } else if (old_en && !new_en) {
            if (stop_controller(s)) {
                status = errno == ETIMEDOUT ? SCOPE_REMOTE_STATUS_TIMEOUT :
                         SCOPE_REMOTE_STATUS_IO;
            } else {
                commit_cc = true;
                /* RDY may still be set: do not zero DMA-owned queue memory.
                 * start_controller waits for RDY=0 before resetting it. */
                memset(&s->pending, 0, sizeof(s->pending));
                s->admin_q.sq_valid = false;
                s->admin_q.cq_valid = false;
                s->io_q.sq_valid = false;
                s->io_q.cq_valid = false;
            }
        } else if (old_en && new_en && new_cc != old_cc) {
            /* Phase 1 permits only shutdown-notification changes while live. */
            if ((new_cc ^ old_cc) & ~NVME_CC_SHN_MASK) {
                status = SCOPE_REMOTE_STATUS_BUSY;
            } else {
                reg_write32(s, NVME_REG_CC, new_cc);
                commit_cc = true;
            }
        } else {
            commit_cc = true;
        }
        if (commit_cc) {
            s->guest_cc = new_cc;
        }
        value = reg_read32(s, NVME_REG_CSTS);
        fprintf(stderr,
                "NVMe BAR CC old=%08x new=%08x committed=%d status=%d "
                "CSTS=%08" PRIx64 " AQA=%08x ASQ=%016" PRIx64
                " ACQ=%016" PRIx64 "\n",
                old_cc, new_cc, commit_cc, status, value, s->guest_aqa,
                s->guest_asq, s->guest_acq);
        fflush(stderr);
    } else if (aligned >= NVME_DOORBELL_BASE && s->doorbell_stride &&
               ((aligned - NVME_DOORBELL_BASE) % s->doorbell_stride) == 0) {
        uint32_t index = (aligned - NVME_DOORBELL_BASE) / s->doorbell_stride;
        uint16_t qid = (uint16_t)(index >> 1);
        bool cq = !!(index & 1U);
        if (qid > NVME_PHASE1_IO_QID) {
            status = SCOPE_REMOTE_STATUS_UNSUPPORTED;
        } else if (!cq) {
            if (submit_pending_to_physical(s, qid)) {
                status = errno == EBUSY ? SCOPE_REMOTE_STATUS_BUSY :
                         SCOPE_REMOTE_STATUS_IO;
            }
        }
        /* Guest CQ heads are shadow-only; physical CQ head is owned here. */
    } else if (aligned == NVME_REG_NSSR) {
        s->guest_bar_shadow[aligned >> 2] =
            apply_wstrb32(s->guest_bar_shadow[aligned >> 2], dword,
                          dword_wstrb);
    } else if (aligned < NVME_MIN_BAR0_SIZE) {
        s->guest_bar_shadow[aligned >> 2] =
            apply_wstrb32(s->guest_bar_shadow[aligned >> 2], dword,
                          dword_wstrb);
    } else {
        status = SCOPE_REMOTE_STATUS_UNSUPPORTED;
    }

respond:
    init_response(s, write ? SCOPE_REMOTE_OP_BAR_WRITE_RSP :
                             SCOPE_REMOTE_OP_BAR_READ_RSP,
                  request_id, sizeof(*rsp), status);
    rsp = (void *)s->tx->payload;
    rsp->offset = htole32(offset);
    rsp->size = htole32(size);
    rsp->value = htole64(value);
    rsp->wstrb = htole32(wstrb);
    {
        int ret;

        fprintf(stderr,
                "NVMe BAR TX request=%" PRIu64 " op=%s off=%04x status=%d "
                "value=%016" PRIx64 " begin\n",
                request_id, write ? "write" : "read", offset, status,
                value);
        fflush(stderr);
        ret = send_response(s, sizeof(*rsp));
        fprintf(stderr,
                "NVMe BAR TX request=%" PRIu64 " op=%s off=%04x status=%d "
                "ret=%d done\n",
                request_id, write ? "write" : "read", offset, status, ret);
        fflush(stderr);
        return ret;
    }
}

static int handle_reset(struct shadow_agent *s)
{
    int32_t status = SCOPE_REMOTE_STATUS_OK;

    if (disable_controller(s)) {
        status = errno == ETIMEDOUT ? SCOPE_REMOTE_STATUS_TIMEOUT :
                 SCOPE_REMOTE_STATUS_IO;
    } else {
        s->guest_cc = 0;
        s->guest_aqa = 0;
        s->guest_asq = 0;
        s->guest_acq = 0;
        s->guest_int_mask = 0;
        memset(s->guest_bar_shadow, 0, sizeof(s->guest_bar_shadow));
        reset_queue_state(s, NVME_ADMIN_BOOT_DEPTH);
    }
    init_response(s, SCOPE_REMOTE_OP_RESET_RSP,
                  le64toh(s->rx->hdr.request_id), 0, status);
    return send_response(s, 0);
}

static int process_message(struct shadow_agent *s)
{
    uint16_t opcode = le16toh(s->rx->hdr.opcode);

    if (s->first) {
        if (opcode != SCOPE_REMOTE_OP_HELLO || handle_hello(s)) return -1;
        s->first = false;
        return 0;
    }
    switch (opcode) {
    case SCOPE_REMOTE_OP_DEVICE_OPEN:
        return handle_open(s);
    case SCOPE_REMOTE_OP_NVME_SUBMIT:
        return stage_nvme(s);
    case SCOPE_REMOTE_OP_BAR_READ:
        return handle_bar(s, false);
    case SCOPE_REMOTE_OP_BAR_WRITE:
        return handle_bar(s, true);
    case SCOPE_REMOTE_OP_RESET:
        return handle_reset(s);
    case SCOPE_REMOTE_OP_KEEPALIVE:
        init_response(s, SCOPE_REMOTE_OP_KEEPALIVE,
                      le64toh(s->rx->hdr.request_id), 0, 0);
        return send_response(s, 0);
    case SCOPE_REMOTE_OP_CLOSE:
        stop_requested = 1;
        return 0;
    default:
        init_response(s, SCOPE_REMOTE_OP_ERROR,
                      le64toh(s->rx->hdr.request_id), 0,
                      SCOPE_REMOTE_STATUS_UNSUPPORTED);
        return send_response(s, 0);
    }
}

static int serve(struct shadow_agent *s)
{
    struct ibv_wc wc;
    s->first = true;
    if (post_recv(s) || rdma_accept(s->id, NULL)) return -1;
    while (!stop_requested) {
        int ret = ibv_poll_cq(s->id->recv_cq, 1, &wc);
        if (ret < 0) return -1;
        if (ret == 1) {
            s->recv_posted = false;
            if (wc.status != IBV_WC_SUCCESS || !validate_header(s, s->rx, s->first)) {
                errno = EPROTO;
                return -1;
            }
            if (process_message(s)) return -1;
            if (!stop_requested && post_recv(s)) return -1;
        }
        ret = poll_physical_completion(s);
        if (ret < 0) return -1;
        if (!ret) usleep(NVME_POLL_US);
    }
    return 0;
}

static void cleanup(struct shadow_agent *s)
{
    if (s->bar0) (void)disable_controller(s);
    if (s->pci_enabled && s->config_fd >= 0 && s->pci_command_saved) {
        uint16_t cmd = htole16(s->saved_pci_command);
        ssize_t written = pwrite(s->config_fd, &cmd, sizeof(cmd), PCI_COMMAND);

        if (written != sizeof(cmd)) {
            fprintf(stderr, "warning: failed to restore PCI command: %s\n",
                    written < 0 ? strerror(errno) : "short write");
        }
    }
    if (s->id) rdma_disconnect(s->id);
    if (s->pool_mr) ibv_dereg_mr(s->pool_mr);
    if (s->tx_mr) rdma_dereg_mr(s->tx_mr);
    if (s->rx_mr) rdma_dereg_mr(s->rx_mr);
    if (s->id) rdma_destroy_ep(s->id);
    if (s->listen_id) rdma_destroy_ep(s->listen_id);
    if (s->pool) {
        munlock(s->pool, NVME_POOL_SIZE);
        munmap(s->pool, NVME_POOL_SIZE);
    }
    if (s->bar0) munmap((void *)s->bar0, s->bar0_size);
    if (s->pool_fd >= 0) close(s->pool_fd);
    if (s->bar_fd >= 0) close(s->bar_fd);
    if (s->config_fd >= 0) close(s->config_fd);
    if (s->pool_file_created && s->opt.hugepage_file) unlink(s->opt.hugepage_file);
    free(s->tx);
    free(s->rx);
}

int main(int argc, char **argv)
{
    struct shadow_agent s = {
        .bar_fd = -1,
        .config_fd = -1,
        .pool_fd = -1,
    };
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
    if (install_signal_handlers() || verify_pci_identity_and_owner(&s) ||
        open_pci_resources(&s) || enable_pci_memory_busmaster(&s) ||
        allocate_dma_pool(&s)) {
        perror("prepare raw NVMe");
        goto out;
    }
    s.cap = reg_read64(&s, NVME_REG_CAP);
    s.vs = reg_read32(&s, NVME_REG_VS);
    s.doorbell_stride = 4U << ((s.cap >> 32) & 0xfU);
    if (!s.cap || !s.doorbell_stride || bootstrap_identify(&s)) {
        perror("bootstrap raw NVMe");
        goto out;
    }
    fprintf(stderr,
            "NVMe %04x:%04x %s CAP=%016" PRIx64 " VS=%08x nsid=%u blocks=%" PRIu64
            " lba_shift=%u pool_bus=%016" PRIx64 "\n",
            s.vendor_id, s.device_id, s.opt.pci_bdf, s.cap, s.vs,
            s.opt.namespace_id, s.namespace_blocks, s.lba_shift, s.pool_bus);

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
    fprintf(stderr,
            "scope-remote-nvme-shadow-agent build=%s listening on %s:%s "
            "for %s\n",
            NVME_AGENT_BUILD_ID, s.opt.listen_addr, s.opt.service,
            s.opt.device_id);
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
    s.pool_mr = ibv_reg_mr(s.id->pd, s.pool, NVME_POOL_SIZE,
                           IBV_ACCESS_LOCAL_WRITE);
    if (!s.rx_mr || !s.tx_mr || !s.pool_mr) {
        perror("register RDMA memory");
        goto out;
    }
    if (serve(&s)) {
        perror("serve RDMA session");
        ret = EXIT_FAILURE;
    } else {
        ret = EXIT_SUCCESS;
    }

out:
    if (res) rdma_freeaddrinfo(res);
    cleanup(&s);
    return ret;
}
