#!/usr/bin/env bash

set -Eeuo pipefail

readonly XRT_ROOT="/home/yanjiarun/xrt-u280-2.16"
readonly KERNEL_RELEASE="$(uname -r)"
readonly MODULE_DIR="${XRT_ROOT}/modules/${KERNEL_RELEASE}"
readonly XCLMGMT_KO="${MODULE_DIR}/xclmgmt.ko"
readonly XOCL_KO="${MODULE_DIR}/xocl.ko"
readonly XBMGMT="${XRT_ROOT}/bin/unwrapped/xbmgmt2"
readonly XBUTIL="${XRT_ROOT}/bin/unwrapped/xbutil2"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PEER_QUERY_SRC="${SCRIPT_DIR}/xocl_vortex_peer_query.c"
readonly PEER_QUERY_BIN="/tmp/xocl-vortex-peer-query-${UID}-${KERNEL_RELEASE}"
readonly DEFAULT_VORTEX_XCLBIN="/home/yanjiarun/Vortex/hw/syn/xilinx/xrt/build1_p2p_xilinx_u280_gen3x16_xdma_1_202211_1_hw/bin/vortex_afu.xclbin"

MGMT_BDF="0000:ab:00.0"
USER_BDF="0000:ab:00.1"
PEER_BDF="0000:2a:00.0"
VORTEX_XCLBIN="$DEFAULT_VORTEX_XCLBIN"
HOST_MEM_BYTES="1073741824"
HOST_MEM_SIZE="1G"
enable_host_mem=1
vortex_p2p=0

usage() {
  cat <<'EOF'
Usage: u280_xrt_start.sh [OPTIONS]

Load and verify the user-local XRT 2.16 drivers without touching /opt.
The normal mode configures 1 GiB Host Memory. --vortex-p2p instead loads
xocl with vortex_peer_mode=1, configures the 64 MiB control window, programs
the Vortex xclbin, and validates the adjacent 64 MiB peer window.

Options:
  --vortex-p2p       Enable the Vortex 64 MiB control + 64 MiB peer layout.
  --u280-bdf BDF     U280 user PF (default: 0000:ab:00.1).
  --peer-bdf BDF     Allowed NM37 peer function (default: 0000:2a:00.0).
  --xclbin PATH      P2P-capable Vortex xclbin (default: current build1 U280).
  --no-host-mem      Do not change Host Memory; still perform validations.
  -h, --help         Show this help.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while (( "$#" )); do
  case "$1" in
    --vortex-p2p)
      vortex_p2p=1
      HOST_MEM_BYTES="67108864"
      HOST_MEM_SIZE="64M"
      shift
      ;;
    --u280-bdf)
      (( "$#" >= 2 )) || die "--u280-bdf requires an argument"
      USER_BDF="$2"
      MGMT_BDF="${2%.*}.0"
      shift 2
      ;;
    --peer-bdf)
      (( "$#" >= 2 )) || die "--peer-bdf requires an argument"
      PEER_BDF="$2"
      shift 2
      ;;
    --xclbin)
      (( "$#" >= 2 )) || die "--xclbin requires an argument"
      VORTEX_XCLBIN="$2"
      shift 2
      ;;
    --no-host-mem)
      enable_host_mem=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown option: $1"
      ;;
  esac
