// SPDX-License-Identifier: GPL-2.0
/*
 * User-space BAR MMIO write latency test for the scope FPGA/QEMU path.
 *
 * Default target matches the current test device BAR assignment seen on
 * XiangShan Linux: BAR0 physical base 0x50000000, offset 0, value 0x5a5a0001.
 */

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_BAR_PHYS 0x50000000ULL
#define DEFAULT_OFFSET   0x0ULL
#define DEFAULT_VALUE    0x5a5a0001U
#define DEFAULT_ITERS    100U
#define DEFAULT_MAP_SIZE 0x1000ULL
#define DEFAULT_GAP_US   10ULL

static void usage(const char *prog)
{
	fprintf(stderr,
		"Usage: %s [bar_phys] [offset] [value] [iterations] [map_size] [gap_us]\n"
		"\n"
		"Defaults:\n"
		"  bar_phys   0x%llx\n"
		"  offset     0x%llx\n"
		"  value      0x%08x\n"
		"  iterations %u\n"
		"  map_size   0x%llx\n"
		"  gap_us     %llu\n"
		"\n"
		"Example:\n"
		"  %s 0x50000000 0x0 0x5a5a0001 100 0x1000 10\n",
		prog,
		(unsigned long long)DEFAULT_BAR_PHYS,
		(unsigned long long)DEFAULT_OFFSET,
		DEFAULT_VALUE,
		DEFAULT_ITERS,
		(unsigned long long)DEFAULT_MAP_SIZE,
		(unsigned long long)DEFAULT_GAP_US,
		prog);
}

static uint64_t parse_u64_arg(const char *arg, const char *name)
{
	char *end = NULL;
	uint64_t value;

	errno = 0;
	value = strtoull(arg, &end, 0);
	if (errno || !end || *end) {
		fprintf(stderr, "invalid %s: %s\n", name, arg);
		exit(EXIT_FAILURE);
	}

	return value;
}

static uint64_t align_down_u64(uint64_t value, uint64_t align)
{
	return value & ~(align - 1);
}

static uint64_t align_up_u64(uint64_t value, uint64_t align)
{
	return (value + align - 1) & ~(align - 1);
}

static uint64_t sub_floor_u64(uint64_t lhs, uint64_t rhs)
{
	return lhs > rhs ? lhs - rhs : 0;
}

static inline uint64_t scope_lat_now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static inline void scope_lat_io_write_barrier(void)
{
#if defined(__riscv)
	asm volatile("fence w,o" ::: "memory");
#else
	__sync_synchronize();
#endif
}

static inline void scope_lat_full_io_barrier(void)
{
#if defined(__riscv)
	asm volatile("fence iorw,iorw" ::: "memory");
#else
	__sync_synchronize();
#endif
}

static inline void scope_lat_write32(volatile uint32_t *addr, uint32_t value)
{
	scope_lat_io_write_barrier();
	*addr = value;
}

static void scope_lat_sleep_us(uint64_t gap_us)
{
	struct timespec req;

	if (!gap_us)
		return;

	req.tv_sec = (time_t)(gap_us / 1000000ULL);
	req.tv_nsec = (long)((gap_us % 1000000ULL) * 1000ULL);
	while (nanosleep(&req, &req) && errno == EINTR)
		;
}

