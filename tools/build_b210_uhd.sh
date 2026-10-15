#!/usr/bin/env bash
# Cross-build cached official sources and the private RISC-V Boost sysroot.
# This script does not install host packages or access FPGA/USB hardware.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
build_root=$(realpath -m "${1:-$repo_root/build/uhd-b210}")
jobs=${JOBS:-16}
uhd_source="$build_root/src/uhd-4.11.0.0"
usb_source="$build_root/src/libusb-1.0.30"
test -f "$uhd_source/host/CMakeLists.txt"
test -f "$usb_source/configure.ac"
test -f "$build_root/sysroot/usr/include/boost/version.hpp"
mkdir -p "$build_root/logs" "$build_root/libusb-build"
exec 9>"$build_root/uhd-build.lock"
flock -n 9 || { echo "Another B210 software build is running." >&2; exit 1; }

if [[ ! -f $usb_source/configure ]]; then
    (cd "$usb_source" && autoreconf -fi)
fi
(
    cd "$build_root/libusb-build"
    env CC=riscv64-linux-gnu-gcc \
        CFLAGS='-O2 -march=rv64imafdc_zicsr_zifencei -mabi=lp64d' \
        "$usb_source/configure" --host=riscv64-linux-gnu --prefix=/opt/uhd \
        --disable-udev --disable-static
    make -j "$jobs"
    make "DESTDIR=$build_root/rootfs" install
) > "$build_root/logs/libusb-build.log" 2>&1

cat > "$build_root/riscv64-toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR riscv64)
set(CMAKE_C_COMPILER riscv64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER riscv64-linux-gnu-g++)
set(CMAKE_C_FLAGS_INIT "-march=rv64imafdc_zicsr_zifencei -mabi=lp64d")
set(CMAKE_CXX_FLAGS_INIT "-march=rv64imafdc_zicsr_zifencei -mabi=lp64d")
set(CMAKE_FIND_ROOT_PATH "$build_root/sysroot" "/usr/riscv64-linux-gnu" "$build_root/rootfs")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
cmake -S "$uhd_source/host" -B "$build_root/uhd-build" -G Ninja \
    "-DCMAKE_TOOLCHAIN_FILE=$build_root/riscv64-toolchain.cmake" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/uhd \
    -DCMAKE_INSTALL_LIBDIR=lib -DBoost_NO_BOOST_CMAKE=ON -DBoost_NO_SYSTEM_PATHS=ON \
    "-DBOOST_ROOT=$build_root/sysroot/usr" \
    "-DBOOST_INCLUDEDIR=$build_root/sysroot/usr/include" \
    "-DBOOST_LIBRARYDIR=$build_root/sysroot/usr/lib/riscv64-linux-gnu" \
    "-DLIBUSB_INCLUDE_DIRS=$build_root/rootfs/opt/uhd/include/libusb-1.0" \
    "-DLIBUSB_LIBRARIES=$build_root/rootfs/opt/uhd/lib/libusb-1.0.so" \
    -DENABLE_PYTHON_API=OFF -DENABLE_PYMOD_UTILS=OFF -DENABLE_TESTS=OFF \
    -DENABLE_MAN_PAGES=OFF -DENABLE_C_API=OFF -DENABLE_B100=OFF \
    -DENABLE_B300=OFF -DENABLE_USRP1=OFF -DENABLE_USRP2=OFF -DENABLE_X300=OFF \
    -DENABLE_MPMD=OFF -DENABLE_SIM=OFF -DENABLE_OCTOCLOCK=OFF -DENABLE_DPDK=OFF \
    -DENABLE_B200=ON -DENABLE_USB=ON -DENABLE_UTILS=ON -DENABLE_EXAMPLES=ON \
    -DUHD_VERSION=4.11.0.0 -DUHD_RELEASE_MODE=release \
    -DUHD_GIT_BRANCH_OVERRIDE=UHD-4.11 -DUHD_VERSION_PATCH_OVERRIDE=0 \
    > "$build_root/logs/uhd-configure.log" 2>&1
ninja -C "$build_root/uhd-build" -j "$jobs" \
    uhd_find_devices uhd_usrp_probe benchmark_rate rx_samples_to_file \
    > "$build_root/logs/uhd-build.log" 2>&1

# Download on the host using the release's manifest and SHA-256 checks.
if [[ ! -s $build_root/rootfs/opt/uhd/share/uhd/images/usrp_b210_fpga.bin ||
      ! -s $build_root/rootfs/opt/uhd/share/uhd/images/usrp_b200_fw.hex ]]; then
    python3 "$build_root/uhd-build/utils/uhd_images_downloader.py" \
        --types 'b2xx_(b210_fpga|common_fw)_default' \
        --install-location "$build_root/rootfs/opt/uhd/share/uhd/images" \
        > "$build_root/logs/b210-images-download.log" 2>&1
fi
overlay=$(mktemp -d "$build_root/guest-root.XXXXXX")
python3 "$repo_root/tools/guest/package_uhd_b210.py" \
    --build "$build_root" --output "$overlay"
ln -sfnT "$overlay" "$build_root/current-root"
echo "To build firmware with this runtime:"
printf 'bash %q --output %q --overlay %q\n' \
    "$repo_root/tools/build_nanhu_host_software.sh" \
    "$repo_root/build/nanhu-b210" "$build_root/current-root"
