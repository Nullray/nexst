`timescale 1ns / 1ps

`include "axi.vh"
`include "axi_custom.vh"

module axilite_trace_recorder #(
    parameter   ADDR_WIDTH      = 32,
    parameter   DATA_WIDTH      = 32,
    parameter   AXI_MODE        = 0
) (
    input clk,
    input rst, 
    `AXI4LITE_SLAVE_IF                  (s_axi, ADDR_WIDTH, DATA_WIDTH),
    `AXI4LITE_MASTER_IF                 (m_axi, ADDR_WIDTH, DATA_WIDTH),
    `AXI4LITE_MASTER_IF                 (m1_axi, ADDR_WIDTH, DATA_WIDTH) // 写 Log 和 读 CSR
);

    wire internal_rst = ~rst;

    // --- payload widths ---
    localparam PROT_WIDTH = 3;
    localparam RESP_WIDTH = 2;
    localparam A_PAYLOAD_FORMATTED_WIDTH = ADDR_WIDTH + PROT_WIDTH;
    localparam R_PAYLOAD_FORMATTED_WIDTH = DATA_WIDTH + RESP_WIDTH;
    localparam W_PAYLOAD_FORMATTED_WIDTH = DATA_WIDTH + DATA_WIDTH/8;
    localparam B_PAYLOAD_FORMATTED_WIDTH = RESP_WIDTH;

    localparam integer MAX_PAYLOAD_FORMATTED_WIDTH_1 =
        (W_PAYLOAD_FORMATTED_WIDTH > R_PAYLOAD_FORMATTED_WIDTH) ?
        W_PAYLOAD_FORMATTED_WIDTH : R_PAYLOAD_FORMATTED_WIDTH;
    localparam integer MAX_PAYLOAD_FORMATTED_WIDTH =
        (A_PAYLOAD_FORMATTED_WIDTH > B_PAYLOAD_FORMATTED_WIDTH) ?
        ((A_PAYLOAD_FORMATTED_WIDTH > MAX_PAYLOAD_FORMATTED_WIDTH_1) ? A_PAYLOAD_FORMATTED_WIDTH : MAX_PAYLOAD_FORMATTED_WIDTH_1)
            : ((B_PAYLOAD_FORMATTED_WIDTH > MAX_PAYLOAD_FORMATTED_WIDTH_1) ? B_PAYLOAD_FORMATTED_WIDTH : MAX_PAYLOAD_FORMATTED_WIDTH_1);

    localparam HEADER_ID_WIDTH = 8;
    localparam HEADER_TS_WIDTH = 56;
    localparam HEADER_WIDTH = HEADER_ID_WIDTH + HEADER_TS_WIDTH; 
    localparam TOTAL_ENTRY_WIDTH = HEADER_WIDTH + MAX_PAYLOAD_FORMATTED_WIDTH;

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

    localparam CH_AR = 8'd0;
    localparam CH_AW = 8'd1;
    localparam CH_R  = 8'd2;
    localparam CH_W  = 8'd3;
    localparam CH_B  = 8'd4;

    // ---------------------------------------------------------
    // 双 FIFO 架构 (已扩容至 32 深度)
    // ---------------------------------------------------------
    localparam FIFO_DEPTH = 32; 
    localparam FIFO_PTR_W = 5;  // 2^5 = 32

    reg [TOTAL_ENTRY_WIDTH-1:0] main_fifo [0:FIFO_DEPTH-1];
    reg [FIFO_PTR_W-1:0] main_wr_ptr, main_rd_ptr;
    reg [5:0] main_count; // 扩宽至 6 bit，以安全表示 0~32

    reg [TOTAL_ENTRY_WIDTH-1:0] w_fifo [0:FIFO_DEPTH-1];
    reg [FIFO_PTR_W-1:0] w_wr_ptr, w_rd_ptr;
    reg [5:0] w_count;    // 扩宽至 6 bit，以安全表示 0~32

    wire can_push_main = (main_count < FIFO_DEPTH-1) && !internal_rst;
    wire can_push_w    = (w_count < FIFO_DEPTH-1)    && !internal_rst;

    assign logging_wready  = can_push_w;
    assign logging_arready = can_push_main;
    assign logging_awready = can_push_main && !logging_arvalid;
    assign logging_rready  = can_push_main && !logging_arvalid && !logging_awvalid;
    assign logging_bready  = can_push_main && !logging_arvalid && !logging_awvalid && !logging_rvalid;

    reg [HEADER_TS_WIDTH-1:0] ts_cnt;
    always @(posedge clk) begin
        if (internal_rst) ts_cnt <= {HEADER_TS_WIDTH{1'b0}};
        else ts_cnt <= ts_cnt + 1;
    end

    reg main_pop, w_pop; 

    // 绝对安全的外部 wire 声明
    wire main_push = (logging_arvalid && logging_arready) || 
                     (logging_awvalid && logging_awready) || 
                     (logging_rvalid  && logging_rready)  || 
                     (logging_bvalid  && logging_bready);
                     
    wire w_push = (logging_wvalid && logging_wready);

    // FIFO 写入与出队
    always @(posedge clk) begin
        if (internal_rst) begin
            main_wr_ptr <= 0; main_rd_ptr <= 0; main_count <= 0;
            w_wr_ptr <= 0; w_rd_ptr <= 0; w_count <= 0;
        end else begin
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
            
            if (main_pop && main_count > 0) main_rd_ptr <= main_rd_ptr + 1;
            main_count <= main_count + main_push - (main_pop && main_count > 0);

            if (w_push) begin
                w_fifo[w_wr_ptr] <= {logging_w_payload, ts_cnt, CH_W};
                w_wr_ptr <= w_wr_ptr + 1;
            end
            
            if (w_pop && w_count > 0) w_rd_ptr <= w_rd_ptr + 1;
            w_count <= w_count + w_push - (w_pop && w_count > 0);
        end
    end

    // ---------------------------------------------------------
    // 软硬协同丢包环形缓冲区引擎 (Hardware-Software Ring Buffer)
    // ---------------------------------------------------------
    localparam integer DATA_BYTES = DATA_WIDTH/8;
    localparam [ADDR_WIDTH-1:0] CSR_HW_WR_PTR    = 32'h1100_0000;
    localparam [ADDR_WIDTH-1:0] CSR_SW_RD_PTR    = 32'h1100_0004;
    localparam [ADDR_WIDTH-1:0] TRACE_DATA_START = 32'h1100_0010; // 极致压缩，仅预留 16 字节
    localparam [ADDR_WIDTH-1:0] TRACE_END_ADDR   = 32'h1102_0000; // 128KB 边界

    reg m1_awvalid_r;
    reg [ADDR_WIDTH-1:0] m1_awaddr_r;
    reg m1_wvalid_r;
    reg [DATA_WIDTH-1:0] m1_wdata_r;
    reg m1_bready_r;

    reg m1_arvalid_r;
    reg [ADDR_WIDTH-1:0] m1_araddr_r;
    reg m1_rready_r;

    assign m1_axi_awvalid = m1_awvalid_r;
    assign m1_axi_awaddr  = m1_awaddr_r;
    assign m1_axi_wvalid  = m1_wvalid_r;
    assign m1_axi_wdata   = m1_wdata_r;
    assign m1_axi_bready  = m1_bready_r;
    assign m1_axi_wstrb   = {(DATA_WIDTH/8){1'b1}}; 
    assign m1_axi_awprot  = 3'b000; // [协议修复] 防死锁

    assign m1_axi_arvalid = m1_arvalid_r;
    assign m1_axi_araddr  = m1_araddr_r;
    assign m1_axi_rready  = m1_rready_r;
    assign m1_axi_arprot  = 3'b000; // [协议修复] 防死锁

    localparam [3:0]
        S_IDLE         = 4'd0,
        S_AW           = 4'd1,
        S_W            = 4'd2,
        S_WAIT_B       = 4'd3,
        S_WRITE_CSR_AW = 4'd4,
        S_WRITE_CSR_W  = 4'd5,
        S_WRITE_CSR_B  = 4'd6,
        S_READ_CSR_AR  = 4'd7,
        S_READ_CSR_R   = 4'd8;
        
    reg [3:0] state;
    reg [TOTAL_ENTRY_WIDTH-1:0] cur_payload;
    reg [7:0] cur_beats;
    reg [ADDR_WIDTH-1:0] next_trace_addr;

    reg [ADDR_WIDTH-1:0] hw_wr_ptr_reg;
    reg [ADDR_WIDTH-1:0] sw_rd_ptr_reg;
    reg overflow_flag;

    reg [7:0] poll_timer;
    reg poll_req;

    always @(posedge clk) begin
        if (internal_rst) begin
            poll_timer <= 0;
            poll_req <= 1'b0;
        end else begin
            poll_timer <= poll_timer + 1;
            if (poll_timer == 8'hFF) poll_req <= 1'b1; 
            // 严格握手清除请求
            if (state == S_READ_CSR_R && m1_axi_rvalid && m1_rready_r) poll_req <= 1'b0; 
        end
    end

    wire [ADDR_WIDTH-1:0] addr_plus_16 = hw_wr_ptr_reg + 16;
    wire [ADDR_WIDTH-1:0] next_trace_addr_calc = (addr_plus_16 >= TRACE_END_ADDR) ? TRACE_DATA_START : addr_plus_16;
    wire is_full = (next_trace_addr_calc == sw_rd_ptr_reg);

    always @(posedge clk) begin
        if (internal_rst) begin
            state <= S_IDLE;
            cur_payload <= {TOTAL_ENTRY_WIDTH{1'b0}};
            cur_beats <= 0;
            next_trace_addr <= TRACE_DATA_START; 
            
            hw_wr_ptr_reg <= TRACE_DATA_START;
            sw_rd_ptr_reg <= TRACE_DATA_START; // 防死锁：初始视为全空
            overflow_flag <= 1'b0;

            m1_awvalid_r <= 1'b0; m1_awaddr_r <= 0; m1_wvalid_r <= 1'b0; m1_wdata_r <= 0; m1_bready_r <= 1'b0;
            m1_arvalid_r <= 1'b0; m1_araddr_r <= 0; m1_rready_r <= 1'b0;
            
            main_pop <= 1'b0; w_pop <= 1'b0;
        end else begin
            main_pop <= 1'b0; w_pop <= 1'b0;
            
            case (state)
                S_IDLE: begin
                    // [修复 1] 绝对最高优先级：打破死锁，定时强制同步指针
                    if (poll_req) begin
                        m1_arvalid_r <= 1'b1;
                        m1_araddr_r  <= CSR_SW_RD_PTR;
                        state <= S_READ_CSR_AR;
                    end
                    else if (main_count > 0) begin
                        main_pop <= 1'b1; 
                        cur_payload <= main_fifo[main_rd_ptr];
                        cur_beats   <= 8'd4; 
                        
                        if (is_full) begin
                            // [修复 2] 真正的零延迟连续丢包优化
                            if (!overflow_flag) begin
                                overflow_flag <= 1'b1;
                                m1_awvalid_r  <= 1'b1;
                                m1_awaddr_r   <= CSR_HW_WR_PTR;
                                state <= S_WRITE_CSR_AW;
                            end else begin
                                // 已经报过警了，就在 IDLE 状态瞬间把数据丢入虚空
                                state <= S_IDLE; 
                            end
                        end else begin
                            overflow_flag <= 1'b0;
                            m1_awvalid_r  <= 1'b1;
                            m1_awaddr_r   <= hw_wr_ptr_reg;
                            next_trace_addr <= hw_wr_ptr_reg; 
                            state <= S_AW;
                        end
                    end 
                    else if (w_count > 0) begin
                        w_pop <= 1'b1;
                        cur_payload <= w_fifo[w_rd_ptr];
                        cur_beats   <= 8'd4; 

                        if (is_full) begin
                            if (!overflow_flag) begin
                                overflow_flag <= 1'b1;
                                m1_awvalid_r  <= 1'b1;
                                m1_awaddr_r   <= CSR_HW_WR_PTR;
                                state <= S_WRITE_CSR_AW;
                            end else begin
                                state <= S_IDLE;
                            end
                        end else begin
                            overflow_flag <= 1'b0;
                            m1_awvalid_r  <= 1'b1;
                            m1_awaddr_r   <= hw_wr_ptr_reg;
                            next_trace_addr <= hw_wr_ptr_reg;
                            state <= S_AW;
                        end
                    end
                end

                S_AW: begin
                    // [修复 3] 清理多重冗余赋值，使用最严谨的 AXI 握手
                    if (m1_axi_awready && m1_awvalid_r) begin
                        m1_awvalid_r <= 1'b0; 
                        m1_wvalid_r <= 1'b1;
                        m1_wdata_r <= cur_payload[DATA_WIDTH-1:0];
                        state <= S_W;
                    end
                end

                S_W: begin
                    if (m1_axi_wready && m1_wvalid_r) begin
                        m1_wvalid_r <= 1'b0;
                        m1_bready_r <= 1'b1; 
                        state <= S_WAIT_B;
                    end
                end

                S_WAIT_B: begin
                    if (m1_axi_bvalid && m1_bready_r) begin
                        m1_bready_r <= 1'b0;
                        cur_payload <= cur_payload >> DATA_WIDTH;
                        
                        if (cur_beats > 1) begin
                            cur_beats <= cur_beats - 1;
                            next_trace_addr <= next_trace_addr + 4;
                            m1_awvalid_r <= 1'b1;
                            m1_awaddr_r  <= next_trace_addr + 4; 
                            state <= S_AW;
                        end else begin
                            hw_wr_ptr_reg <= next_trace_addr_calc; 
                            m1_awvalid_r <= 1'b1;
                            m1_awaddr_r  <= CSR_HW_WR_PTR;
                            state <= S_WRITE_CSR_AW;
                        end
                    end
                end

                S_WRITE_CSR_AW: begin
                    if (m1_axi_awready && m1_awvalid_r) begin
                        m1_awvalid_r <= 1'b0;
                        m1_wvalid_r  <= 1'b1;
                        m1_wdata_r   <= {overflow_flag, hw_wr_ptr_reg[30:0]}; // 最高位通报软件
                        state <= S_WRITE_CSR_W;
                    end
                end

                S_WRITE_CSR_W: begin
                    if (m1_axi_wready && m1_wvalid_r) begin
                        m1_wvalid_r <= 1'b0;
                        m1_bready_r <= 1'b1;
                        state <= S_WRITE_CSR_B;
                    end
                end

                S_WRITE_CSR_B: begin
                    if (m1_axi_bvalid && m1_bready_r) begin
                        m1_bready_r <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                S_READ_CSR_AR: begin
                    if (m1_axi_arready && m1_arvalid_r) begin
                        m1_arvalid_r <= 1'b0;
                        m1_rready_r  <= 1'b1;
                        state <= S_READ_CSR_R;
                    end
                end

                S_READ_CSR_R: begin
                    if (m1_axi_rvalid && m1_rready_r) begin
                        m1_rready_r <= 1'b0;
                        sw_rd_ptr_reg <= m1_axi_rdata; 
                        
                        // 自愈：如果软件释放了空间，且之前报过满，硬件立刻自我解除溢出状态
                        if (next_trace_addr_calc != m1_axi_rdata) begin
                            overflow_flag <= 1'b0;
                        end
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ---------------------------
    // 子模块实例化
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
        .rst(internal_rst), 
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