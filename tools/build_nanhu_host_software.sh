#!/usr/bin/env bash
# Build software for the existing Nanhu-G SCOPE image; no FPGA operations.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
kernel="$repo_root/work_farm/software/linux"
out="$repo_root/build/nanhu-host"
dry_run=0
kernel_check=0
overlay=
while (( $# )); do
    option=$1
    case "$option" in
        --dry-run) dry_run=1 ;;
        --kernel-check) kernel_check=1 ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--kernel-check] [--output DIR] [--overlay DIR]"
            echo "Default: build Linux Image, DTB and OpenSBI fw_payload.bin."
            echo "--kernel-check: compile only the PCI DMA integration object."
            exit 0 ;;
        --output|--overlay)
            (( $# >= 2 )) || { echo "Missing argument for $option" >&2; exit 2; }
            if [[ $option == --output ]]; then out=$(realpath -m "$2");
            else overlay=$(realpath -m "$2"); fi
            shift ;;
        *) echo "Unknown option: $option" >&2; exit 2 ;;
    esac
    shift
done
if (( ! dry_run )); then
    mkdir -p "$out" "$repo_root/build/software-logs"
    exec 9>"$out/build.lock"
    flock -n 9 || { echo "Nanhu-G firmware build is already running." >&2; exit 1; }
    log="$repo_root/build/software-logs/firmware-$(date +%Y%m%d_%H%M%S)-$$.log"
    echo "Build log: $log"
    exec > >(tee "$log") 2>&1
fi
run() {
    printf '%q ' "$@"
    printf '\n'
    if (( ! dry_run )); then "$@"; fi
}
prefix=${CROSS_COMPILE:-riscv64-linux-gnu-}
jobs=${JOBS:-8}
# New binutils requires CSR/fence extensions to be explicit for this 5.16 tree.
# The kernel Makefile still removes fd from C flags and retains it for assembly.
flags=(-C "$kernel" "O=$out/linux" ARCH=riscv "CROSS_COMPILE=$prefix"
    riscv-march-y=rv64imafdc_zicsr_zifencei)
run bash "$repo_root/tools/guest/bootstrap.sh" --kernel-only
run python3 "$repo_root/tools/guest/install_pci_dma.py" "$kernel"
run python3 "$repo_root/tools/guest/install_xhci_start_fix.py" "$kernel"
ramfs_args=(--output "$out/initramfs.txt")
if [[ -n $overlay ]]; then ramfs_args+=(--overlay "$overlay"); fi
run python3 "$repo_root/tools/guest/prepare_initramfs.py" "${ramfs_args[@]}"
run make "${flags[@]}" riscv_serve_defconfig
run env "KCONFIG_CONFIG=$out/linux/.config" bash "$kernel/scripts/kconfig/merge_config.sh" \
    -m -O "$out/linux" "$out/linux/.config" "$repo_root/config/host-proxy/usb.config"
run make "${flags[@]}" olddefconfig
if (( kernel_check )); then
    run make "${flags[@]}" -j "$jobs" drivers/pci/pci-driver.o
else
    run make "${flags[@]}" "CONFIG_INITRAMFS_SOURCE=$out/initramfs.txt" -j "$jobs" Image
    run dtc -I dts -O dtb -o "$out/XSTop_vpcie.dtb" \
        "$repo_root/nanhu-g/software/dt/XSTop_vpcie.dts"
    run make -C "$repo_root/nanhu-g/software/opensbi" "O=$out/opensbi" \
        "CROSS_COMPILE=$prefix" PLATFORM=ict \
        PLATFORM_RISCV_ISA=rv64imafdc_zicsr_zifencei \
        "OPENSBI_PAYLOAD=$out/linux/arch/riscv/boot/Image" \
        "FW_FDT_PATH=$out/XSTop_vpcie.dtb" \
        SERVE_PLAT=h HART_COUNT=1 RV_TARGET=xiangshan WITH_SM=n -j "$jobs"
    if (( ! dry_run )); then
        test -s "$out/opensbi/platform/ict/firmware/fw_payload.bin"
        echo "Firmware: $out/opensbi/platform/ict/firmware/fw_payload.bin"
    fi
fi
