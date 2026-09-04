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

#define AGENT_DEFAULT_SERVICE            "7472"
#define SHADOW_BAR0_SIZE                 0x20000U
#define SHADOW_POOL_SIZE                 (2U * 1024U * 1024U)
#define SHADOW_RING_DEPTH                256U
#define SHADOW_DESC_SIZE                 16U
#define SHADOW_BUFFER_SIZE               2048U
#define SHADOW_TX_RING_OFFSET            0x0000U
#define SHADOW_RX_RING_OFFSET            0x1000U
#define SHADOW_TX_BUFFER_OFFSET          0x2000U
#define SHADOW_RX_BUFFER_OFFSET          0x82000U
#define SHADOW_TX_TIMEOUT_MS             1000U
#define SHADOW_LINK_WAIT_MS              5000U

#define IXGBE_STATUS                     0x00008U
#define IXGBE_ESDP                       0x00020U
#define IXGBE_EICR                       0x00800U
#define IXGBE_EIMC                       0x00888U
#define IXGBE_EIMC_EX0                   0x00ab0U
#define IXGBE_EIMC_EX1                   0x00ab4U
#define IXGBE_RDBAL0                     0x01000U
#define IXGBE_RDBAH0                     0x01004U
#define IXGBE_RDLEN0                     0x01008U
#define IXGBE_RDH0                       0x01010U
#define IXGBE_RDT0                       0x01018U
#define IXGBE_RXDCTL0                    0x01028U
#define IXGBE_SRRCTL0                    0x02100U
#define IXGBE_RDRXCTL                    0x02f00U
#define IXGBE_RXCTRL                     0x03000U
#define IXGBE_GPRC                       0x04074U
#define IXGBE_GPTC                       0x04080U
#define IXGBE_HLREG0                     0x04240U
#define IXGBE_LINKS                      0x042a4U
#define IXGBE_DMATXCTL                   0x04a80U
#define IXGBE_FCTRL                      0x05080U
#define IXGBE_RAL0                       0x05400U
#define IXGBE_RAH0                       0x05404U
#define IXGBE_TDBAL0                     0x06000U
#define IXGBE_TDBAH0                     0x06004U
#define IXGBE_TDLEN0                     0x06008U
#define IXGBE_TDH0                       0x06010U
#define IXGBE_TDT0                       0x06018U
#define IXGBE_TXDCTL0                    0x06028U

#define IXGBE_QUEUE_ENABLE               0x02000000U
#define IXGBE_ESDP_SDP3                  0x00000008U
#define IXGBE_RXCTRL_RXEN                0x00000001U
#define IXGBE_DMATXCTL_TE                0x00000001U
#define IXGBE_LINKS_UP                   0x40000000U
#define IXGBE_LINKS_SPEED_MASK           0x30000000U
#define IXGBE_LINKS_SPEED_10G            0x30000000U
#define IXGBE_RDRXCTL_CRCSTRIP           0x00000002U
#define IXGBE_HLREG0_RXCRCSTRP           0x00000002U
#define IXGBE_HLREG0_TXCRCEN             0x00000001U
#define IXGBE_FCTRL_MPE                  0x00000100U
#define IXGBE_FCTRL_UPE                  0x00000200U
#define IXGBE_FCTRL_BAM                  0x00000400U
#define IXGBE_SRRCTL_BSIZEPKT_SHIFT      10U
#define IXGBE_SRRCTL_DESCTYPE_ADV_ONEBUF 0x02000000U
#define IXGBE_SRRCTL_DROP_EN             0x10000000U
#define IXGBE_TXDCTL_THRESHOLDS          0x00010120U
#define IXGBE_ADVTXD_DTYP_DATA           0x00300000U
#define IXGBE_ADVTXD_DCMD_EOP            0x01000000U
#define IXGBE_ADVTXD_DCMD_IFCS           0x02000000U
#define IXGBE_ADVTXD_DCMD_RS             0x08000000U
#define IXGBE_ADVTXD_DCMD_DEXT           0x20000000U
#define IXGBE_ADVTXD_PAYLEN_SHIFT        14U
#define IXGBE_ADVTXD_STAT_DD             0x00000001U
#define IXGBE_RXD_STAT_DD                0x00000001U
#define IXGBE_RXD_STAT_EOP               0x00000002U

#define PCI_COMMAND                      0x04U
#define PCI_COMMAND_MEMORY               0x0002U
#define PCI_COMMAND_MASTER               0x0004U
#define PAGEMAP_PRESENT                  (1ULL << 63)
#define PAGEMAP_PFN_MASK                 ((1ULL << 55) - 1U)

struct shadow_options {
    const char *listen_addr;
    const char *service;
    const char *rdma_device;
    const char *device_id;
    const char *pci_bdf;
    const char *hugepage_file;
    bool allow_identity_dma;
    bool restore_sfp_tx_laser;
    bool require_link_up;
};

struct ixgbe_tx_desc {
    uint64_t buffer_addr;
    uint32_t cmd_type_len;
    uint32_t olinfo_status;
} __attribute__((packed));

struct ixgbe_rx_desc {
    union {
        struct {
            uint64_t pkt_addr;
            uint64_t hdr_addr;
        } read;
        struct {
            uint32_t pkt_info;
            uint32_t rss;
            uint32_t status_error;
            uint16_t length;
            uint16_t vlan;
        } wb;
    } u;
} __attribute__((packed));

