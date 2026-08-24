#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VORTEX_HOME=${VORTEX_HOME:-/home/yanjiarun/Vortex_16}
CC=${CC:-cc}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/layout.c" <<'EOF'
#include <stddef.h>
#include <stdio.h>
#include HEADER

int main(void)
{
    printf("header_size=%zu\n", sizeof(struct scope_gids_queue_header));
    printf("sqe_size=%zu\n", sizeof(struct scope_gids_sqe));
    printf("cqe_size=%zu\n", sizeof(struct scope_gids_cqe));
    printf("header_state=%zu\n", offsetof(struct scope_gids_queue_header, state));
    printf("header_generation=%zu\n", offsetof(struct scope_gids_queue_header, generation));
    printf("header_sq_producer=%zu\n", offsetof(struct scope_gids_queue_header, sq_producer));
    printf("header_cq_producer=%zu\n", offsetof(struct scope_gids_queue_header, cq_producer));
    printf("header_fatal_error=%zu\n", offsetof(struct scope_gids_queue_header, fatal_error));
    printf("sqe_slba=%zu\n", offsetof(struct scope_gids_sqe, slba));
    printf("sqe_generation=%zu\n", offsetof(struct scope_gids_sqe, buffer_generation));
    printf("cqe_token=%zu\n", offsetof(struct scope_gids_cqe, user_token));
    printf("magic=%u\n", SCOPE_GIDS_ABI_MAGIC);
    printf("major=%u\n", SCOPE_GIDS_ABI_MAJOR);
    printf("minor=%u\n", SCOPE_GIDS_ABI_MINOR);
    printf("max_depth=%u\n", SCOPE_GIDS_MAX_DEPTH);
    printf("status_timeout=%u\n", SCOPE_GIDS_STATUS_TIMEOUT);
    printf("status_transport=%u\n", SCOPE_GIDS_STATUS_TRANSPORT);
    printf("status_nvme=%u\n", SCOPE_GIDS_STATUS_NVME);
    return 0;
}
EOF

CANONICAL="$ROOT/qemu-mount/include/hw/misc/scope_vortex_gids_abi.h"
MIRROR="$VORTEX_HOME/sw/kernel/include/vx_gids_abi.h"
test -r "$CANONICAL" || { echo "missing canonical ABI: $CANONICAL" >&2; exit 1; }
test -r "$MIRROR" || { echo "missing Vortex ABI mirror: $MIRROR" >&2; exit 1; }

"$CC" -std=c11 -Wall -Wextra -Werror \
  -DHEADER='"hw/misc/scope_vortex_gids_abi.h"' \
  -I"$ROOT/qemu-mount/include" "$TMP/layout.c" -o "$TMP/qemu-layout"
"$CC" -std=c11 -Wall -Wextra -Werror \
  -DHEADER='"vx_gids_abi.h"' \
  -I"$VORTEX_HOME/sw/kernel/include" "$TMP/layout.c" -o "$TMP/vortex-layout"

"$TMP/qemu-layout" >"$TMP/qemu.txt"
"$TMP/vortex-layout" >"$TMP/vortex.txt"
if ! diff -u "$TMP/qemu.txt" "$TMP/vortex.txt"; then
  echo "GIDS ABI mismatch between QEMU and Vortex" >&2
  exit 1
fi
echo "GIDS ABI layout matches: QEMU <-> Vortex"
cat "$TMP/qemu.txt"
