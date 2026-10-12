#!/usr/bin/env bash
# Build software for the existing Nanhu-G SCOPE image; no FPGA operations.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
kernel="$repo_root/work_farm/software/linux"
out="$repo_root/build/nanhu-host"
dry_run=0
kernel_check=0
for option in "$@"; do
    case "$option" in
        --dry-run) dry_run=1 ;;
        --kernel-check) kernel_check=1 ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--kernel-check]"
            echo "Default: build Linux Image, DTB and OpenSBI fw_payload.bin."
            echo "--kernel-check: compile only the PCI DMA integration object."
            exit 0 ;;
        *) echo "Unknown option: $option" >&2; exit 2 ;;
    esac
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
flags=(-C "$kernel" "O=$out/linux" ARCH=riscv "CROSS_COMPILE=$prefix")
run bash "$repo_root/tools/guest/bootstrap.sh" --kernel-only
run python3 "$repo_root/tools/guest/install_pci_dma.py" "$kernel"
run python3 "$repo_root/tools/guest/prepare_initramfs.py" --output "$out/initramfs.txt"
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
