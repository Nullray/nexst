#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdbool.h>
#include <signal.h> // [新增] 引入信号处理库

// -------------------------------------------------------------
// 物理地址与偏移量定义 (需严格与 Verilog 匹配)
// -------------------------------------------------------------
#define BRAM_X86_BASE_ADDR 0x97000000   // x86 视角的 BRAM 起始地址
#define BRAM_FPGA_BASE     0x11000000   // FPGA 视角的 AXI 起始地址
#define BRAM_SIZE          (128 * 1024) // 128 KB
#define TRACE_DATA_OFFSET  0x10         // 数据区偏移量 (跳过 16 字节的 CSR)
#define RECORD_SIZE        16           // 定长 16 字节

// CSR 寄存器偏移
#define CSR_HW_WR_PTR_OFFSET 0x00
#define CSR_SW_RD_PTR_OFFSET 0x04

// Channel IDs
#define CH_AR 0
#define CH_AW 1
#define CH_R  2
#define CH_W  3
#define CH_B  4

// -------------------------------------------------------------
// [新增] 全局运行标志位与信号处理函数
// -------------------------------------------------------------
volatile sig_atomic_t keep_running = 1;

void sig_handler(int signo) {
    if (signo == SIGINT || signo == SIGQUIT) {
        keep_running = 0; // 收到信号，拉低运行标志位
    }
}

// -------------------------------------------------------------
// 工具函数
// -------------------------------------------------------------
uint32_t fpga_to_offset(uint32_t fpga_addr) {
    return fpga_addr - BRAM_FPGA_BASE;
}

uint32_t offset_to_fpga(uint32_t offset) {
    return offset + BRAM_FPGA_BASE;
}

int main() {
    int mem_fd;
    void *mapped_base;

    // [新增] 注册信号处理函数，捕获 Ctrl+C 和 Ctrl+\ 
    signal(SIGINT, sig_handler);
    signal(SIGQUIT, sig_handler);

    // 1. 映射物理内存
    mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        perror("Failed to open /dev/mem");
        return -1;
    }

    mapped_base = mmap(NULL, BRAM_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, BRAM_X86_BASE_ADDR);
    if (mapped_base == MAP_FAILED) {
        perror("Failed to mmap");
        close(mem_fd);
        return -1;
    }

    volatile uint32_t *mem32 = (volatile uint32_t *)mapped_base;
    uint32_t sw_offset = TRACE_DATA_OFFSET;

    printf("=================================================================\n");
    printf(" AXI Trace Daemon (Hardware-Software Ring Buffer)\n");
    printf(" Press \033[93mCtrl+C\033[0m or \033[93mCtrl+\\\033[0m to gracefully exit.\n"); // 启动提示
    printf("=================================================================\n");

    // 2. 软件初始化：重置 FPGA 内部的软件指针
    mem32[CSR_SW_RD_PTR_OFFSET / 4] = offset_to_fpga(sw_offset);
    printf("[*] Daemon Started. Synchronized SW_RD_PTR to 0x%08X\n\n", offset_to_fpga(sw_offset));

    // 3. 守护进程主循环 (受 keep_running 标志位控制)
    while (keep_running) {
        uint32_t hw_reg_val = mem32[CSR_HW_WR_PTR_OFFSET / 4];
        
        bool is_overflow = (hw_reg_val >> 31) & 0x1;
        uint32_t hw_fpga_addr = hw_reg_val & 0x7FFFFFFF; 
        
        if (hw_fpga_addr < BRAM_FPGA_BASE) {
            usleep(10000); 
            continue;
        }

        uint32_t hw_offset = fpga_to_offset(hw_fpga_addr);

        if (is_overflow) {
            printf("\033[91m[WARNING] BRAM Ring Buffer Overflow! Packets were actively dropped by FPGA.\033[0m\n");
        }

        if (sw_offset != hw_offset) {
            // uint32_t parsed_count = 0; // 如果需要打印条数可以取消注释

            while (sw_offset != hw_offset) {
                uint32_t idx = sw_offset / 4;
                uint32_t w0 = mem32[idx];
                uint32_t w1 = mem32[idx + 1];
                uint32_t w2 = mem32[idx + 2];
                uint32_t w3 = mem32[idx + 3];

                uint8_t  ch_id = w0 & 0xFF;
                uint64_t ts    = ((uint64_t)w1 << 24) | (w0 >> 8);

                switch (ch_id) {
                    case CH_AR:
                        printf("[%012llu] AR | Addr: 0x%08X, Prot: %d\n", ts, w2, w3 & 0x7);
                        break;
                    case CH_AW:
                        printf("[%012llu] AW | Addr: 0x%08X, Prot: %d\n", ts, w2, w3 & 0x7);
                        break;
                    case CH_R:
                        printf("[%012llu] R  | Data: 0x%08X, Resp: %d\n", ts, w2, w3 & 0x3);
                        break;
                    case CH_W:
                        printf("[%012llu] W  | Data: 0x%08X, Strb: 0x%X\n", ts, w2, w3 & 0xF);
                        break;
                    case CH_B:
                        printf("[%012llu] B  | Resp: %d\n", ts, w2 & 0x3);
                        break;
                    default:
                        break;
                }

                sw_offset += RECORD_SIZE;
                // parsed_count++;

                if (sw_offset >= BRAM_SIZE) {
                    sw_offset = TRACE_DATA_OFFSET;
                }
            }

            mem32[CSR_SW_RD_PTR_OFFSET / 4] = offset_to_fpga(sw_offset);
        }

        usleep(1000); 
    }

    // 4. 清理资源与退出提示
    printf("\n=================================================================\n");
    printf("[*] Caught termination signal. Daemon gracefully stopped.\n");
    printf("[*] Unmapping memory and releasing resources...\n");
    printf("=================================================================\n");

    munmap(mapped_base, BRAM_SIZE);
    close(mem_fd);

    return 0;
}