done
validate_bdf() {
  [[ "$1" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] ||
    die "invalid PCI BDF: $1"
}

validate_bdf "$USER_BDF"
validate_bdf "$MGMT_BDF"
validate_bdf "$PEER_BDF"

case "$XRT_ROOT" in
  /opt|/opt/*)
    die "XRT_ROOT must not be under /opt"
    ;;
esac

for path in "$XCLMGMT_KO" "$XOCL_KO" "$XBMGMT" "$XBUTIL" \
            "${XRT_ROOT}/rules/99-xclmgmt.rules" \
            "${XRT_ROOT}/rules/99-xocl.rules"; do
  [[ -e "$path" ]] || die "required local XRT file is missing: ${path}"
done
if (( vortex_p2p )); then
  modinfo -F parm "$XOCL_KO" | grep -q "^vortex_peer_mode:" ||
    die "${XOCL_KO} does not provide vortex_peer_mode; install the peer-enabled local module"
  [[ -r "$PEER_QUERY_SRC" ]] || die "missing peer query source: ${PEER_QUERY_SRC}"
fi


module_kernel() {
  modinfo -F vermagic "$1" | awk '{print $1}'
}

[[ "$(module_kernel "$XCLMGMT_KO")" == "$KERNEL_RELEASE" ]] ||
  die "xclmgmt.ko was not built for ${KERNEL_RELEASE}; rebuild the driver after a kernel update"
[[ "$(module_kernel "$XOCL_KO")" == "$KERNEL_RELEASE" ]] ||
  die "xocl.ko was not built for ${KERNEL_RELEASE}; rebuild the driver after a kernel update"

check_pci_id() {
  local bdf="$1"
  local expected_device="$2"
  local dev_path="/sys/bus/pci/devices/${bdf}"
  local vendor device

  [[ -d "$dev_path" ]] || die "PCI function ${bdf} is absent; perform a cold reboot and check lspci"
  vendor="$(<"${dev_path}/vendor")"
  device="$(<"${dev_path}/device")"
  [[ "$vendor" == "0x10ee" && "$device" == "$expected_device" ]] ||
    die "${bdf} is ${vendor}:${device}, expected Xilinx ${expected_device}"
}

check_pci_id "$MGMT_BDF" "0x500c"
check_pci_id "$USER_BDF" "0x500d"

validate_peer_bar2() {
  local resource_file="/sys/bus/pci/devices/${PEER_BDF}/resource"
  local start end flags size

  [[ -r "$resource_file" ]] ||
    die "NM37 peer ${PEER_BDF} is absent or has no PCI resource table"
  read -r start end flags < <(sed -n '3p' "$resource_file")
  [[ -n "${start:-}" && -n "${end:-}" && -n "${flags:-}" ]] ||
    die "cannot read BAR2 for NM37 peer ${PEER_BDF}"
  (( (flags & 0x200) != 0 && start != 0 && end >= start )) ||
    die "${PEER_BDF} BAR2 is not an assigned IORESOURCE_MEM BAR"
  size=$((end - start + 1))
  (( size >= 0x200000000 )) ||
    die "${PEER_BDF} BAR2 is only ${size} bytes; direct P2P needs at least 8 GiB"
  printf 'NM37 peer: %s BAR2=%#x..%#x (%#x bytes)\n' \
    "$PEER_BDF" "$start" "$end" "$size"
}

if (( vortex_p2p )); then
  validate_peer_bar2
fi

driver_for() {
  local link="/sys/bus/pci/devices/$1/driver"
  if [[ -L "$link" ]]; then
    basename "$(readlink -f "$link")"
  else
    printf '%s' ""
  fi
}

check_existing_binding() {
  local bdf="$1"
  local expected="$2"
  local current
  current="$(driver_for "$bdf")"
  if [[ -n "$current" && "$current" != "$expected" ]]; then
    die "${bdf} is already bound to ${current}; refusing to unbind it automatically"
  fi
}

check_existing_binding "$MGMT_BDF" "xclmgmt"
check_existing_binding "$USER_BDF" "xocl"

if (( EUID == 0 )); then
  SUDO=()
else
  command -v sudo >/dev/null || die "sudo is required to load kernel modules"
  echo "Requesting sudo once to load the XRT drivers and configure host memory..."
  sudo -v
  SUDO=(sudo)
fi

"${SUDO[@]}" install -d -m 0755 /run/udev/rules.d
"${SUDO[@]}" install -m 0644 "${XRT_ROOT}/rules/99-xclmgmt.rules" \
  /run/udev/rules.d/99-xrt-local-xclmgmt.rules
"${SUDO[@]}" install -m 0644 "${XRT_ROOT}/rules/99-xocl.rules" \
  /run/udev/rules.d/99-xrt-local-xocl.rules
"${SUDO[@]}" udevadm control --reload-rules

"${SUDO[@]}" modprobe libcrc32c

module_loaded() {
  [[ -d "/sys/module/$1" ]]
}
show_xocl_users() {
  echo "Processes that may own XRT devices:" >&2
  command -v fuser >/dev/null && \
    "${SUDO[@]}" fuser -v /dev/dri/renderD* /dev/xclmgmt* 2>/dev/null || true
  ps -eo pid,user,comm,args | \
    grep -E '[x]butil|[x]bmgmt|[s]cope-vortex|[v]ortex' >&2 || true
}


check_loaded_version() {
  local module="$1"
  local expected_prefix="$2"
  local loaded_version
  loaded_version="$(<"/sys/module/${module}/version")"
  [[ "$loaded_version" == "${expected_prefix}"* ]] ||
    die "${module} ${loaded_version} is already loaded; expected ${expected_prefix}"
}

if module_loaded xclmgmt; then
  check_loaded_version xclmgmt "2.16.0"
else
  "${SUDO[@]}" insmod "$XCLMGMT_KO"
fi

if module_loaded xocl; then
  check_loaded_version xocl "2.16.0"
  if (( vortex_p2p )); then
    peer_mode_attr="/sys/module/xocl/parameters/vortex_peer_mode"
    if [[ ! -r "$peer_mode_attr" ]] ||
       [[ "$(<"$peer_mode_attr")" != "Y" && "$(<"$peer_mode_attr")" != "1" ]]; then
      show_xocl_users
      die "xocl is already loaded without vortex_peer_mode=1; stop the listed users and unload it explicitly"
    fi
  fi
else
  if (( vortex_p2p )); then
    "${SUDO[@]}" insmod "$XOCL_KO" vortex_peer_mode=1
  else
    "${SUDO[@]}" insmod "$XOCL_KO"
  fi
fi

for _ in {1..40}; do
  if [[ "$(driver_for "$MGMT_BDF")" == "xclmgmt" && \
        "$(driver_for "$USER_BDF")" == "xocl" ]]; then
    break
  fi
  sleep 0.25
done

[[ "$(driver_for "$MGMT_BDF")" == "xclmgmt" ]] ||
  die "xclmgmt did not bind to ${MGMT_BDF}; inspect: sudo dmesg | tail -100"
[[ "$(driver_for "$USER_BDF")" == "xocl" ]] ||
  die "xocl did not bind to ${USER_BDF}; inspect: sudo dmesg | tail -100"

"${SUDO[@]}" udevadm trigger --action=change --subsystem-match=drm || true
"${SUDO[@]}" udevadm settle

xrt_admin() {
  "${SUDO[@]}" env \
    XILINX_XRT="$XRT_ROOT" \
    LD_LIBRARY_PATH="${XRT_ROOT}/lib" \
    "$@"
}

echo "XRT drivers are bound: ${MGMT_BDF}=xclmgmt, ${USER_BDF}=xocl"
xrt_admin "$XBMGMT" examine
xrt_admin "$XBUTIL" examine

host_mem_attr="/sys/bus/pci/devices/${USER_BDF}/host_mem_size"
current_host_mem=0
[[ -r "$host_mem_attr" ]] && current_host_mem="$(<"$host_mem_attr")"

if (( enable_host_mem )); then
  if [[ "$current_host_mem" == "$HOST_MEM_BYTES" ]]; then
    echo "Host memory is already enabled at ${HOST_MEM_SIZE}."
  elif [[ "$current_host_mem" != "0" ]]; then
    show_xocl_users
    die "host memory is already ${current_host_mem} bytes; stop its users and disable it explicitly before changing size"
  else
    xrt_admin "$XBUTIL" configure --host-mem \
      --device "$USER_BDF" --size "$HOST_MEM_SIZE" enable
    if [[ -r "$host_mem_attr" ]]; then
      current_host_mem="$(<"$host_mem_attr")"
      [[ "$current_host_mem" == "$HOST_MEM_BYTES" ]] ||
        die "host-memory command completed but ${host_mem_attr} reports ${current_host_mem}"
    fi
  fi
fi

if (( vortex_p2p )); then
  [[ -r "$VORTEX_XCLBIN" ]] ||
    die "P2P-capable Vortex xclbin is not readable: ${VORTEX_XCLBIN}"
  if pgrep -f '/scope-vortex-bridge([[:space:]]|$)' >/dev/null; then
    show_xocl_users
    die "scope-vortex-bridge is already running; refusing to reload its xclbin"
  fi
  xrt_admin "$XBUTIL" program --device "$USER_BDF" --user "$VORTEX_XCLBIN"

  [[ -r "$host_mem_attr" ]] || die "xocl does not expose ${host_mem_attr}"
  current_host_mem="$(<"$host_mem_attr")"
  [[ "$current_host_mem" == "$HOST_MEM_BYTES" ]] ||
    die "direct P2P requires exactly 64 MiB Host Memory; ${host_mem_attr} reports ${current_host_mem}"

  command -v cc >/dev/null || die "cc is required to build the peer-layout query helper"
  if [[ ! -x "$PEER_QUERY_BIN" || "$PEER_QUERY_SRC" -nt "$PEER_QUERY_BIN" ||
        "${XRT_ROOT}/include/xocl_ioctl.h" -nt "$PEER_QUERY_BIN" ]]; then
    cc -std=gnu11 -Wall -Wextra -Werror \
      -I"${XRT_ROOT}/include" "$PEER_QUERY_SRC" -o "$PEER_QUERY_BIN"
  fi

  set +e
  peer_layout="$("${SUDO[@]}" "$PEER_QUERY_BIN" "$USER_BDF" 2>&1)"
  peer_query_rc=$?
  set -e
  if (( peer_query_rc != 0 )); then
    echo "$peer_layout" >&2
    if (( peer_query_rc == 2 )); then
      die "peer layout is not active after programming ${VORTEX_XCLBIN}; verify its HOST topology"
    fi
    die "could not query the xocl peer layout"
  fi

  layout_value() {
    local key="$1"
    sed -n "s/^${key}=//p" <<<"$peer_layout"
  }

  peer_flags="$(layout_value flags)"
  host_base="$(layout_value host_base)"
  control_size="$(layout_value control_size)"
  peer_base="$(layout_value peer_base)"
  peer_size="$(layout_value peer_size)"
  slot_size="$(layout_value slot_size)"
  generation="$(layout_value generation)"
  [[ -n "$peer_flags" && -n "$host_base" && -n "$control_size" &&
     -n "$peer_base" && -n "$peer_size" && -n "$slot_size" &&
     -n "$generation" ]] || die "peer query returned an incomplete layout"
  (( (peer_flags & 1) != 0 )) || die "xocl reports peer mode disabled"
  (( slot_size == 4194304 )) || die "translator slot is ${slot_size}, expected 4194304"
  (( control_size == 67108864 )) || die "control window is ${control_size}, expected 67108864"
  (( peer_size == 67108864 )) || die "peer window is ${peer_size}, expected 67108864"
  (( peer_base == host_base + control_size )) ||
    die "peer window is not contiguous with the control window"

  echo "$peer_layout"
  echo "Bridge allowlist argument: --allow-peer-bdf ${PEER_BDF}"
fi

echo
echo "U280 XRT startup completed successfully."
echo "For XRT tools and Vortex builds in this shell, run:"
echo "  source ${XRT_ROOT}/setup.sh"
if (( vortex_p2p )); then
  echo "Start Bridge in direct-P2P mode with:"
  echo "  scope-vortex-bridge --allow-peer-bdf ${PEER_BDF} ..."
  echo "Use a QEMU Vortex backend with data-path=direct-p2p."
fi
