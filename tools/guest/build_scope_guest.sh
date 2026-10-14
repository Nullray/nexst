#!/usr/bin/env bash
# Build ordinary Kunminghu SCOPE Linux, a minimal busybox initramfs and firmware.
set -euo pipefail
guest_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
guest_cores=${NUM_CORES:-$(python3 "$guest_root/tools/hardware/profile.py" --field num_cores)}
guest_cross=${CROSS_COMPILE:-riscv64-linux-gnu-}
guest_jobs=${JOBS:-4}
guest_dt_source=${SCOPE_DT_SOURCE:-$guest_root/kmh/hardware/xs-gen/build/XSTop.dts}
[[ $guest_cores == 1 || $guest_cores == 2 ]] || { echo 'NUM_CORES must be 1 or 2' >&2; exit 1; }
guest_out="$guest_root/build/guest-${guest_cores}core"
guest_linux="$guest_root/work_farm/software/linux"
guest_busybox="$guest_root/kmh/software/rootfs/apps/busybox"
guest_opensbi="$guest_root/kmh/software/opensbi"
mkdir -p "$guest_out" "$guest_root/build/software-logs"
guest_log="$guest_root/build/software-logs/guest-${guest_cores}core-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$guest_log") 2>&1
echo "Guest build log: $guest_log"
python3 "$guest_root/tools/guest/prepare_profile_dt.py" --num-cores "$guest_cores" \
    --source "$guest_dt_source" --output "$guest_out/kunminghu-scope.dts" --dtb "$guest_out/kunminghu-scope.dtb"
python3 "$guest_root/tools/guest/install_pci_dma.py" "$guest_linux"
python3 "$guest_root/tools/guest/install_xhci_start_fix.py" "$guest_linux"
guest_busybox_out="$guest_out/busybox"
mkdir -p "$guest_busybox_out"
make -C "$guest_busybox" O="$guest_busybox_out" CROSS_COMPILE="$guest_cross" defconfig
# Static busybox avoids dependence on the build host's libc files at boot.
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' "$guest_busybox_out/.config"
make -C "$guest_busybox" O="$guest_busybox_out" CROSS_COMPILE="$guest_cross" \
    CONFIG_STATIC=y -j "$guest_jobs"
cat > "$guest_out/init" <<'INIT'
#!/bin/busybox sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
/bin/busybox --install -s
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /tmp
mkdir -p /usr/share/udhcpc
echo 'Ordinary Kunminghu SCOPE guest: inspect /sys/bus/pci/devices and dmesg.'
echo 'Run ip link and udhcpc -i <network interface> to configure networking.'
exec setsid cttyhack sh
INIT
cat > "$guest_out/initramfs.txt" <<EOF
dir /bin 755 0 0
dir /sbin 755 0 0
dir /usr 755 0 0
dir /usr/bin 755 0 0
dir /usr/sbin 755 0 0
dir /usr/share 755 0 0
dir /usr/share/udhcpc 755 0 0
dir /dev 755 0 0
dir /proc 755 0 0
dir /sys 755 0 0
dir /tmp 1777 0 0
dir /etc 755 0 0
file /bin/busybox $guest_busybox_out/busybox 755 0 0
file /init $guest_out/init 755 0 0
file /usr/share/udhcpc/default.script $guest_root/kmh/software/rootfs/files/usr/share/udhcpc/default.script 755 0 0
nod /dev/console 600 0 0 c 5 1
nod /dev/null 666 0 0 c 1 3
EOF
guest_kernel_out="$guest_out/linux"
mkdir -p "$guest_kernel_out"
make -C "$guest_linux" O="$guest_kernel_out" ARCH=riscv CROSS_COMPILE="$guest_cross" riscv_serve_defconfig
(cd "$guest_linux"; scripts/kconfig/merge_config.sh -m -O "$guest_kernel_out" \
    "$guest_kernel_out/.config" "$guest_root/tools/guest/scope_kernel.config")
make -C "$guest_linux" O="$guest_kernel_out" ARCH=riscv CROSS_COMPILE="$guest_cross" \
    CONFIG_INITRAMFS_SOURCE="$guest_out/initramfs.txt" olddefconfig
for guest_required in PCI_HOST_GENERIC SCOPE_PCIE_P2P_DMA USB_XHCI_PCI IGB IXGBE SERIAL_UARTLITE_CONSOLE; do
    rg -q "^CONFIG_${guest_required}=y$" "$guest_kernel_out/.config" || {
        echo "Missing required guest config: $guest_required" >&2; exit 1;
    }
done
make -C "$guest_linux" O="$guest_kernel_out" ARCH=riscv CROSS_COMPILE="$guest_cross" \
    CONFIG_INITRAMFS_SOURCE="$guest_out/initramfs.txt" -j "$guest_jobs" Image
cp "$guest_kernel_out/arch/riscv/boot/Image" "$guest_out/Image"
make -C "$guest_opensbi" O="$guest_out/opensbi" CROSS_COMPILE="$guest_cross" \
    PLATFORM=ict SERVE_PLAT=scope RV_TARGET=kunminghu_scope HART_COUNT="$guest_cores" WITH_SM=n \
    FW_FDT_PATH="$guest_out/kunminghu-scope.dtb" OPENSBI_PAYLOAD="$guest_out/Image" -j "$guest_jobs"
cp "$guest_out/opensbi/platform/ict/firmware/fw_payload.bin" "$guest_out/RV_BOOT.bin"
make -C "$guest_root/kmh/software/zsbl" O="$guest_out" CROSS_COMPILE="$guest_cross"
sha256sum "$guest_out/Image" "$guest_out/RV_BOOT.bin" "$guest_out/bootrom.bin" "$guest_out/kunminghu-scope.dtb" \
    > "$guest_out/SHA256SUMS"
echo "Guest artifacts: $guest_out; build complete."
