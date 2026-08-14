/*
 * Query the private xocl Vortex peer-window ABI for one PCI function.
 * This utility is intentionally read-only; PEER_MAP remains owned by Bridge.
 */

#include <errno.h>
#include <stdbool.h>
#include <fcntl.h>
#include <glob.h>
#include <inttypes.h>
#include <libdrm/drm.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <xocl_ioctl.h>

static int open_render_node(const char *bdf)
{
    char path[512];
    glob_t matches = { 0 };
    int fd = -1;

    if (snprintf(path, sizeof(path),
                 "/dev/dri/by-path/pci-%s-render", bdf) < (int)sizeof(path)) {
        fd = open(path, O_RDWR | O_CLOEXEC);
        if (fd >= 0)
            return fd;
    }

    if (snprintf(path, sizeof(path),
                 "/sys/bus/pci/devices/%s/drm/renderD*", bdf) >=
        (int)sizeof(path))
        return -ENAMETOOLONG;
    if (glob(path, 0, NULL, &matches) || matches.gl_pathc != 1) {
        globfree(&matches);
        return -ENOENT;
    }
    {
        const char *name = strrchr(matches.gl_pathv[0], '/');

        if (!name ||
            snprintf(path, sizeof(path), "/dev/dri/%s", name + 1) >=
                (int)sizeof(path)) {
            globfree(&matches);
            return -ENAMETOOLONG;
        }
    }
    fd = open(path, O_RDWR | O_CLOEXEC);
    globfree(&matches);
    return fd >= 0 ? fd : -errno;
}

int main(int argc, char **argv)
{
    struct drm_xocl_vortex_peer_query query = {
        .abi_version = XOCL_VORTEX_PEER_ABI_VERSION,
    };
    int fd;
    int saved_errno;

    if (argc != 2) {
        fprintf(stderr, "usage: %s DOMAIN:BUS:DEVICE.FUNCTION\n", argv[0]);
        return 64;
    }

    fd = open_render_node(argv[1]);
    if (fd < 0) {
        fprintf(stderr, "cannot open xocl render node for %s: %s\n",
                argv[1], strerror(-fd));
        return 1;
    }
    if (ioctl(fd, DRM_IOCTL_XOCL_VORTEX_PEER_QUERY, &query)) {
        saved_errno = errno;
        close(fd);
        fprintf(stderr, "PEER_QUERY for %s failed: %s\n",
                argv[1], strerror(saved_errno));
        return (saved_errno == ENODEV || saved_errno == EOPNOTSUPP ||
                saved_errno == EINVAL) ? 2 : 1;
    }
    close(fd);

    printf("flags=0x%08" PRIx32 "\n", query.flags);
    printf("host_base=0x%016" PRIx64 "\n", query.host_base);
    printf("control_size=%" PRIu64 "\n", query.control_size);
    printf("peer_base=0x%016" PRIx64 "\n", query.peer_base);
    printf("peer_size=%" PRIu64 "\n", query.peer_size);
    printf("slot_size=%" PRIu64 "\n", query.slot_size);
    printf("generation=%" PRIu64 "\n", query.generation);
    return 0;
}
