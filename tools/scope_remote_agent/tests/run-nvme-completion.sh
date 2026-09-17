#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
source_file=${SCOPE_NVME_AGENT_SOURCE:-$root/scope_remote_nvme_shadow_agent.c}
sed -n '/^struct nvme_cqe {/,/^struct shadow_agent {/p' "$source_file" |
    sed '$d' > "$tmp/nvme-types.inc"
sed -n '/^static int poll_physical_completion(/,/^static uint32_t apply_wstrb32(/p' \
    "$source_file" | sed '$d' > "$tmp/nvme-completion.inc"
grep -q '^static int poll_physical_completion(' "$tmp/nvme-completion.inc"
"${CC:-cc}" -std=gnu11 -O2 -g -Wall -Wextra -Werror \
    ${SANITIZER_FLAGS:--fsanitize=address,undefined -fno-omit-frame-pointer} \
    -I"$root" -I"$tmp" "$root/tests/test-nvme-completion.c" -o "$tmp/test-cqe"
"$tmp/test-cqe"