int main(int argc, char **argv)
{
	uint64_t bar_phys = DEFAULT_BAR_PHYS;
	uint64_t offset = DEFAULT_OFFSET;
	uint32_t value = DEFAULT_VALUE;
	uint32_t iterations = DEFAULT_ITERS;
	uint64_t map_size = DEFAULT_MAP_SIZE;
	uint64_t gap_us = DEFAULT_GAP_US;
	uint64_t page_size;
	uint64_t access_phys;
	uint64_t map_phys;
	uint64_t map_delta;
	uint64_t map_len;
	volatile uint32_t *mmio;
	void *map;
	int fd;
	uint64_t total = 0;
	uint64_t min = UINT64_MAX;
	uint64_t max = 0;
	uint64_t first = 0;
	uint64_t warm_total;
	uint64_t timer_overhead_total = 0;
	uint64_t timer_overhead_ns;
	uint64_t avg_ns;
	uint64_t warm_avg_ns;
	uint32_t warm_iterations;
	uint32_t i;

	if (argc > 7) {
		usage(argv[0]);
		return EXIT_FAILURE;
	}

	if (argc > 1)
		bar_phys = parse_u64_arg(argv[1], "bar_phys");
	if (argc > 2)
		offset = parse_u64_arg(argv[2], "offset");
	if (argc > 3)
		value = (uint32_t)parse_u64_arg(argv[3], "value");
	if (argc > 4)
		iterations = (uint32_t)parse_u64_arg(argv[4], "iterations");
	if (argc > 5)
		map_size = parse_u64_arg(argv[5], "map_size");
	if (argc > 6)
		gap_us = parse_u64_arg(argv[6], "gap_us");

	if (!iterations)
		iterations = 1;
	if (offset & 0x3) {
		fprintf(stderr, "offset must be 4-byte aligned: 0x%llx\n",
			(unsigned long long)offset);
		return EXIT_FAILURE;
	}
	if (offset + sizeof(uint32_t) < offset) {
		fprintf(stderr, "offset overflow\n");
		return EXIT_FAILURE;
	}
	if (map_size < offset + sizeof(uint32_t))
		map_size = offset + sizeof(uint32_t);

	page_size = (uint64_t)sysconf(_SC_PAGESIZE);
	if (!page_size || (page_size & (page_size - 1))) {
		fprintf(stderr, "unsupported page size: %llu\n",
			(unsigned long long)page_size);
		return EXIT_FAILURE;
	}

	access_phys = bar_phys + offset;
	if (access_phys < bar_phys) {
		fprintf(stderr, "BAR physical address overflow\n");
		return EXIT_FAILURE;
	}

	map_phys = align_down_u64(bar_phys, page_size);
	map_delta = bar_phys - map_phys;
	map_len = align_up_u64(map_delta + map_size, page_size);

	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		fprintf(stderr, "open /dev/mem failed: %s\n", strerror(errno));
		return EXIT_FAILURE;
	}

	map = mmap(NULL, (size_t)map_len, PROT_READ | PROT_WRITE, MAP_SHARED,
		   fd, (off_t)map_phys);
	if (map == MAP_FAILED) {
		fprintf(stderr, "mmap /dev/mem phys=0x%llx len=0x%llx failed: %s\n",
			(unsigned long long)map_phys,
			(unsigned long long)map_len,
			strerror(errno));
		close(fd);
		return EXIT_FAILURE;
	}

	mmio = (volatile uint32_t *)((uint8_t *)map + map_delta + offset);

	printf("[scope-mmio-lat-user] bar_phys=0x%016" PRIx64
	       " offset=0x%llx access_phys=0x%016" PRIx64
	       " value=0x%08x iterations=%u gap_us=%" PRIu64 "\n",
	       bar_phys, (unsigned long long)offset, access_phys, value,
	       iterations, gap_us);

	for (i = 0; i < iterations; i++) {
		uint64_t start;
		uint64_t end;

		start = scope_lat_now();
		end = scope_lat_now();
		timer_overhead_total += end - start;
	}
	timer_overhead_ns = timer_overhead_total / iterations;

	scope_lat_full_io_barrier();
	for (i = 0; i < iterations; i++) {
		uint64_t start;
		uint64_t end;
		uint64_t delta;

		start = scope_lat_now();
		scope_lat_write32(mmio, value);
		scope_lat_full_io_barrier();
		end = scope_lat_now();

		delta = end - start;
		if (!i)
			first = delta;
		total += delta;
		if (delta < min)
			min = delta;
		if (delta > max)
			max = delta;

		if (i + 1 < iterations)
			scope_lat_sleep_us(gap_us);
	}

	avg_ns = total / iterations;
	warm_iterations = iterations > 1 ? iterations - 1 : iterations;
	warm_total = iterations > 1 ? total - first : total;
	warm_avg_ns = warm_total / warm_iterations;

	printf("[scope-mmio-lat-user] raw_avg_ns=%" PRIu64
	       " gap_us=%" PRIu64
	       " timer_overhead_ns=%" PRIu64
	       " adjusted_avg_ns=%" PRIu64
	       " first_ns=%" PRIu64
	       " warm_avg_ns=%" PRIu64
	       " adjusted_warm_avg_ns=%" PRIu64
	       " min_ns=%" PRIu64
	       " max_ns=%" PRIu64
	       " total_ns=%" PRIu64 "\n",
	       avg_ns, gap_us, timer_overhead_ns,
	       sub_floor_u64(avg_ns, timer_overhead_ns), first,
	       warm_avg_ns, sub_floor_u64(warm_avg_ns, timer_overhead_ns),
	       min, max, total);

	munmap(map, (size_t)map_len);
	close(fd);
	return EXIT_SUCCESS;
}
