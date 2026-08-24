/* SPDX-License-Identifier: GPL-2.0-or-later */
#define _GNU_SOURCE

#include "scope_remote_proto.h"

#include <arpa/inet.h>
#include <endian.h>
#include <errno.h>
#include <getopt.h>
#include <infiniband/verbs.h>
#include <inttypes.h>
#include <limits.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <net/if.h>
#include <rdma/rdma_cma.h>
#include <rdma/rdma_verbs.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define AGENT_DEFAULT_SERVICE "7472"

struct nic_options {
    const char *listen_addr;
    const char *service;
    const char *rdma_device;
    const char *device_id;
    const char *netdev;
};

struct nic_agent {
    struct nic_options opt;
    struct rdma_cm_id *listen_id;
    struct rdma_cm_id *id;
    struct ibv_mr *rx_mr;
    struct ibv_mr *tx_mr;
    struct scope_remote_message *rx;
    struct scope_remote_message *tx;
    int packet_fd;
    int ifindex;
    uint8_t mac[6];
    uint32_t mtu;
    bool link_up;
    bool opened;
    bool first;
    uint64_t session_id;
    uint64_t generation;
    uint64_t last_link_check_ms;
    uint64_t rx_packets;
    uint64_t tx_packets;
};

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s --listen ADDR --rdma-device DEV --device-id ID "
            "--netdev IFACE [--service 7472]\n", prog);
}

static bool parse_options(int argc, char **argv, struct nic_options *opt)
{
    static const struct option options[] = {
        { "listen", required_argument, NULL, 'l' },
        { "service", required_argument, NULL, 's' },
        { "rdma-device", required_argument, NULL, 'r' },
        { "device-id", required_argument, NULL, 'd' },
        { "netdev", required_argument, NULL, 'n' },
        { "help", no_argument, NULL, 'h' },
        { NULL, 0, NULL, 0 },
    };
    int ch;

    *opt = (struct nic_options) { .service = AGENT_DEFAULT_SERVICE };
    while ((ch = getopt_long(argc, argv, "l:s:r:d:n:h", options, NULL)) != -1) {
        switch (ch) {
        case 'l': opt->listen_addr = optarg; break;
        case 's': opt->service = optarg; break;
        case 'r': opt->rdma_device = optarg; break;
        case 'd': opt->device_id = optarg; break;
        case 'n': opt->netdev = optarg; break;
        default: return false;
        }
    }
    return opt->listen_addr && opt->rdma_device && opt->device_id &&
           opt->netdev && strlen(opt->device_id) < SCOPE_REMOTE_MAX_DEVICE_ID;
}

static uint64_t now_ms(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000U + ts.tv_nsec / 1000000U;
}

