#!/usr/bin/env bash

set -Eeuo pipefail

readonly REPO_ROOT="/home/yanjiarun/nexst_proxy_14"
readonly WORK_FARM="${REPO_ROOT}/work_farm"
readonly VORTEX_HOME="/home/yanjiarun/Vortex"
readonly ROOTFS_SRC="${REPO_ROOT}/nanhu-g/software/rootfs"
readonly CROSS_CXX_PATH="/usr/bin/riscv64-linux-gnu-g++"
readonly CROSS_PATH="/usr/bin"
readonly CROSS_PREFIX="riscv64-linux-gnu-"
readonly KERNEL_C_ISA_FLAGS="-march=rv64imac_zicsr_zifencei"
readonly KERNEL_ASM_ISA_FLAGS="-march=rv64imafdc_zicsr_zifencei"
readonly OPENSBI_ISA="rv64imafdc_zicsr_zifencei"
readonly BOARD="nm37_vu37p"
readonly PROJECT="target:nanhu-g:proto"
readonly DT_TARGET="XSTop_vpcie"
readonly VORTEX_CONFIGS_VALUE="-DVX_CFG_NUM_CLUSTERS=1 -DVX_CFG_NUM_CORES=1 -DVX_CFG_PLATFORM_MEMORY_NUM_BANKS=1 -DVX_CFG_PLATFORM_MEMORY_ADDR_WIDTH=28"
readonly WORK_OUTPUT="${WORK_FARM}/target/nanhu-g/ready_for_download/proto_nm37_vu37p/RV_BOOT.bin"
readonly WORK_BACKUP="${WORK_FARM}/target/nanhu-g/ready_for_download/proto_nm37_vu37p/RV_BOOT.pre_vortex_1bank.bin"
readonly FINAL_OUTPUT="${REPO_ROOT}/nanhu-g/ready_for_download/proto_nm37_vu37p/RV_BOOT_vortex_1bank.bin"

require_file() {
    [[ -e "$1" ]] || {
        echo "ERROR: required path is missing: $1" >&2
        exit 1
    }
}

require_file "${VORTEX_HOME}/tools/scope_vortex_bridge/build_vecadd_riscv64.sh"
require_file "${WORK_FARM}/Makefile"
require_file "${CROSS_CXX_PATH}"
require_file "${CROSS_PATH}/${CROSS_PREFIX}gcc"

echo "Building XiangShan Vortex guest for the loaded single-bank U280 xclbin"
echo "VORTEX_CONFIGS=${VORTEX_CONFIGS_VALUE}"

# scope_vortex_guest does not currently track CONFIGS in its prerequisites.
# Remove only its generated output so changed capability constants cannot leave
# a stale executable behind.
make -C "${VORTEX_HOME}/tools/scope_vortex_guest" clean

CONFIGS="${VORTEX_CONFIGS_VALUE}" \
    CROSS_CXX="${CROSS_CXX_PATH}" \
    "${VORTEX_HOME}/tools/scope_vortex_bridge/build_vecadd_riscv64.sh"

# Re-enter the rootfs Makefile directly.  The outer work_farm target does not
# track rebuilt Vortex guest binaries, while this Makefile has phony app
# targets and therefore copies them and refreshes initramfs.txt every time.
make -C "${ROOTFS_SRC}" \
    RISCV=/usr \
    CROSS_COMPILE="${CROSS_PREFIX}" \
    RISCV_SYSROOT=/usr/riscv64-linux-gnu \
    CC="${CROSS_PATH}/${CROSS_PREFIX}gcc" \
    LMBENCH_ENABLE=0 \
    VORTEX_ENABLE=1 \
    VORTEX_HOME="${VORTEX_HOME}" \
    VORTEX_CONFIGS="${VORTEX_CONFIGS_VALUE}" \
    all

# The Debian/Ubuntu RISC-V loader searches its multiarch directory, not the
# legacy /lib64/lp64d layout used by the original project toolchain.
for guest_lib in libc.so.6 libdl.so.2 libm.so.6 libpthread.so.0 libresolv.so.2; do
    grep -F "file /lib/riscv64-linux-gnu/${guest_lib} " \
        "${ROOTFS_SRC}/initramfs.txt" >/dev/null || {
        echo "ERROR: initramfs is missing /lib/riscv64-linux-gnu/${guest_lib}" >&2
        exit 1
    }
done

make -C "${WORK_FARM}" \
    PRJ="${PROJECT}" \
    FPGA_BD="${BOARD}" \
    ARCH=riscv \
    riscv_LINUX_GCC_PATH="${CROSS_PATH}" \
    riscv_LINUX_GCC_PREFIX="${CROSS_PREFIX}" \
    ROOTFS_SRC="${ROOTFS_SRC}" \
    RISCV_SYSROOT=/usr/riscv64-linux-gnu \
    CC="${CROSS_PATH}/${CROSS_PREFIX}gcc" \
    KCFLAGS="${KERNEL_C_ISA_FLAGS}" \
    KAFLAGS="${KERNEL_ASM_ISA_FLAGS}" \
    LMBENCH_ENABLE=0 \
    DT_TARGET="${DT_TARGET}" \
    VORTEX_ENABLE=1 \
    VORTEX_HOME="${VORTEX_HOME}" \
    VORTEX_CONFIGS="${VORTEX_CONFIGS_VALUE}" \
    phy_os.os

if [[ -f "${WORK_OUTPUT}" && ! -e "${WORK_BACKUP}" ]]; then
    cp --reflink=auto --preserve=mode,timestamps "${WORK_OUTPUT}" "${WORK_BACKUP}"
fi

# Rebuild OpenSBI from a clean generated directory so fw_payload.bin cannot
# retain the previous Linux Image/initramfs payload.
make -C "${WORK_FARM}" \
    PRJ="${PROJECT}" \
    FPGA_BD="${BOARD}" \
    ARCH=riscv \
    riscv_LINUX_GCC_PATH="${CROSS_PATH}" \
    riscv_LINUX_GCC_PREFIX="${CROSS_PREFIX}" \
    PLATFORM_RISCV_ISA="${OPENSBI_ISA}" \
    DT_TARGET="${DT_TARGET}" \
    opensbi_clean

make -C "${WORK_FARM}" \
    PRJ="${PROJECT}" \
    FPGA_BD="${BOARD}" \
    ARCH=riscv \
    riscv_LINUX_GCC_PATH="${CROSS_PATH}" \
    riscv_LINUX_GCC_PREFIX="${CROSS_PREFIX}" \
    PLATFORM_RISCV_ISA="${OPENSBI_ISA}" \
    DT_TARGET="${DT_TARGET}" \
    opensbi

require_file "${WORK_OUTPUT}"
install -m 0644 "${WORK_OUTPUT}" "${FINAL_OUTPUT}"

echo "Checking embedded guest configuration"
for expected in \
    "VX_CFG_NUM_CORES=1" \
    "VX_CFG_PLATFORM_MEMORY_NUM_BANKS=1" \
    "VX_CFG_PLATFORM_MEMORY_ADDR_WIDTH=28"; do
    strings -a "${FINAL_OUTPUT}" | grep -Fx "${expected}" >/dev/null || {
        echo "ERROR: final RV_BOOT image does not contain ${expected}" >&2
        exit 1
    }
done

sha256sum "${FINAL_OUTPUT}"
stat -c 'Output: %n (%s bytes)' "${FINAL_OUTPUT}"
echo "Use this image with tools/proto/load_and_run_5.sh; the original top-level RV_BOOT.bin was not overwritten."