struct shadow_agent {
    struct shadow_options opt;
    struct rdma_cm_id *listen_id;
    struct rdma_cm_id *id;
    struct ibv_mr *rx_mr;
    struct ibv_mr *tx_mr;
    struct scope_remote_message *rx;
    struct scope_remote_message *tx;
    int bar_fd;
    int config_fd;
    int pool_fd;
    volatile uint8_t *bar0;
    size_t bar0_size;
    uint8_t *pool;
    uint64_t pool_bus;
    volatile struct ixgbe_tx_desc *tx_ring;
    volatile struct ixgbe_rx_desc *rx_ring;
    uint8_t *tx_buffers;
    uint8_t *rx_buffers;
    uint16_t saved_pci_command;
    uint16_t tx_next;
    uint16_t rx_next;
    uint8_t mac[6];
    bool pci_command_saved;
    bool pci_enabled;
    bool pool_file_created;
    bool queues_started;
    bool link_up;
    bool opened;
    bool first;
    uint64_t session_id;
    uint64_t generation;
    uint64_t last_link_check_ms;
    uint64_t rx_packets;
    uint64_t tx_packets;
};

static volatile sig_atomic_t stop_requested;

_Static_assert(sizeof(struct ixgbe_tx_desc) == SHADOW_DESC_SIZE,
               "82599 TX descriptor size changed");
_Static_assert(sizeof(struct ixgbe_rx_desc) == SHADOW_DESC_SIZE,
               "82599 RX descriptor size changed");
_Static_assert(SHADOW_RX_BUFFER_OFFSET +
               SHADOW_RING_DEPTH * SHADOW_BUFFER_SIZE <= SHADOW_POOL_SIZE,
               "shadow pool layout exceeds hugepage");

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s --listen ADDR --rdma-device DEV --device-id ID "
            "--pci-bdf DDDD:BB:DD.F --hugepage-file PATH "
            "--allow-unsafe-identity-dma [--restore-sfp-tx-laser] "
            "[--require-link-up] [--service 7472]\n",
            prog);
}

static void request_stop(int signo)
{
    (void)signo;
    stop_requested = 1;
}

static int install_signal_handlers(void)
{
    struct sigaction action = {
        .sa_handler = request_stop,
    };

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

static bool parse_options(int argc, char **argv, struct shadow_options *opt)
{
    static const struct option options[] = {
        { "listen", required_argument, NULL, 'l' },
        { "service", required_argument, NULL, 's' },
        { "rdma-device", required_argument, NULL, 'r' },
        { "device-id", required_argument, NULL, 'd' },
        { "pci-bdf", required_argument, NULL, 'p' },
        { "hugepage-file", required_argument, NULL, 'H' },
        { "allow-unsafe-identity-dma", no_argument, NULL, 'I' },
        { "restore-sfp-tx-laser", no_argument, NULL, 'L' },
        { "require-link-up", no_argument, NULL, 'U' },
        { "help", no_argument, NULL, 'h' },
        { NULL, 0, NULL, 0 },
    };
    int ch;

    *opt = (struct shadow_options) { .service = AGENT_DEFAULT_SERVICE };
    while ((ch = getopt_long(argc, argv, "l:s:r:d:p:H:ILUh", options,
                             NULL)) != -1) {
        switch (ch) {
        case 'l': opt->listen_addr = optarg; break;
        case 's': opt->service = optarg; break;
        case 'r': opt->rdma_device = optarg; break;
        case 'd': opt->device_id = optarg; break;
        case 'p': opt->pci_bdf = optarg; break;
        case 'H': opt->hugepage_file = optarg; break;
        case 'I': opt->allow_identity_dma = true; break;
        case 'L': opt->restore_sfp_tx_laser = true; break;
        case 'U': opt->require_link_up = true; break;
        default: return false;
        }
    }
    return opt->listen_addr && opt->rdma_device && opt->device_id &&
           opt->pci_bdf && opt->hugepage_file && opt->allow_identity_dma &&
           valid_bdf(opt->pci_bdf) && opt->hugepage_file[0] == '/' &&
           strlen(opt->device_id) < SCOPE_REMOTE_MAX_DEVICE_ID;
}

static uint64_t now_ms(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000U + ts.tv_nsec / 1000000U;
}

static uint32_t reg_read(struct shadow_agent *s, uint32_t offset)
{
    volatile uint32_t *reg;

    if (!s->bar0 || offset > s->bar0_size - sizeof(*reg)) {
        return 0;
    }
    reg = (volatile uint32_t *)(s->bar0 + offset);
    return le32toh(*reg);
}

static void reg_write(struct shadow_agent *s, uint32_t offset, uint32_t value)
{
    volatile uint32_t *reg;

    if (!s->bar0 || offset > s->bar0_size - sizeof(*reg)) {
        return;
    }
    reg = (volatile uint32_t *)(s->bar0 + offset);
    *reg = htole32(value);
    (void)reg_read(s, IXGBE_STATUS);
}

static int read_hex_file(const char *path, unsigned int *value)
{
    FILE *file = fopen(path, "r");
    int ret = -1;

    if (file) {
        ret = fscanf(file, "%x", value) == 1 ? 0 : -1;
        fclose(file);
    }
    return ret;
}

static int verify_pci_identity_and_owner(struct shadow_agent *s)
{
    char path[PATH_MAX];
    struct stat st;
    unsigned int vendor, device;

    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/vendor",
             s->opt.pci_bdf);
    if (read_hex_file(path, &vendor)) {
        return -1;
    }
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/device",
             s->opt.pci_bdf);
    if (read_hex_file(path, &device)) {
        return -1;
    }
    if (vendor != 0x8086U || device != 0x10fbU) {
        fprintf(stderr, "%s is %04x:%04x, expected Intel 82599 8086:10fb\n",
                s->opt.pci_bdf, vendor, device);
        errno = ENODEV;
        return -1;
    }
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/driver",
             s->opt.pci_bdf);
    if (!lstat(path, &st)) {
        fprintf(stderr, "%s is still bound to a kernel driver\n",
                s->opt.pci_bdf);
        errno = EBUSY;
        return -1;
    }
    return errno == ENOENT ? 0 : -1;
}

