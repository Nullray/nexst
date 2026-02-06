`timescale 1ns / 1ps

`include "axi.vh"
`include "axi_custom.vh"

module axilite_trace_recorder #(
    parameter   ADDR_WIDTH      = 32,
    parameter   DATA_WIDTH      = 32,
    parameter   AXI_MODE        = 0
) (
    input clk,
    // 【重要】Block Design连接的是axi_ctl_aresetn (低电平复位)
    // 内部会取反生成高电平复位信号 internal_rst
    input rst, 
    `AXI4LITE_SLAVE_IF                  (s_axi, ADDR_WIDTH, DATA_WIDTH),
    `AXI4LITE_MASTER_IF                 (m_axi, ADDR_WIDTH, DATA_WIDTH),
    `AXI4LITE_MASTER_IF                 (m1_axi, ADDR_WIDTH, DATA_WIDTH) // 写 Log 的 Master 接口
);

    // [FIX 1] 内部生成高有效复位信号
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

    // beats per channel including header
    localparam integer A_BEATS_HDR = (A_PAYLOAD_FORMATTED_WIDTH + HEADER_WIDTH + DATA_WIDTH - 1) / DATA_WIDTH;
    localparam integer R_BEATS_HDR = (R_PAYLOAD_FORMATTED_WIDTH + HEADER_WIDTH + DATA_WIDTH - 1) / DATA_WIDTH;
    localparam integer W_BEATS_HDR = (W_PAYLOAD_FORMATTED_WIDTH + HEADER_WIDTH + DATA_WIDTH - 1) / DATA_WIDTH;
    localparam integer B_BEATS_HDR = (B_PAYLOAD_FORMATTED_WIDTH + HEADER_WIDTH + DATA_WIDTH - 1) / DATA_WIDTH;

    // wires from channel logger
    wire logging_arvalid;
    wire logging_arready;
    wire [A_PAYLOAD_FORMATTED_WIDTH-1:0] logging_ar_payload;
    wire logging_awvalid;
    wire logging_awready;
    wire [A_PAYLOAD_FORMATTED_WIDTH-1:0] logging_aw_payload;
    wire logging_rvalid;
    wire logging_rready;
    wire [R_PAYLOAD_FORMATTED_WIDTH-1:0] logging_r_payload;
    wire logging_wvalid;
    wire logging_wready;
    wire [W_PAYLOAD_FORMATTED_WIDTH-1:0] logging_w_payload;
    wire logging_bvalid;
    wire logging_bready;
    wire [B_PAYLOAD_FORMATTED_WIDTH-1:0] logging_b_payload;

    // ---------------------------
    // FIFO for events
    // ---------------------------
    localparam FIFO_DEPTH = 8;
    localparam FIFO_PTR_W = 3; 
    integer i;
    
    localparam CH_AR = 8'd0;
    localparam CH_AW = 8'd1;
    localparam CH_R = 8'd2;
    localparam CH_W = 8'd3;
    localparam CH_B = 8'd4;

    reg [FIFO_PTR_W-1:0] fifo_wr_ptr;
    reg [FIFO_PTR_W-1:0] fifo_rd_ptr;
    reg [4:0] fifo_count; 
    reg [7:0] fifo_beats [0:FIFO_DEPTH-1];
    reg [TOTAL_ENTRY_WIDTH-1:0] fifo_payload [0:FIFO_DEPTH-1];
    reg [7:0] fifo_chanid [0:FIFO_DEPTH-1];

    assign logging_arready = (fifo_count < FIFO_DEPTH-1);
    assign logging_awready = (fifo_count < FIFO_DEPTH-1);
    assign logging_wready  = (fifo_count < FIFO_DEPTH-1);
    assign logging_rready  = (fifo_count < FIFO_DEPTH-1);
    assign logging_bready  = (fifo_count < FIFO_DEPTH-1);

    // timestamp counter
    reg [HEADER_TS_WIDTH-1:0] ts_cnt;
    always @(posedge clk) begin
        if (internal_rst) ts_cnt <= {HEADER_TS_WIDTH{1'b0}};
        else ts_cnt <= ts_cnt + 1;
    end

    reg pop_req; 
    reg pop_ack; 
    integer count_delta;

    // FIFO Management
    always @(posedge clk) begin
        if (internal_rst) begin
            fifo_wr_ptr <= {FIFO_PTR_W{1'b0}};
            fifo_rd_ptr <= {FIFO_PTR_W{1'b0}};
            fifo_count <= 0;
            pop_ack <= 1'b0;
            for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
                fifo_beats[i] <= 0;
                fifo_payload[i] <= {TOTAL_ENTRY_WIDTH{1'b0}};
                fifo_chanid[i] <= 0;
            end
        end else begin
            pop_ack <= 1'b0;
            count_delta = 0;

            // Pop Logic
            if (pop_req && (fifo_count > 0)) begin
                fifo_rd_ptr <= fifo_rd_ptr + 1;
                count_delta = count_delta - 1;
                pop_ack <= 1'b1;
            end

            // Push Logic
            if (fifo_count < FIFO_DEPTH) begin
                if (logging_arvalid && logging_arready) begin
                    fifo_payload[fifo_wr_ptr] <= { {{(MAX_PAYLOAD_FORMATTED_WIDTH - A_PAYLOAD_FORMATTED_WIDTH){1'b0}}, logging_ar_payload}, {ts_cnt, CH_AR} };
                    fifo_beats[fifo_wr_ptr] <= A_BEATS_HDR;
                    fifo_chanid[fifo_wr_ptr] <= CH_AR;
                    fifo_wr_ptr <= fifo_wr_ptr + 1;
                    count_delta = count_delta + 1;
                end else if (logging_awvalid && logging_awready) begin
                    fifo_payload[fifo_wr_ptr] <= { {{(MAX_PAYLOAD_FORMATTED_WIDTH - A_PAYLOAD_FORMATTED_WIDTH){1'b0}}, logging_aw_payload}, {ts_cnt, CH_AW} };
                    fifo_beats[fifo_wr_ptr] <= A_BEATS_HDR;
                    fifo_chanid[fifo_wr_ptr] <= CH_AW;
                    fifo_wr_ptr <= fifo_wr_ptr + 1;
                    count_delta = count_delta + 1;
                end else if (logging_wvalid && logging_wready) begin
                    fifo_payload[fifo_wr_ptr] <= { {{(MAX_PAYLOAD_FORMATTED_WIDTH - W_PAYLOAD_FORMATTED_WIDTH){1'b0}}, logging_w_payload}, {ts_cnt, CH_W} };
                    fifo_beats[fifo_wr_ptr] <= W_BEATS_HDR;
                    fifo_chanid[fifo_wr_ptr] <= CH_W;
                    fifo_wr_ptr <= fifo_wr_ptr + 1;
                    count_delta = count_delta + 1;
                end else if (logging_rvalid && logging_rready) begin
                    fifo_payload[fifo_wr_ptr] <= { {{(MAX_PAYLOAD_FORMATTED_WIDTH - R_PAYLOAD_FORMATTED_WIDTH){1'b0}}, logging_r_payload}, {ts_cnt, CH_R} };
                    fifo_beats[fifo_wr_ptr] <= R_BEATS_HDR;
                    fifo_chanid[fifo_wr_ptr] <= CH_R;
                    fifo_wr_ptr <= fifo_wr_ptr + 1;
                    count_delta = count_delta + 1;
                end else if (logging_bvalid && logging_bready) begin
                    fifo_payload[fifo_wr_ptr] <= { {{(MAX_PAYLOAD_FORMATTED_WIDTH - B_PAYLOAD_FORMATTED_WIDTH){1'b0}}, logging_b_payload}, {ts_cnt, CH_B} };
                    fifo_beats[fifo_wr_ptr] <= B_BEATS_HDR;
                    fifo_chanid[fifo_wr_ptr] <= CH_B;
                    fifo_wr_ptr <= fifo_wr_ptr + 1;
                    count_delta = count_delta + 1;
                end
            end
            fifo_count <= fifo_count + count_delta;
        end
    end

    // FIFO Head Views
    wire [TOTAL_ENTRY_WIDTH-1:0] fifo_head_payload = fifo_payload[fifo_rd_ptr];
    wire [7:0] fifo_head_beats = fifo_beats[fifo_rd_ptr];
    wire [7:0] fifo_head_chanid = fifo_chanid[fifo_rd_ptr];

    // ---------------------------
    // Log-to-AXI Write Engine
    // ---------------------------
    localparam integer DATA_BYTES = DATA_WIDTH/8;
    localparam [ADDR_WIDTH-1:0] TRACE_BASE_ADDR = {ADDR_WIDTH{1'b0}} + 32'h1100_0000; 

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
    
    // [FIX 4] 添加缺失的 WSTRB 信号，始终全为 1
    assign m1_axi_wstrb   = {(DATA_WIDTH/8){1'b1}}; 

    // 状态机
    localparam [2:0]
        S_IDLE     = 3'd0,
        S_POP_WAIT = 3'd1,
        S_AW       = 3'd2,
        S_W        = 3'd3,
        S_WAIT_B   = 3'd4;
        
    reg [2:0] state;
    reg [TOTAL_ENTRY_WIDTH-1:0] cur_payload;
    reg [7:0] cur_beats;
    reg [ADDR_WIDTH-1:0] next_trace_addr;

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
            pop_req <= 1'b0;
        end else begin
            // 默认拉低 Pulse 信号
            pop_req <= 1'b0;
            
            case (state)
                S_IDLE: begin
                    if (fifo_count > 0) begin
                        pop_req <= 1'b1;
                        state <= S_POP_WAIT;
                    end
                end

                S_POP_WAIT: begin
                    if (pop_ack) begin
                        cur_payload <= fifo_head_payload;
                        cur_beats   <= fifo_head_beats;
                        
                        // 准备第一个地址
                        m1_awvalid_r <= 1'b1;
                        m1_awaddr_r  <= next_trace_addr;
                        state <= S_AW;
                    end
                end

                S_AW: begin
                    m1_awvalid_r <= 1'b1; 
                    if (m1_axi_awready) begin
                        m1_awvalid_r <= 1'b0; 
                        
                        // 准备数据
                        m1_wvalid_r <= 1'b1;
                        m1_wdata_r <= cur_payload[DATA_WIDTH-1:0];
                        state <= S_W;
                    end
                end

                S_W: begin
                    m1_wvalid_r <= 1'b1; 
                    if (m1_axi_wready) begin
                        m1_wvalid_r <= 1'b0;
                        m1_bready_r <= 1'b1; // Wait for B
                        state <= S_WAIT_B;
                    end
                end

                S_WAIT_B: begin
                    m1_bready_r <= 1'b1;
                    if (m1_axi_bvalid) begin
                        m1_bready_r <= 1'b0;
                        
                        // 数据移位，地址递增
                        cur_payload <= cur_payload >> DATA_WIDTH;
                        next_trace_addr <= next_trace_addr + 4; 
                        
                        if (cur_beats > 1) begin
                            cur_beats <= cur_beats - 1;
                            // 循环回 AW 发送下一个字
                            m1_awvalid_r <= 1'b1;
                            m1_awaddr_r <= next_trace_addr + 4; 
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

    // 子模块实例化 (保持不变)
    axilite_channel_logger #(
        .A_PAYLOAD_FORMANTTED_WIDTH(A_PAYLOAD_FORMATTED_WIDTH),
        .R_PAYLOAD_FORMANTTED_WIDTH(R_PAYLOAD_FORMATTED_WIDTH),
        .W_PAYLOAD_FORMANTTED_WIDTH(W_PAYLOAD_FORMATTED_WIDTH),
        .B_PAYLOAD_FORMANTTED_WIDTH(B_PAYLOAD_FORMATTED_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) axilite_channel_logger (
        .clk(clk),
        .rst(internal_rst), // 传入修正后的内部高电平复位
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