#!/usr/bin/env bash

set -Eeuo pipefail

readonly XRT_ROOT="/home/yanjiarun/xrt-u280-2.16"
readonly MGMT_BDF="0000:ab:00.0"
readonly USER_BDF="0000:ab:00.1"
readonly HOST_MEM_BYTES="1073741824"
readonly HOST_MEM_SIZE="1G"
readonly KERNEL_RELEASE="$(uname -r)"
readonly MODULE_DIR="${XRT_ROOT}/modules/${KERNEL_RELEASE}"
readonly XCLMGMT_KO="${MODULE_DIR}/xclmgmt.ko"
readonly XOCL_KO="${MODULE_DIR}/xocl.ko"
readonly XBMGMT="${XRT_ROOT}/bin/unwrapped/xbmgmt2"
readonly XBUTIL="${XRT_ROOT}/bin/unwrapped/xbutil2"

enable_host_mem=1

usage() {
  cat <<'EOF'
Usage: u280_xrt_start.sh [--no-host-mem]

Load the user-local XRT 2.16 drivers for the U280 at 0000:ab:00.0/.1.
By default, also enable 1 GiB of host memory on user PF 0000:ab:00.1.

Options:
  --no-host-mem  Load and verify the drivers without enabling host memory.
  -h, --help     Show this help.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --no-host-mem)
      enable_host_mem=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown option: ${arg}"
      ;;
  esac
done

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
else
  "${SUDO[@]}" insmod "$XOCL_KO"
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

if (( enable_host_mem )); then
  host_mem_attr="/sys/bus/pci/devices/${USER_BDF}/host_mem_size"
  current_host_mem=0
  [[ -r "$host_mem_attr" ]] && current_host_mem="$(<"$host_mem_attr")"

  if [[ "$current_host_mem" == "$HOST_MEM_BYTES" ]]; then
    echo "Host memory is already enabled at ${HOST_MEM_SIZE}."
  elif [[ "$current_host_mem" != "0" ]]; then
    die "host memory is already ${current_host_mem} bytes; disable it explicitly before changing size"
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

echo
echo "U280 XRT startup completed successfully."
echo "For XRT tools and Vortex builds in this shell, run:"
echo "  source ${XRT_ROOT}/setup.sh"