static int open_pci_resources(struct shadow_agent *s)
{
    char path[PATH_MAX];
    struct stat st;

    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource0",
             s->opt.pci_bdf);
    s->bar_fd = open(path, O_RDWR | O_SYNC | O_CLOEXEC);
    if (s->bar_fd < 0 || fstat(s->bar_fd, &st)) {
        return -1;
    }
    if (st.st_size < SHADOW_BAR0_SIZE) {
        fprintf(stderr, "82599 BAR0 is only %jd bytes\n", (intmax_t)st.st_size);
        errno = ERANGE;
        return -1;
    }
    s->bar0_size = SHADOW_BAR0_SIZE;
    s->bar0 = mmap(NULL, s->bar0_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                   s->bar_fd, 0);
    if (s->bar0 == MAP_FAILED) {
        s->bar0 = NULL;
        return -1;
    }

    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/config",
             s->opt.pci_bdf);
    s->config_fd = open(path, O_RDWR | O_CLOEXEC);
    return s->config_fd < 0 ? -1 : 0;
}

static int pool_physical_base(void *pool, size_t length, uint64_t *base)
{
    const uint64_t page_size = (uint64_t)sysconf(_SC_PAGESIZE);
    const uintptr_t address = (uintptr_t)pool;
    uint64_t first = 0;
    int fd = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC);
    size_t offset;

    if (fd < 0 || !page_size || (address & (page_size - 1U))) {
        if (fd >= 0) close(fd);
        errno = EINVAL;
        return -1;
    }
    for (offset = 0; offset < length; offset += page_size) {
        uint64_t entry;
        uint64_t pfn;
        off_t pos = (off_t)(((address + offset) / page_size) * sizeof(entry));

        if (pread(fd, &entry, sizeof(entry), pos) != sizeof(entry) ||
            !(entry & PAGEMAP_PRESENT) || !(entry & PAGEMAP_PFN_MASK)) {
            close(fd);
            errno = EPERM;
            return -1;
        }
        pfn = entry & PAGEMAP_PFN_MASK;
        if (!offset) {
            first = pfn;
        } else if (pfn != first + offset / page_size) {
            close(fd);
            errno = EXDEV;
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

    s->pool_fd = open(s->opt.hugepage_file,
                      O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (s->pool_fd < 0 || fstatfs(s->pool_fd, &fs)) {
        return -1;
    }
    s->pool_file_created = true;
    if ((unsigned long)fs.f_type != HUGETLBFS_MAGIC) {
        fprintf(stderr, "%s is not on hugetlbfs\n", s->opt.hugepage_file);
        errno = EINVAL;
        return -1;
    }
    if (ftruncate(s->pool_fd, SHADOW_POOL_SIZE)) {
        return -1;
    }
    s->pool = mmap(NULL, SHADOW_POOL_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
                   s->pool_fd, 0);
    if (s->pool == MAP_FAILED) {
        s->pool = NULL;
        return -1;
    }
    memset(s->pool, 0, SHADOW_POOL_SIZE);
    if (mlock(s->pool, SHADOW_POOL_SIZE) ||
        pool_physical_base(s->pool, SHADOW_POOL_SIZE, &s->pool_bus)) {
        return -1;
    }
    s->tx_ring = (volatile struct ixgbe_tx_desc *)(s->pool +
                                                   SHADOW_TX_RING_OFFSET);
    s->rx_ring = (volatile struct ixgbe_rx_desc *)(s->pool +
                                                   SHADOW_RX_RING_OFFSET);
    s->tx_buffers = s->pool + SHADOW_TX_BUFFER_OFFSET;
    s->rx_buffers = s->pool + SHADOW_RX_BUFFER_OFFSET;
    return 0;
}

static int set_pci_bus_master(struct shadow_agent *s, bool enable)
{
    uint16_t command;

    if (enable) {
        if (pread(s->config_fd, &command, sizeof(command), PCI_COMMAND) !=
            sizeof(command)) {
            return -1;
        }
        s->saved_pci_command = le16toh(command);
        s->pci_command_saved = true;
        command = htole16(s->saved_pci_command | PCI_COMMAND_MEMORY |
                          PCI_COMMAND_MASTER);
    } else {
        command = htole16(s->pci_command_saved ?
                          (s->saved_pci_command & ~PCI_COMMAND_MASTER) : 0);
    }
    if (pwrite(s->config_fd, &command, sizeof(command), PCI_COMMAND) !=
        sizeof(command)) {
        return -1;
    }
    if (pread(s->config_fd, &command, sizeof(command), PCI_COMMAND) !=
        sizeof(command)) {
        return -1;
    }
    command = le16toh(command);
    return enable ?
        ((command & (PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER)) ==
         (PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER) ? 0 : -1) :
        (!(command & PCI_COMMAND_MASTER) ? 0 : -1);
}

static int wait_queue_state(struct shadow_agent *s, uint32_t reg, bool enabled)
{
    uint64_t deadline = now_ms() + 100U;

    do {
        if (!!(reg_read(s, reg) & IXGBE_QUEUE_ENABLE) == enabled) {
            return 0;
        }
        usleep(100);
    } while (now_ms() < deadline);
    errno = ETIMEDOUT;
    return -1;
}

static void read_mac_and_link(struct shadow_agent *s)
{
    uint32_t ral = reg_read(s, IXGBE_RAL0);
    uint32_t rah = reg_read(s, IXGBE_RAH0);
    uint32_t links = reg_read(s, IXGBE_LINKS);

    s->mac[0] = ral;
    s->mac[1] = ral >> 8;
    s->mac[2] = ral >> 16;
    s->mac[3] = ral >> 24;
    s->mac[4] = rah;
    s->mac[5] = rah >> 8;
    s->link_up = !!(links & IXGBE_LINKS_UP);
}

static int restore_sfp_tx_laser_and_wait(struct shadow_agent *s)
{
    uint32_t esdp_before = reg_read(s, IXGBE_ESDP);
    uint64_t deadline;

    if (esdp_before & IXGBE_ESDP_SDP3) {
        reg_write(s, IXGBE_ESDP, esdp_before & ~IXGBE_ESDP_SDP3);
        (void)reg_read(s, IXGBE_STATUS);
    }
    deadline = now_ms() + SHADOW_LINK_WAIT_MS;
    do {
        uint32_t links = reg_read(s, IXGBE_LINKS);

        if (links & IXGBE_LINKS_UP) {
            fprintf(stderr,
                    "restored 82599 SFP TX laser: ESDP 0x%08x -> "
                    "0x%08x, LINKS=0x%08x\n",
                    esdp_before, reg_read(s, IXGBE_ESDP), links);
            return 0;
        }
        usleep(100000);
    } while (now_ms() < deadline);

    fprintf(stderr,
            "82599 link remained down after SFP TX laser restore: "
            "ESDP 0x%08x -> 0x%08x, LINKS=0x%08x\n",
            esdp_before, reg_read(s, IXGBE_ESDP), reg_read(s, IXGBE_LINKS));
    errno = ENOLINK;
    return -1;
}

static void reset_hardware_packet_counters(struct shadow_agent *s)
{
    /* GPRC/GPTC are clear-on-read on the 82599. */
    (void)reg_read(s, IXGBE_GPRC);
    (void)reg_read(s, IXGBE_GPTC);
}

static void print_hardware_packet_counters(struct shadow_agent *s)
{
    if (s->bar0 && s->pci_enabled) {
        fprintf(stderr, "physical 82599 counters: tx=%u rx=%u\n",
                reg_read(s, IXGBE_GPTC), reg_read(s, IXGBE_GPRC));
    }
}

static int stop_hardware_queues(struct shadow_agent *s)
{
    uint32_t value;
    int ret = 0;

    if (!s->bar0) {
        return 0;
    }
    reg_write(s, IXGBE_EIMC, UINT32_MAX);
    reg_write(s, IXGBE_EIMC_EX0, UINT32_MAX);
    reg_write(s, IXGBE_EIMC_EX1, UINT32_MAX);
    value = reg_read(s, IXGBE_RXCTRL) & ~IXGBE_RXCTRL_RXEN;
    reg_write(s, IXGBE_RXCTRL, value);
    value = reg_read(s, IXGBE_DMATXCTL) & ~IXGBE_DMATXCTL_TE;
    reg_write(s, IXGBE_DMATXCTL, value);
    value = reg_read(s, IXGBE_RXDCTL0) & ~IXGBE_QUEUE_ENABLE;
    reg_write(s, IXGBE_RXDCTL0, value);
    if (wait_queue_state(s, IXGBE_RXDCTL0, false)) {
        ret = -1;
    }
    value = reg_read(s, IXGBE_TXDCTL0) & ~IXGBE_QUEUE_ENABLE;
    reg_write(s, IXGBE_TXDCTL0, value);
    if (wait_queue_state(s, IXGBE_TXDCTL0, false)) {
        ret = -1;
    }
    s->queues_started = false;
    return ret;
}

static int start_hardware_queues(struct shadow_agent *s)
{
    uint64_t tx_ring_bus = s->pool_bus + SHADOW_TX_RING_OFFSET;
    uint64_t rx_ring_bus = s->pool_bus + SHADOW_RX_RING_OFFSET;
    uint32_t i;
    uint32_t value;

    reg_write(s, IXGBE_EIMC, UINT32_MAX);
    reg_write(s, IXGBE_EIMC_EX0, UINT32_MAX);
    reg_write(s, IXGBE_EIMC_EX1, UINT32_MAX);
    (void)reg_read(s, IXGBE_EICR);
    if (stop_hardware_queues(s)) {
        return -1;
    }

    memset((void *)s->tx_ring, 0, SHADOW_RING_DEPTH * SHADOW_DESC_SIZE);
    memset((void *)s->rx_ring, 0, SHADOW_RING_DEPTH * SHADOW_DESC_SIZE);
    for (i = 0; i < SHADOW_RING_DEPTH; i++) {
        s->rx_ring[i].u.read.pkt_addr = htole64(
            s->pool_bus + SHADOW_RX_BUFFER_OFFSET +
            (uint64_t)i * SHADOW_BUFFER_SIZE);
    }

    reg_write(s, IXGBE_TDBAL0, (uint32_t)tx_ring_bus);
    reg_write(s, IXGBE_TDBAH0, (uint32_t)(tx_ring_bus >> 32));
    reg_write(s, IXGBE_TDLEN0, SHADOW_RING_DEPTH * SHADOW_DESC_SIZE);
    reg_write(s, IXGBE_TDH0, 0);
    reg_write(s, IXGBE_TDT0, 0);

    reg_write(s, IXGBE_RDBAL0, (uint32_t)rx_ring_bus);
    reg_write(s, IXGBE_RDBAH0, (uint32_t)(rx_ring_bus >> 32));
    reg_write(s, IXGBE_RDLEN0, SHADOW_RING_DEPTH * SHADOW_DESC_SIZE);
    reg_write(s, IXGBE_RDH0, 0);
    reg_write(s, IXGBE_RDT0, 0);
    reg_write(s, IXGBE_SRRCTL0,
              (SHADOW_BUFFER_SIZE >> IXGBE_SRRCTL_BSIZEPKT_SHIFT) |
              IXGBE_SRRCTL_DESCTYPE_ADV_ONEBUF |
              IXGBE_SRRCTL_DROP_EN);

    /*
     * Keep multicast promiscuous until guest MTA programming is mirrored, but
     * do not receive unrelated unicast traffic from the Host B network.
     * RAL0/RAH0 retain the exported MAC address read during preflight.
     */
    value = (reg_read(s, IXGBE_FCTRL) & ~IXGBE_FCTRL_UPE) |
            IXGBE_FCTRL_MPE | IXGBE_FCTRL_BAM;
    reg_write(s, IXGBE_FCTRL, value);
    reg_write(s, IXGBE_RDRXCTL,
              reg_read(s, IXGBE_RDRXCTL) | IXGBE_RDRXCTL_CRCSTRIP);
    reg_write(s, IXGBE_HLREG0,
              reg_read(s, IXGBE_HLREG0) | IXGBE_HLREG0_RXCRCSTRP |
              IXGBE_HLREG0_TXCRCEN);

    reg_write(s, IXGBE_DMATXCTL,
              reg_read(s, IXGBE_DMATXCTL) | IXGBE_DMATXCTL_TE);
    value = IXGBE_TXDCTL_THRESHOLDS | IXGBE_QUEUE_ENABLE;
    reg_write(s, IXGBE_TXDCTL0, value);
    if (wait_queue_state(s, IXGBE_TXDCTL0, true)) {
        return -1;
    }
    value = reg_read(s, IXGBE_RXDCTL0) | IXGBE_QUEUE_ENABLE;
    reg_write(s, IXGBE_RXDCTL0, value);
    if (wait_queue_state(s, IXGBE_RXDCTL0, true)) {
        return -1;
    }
    reg_write(s, IXGBE_RXCTRL,
              reg_read(s, IXGBE_RXCTRL) | IXGBE_RXCTRL_RXEN);
    __sync_synchronize();
    reg_write(s, IXGBE_RDT0, SHADOW_RING_DEPTH - 1U);
    s->tx_next = 0;
    s->rx_next = 0;
    s->queues_started = true;
    return 0;
}

static int poll_send_completion(struct shadow_agent *s)
{
    struct ibv_wc wc;

    while (!stop_requested) {
        int ret = ibv_poll_cq(s->id->send_cq, 1, &wc);

        if (ret < 0) return -1;
        if (!ret) {
            usleep(20);
            continue;
        }
        if (wc.status != IBV_WC_SUCCESS || wc.opcode != IBV_WC_SEND) {
            fprintf(stderr, "RDMA send failed: %s\n",
                    ibv_wc_status_str(wc.status));
            return -1;
        }
        return 0;
    }
    errno = EINTR;
    return -1;
}

static int post_recv(struct shadow_agent *s)
{
    memset(s->rx, 0, sizeof(*s->rx));
    return rdma_post_recv(s->id, s->rx, s->rx, sizeof(*s->rx), s->rx_mr);
}

static void init_message(struct shadow_agent *s, uint16_t opcode,
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

static int send_message(struct shadow_agent *s, size_t payload_len)
{
    size_t bytes = sizeof(s->tx->hdr) + payload_len;

    if (rdma_post_send(s->id, s->tx, s->tx, bytes, s->tx_mr,
                       IBV_SEND_SIGNALED)) {
        return -1;
    }
    return poll_send_completion(s);
}

static bool valid_header(struct shadow_agent *s)
{
    if (le32toh(s->rx->hdr.magic) != SCOPE_REMOTE_MAGIC ||
        le16toh(s->rx->hdr.major) != SCOPE_REMOTE_PROTO_MAJOR ||
        le16toh(s->rx->hdr.minor) > SCOPE_REMOTE_PROTO_MINOR ||
        le32toh(s->rx->hdr.payload_len) > sizeof(s->rx->payload)) {
        return false;
    }
    return s->first ||
           (le64toh(s->rx->hdr.session_id) == s->session_id &&
            le64toh(s->rx->hdr.generation) == s->generation);
}

static int handle_hello(struct shadow_agent *s)
{
    const struct scope_remote_hello *hello = (const void *)s->rx->payload;
    struct scope_remote_hello *rsp;
    uint64_t features;

    if (le32toh(s->rx->hdr.payload_len) != sizeof(*hello)) {
        return -1;
    }
    features = le64toh(hello->features);
    if ((features & SCOPE_REMOTE_IXGBE_SHADOW_FEATURES) !=
        SCOPE_REMOTE_IXGBE_SHADOW_FEATURES) {
        fprintf(stderr, "peer did not request ixgbe shadow-ring mode\n");
        return -1;
    }
    s->session_id = le64toh(s->rx->hdr.session_id);
    s->generation = le64toh(s->rx->hdr.generation);
    if (!s->session_id || !s->generation) {
        return -1;
    }
    init_message(s, SCOPE_REMOTE_OP_HELLO_RSP,
                 le64toh(s->rx->hdr.request_id), sizeof(*rsp), 0);
    rsp = (void *)s->tx->payload;
    rsp->features = htole64(SCOPE_REMOTE_IXGBE_SHADOW_FEATURES);
    rsp->max_inflight = htole32(1);
    return send_message(s, sizeof(*rsp));
}

static int handle_open(struct shadow_agent *s)
{
    const struct scope_remote_device_open *req = (const void *)s->rx->payload;
    struct scope_remote_device_info *info;
    bool valid = le32toh(s->rx->hdr.payload_len) == sizeof(*req) &&
                 le32toh(req->device_type) ==
                    SCOPE_REMOTE_DEVICE_IXGBE_PACKET &&
                 strnlen(req->device_id, sizeof(req->device_id)) <
                    sizeof(req->device_id) &&
                 !strcmp(req->device_id, s->opt.device_id);

    read_mac_and_link(s);
    init_message(s, SCOPE_REMOTE_OP_DEVICE_OPEN_RSP,
                 le64toh(s->rx->hdr.request_id), sizeof(*info),
                 valid ? 0 : SCOPE_REMOTE_STATUS_DEVICE);
    info = (void *)s->tx->payload;
    if (valid) {
        info->vendor_id = htole16(0x8086);
        info->device_id = htole16(0x10fb);
        info->class_code = htole32(0x020000);
        info->bar0_size = htole64(SHADOW_BAR0_SIZE);
        info->max_transfer_bytes = htole32(SCOPE_REMOTE_ETHER_MAX_FRAME);
        info->max_inflight = htole32(1);
        info->device_type = htole32(SCOPE_REMOTE_DEVICE_IXGBE_PACKET);
        info->mtu = htole32(1500);
        memcpy(info->mac, s->mac, sizeof(info->mac));
        info->link_up = s->link_up;
        s->opened = true;
    }
    return send_message(s, sizeof(*info));
}

static int submit_physical_tx(struct shadow_agent *s, const uint8_t *data,
                              uint32_t length)
{
    volatile struct ixgbe_tx_desc *desc = &s->tx_ring[s->tx_next];
    uint8_t *buffer = s->tx_buffers +
                      (size_t)s->tx_next * SHADOW_BUFFER_SIZE;
    uint16_t next = (s->tx_next + 1U) % SHADOW_RING_DEPTH;
    uint64_t deadline = now_ms() + SHADOW_TX_TIMEOUT_MS;

    memcpy(buffer, data, length);
    desc->buffer_addr = htole64(s->pool_bus + SHADOW_TX_BUFFER_OFFSET +
                                (uint64_t)s->tx_next * SHADOW_BUFFER_SIZE);
    desc->olinfo_status = htole32(length << IXGBE_ADVTXD_PAYLEN_SHIFT);
    __sync_synchronize();
    desc->cmd_type_len = htole32(length | IXGBE_ADVTXD_DTYP_DATA |
                                 IXGBE_ADVTXD_DCMD_EOP |
                                 IXGBE_ADVTXD_DCMD_IFCS |
                                 IXGBE_ADVTXD_DCMD_RS |
                                 IXGBE_ADVTXD_DCMD_DEXT);
    __sync_synchronize();
    reg_write(s, IXGBE_TDT0, next);
    do {
        __sync_synchronize();
        if (le32toh(desc->olinfo_status) & IXGBE_ADVTXD_STAT_DD) {
            s->tx_next = next;
            return 0;
        }
        if (stop_requested) {
            errno = EINTR;
            return -1;
        }
        usleep(20);
    } while (now_ms() < deadline);
    errno = ETIMEDOUT;
    return -1;
}

static int handle_tx(struct shadow_agent *s)
{
    const struct scope_remote_ether_frame *frame =
        (const void *)s->rx->payload;
    struct scope_remote_ether_complete *complete;
    uint32_t length = le32toh(frame->length);
    int32_t status = 0;

    if (!s->opened || le32toh(s->rx->hdr.payload_len) != sizeof(*frame) ||
        !length || length > SCOPE_REMOTE_ETHER_MAX_FRAME ||
        length > 1518U) {
        status = SCOPE_REMOTE_STATUS_RANGE;
    } else if (submit_physical_tx(s, frame->data, length)) {
        perror("physical 82599 TX");
        status = errno == ETIMEDOUT ? SCOPE_REMOTE_STATUS_TIMEOUT :
                                      SCOPE_REMOTE_STATUS_IO;
    } else {
        s->tx_packets++;
    }
    init_message(s, SCOPE_REMOTE_OP_IXGBE_TX_COMPLETE,
                 le64toh(s->rx->hdr.request_id), sizeof(*complete), status);
    complete = (void *)s->tx->payload;
    complete->length = htole32(status ? 0 : length);
    return send_message(s, sizeof(*complete));
}

static int process_rdma(struct shadow_agent *s)
{
    struct ibv_wc wc;
    uint16_t opcode;
    int ret = ibv_poll_cq(s->id->recv_cq, 1, &wc);

    if (ret <= 0) return ret;
    if (wc.status != IBV_WC_SUCCESS || wc.opcode != IBV_WC_RECV ||
        !valid_header(s)) {
        return -1;
    }
    opcode = le16toh(s->rx->hdr.opcode);
    if (s->first) {
        if (opcode != SCOPE_REMOTE_OP_HELLO || handle_hello(s)) return -1;
        s->first = false;
    } else if (opcode == SCOPE_REMOTE_OP_DEVICE_OPEN) {
        if (handle_open(s)) return -1;
    } else if (opcode == SCOPE_REMOTE_OP_IXGBE_TX) {
        if (handle_tx(s)) return -1;
    } else if (opcode == SCOPE_REMOTE_OP_CLOSE) {
        return 2;
    } else {
        init_message(s, SCOPE_REMOTE_OP_ERROR,
                     le64toh(s->rx->hdr.request_id), 0,
                     SCOPE_REMOTE_STATUS_UNSUPPORTED);
        if (send_message(s, 0)) return -1;
    }
    return post_recv(s) ? -1 : 1;
}

static int send_rx_frame(struct shadow_agent *s)
{
    volatile struct ixgbe_rx_desc *desc = &s->rx_ring[s->rx_next];
    struct scope_remote_ether_frame *frame;
    uint32_t status;
    uint16_t length;
    uint16_t consumed;

    if (!s->opened) return 0;
    __sync_synchronize();
    status = le32toh(desc->u.wb.status_error);
    if (!(status & IXGBE_RXD_STAT_DD)) return 0;
    length = le16toh(desc->u.wb.length);
    consumed = s->rx_next;
    if (!(status & IXGBE_RXD_STAT_EOP) || !length ||
        length > SCOPE_REMOTE_ETHER_MAX_FRAME || length > 1518U) {
        fprintf(stderr, "dropping invalid physical RX descriptor "
                "index=%u status=0x%08x length=%u\n",
                consumed, status, length);
    } else {
        init_message(s, SCOPE_REMOTE_OP_IXGBE_RX, 0, sizeof(*frame), 0);
        frame = (void *)s->tx->payload;
        frame->length = htole32(length);
        memcpy(frame->data,
               s->rx_buffers + (size_t)consumed * SHADOW_BUFFER_SIZE,
               length);
        if (send_message(s, sizeof(*frame))) return -1;
        s->rx_packets++;
    }
    memset((void *)desc, 0, sizeof(*desc));
    desc->u.read.pkt_addr = htole64(
        s->pool_bus + SHADOW_RX_BUFFER_OFFSET +
        (uint64_t)consumed * SHADOW_BUFFER_SIZE);
    __sync_synchronize();
    reg_write(s, IXGBE_RDT0, consumed);
    s->rx_next = (consumed + 1U) % SHADOW_RING_DEPTH;
    return 1;
}

static int send_link_change(struct shadow_agent *s)
{
    struct scope_remote_link_state *link;
    uint32_t links;
    bool old;

    if (!s->opened || now_ms() - s->last_link_check_ms < 500U) return 0;
    s->last_link_check_ms = now_ms();
    old = s->link_up;
    links = reg_read(s, IXGBE_LINKS);
    s->link_up = !!(links & IXGBE_LINKS_UP);
    if (old == s->link_up) return 0;
    init_message(s, SCOPE_REMOTE_OP_IXGBE_LINK, 0, sizeof(*link), 0);
    link = (void *)s->tx->payload;
    link->link_up = htole32(s->link_up);
    link->speed_mbps = htole32(
        s->link_up && (links & IXGBE_LINKS_SPEED_MASK) ==
                         IXGBE_LINKS_SPEED_10G ? 10000 : 0);
    return send_message(s, sizeof(*link)) ? -1 : 1;
}

static int serve(struct shadow_agent *s)
{
    s->first = true;
    if (post_recv(s) || rdma_accept(s->id, NULL)) return -1;
    while (!stop_requested) {
        int ret = process_rdma(s);

        if (ret < 0) return -1;
        if (ret == 2) return 0;
        if (stop_requested) break;
        if (send_rx_frame(s) < 0 || send_link_change(s) < 0) return -1;
        if (!ret) usleep(20);
    }
    return 0;
}

static void cleanup(struct shadow_agent *s)
{
    if (s->bar0 && s->pci_enabled) stop_hardware_queues(s);
    if (s->config_fd >= 0 && s->pci_command_saved) {
        if (set_pci_bus_master(s, false)) {
            perror("clear 82599 bus master");
        }
    }
    if (s->id) rdma_disconnect(s->id);
    if (s->tx_mr) rdma_dereg_mr(s->tx_mr);
    if (s->rx_mr) rdma_dereg_mr(s->rx_mr);
    if (s->id) rdma_destroy_ep(s->id);
    if (s->listen_id) rdma_destroy_ep(s->listen_id);
    if (s->bar0) munmap((void *)s->bar0, s->bar0_size);
    if (s->pool) {
        munlock(s->pool, SHADOW_POOL_SIZE);
        munmap(s->pool, SHADOW_POOL_SIZE);
    }
    if (s->bar_fd >= 0) close(s->bar_fd);
    if (s->config_fd >= 0) close(s->config_fd);
    if (s->pool_fd >= 0) close(s->pool_fd);
    if (s->pool_file_created) unlink(s->opt.hugepage_file);
    free(s->tx);
    free(s->rx);
}

int main(int argc, char **argv)
{
    struct shadow_agent s = {
        .bar_fd = -1, .config_fd = -1, .pool_fd = -1,
    };
    struct rdma_addrinfo hints = {
        .ai_flags = RAI_PASSIVE,
        .ai_port_space = RDMA_PS_TCP,
        .ai_qp_type = IBV_QPT_RC,
    };
    struct rdma_addrinfo *res = NULL;
    struct ibv_qp_init_attr qp = {
        .cap = {
            .max_send_wr = 128, .max_recv_wr = 128,
            .max_send_sge = 1, .max_recv_sge = 1,
        },
        .qp_type = IBV_QPT_RC,
    };
    int result = EXIT_FAILURE;

    if (!parse_options(argc, argv, &s.opt)) {
        usage(argv[0]);
        return result;
    }
    if (install_signal_handlers()) {
        perror("install signal handlers");
        return result;
    }
    if (verify_pci_identity_and_owner(&s) || open_pci_resources(&s) ||
        allocate_dma_pool(&s) || set_pci_bus_master(&s, true)) {
        perror("prepare unbound 82599 identity-DMA resources");
        goto out;
    }
    s.pci_enabled = true;
    if (s.opt.restore_sfp_tx_laser &&
        restore_sfp_tx_laser_and_wait(&s) && s.opt.require_link_up) {
        perror("restore physical 82599 link");
        goto out;
    }
    read_mac_and_link(&s);
    if (s.opt.require_link_up && !s.link_up) {
        errno = ENOLINK;
        perror("physical 82599 link is down");
        goto out;
    }
    if ((s.mac[0] & 1U) || !memcmp(s.mac, "\0\0\0\0\0\0", 6)) {
        fprintf(stderr, "physical 82599 returned an invalid MAC address\n");
        goto out;
    }
    reset_hardware_packet_counters(&s);
    if (start_hardware_queues(&s)) {
        perror("start physical 82599 shadow rings");
        goto out;
    }

    s.rx = aligned_alloc(64, sizeof(*s.rx));
    s.tx = aligned_alloc(64, sizeof(*s.tx));
    if (!s.rx || !s.tx) {
        perror("allocate RDMA messages");
        goto out;
    }
    if (rdma_getaddrinfo((char *)s.opt.listen_addr, (char *)s.opt.service,
                         &hints, &res) ||
        rdma_create_ep(&s.listen_id, res, NULL, &qp) ||
        rdma_listen(s.listen_id, 1)) {
        perror("create RDMA listener");
        goto out;
    }
    rdma_freeaddrinfo(res);
    res = NULL;
    fprintf(stderr, "scope-remote-ixgbe-shadow-agent listening on %s:%s, "
            "exporting %s as 8086:10fb "
            "(%02x:%02x:%02x:%02x:%02x:%02x), pool_bus=0x%" PRIx64
            " link=%s\n", s.opt.listen_addr, s.opt.service, s.opt.pci_bdf,
            s.mac[0], s.mac[1], s.mac[2], s.mac[3], s.mac[4], s.mac[5],
            s.pool_bus, s.link_up ? "up" : "down");
    if (rdma_get_request(s.listen_id, &s.id)) {
        if (stop_requested) {
            result = EXIT_SUCCESS;
            goto out;
        }
        perror("accept RDMA request");
        goto out;
    }
    if (strcmp(ibv_get_device_name(s.id->verbs->device), s.opt.rdma_device)) {
        fprintf(stderr, "RDMA request did not use expected device %s\n",
                s.opt.rdma_device);
        goto out;
    }
    s.rx_mr = rdma_reg_msgs(s.id, s.rx, sizeof(*s.rx));
    s.tx_mr = rdma_reg_msgs(s.id, s.tx, sizeof(*s.tx));
    if (!s.rx_mr || !s.tx_mr) {
        perror("register RDMA messages");
        goto out;
    }
    result = serve(&s) && !stop_requested ? EXIT_FAILURE : EXIT_SUCCESS;

out:
    if (res) rdma_freeaddrinfo(res);
    fprintf(stderr, "remote shadow NIC totals: tx=%" PRIu64 " rx=%" PRIu64
            "\n", s.tx_packets, s.rx_packets);
    print_hardware_packet_counters(&s);
    cleanup(&s);
    return result;
}
