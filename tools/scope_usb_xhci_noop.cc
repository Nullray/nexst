// SPDX-License-Identifier: GPL-2.0-or-later
// Pre-boot xHCI No-op DMA probe. The Python wrapper owns reset/driver lifecycle.
#include <array>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;
static volatile sig_atomic_t interrupted;
static void interrupt_handler(int) { interrupted = 1; }
static void require(bool ok, const std::string &why) {
    if (!ok) throw std::runtime_error(why);
}
static std::string contents(const fs::path &path) {
    std::ifstream in(path);
    require(bool(in), "Cannot read " + path.string());
    std::string value;
    std::getline(in, value);
    return value;
}
struct Mapping {
    int fd = -1;
    size_t size;
    void *address = MAP_FAILED;
    Mapping(const fs::path &path, size_t length, uint64_t offset = 0) : size(length) {
        fd = open(path.c_str(), O_RDWR | O_SYNC | O_CLOEXEC);
        require(fd >= 0, "Cannot open " + path.string());
        address = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, off_t(offset));
        if (address == MAP_FAILED) {
            close(fd);
            fd = -1;
            throw std::runtime_error("Cannot mmap " + path.string());
        }
    }
    ~Mapping() {
        if (address != MAP_FAILED) munmap(address, size);
        if (fd >= 0) close(fd);
    }
    Mapping(const Mapping &) = delete;
    Mapping &operator=(const Mapping &) = delete;
    uint32_t read(size_t offset) const {
        require(!(offset & 3) && offset + 4 <= size, "MMIO read out of range");
        return *reinterpret_cast<volatile uint32_t *>(static_cast<char *>(address) + offset);
    }
    void write(size_t offset, uint32_t value) {
        require(!(offset & 3) && offset + 4 <= size, "MMIO write out of range");
        *reinterpret_cast<volatile uint32_t *>(static_cast<char *>(address) + offset) = value;
    }
    void write64(size_t offset, uint64_t value) {
        write(offset, uint32_t(value));
        write(offset + 4, uint32_t(value >> 32));
    }
};
struct Config {
    int fd;
    uint16_t original = 0;
    bool touched = false;
    explicit Config(const fs::path &path) : fd(open(path.c_str(), O_RDWR | O_CLOEXEC)) {
        require(fd >= 0, "Cannot open PCI config");
        original = command();
    }
    ~Config() {
        if (touched) {
            try { command(uint16_t(original & ~4U)); }
            catch (...) { std::fputs("Cannot restore PCI command with BME off\n", stderr); }
        }
        close(fd);
    }
    uint16_t command() {
        uint8_t bytes[2];
        require(pread(fd, bytes, 2, 4) == 2, "Cannot read PCI command");
        return uint16_t(bytes[0]) | (uint16_t(bytes[1]) << 8);
    }
    void command(uint16_t value) {
        uint8_t bytes[] = {uint8_t(value), uint8_t(value >> 8)};
        touched = true;
        require(pwrite(fd, bytes, 2, 4) == 2, "Cannot write PCI command");
        require(((command() ^ value) & 0x406) == 0, "PCI command readback mismatch");
    }
};
static bool wait_reg(Mapping &bar, size_t reg, uint32_t mask, uint32_t wanted,
                     unsigned milliseconds, bool cancel = true) {
    const auto end = Clock::now() + std::chrono::milliseconds(milliseconds);
    do {
        if (cancel && interrupted) throw std::runtime_error("Probe interrupted");
        uint32_t value = bar.read(reg);
        if (value != UINT32_MAX && (value & mask) == wanted) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    } while (Clock::now() < end);
    return false;
}
struct Controller {
    Mapping &bar;
    Config &pci;
    uint32_t op;
    uint16_t saved;
    bool clean = false;
    Controller(Mapping &b, Config &p, uint32_t o) : bar(b), pci(p), op(o), saved(p.original) {}
    uint16_t disabled() const { return uint16_t((saved | 0x402) & ~4); }
    void halt_reset(bool cancel = true) {
        pci.command(disabled());
        bar.write(op, bar.read(op) & ~5U);
        require(wait_reg(bar, op + 4, 1, 1, 2000, cancel), "xHCI did not halt; BME remains off");
        bar.write(op, 2);
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        require(wait_reg(bar, op, 2, 0, 2000, cancel), "xHCI reset timed out; BME remains off");
        require(wait_reg(bar, op + 4, 1U << 11, 0, 2000, cancel), "xHCI CNR remained set");
    }
    void finish() {
        halt_reset(false);
        pci.command(uint16_t(saved & ~4U)); // Host driver must initialize its own queues before BME.
        clean = true;
    }
    ~Controller() {
        if (!clean) {
            try { finish(); }
            catch (const std::exception &error) {
                std::fprintf(stderr, "CLEANUP FAILED: %s\n", error.what());
                try { pci.command(disabled()); } catch (...) {}
            }
        }
    }
};
static std::pair<uint64_t, uint64_t> memory_bar(const fs::path &device, int wanted = -1) {
    std::ifstream in(device / "resource");
    require(bool(in), "Cannot read PCI resources");
    uint64_t start, end, flags, base = 0, size = 0;
    for (int i = 0; i < 6 && (in >> std::hex >> start >> end >> flags); ++i) {
        if ((wanted < 0 || wanted == i) && (flags & 0x200) && start && end >= start) {
            base = start;
            size = end - start + 1;
        }
    }
    require(size != 0, "No assigned PCI memory BAR");
    return {base, size};
}
static void check_owner(const fs::path &node, const std::string &bdf) {
    struct stat info{};
    require(stat(node.c_str(), &info) == 0 && S_ISCHR(info.st_mode), "Invalid XDMA character device");
    auto sys = fs::path("/sys/dev/char") /
        (std::to_string(major(info.st_rdev)) + ":" + std::to_string(minor(info.st_rdev)));
    bool found = false;
    for (const auto &part : fs::canonical(sys)) if (part.string() == bdf) found = true;
    require(found, "XDMA node belongs to another FPGA");
}
static int probe(int argc, char **argv) {
    require(argc == 6, "Usage: xhci-p2p-noop FPGA_BDF XHCI_BDF XDMA_BYPASS SCRATCH_PA alias|noop|stop");
    const fs::path pci_root("/sys/bus/pci/devices");
    const fs::path fpga = pci_root / argv[1], xhci = pci_root / argv[2];
    const std::string mode(argv[5]);
    require(mode == "alias" || mode == "noop" || mode == "stop", "Invalid probe mode");
    require(geteuid() == 0, "Root is required");
    require(contents(fpga / "vendor") == "0x10ee" && contents(fpga / "device") == "0x903f",
            "Unexpected NM37 PCI identity");
    require(contents(xhci / "vendor") == "0x1022" && contents(xhci / "device") == "0x43fd" &&
            contents(xhci / "class") == "0x0c0330", "Unexpected B650 xHCI identity");
    const std::string bypass(argv[3]);
    require(bypass.size() > 7 && bypass.substr(bypass.size() - 7) == "_bypass", "Invalid bypass node name");
    check_owner(bypass, argv[1]);
    if (mode != "stop") {
        const std::string user = bypass.substr(0, bypass.size() - 7) + "_user";
        check_owner(user, argv[1]);
        Mapping bootrom(user, 4096), reset(user, 4096, 0x100000);
        require(bootrom.read(0) == 0x0000006f && !(reset.read(0) & 1),
                "Use the Python wrapper: CPU must run the test spin loop with SoC reset released");
    }
    const uint64_t scratch = std::stoull(argv[4], nullptr, 0);
    require(scratch >= 0x80000000ULL && scratch <= 0xff800000ULL && !(scratch & 0xffff),
            "Scratch must be 64 KiB aligned and wholly inside the 2 GiB guest RAM");
    constexpr uint64_t alias = 0x100000000ULL;
    auto [fpga_base, fpga_size] = memory_bar(fpga);
    const uint64_t offset = alias + scratch, bus = fpga_base + offset;
    require(offset + 0x800000 <= fpga_size && bus >= fpga_base, "Coherent scratch not covered by FPGA BAR");
    if (mode == "alias") {
        Mapping mem(argv[3], 4096, offset);
        for (unsigned i = 0; i < 64; ++i) mem.write(i * 4, 0x53435045U ^ (i * 0x1020304U));
        __sync_synchronize();
        for (unsigned i = 0; i < 64; ++i)
            require(mem.read(i * 4) == (0x53435045U ^ (i * 0x1020304U)), "Coherent alias readback mismatch");
        std::printf("PASS: coherent alias CPU read/write at PA=0x%llx bus=0x%llx; P2P not yet tested\n",
                    (unsigned long long)scratch, (unsigned long long)bus);
        return 0;
    }
    require(!fs::exists(xhci / "driver"), "xHCI must be unbound");
    if (fs::exists(xhci / "iommu_group"))
        require(contents(xhci / "iommu_group/type") == "identity", "Identity/no-IOMMU required");
    auto [xhci_base, bar_size] = memory_bar(xhci, 0);
    (void)xhci_base;
    require(bar_size <= 0x100000, "Unexpected xHCI BAR0 size");
    Config config(xhci / "config");
    // pci_disable_device() during unbind may turn MEM off. Enable only MMIO first.
    config.command(uint16_t((config.original | 0x402) & ~4U));
    Mapping bar(xhci / "resource0", size_t(bar_size));
    const uint32_t op = bar.read(0) & 0xff, hcc = bar.read(0x10);
    const uint32_t rt = bar.read(0x18) & ~31U, db = bar.read(0x14) & ~3U;
    require(hcc != UINT32_MAX && (hcc & 1) && op >= 0x20 && uint64_t(op) + 0x40 <= bar_size &&
            rt >= 0x20 && uint64_t(rt) + 0x40 <= bar_size && db >= 0x20 && uint64_t(db) + 4 <= bar_size,
            "Invalid xHCI layout or no 64-bit DMA");
    std::array<uint8_t, 256> cfg{};
    require(pread(config.fd, cfg.data(), cfg.size(), 0) == ssize_t(cfg.size()), "Short PCI config");
    unsigned cap = cfg[0x34] & ~3U, count = 0;
    while (cap && count++ < 48) {
        require(cap >= 0x40 && cap <= 0xfc, "Malformed PCI capabilities");
        uint16_t bits = uint16_t(cfg[cap + 2]) | (uint16_t(cfg[cap + 3]) << 8);
        require(!((cfg[cap] == 5 && (bits & 1)) || (cfg[cap] == 0x11 && (bits & 0x8000))),
                "Host MSI/MSI-X still enabled");
        cap = cfg[cap + 1] & ~3U;
    }
    require(!cap, "PCI capability loop");
    // Never seize a controller from firmware; disable legacy SMI as in the production backend.
    unsigned ext = (hcc >> 16) * 4U;
    count = 0;
    while (ext && count++ < 256) {
        uint32_t value = bar.read(ext);
        require(value != UINT32_MAX, "Unreadable xHCI extended capability");
        if ((value & 0xff) == 1) {
            require(!(value & (1U << 16)), "BIOS still owns xHCI");
            uint32_t control = bar.read(ext + 4);
            bar.write(ext, value | (1U << 24));
            bar.write(ext + 4, (control & ((7U << 1) | (0xffU << 5) | (7U << 17))) | (7U << 29));
        }
        ext = value & 0xff00 ? ext + ((value >> 8) & 0xff) * 4U : 0;
    }
    require(!ext, "xHCI extended capability loop");
    Controller controller(bar, config, op);
    if (mode == "stop") {
        controller.finish();
        std::puts("PASS: xHCI stopped/reset, bus master off");
        return 0;
    }
    controller.halt_reset();
    uint32_t page_mask = bar.read(op + 8) & 0xffff;
    require(page_mask != 0, "No supported xHCI page size");
    uint64_t page_size = 4096ULL << __builtin_ctz(page_mask);
    uint32_t hcs2 = bar.read(8);
    unsigned scratchpads = ((hcs2 >> 16) & 0x3e0) | ((hcs2 >> 27) & 0x1f);
    size_t length = size_t(0x10000ULL + uint64_t(scratchpads) * page_size);
    require(page_size <= 0x10000 && length <= 0x800000, "Scratchpad allocation exceeds test region");
    Mapping mem(argv[3], length, offset);
    for (size_t i = 0; i < length; i += 4) mem.write(i, 0);
    constexpr unsigned commands = 8, cmd_ring = 0x1000, events = 0x2000, erst = 0x3000, sp_array = 0x4000;
    if (scratchpads) mem.write64(0, bus + sp_array);
    for (unsigned i = 0; i < scratchpads; ++i) mem.write64(sp_array + i * 8, bus + 0x10000 + i * page_size);
    for (unsigned i = 0; i < commands; ++i) mem.write(cmd_ring + i * 16 + 12, (23U << 10) | 1);
    mem.write64(cmd_ring + 255 * 16, bus + cmd_ring);
    mem.write(cmd_ring + 255 * 16 + 12, (6U << 10) | 3); // Link TRB, toggle cycle.
    mem.write64(erst, bus + events);
    mem.write(erst + 8, 256);
    __sync_synchronize();
    require(mem.read(cmd_ring + 12) == ((23U << 10) | 1) && mem.read(erst + 8) == 256 &&
            mem.read(length - 4) == 0, "Ring/scratchpad initialization readback failed");
    bar.write64(op + 0x30, bus); // DCBAAP
    bar.write64(op + 0x18, (bus + cmd_ring) | 1); // CRCR.RCS
    bar.write(op + 0x38, 1); // MaxSlotsEn; no USB slot/endpoint commands are issued.
    bar.write(rt + 0x20, 1); // IMAN.IP W1C, IE=0; use polling.
    bar.write(rt + 0x24, 0);
    bar.write(rt + 0x28, 1);
    bar.write64(rt + 0x30, bus + erst);
    bar.write64(rt + 0x38, bus + events);
    require(!(bar.read(op + 4) & (1U << 11)), "Controller not ready before RUN");
    config.command(controller.disabled() | 4);
    bar.write(op, 1); // RUN, global IRQ enable stays off.
    require(wait_reg(bar, op + 4, 1, 0, 2000), "xHCI did not enter RUN");
    bar.write(db, 0);
    (void)bar.read(op + 4); // Drain posted doorbell write.
    std::printf("Probe: %u No-op commands, %u scratchpads, page=%llu, bus=0x%llx\n",
                commands, scratchpads, (unsigned long long)page_size, (unsigned long long)bus);
    std::fflush(stdout);
    std::array<bool, commands> done{};
    unsigned completed = 0, index = 0;
    const auto deadline = Clock::now() + std::chrono::seconds(10);
    while (completed < commands && Clock::now() < deadline) {
        require(!interrupted, "Probe interrupted");
        require(index < 256, "Event ring unexpectedly filled");
        uint32_t control = mem.read(events + index * 16 + 12);
        if (!(control & 1)) {
            uint32_t status = bar.read(op + 4);
            require(status != UINT32_MAX && !(status & ((1U << 2) | (1U << 12))),
                    "xHCI host system/controller error during DMA");
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            continue;
        }
        __sync_synchronize();
        uint64_t pointer = mem.read(events + index * 16);
        pointer |= uint64_t(mem.read(events + index * 16 + 4)) << 32;
        uint32_t code = mem.read(events + index * 16 + 8) >> 24;
        if (((control >> 10) & 0x3f) == 33) {
            require(code == 1 && pointer >= bus + cmd_ring && pointer < bus + cmd_ring + commands * 16 &&
                    !((pointer - bus - cmd_ring) & 15), "Invalid No-op completion pointer/code");
            unsigned command = unsigned((pointer - bus - cmd_ring) / 16);
            require(!done[command], "Duplicate No-op completion");
            done[command] = true;
            ++completed;
        }
        ++index;
        bar.write64(rt + 0x38, (bus + events + index * 16) | 8); // Advance ERDP, clear EHB.
    }
    if (completed != commands) {
        std::fprintf(stderr, "DMA timeout: completions=%u/%u USBSTS=0x%08x CRCR=0x%08x%08x event0=0x%08x\n",
                     completed, commands, bar.read(op + 4), bar.read(op + 0x1c),
                     bar.read(op + 0x18), mem.read(events + 12));
        throw std::runtime_error("No-op completion timeout: P2P route is NOT verified");
    }
    controller.finish();
    std::printf("PASS: %u/%u matching No-op completions: physical xHCI DMA read AND write reached FPGA DDR via the configured alias\n",
                completed, commands);
    return 0;
}
int main(int argc, char **argv) {
    std::signal(SIGINT, interrupt_handler);
    std::signal(SIGTERM, interrupt_handler);
    try { return probe(argc, argv); }
    catch (const std::exception &error) {
        std::fprintf(stderr, "FAIL: %s\n", error.what());
        return 1;
    }
}