static int poll_send_completion(struct nic_agent *s)
{
    struct ibv_wc wc;

    for (;;) {
        int ret = ibv_poll_cq(s->id->send_cq, 1, &wc);

        if (ret < 0) {
            return -1;
        }
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
}

static int post_recv(struct nic_agent *s)
{
    memset(s->rx, 0, sizeof(*s->rx));
    return rdma_post_recv(s->id, s->rx, s->rx, sizeof(*s->rx), s->rx_mr);
}

static void init_message(struct nic_agent *s, uint16_t opcode,
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

static int send_message(struct nic_agent *s, size_t payload_len)
{
    size_t bytes = sizeof(s->tx->hdr) + payload_len;

    if (rdma_post_send(s->id, s->tx, s->tx, bytes, s->tx_mr,
                       IBV_SEND_SIGNALED)) {
        return -1;
    }
    return poll_send_completion(s);
}

static bool valid_header(struct nic_agent *s)
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

static int query_interface(struct nic_agent *s, bool initialize)
{
    struct ifreq ifr = { 0 };
    bool old_link = s->link_up;
    int ctl = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);

    if (ctl < 0) {
        return -1;
    }
    snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", s->opt.netdev);
    if (ioctl(ctl, SIOCGIFFLAGS, &ifr)) {
        close(ctl);
        return -1;
    }
    s->link_up = (ifr.ifr_flags & IFF_UP) && (ifr.ifr_flags & IFF_RUNNING);
    if (initialize) {
        if (ioctl(ctl, SIOCGIFHWADDR, &ifr)) {
            close(ctl);
            return -1;
        }
        memcpy(s->mac, ifr.ifr_hwaddr.sa_data, sizeof(s->mac));
        if (ioctl(ctl, SIOCGIFMTU, &ifr)) {
            close(ctl);
            return -1;
        }
        s->mtu = ifr.ifr_mtu;
    }
    close(ctl);
    return initialize ? 0 : old_link != s->link_up;
}

static int verify_82599_pci_identity(const char *netdev)
{
    char path[PATH_MAX];
    unsigned int vendor;
    unsigned int device;
    FILE *file;
    int length;

    length = snprintf(path, sizeof(path), "/sys/class/net/%s/device/vendor",
                      netdev);
    if (length < 0 || (size_t)length >= sizeof(path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    file = fopen(path, "r");
    if (!file || fscanf(file, "%x", &vendor) != 1) {
        if (file) {
            fclose(file);
        }
        return -1;
    }
    fclose(file);

    length = snprintf(path, sizeof(path), "/sys/class/net/%s/device/device",
                      netdev);
    if (length < 0 || (size_t)length >= sizeof(path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    file = fopen(path, "r");
    if (!file || fscanf(file, "%x", &device) != 1) {
        if (file) {
            fclose(file);
        }
        return -1;
    }
    fclose(file);

    if (vendor != 0x8086 || device != 0x10fb) {
        fprintf(stderr,
                "%s is %04x:%04x; a physical Intel 82599 (8086:10fb) "
                "is required\n",
                netdev, vendor, device);
        errno = ENODEV;
        return -1;
    }
    return 0;
}

static int open_packet_socket(struct nic_agent *s)
{
    struct sockaddr_ll addr = { 0 };
    int one = 1;

    s->ifindex = if_nametoindex(s->opt.netdev);
    if (!s->ifindex || verify_82599_pci_identity(s->opt.netdev) ||
        query_interface(s, true) || s->mtu > 1500 ||
        s->mtu < 576 || (s->mac[0] & 1)) {
        errno = EINVAL;
        return -1;
    }
    s->packet_fd = socket(AF_PACKET, SOCK_RAW | SOCK_NONBLOCK | SOCK_CLOEXEC,
                          htons(ETH_P_ALL));
    if (s->packet_fd < 0) {
        return -1;
    }
#ifdef PACKET_IGNORE_OUTGOING
    if (setsockopt(s->packet_fd, SOL_PACKET, PACKET_IGNORE_OUTGOING,
                   &one, sizeof(one))) {
        return -1;
    }
#endif
    addr.sll_family = AF_PACKET;
    addr.sll_protocol = htons(ETH_P_ALL);
    addr.sll_ifindex = s->ifindex;
    return bind(s->packet_fd, (struct sockaddr *)&addr, sizeof(addr));
}

static int handle_hello(struct nic_agent *s)
{
    const struct scope_remote_hello *hello = (const void *)s->rx->payload;
    struct scope_remote_hello *rsp;
    uint64_t features;

    if (le32toh(s->rx->hdr.payload_len) != sizeof(*hello)) {
        return -1;
    }
    features = le64toh(hello->features);
    if ((features & SCOPE_REMOTE_IXGBE_FEATURES) !=
        SCOPE_REMOTE_IXGBE_FEATURES) {
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
    rsp->features = htole64(SCOPE_REMOTE_IXGBE_FEATURES);
    rsp->max_inflight = htole32(64);
    rsp->max_segments = htole32(0);
    return send_message(s, sizeof(*rsp));
}

static int handle_open(struct nic_agent *s)
{
    const struct scope_remote_device_open *req = (const void *)s->rx->payload;
    struct scope_remote_device_info *info;
    bool valid = le32toh(s->rx->hdr.payload_len) == sizeof(*req) &&
                 le32toh(req->device_type) ==
                    SCOPE_REMOTE_DEVICE_IXGBE_PACKET &&
                 strnlen(req->device_id, sizeof(req->device_id)) <
                    sizeof(req->device_id) &&
                 !strcmp(req->device_id, s->opt.device_id);

    init_message(s, SCOPE_REMOTE_OP_DEVICE_OPEN_RSP,
                 le64toh(s->rx->hdr.request_id), sizeof(*info),
                 valid ? 0 : SCOPE_REMOTE_STATUS_DEVICE);
    info = (void *)s->tx->payload;
    if (valid) {
        info->vendor_id = htole16(0x8086);
        info->device_id = htole16(0x10fb);
        info->class_code = htole32(0x020000);
        info->bar0_size = htole64(0x20000);
        info->max_transfer_bytes = htole32(SCOPE_REMOTE_ETHER_MAX_FRAME);
        info->max_inflight = htole32(64);
        info->device_type = htole32(SCOPE_REMOTE_DEVICE_IXGBE_PACKET);
        info->mtu = htole32(s->mtu);
        memcpy(info->mac, s->mac, sizeof(info->mac));
        info->link_up = s->link_up;
        s->opened = true;
    }
    return send_message(s, sizeof(*info));
}

static int handle_tx(struct nic_agent *s)
{
    const struct scope_remote_ether_frame *frame =
        (const void *)s->rx->payload;
    struct scope_remote_ether_complete *complete;
    uint32_t length = le32toh(frame->length);
    int32_t status = 0;
    ssize_t sent;
    struct sockaddr_ll to = {
        .sll_family = AF_PACKET,
        .sll_protocol = htons(ETH_P_ALL),
        .sll_ifindex = s->ifindex,
    };

    if (!s->opened || le32toh(s->rx->hdr.payload_len) != sizeof(*frame) ||
        !length || length > SCOPE_REMOTE_ETHER_MAX_FRAME ||
        length > s->mtu + ETH_HLEN + 4U) {
        status = SCOPE_REMOTE_STATUS_RANGE;
        sent = 0;
    } else {
        sent = sendto(s->packet_fd, frame->data, length, 0,
                      (struct sockaddr *)&to, sizeof(to));
        if (sent != length) {
            status = SCOPE_REMOTE_STATUS_IO;
        } else {
            s->tx_packets++;
        }
    }
    init_message(s, SCOPE_REMOTE_OP_IXGBE_TX_COMPLETE,
                 le64toh(s->rx->hdr.request_id), sizeof(*complete), status);
    complete = (void *)s->tx->payload;
    complete->length = htole32(status ? 0 : length);
    return send_message(s, sizeof(*complete));
}

static int process_rdma(struct nic_agent *s)
{
    struct ibv_wc wc;
    uint16_t opcode;
    int ret = ibv_poll_cq(s->id->recv_cq, 1, &wc);

    if (ret <= 0) {
        return ret;
    }
    if (wc.status != IBV_WC_SUCCESS || wc.opcode != IBV_WC_RECV ||
        !valid_header(s)) {
        return -1;
    }
    opcode = le16toh(s->rx->hdr.opcode);
    if (s->first) {
        if (opcode != SCOPE_REMOTE_OP_HELLO || handle_hello(s)) {
            return -1;
        }
        s->first = false;
    } else if (opcode == SCOPE_REMOTE_OP_DEVICE_OPEN) {
        if (handle_open(s)) {
            return -1;
        }
    } else if (opcode == SCOPE_REMOTE_OP_IXGBE_TX) {
        if (handle_tx(s)) {
            return -1;
        }
    } else if (opcode == SCOPE_REMOTE_OP_CLOSE) {
        return 2;
    } else {
        init_message(s, SCOPE_REMOTE_OP_ERROR,
                     le64toh(s->rx->hdr.request_id), 0,
                     SCOPE_REMOTE_STATUS_UNSUPPORTED);
        if (send_message(s, 0)) {
            return -1;
        }
    }
    return post_recv(s) ? -1 : 1;
}

static int send_rx_frame(struct nic_agent *s)
{
    struct sockaddr_ll from = { 0 };
    socklen_t from_len = sizeof(from);
    struct scope_remote_ether_frame *frame;
    uint8_t data[SCOPE_REMOTE_ETHER_MAX_FRAME];
    ssize_t length = recvfrom(s->packet_fd, data, sizeof(data), 0,
                              (struct sockaddr *)&from, &from_len);

    if (length < 0) {
        return errno == EAGAIN || errno == EWOULDBLOCK ? 0 : -1;
    }
    if (!s->opened || from.sll_pkttype == PACKET_OUTGOING) {
        return 1;
    }
    init_message(s, SCOPE_REMOTE_OP_IXGBE_RX, 0, sizeof(*frame), 0);
    frame = (void *)s->tx->payload;
    frame->length = htole32(length);
    memcpy(frame->data, data, length);
    if (send_message(s, sizeof(*frame))) {
        return -1;
    }
    s->rx_packets++;
    return 1;
}

static int send_link_change(struct nic_agent *s)
{
    struct scope_remote_link_state *link;
    int changed;

    if (!s->opened || now_ms() - s->last_link_check_ms < 500) {
        return 0;
    }
    s->last_link_check_ms = now_ms();
    changed = query_interface(s, false);
    if (changed <= 0) {
        return changed;
    }
    init_message(s, SCOPE_REMOTE_OP_IXGBE_LINK, 0, sizeof(*link), 0);
    link = (void *)s->tx->payload;
    link->link_up = htole32(s->link_up);
    link->speed_mbps = htole32(s->link_up ? 10000 : 0);
    return send_message(s, sizeof(*link)) ? -1 : 1;
}

static int serve(struct nic_agent *s)
{
    s->first = true;
    if (post_recv(s) || rdma_accept(s->id, NULL)) {
        return -1;
    }
    for (;;) {
        int ret = process_rdma(s);
        if (ret < 0) {
            return -1;
        }
        if (ret == 2) {
            return 0;
        }
        if (send_rx_frame(s) < 0 || send_link_change(s) < 0) {
            return -1;
        }
        if (!ret) {
            usleep(20);
        }
    }
}

static void cleanup(struct nic_agent *s)
{
    if (s->id) rdma_disconnect(s->id);
    if (s->tx_mr) rdma_dereg_mr(s->tx_mr);
    if (s->rx_mr) rdma_dereg_mr(s->rx_mr);
    if (s->id) rdma_destroy_ep(s->id);
    if (s->listen_id) rdma_destroy_ep(s->listen_id);
    if (s->packet_fd >= 0) close(s->packet_fd);
    free(s->tx);
    free(s->rx);
}

int main(int argc, char **argv)
{
    struct nic_agent s = { .packet_fd = -1 };
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
    if (open_packet_socket(&s)) {
        perror("open dedicated 82599 packet interface");
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
    fprintf(stderr, "scope-remote-nic-agent listening on %s:%s, "
            "exporting %s as 8086:10fb (%02x:%02x:%02x:%02x:%02x:%02x)\n",
            s.opt.listen_addr, s.opt.service, s.opt.netdev,
            s.mac[0], s.mac[1], s.mac[2], s.mac[3], s.mac[4], s.mac[5]);
    if (rdma_get_request(s.listen_id, &s.id) ||
        strcmp(ibv_get_device_name(s.id->verbs->device), s.opt.rdma_device)) {
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
    result = serve(&s) ? EXIT_FAILURE : EXIT_SUCCESS;

out:
    if (res) rdma_freeaddrinfo(res);
    fprintf(stderr, "remote NIC totals: tx=%" PRIu64 " rx=%" PRIu64 "\n",
            s.tx_packets, s.rx_packets);
    cleanup(&s);
    return result;
}
