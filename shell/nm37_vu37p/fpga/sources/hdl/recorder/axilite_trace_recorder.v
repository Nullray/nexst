`timescale 1ns / 1ps

`include "axi.vh"
`include "axi_custom.vh"

module axilite_trace_recorder #(
    parameter   ADDR_WIDTH      = 32,
    parameter   DATA_WIDTH      = 32,
    parameter   AXI_MODE        = 0
) (
    input clk,
    input rst, // Block Design 连接的是低电平有效的 axi_ctl_aresetn
    `AXI4LITE_SLAVE_IF                  (s_axi, ADDR_WIDTH, DATA_WIDTH),
    `AXI4LITE_MASTER_IF                 (m_axi, ADDR_WIDTH, DATA_WIDTH),
    `AXI4LITE_MASTER_IF                 (m1_axi, ADDR_WIDTH, DATA_WIDTH) // 写 Log 的 Master 接口
);

    // 内部生成高有效复位信号
    wire internal_rst = ~rst;

    // --- payload widths ---
    localparam PROT_WIDTH = 3;
    localparam RESP_WIDTH = 2;
    localparam A_PAYLOAD_FORMATTED_WIDTH = ADDR_WIDTH + PROT_WIDTH;
    localparam R_PAYLOAD_FORMATTED_WIDTH = DATA_WIDTH + RESP_WIDTH;
    localparam W_PAYLOAD_FORMATTED_WIDTH = DATA_WIDTH + DATA_WIDTH/8;
    localparam B_PAYLOAD_FORMATTED_WIDTH = RESP_WIDTH;

    // compute max payload width among channels
    localparam integer MAX_PAYLOAD_FORMATTED_WIDTH_1 =
        (W_PAYLOAD_FORMATTED_WIDTH > R_PAYLOAD_FORMATTED_WIDTH) ?
        W_PAYLOAD_FORMATTED_WIDTH : R_PAYLOAD_FORMATTED_WIDTH;
    localparam integer MAX_PAYLOAD_FORMATTED_WIDTH =
        (A_PAYLOAD_FORMATTED_WIDTH > B_PAYLOAD_FORMATTED_WIDTH) ?
        ((A_PAYLOAD_FORMATTED_WIDTH > MAX_PAYLOAD_FORMATTED_WIDTH_1) ? A_PAYLOAD_FORMATTED_WIDTH : MAX_PAYLOAD_FORMATTED_WIDTH_1)
            : ((B_PAYLOAD_FORMATTED_WIDTH > MAX_PAYLOAD_FORMATTED_WIDTH_1) ? B_PAYLOAD_FORMATTED_WIDTH : MAX_PAYLOAD_FORMATTED_WIDTH_1);

    // --- header: 8-bit channel ID + 56-bit timestamp (total 64 bits) ---
    localparam HEADER_ID_WIDTH = 8;
    localparam HEADER_TS_WIDTH = 56;
    localparam HEADER_WIDTH = HEADER_ID_WIDTH + HEADER_TS_WIDTH; 

    // total width per FIFO entry = header + max payload
    localparam TOTAL_ENTRY_WIDTH = HEADER_WIDTH + MAX_PAYLOAD_FORMATTED_WIDTH;

    // wires from channel logger
    wire logging_arvalid, logging_arready;
    wire [A_PAYLOAD_FORMATTED_WIDTH-1:0] logging_ar_payload;
    wire logging_awvalid, logging_awready;
    wire [A_PAYLOAD_FORMATTED_WIDTH-1:0] logging_aw_payload;
    wire logging_rvalid, logging_rready;
    wire [R_PAYLOAD_FORMATTED_WIDTH-1:0] logging_r_payload;
    wire logging_wvalid, logging_wready;
    wire [W_PAYLOAD_FORMATTED_WIDTH-1:0] logging_w_payload;
    wire logging_bvalid, logging_bready;
    wire [B_PAYLOAD_FORMATTED_WIDTH-1:0] logging_b_payload;

    // Channel IDs
    localparam CH_AR = 8'd0;
    localparam CH_AW = 8'd1;
    localparam CH_R  = 8'd2;
    localparam CH_W  = 8'd3;
    localparam CH_B  = 8'd4;

    // ---------------------------------------------------------
    // 双 FIFO 架构：分离 W 通道以支持并发握手
    // ---------------------------------------------------------
    localparam FIFO_DEPTH = 8;
    localparam FIFO_PTR_W = 3; 

    // 1. MAIN FIFO (复用处理 AR, AW, R, B 通道)
    reg [TOTAL_ENTRY_WIDTH-1:0] main_fifo [0:FIFO_DEPTH-1];
    reg [FIFO_PTR_W-1:0] main_wr_ptr, main_rd_ptr;
    reg [4:0] main_count;

    // 2. W 专属 FIFO (专门处理 W 通道)
    reg [TOTAL_ENTRY_WIDTH-1:0] w_fifo [0:FIFO_DEPTH-1];
    reg [FIFO_PTR_W-1:0] w_wr_ptr, w_rd_ptr;
    reg [4:0] w_count;

    // 独立判定能否入队
    wire can_push_main = (main_count < FIFO_DEPTH-1) && !internal_rst;
    wire can_push_w    = (w_count < FIFO_DEPTH-1)    && !internal_rst;

    // Ready 信号优先级反压分配 (W独立，MAIN内部分级)
    assign logging_wready  = can_push_w;
    assign logging_arready = can_push_main;
    assign logging_awready = can_push_main && !logging_arvalid;
    assign logging_rready  = can_push_main && !logging_arvalid && !logging_awvalid;
    assign logging_bready  = can_push_main && !logging_arvalid && !logging_awvalid && !logging_rvalid;

    // 时间戳计数器
    reg [HEADER_TS_WIDTH-1:0] ts_cnt;
    always @(posedge clk) begin
        if (internal_rst) ts_cnt <= {HEADER_TS_WIDTH{1'b0}};
        else ts_cnt <= ts_cnt + 1;
    end

    // 由仲裁状态机控制的出队脉冲
    reg main_pop, w_pop; 

    // ---------------------------------------------------------
    // [绝对关键的修复] 
    // 将线网型变量 (wire) 的声明强制放在 always 块外部！
    // ---------------------------------------------------------
    wire main_push = (logging_arvalid && logging_arready) || 
                     (logging_awvalid && logging_awready) || 
                     (logging_rvalid  && logging_rready)  || 
                     (logging_bvalid  && logging_bready);
                     
    wire w_push = (logging_wvalid && logging_wready);

    // 双 FIFO 并发写入与出队逻辑
    always @(posedge clk) begin
        if (internal_rst) begin
            main_wr_ptr <= 0; main_rd_ptr <= 0; main_count <= 0;
            w_wr_ptr <= 0; w_rd_ptr <= 0; w_count <= 0;
        end else begin
            // ---- [动作 A]：MAIN FIFO 写入 (内部互斥) ----
            
            // 利用 Verilog 隐式高位补 0 机制进行拼接，安全可靠
            if (logging_arvalid && logging_arready) begin
                main_fifo[main_wr_ptr] <= {logging_ar_payload, ts_cnt, CH_AR};
                main_wr_ptr <= main_wr_ptr + 1;
            end else if (logging_awvalid && logging_awready) begin
                main_fifo[main_wr_ptr] <= {logging_aw_payload, ts_cnt, CH_AW};
                main_wr_ptr <= main_wr_ptr + 1;
            end else if (logging_rvalid && logging_rready) begin
                main_fifo[main_wr_ptr] <= {logging_r_payload, ts_cnt, CH_R};
                main_wr_ptr <= main_wr_ptr + 1;
            end else if (logging_bvalid && logging_bready) begin
                main_fifo[main_wr_ptr] <= {logging_b_payload, ts_cnt, CH_B};
                main_wr_ptr <= main_wr_ptr + 1;
            end
            
            // 无延迟 FWFT 出队：收到 pop 脉冲直接挪动读指针
            if (main_pop && main_count > 0) main_rd_ptr <= main_rd_ptr + 1;
            main_count <= main_count + main_push - (main_pop && main_count > 0);

            // ---- [动作 B]：W FIFO 写入 (独立并行) ----
            
            if (w_push) begin
                w_fifo[w_wr_ptr] <= {logging_w_payload, ts_cnt, CH_W};
                w_wr_ptr <= w_wr_ptr + 1;
            end
            
            if (w_pop && w_count > 0) w_rd_ptr <= w_rd_ptr + 1;
            w_count <= w_count + w_push - (w_pop && w_count > 0);
        end
    end

    // ---------------------------------------------------------
    // Log-to-AXI Write Engine (仲裁与环形写入)
    // ---------------------------------------------------------
    localparam integer DATA_BYTES = DATA_WIDTH/8;
    localparam [ADDR_WIDTH-1:0] TRACE_BASE_ADDR  = {ADDR_WIDTH{1'b0}} + 32'h1100_0000; 
    localparam [ADDR_WIDTH-1:0] TRACE_SIZE_BYTES = 32'h20000; // BRAM 大小 128KB
    localparam [ADDR_WIDTH-1:0] TRACE_END_ADDR   = TRACE_BASE_ADDR + TRACE_SIZE_BYTES;

    reg m1_awvalid_r;
    reg [ADDR_WIDTH-1:0] m1_awaddr_r;
    reg m1_wvalid_r;
    reg [DATA_WIDTH-1:0] m1_wdata_r;
    reg m1_bready_r;

    assign m1_axi_awvalid = m1_awvalid_r;
    assign m1_axi_awaddr  = m1_awaddr_r;
    assign m1_axi_wvalid  = m1_wvalid_r;
    assign m1_axi_wdata   = m1_wdata_r;
    assign m1_axi_bready  = m1_bready_r;
    
    // WSTRB 修复，统一全 F 避免数据无效
    assign m1_axi_wstrb   = {(DATA_WIDTH/8){1'b1}}; 

    localparam [1:0]
        S_IDLE     = 2'd0,
        S_AW       = 2'd1,
        S_W        = 2'd2,
        S_WAIT_B   = 2'd3;
        
    reg [1:0] state;
    reg [TOTAL_ENTRY_WIDTH-1:0] cur_payload;
    reg [7:0] cur_beats;
    reg [ADDR_WIDTH-1:0] next_trace_addr;

    // BRAM 环形地址计算辅助逻辑
    wire [ADDR_WIDTH-1:0] addr_plus_4 = next_trace_addr + 4;
    wire [ADDR_WIDTH-1:0] updated_addr = (addr_plus_4 >= TRACE_END_ADDR) ? TRACE_BASE_ADDR : addr_plus_4;

    always @(posedge clk) begin
        if (internal_rst) begin
            state <= S_IDLE;
            cur_payload <= {TOTAL_ENTRY_WIDTH{1'b0}};
            cur_beats <= 0;
            next_trace_addr <= TRACE_BASE_ADDR;
            m1_awvalid_r <= 1'b0;
            m1_awaddr_r <= {ADDR_WIDTH{1'b0}};
            m1_wvalid_r <= 1'b0;
            m1_wdata_r <= {DATA_WIDTH{1'b0}};
            m1_bready_r <= 1'b0;
            main_pop <= 1'b0;
            w_pop <= 1'b0;
        end else begin
            // 默认拉低，形成单周期出队脉冲
            main_pop <= 1'b0;
            w_pop <= 1'b0;
            
            case (state)
                S_IDLE: begin
                    // 2选1仲裁，无延迟 FWFT 抓取数据
                    if (main_count > 0) begin
                        main_pop <= 1'b1; 
                        cur_payload <= main_fifo[main_rd_ptr];
                        cur_beats   <= 8'd4; // 强制统一 16 字节定长
                        
                        m1_awvalid_r <= 1'b1;
                        m1_awaddr_r  <= next_trace_addr;
                        state <= S_AW;
                    end 
                    else if (w_count > 0) begin
                        w_pop <= 1'b1;
                        cur_payload <= w_fifo[w_rd_ptr];
                        cur_beats   <= 8'd4; // 强制统一 16 字节定长
                        
                        m1_awvalid_r <= 1'b1;
                        m1_awaddr_r  <= next_trace_addr;
                        state <= S_AW;
                    end
                end

                S_AW: begin
                    m1_awvalid_r <= 1'b1; 
                    if (m1_axi_awready) begin
                        m1_awvalid_r <= 1'b0; 
                        m1_wvalid_r <= 1'b1;
                        m1_wdata_r <= cur_payload[DATA_WIDTH-1:0];
                        state <= S_W;
                    end
                end

                S_W: begin
                    m1_wvalid_r <= 1'b1; 
                    if (m1_axi_wready) begin
                        m1_wvalid_r <= 1'b0;
                        m1_bready_r <= 1'b1; 
                        state <= S_WAIT_B;
                    end
                end

                S_WAIT_B: begin
                    m1_bready_r <= 1'b1;
                    if (m1_axi_bvalid) begin
                        m1_bready_r <= 1'b0;
                        cur_payload <= cur_payload >> DATA_WIDTH;
                        
                        // 环形缓冲回绕，防止卡死或越界触发 DECERR
                        next_trace_addr <= updated_addr;
                        
                        if (cur_beats > 1) begin
                            cur_beats <= cur_beats - 1;
                            m1_awvalid_r <= 1'b1;
                            m1_awaddr_r  <= updated_addr; // 使用下一跳地址
                            state <= S_AW;
                        end else begin
                            state <= S_IDLE;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ---------------------------
    // 子模块实例化 (保持不变)
    // ---------------------------
    axilite_channel_logger #(
        .A_PAYLOAD_FORMANTTED_WIDTH(A_PAYLOAD_FORMATTED_WIDTH),
        .R_PAYLOAD_FORMANTTED_WIDTH(R_PAYLOAD_FORMATTED_WIDTH),
        .W_PAYLOAD_FORMANTTED_WIDTH(W_PAYLOAD_FORMATTED_WIDTH),
        .B_PAYLOAD_FORMANTTED_WIDTH(B_PAYLOAD_FORMATTED_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) axilite_channel_logger (
        .clk(clk),
        .rst(internal_rst), // 传入修正后的内部高有效复位
        .logging_arvalid(logging_arvalid),
        .logging_arready(logging_arready),
        .logging_ar_payload(logging_ar_payload),
        .logging_awvalid(logging_awvalid),
        .logging_awready(logging_awready),
        .logging_aw_payload(logging_aw_payload),
        .logging_rvalid(logging_rvalid),
        .logging_rready(logging_rready),
        .logging_r_payload(logging_r_payload),
        .logging_wvalid(logging_wvalid),
        .logging_wready(logging_wready),
        .logging_w_payload(logging_w_payload),
        .logging_bvalid(logging_bvalid),
        .logging_bready(logging_bready),
        .logging_b_payload(logging_b_payload),
        `AXI4LITE_CONNECT           (s_axi, s_axi),
        `AXI4LITE_CONNECT           (m_axi, m_axi)
    );
endmodule