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
    `AXI4LITE_MASTER_IF                 (m1_axi, ADDR_WIDTH, DATA_WIDTH) 
);

    wire internal_rst = ~rst;

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

    localparam FIFO_DEPTH = 32; 
    localparam FIFO_PTR_W = 5;  

    reg [TOTAL_ENTRY_WIDTH-1:0] main_fifo [0:FIFO_DEPTH-1];
    reg [FIFO_PTR_W-1:0] main_wr_ptr, main_rd_ptr;
    reg [5:0] main_count; 

    reg [TOTAL_ENTRY_WIDTH-1:0] w_fifo [0:FIFO_DEPTH-1];
    reg [FIFO_PTR_W-1:0] w_wr_ptr, w_rd_ptr;
    reg [5:0] w_count; 

    // 绝对被动监控！永远对目标总线返回 1
    assign logging_wready  = 1'b1;
    assign logging_arready = 1'b1;
    assign logging_awready = 1'b1;
    assign logging_rready  = 1'b1;
    assign logging_bready  = 1'b1;

    wire can_push_main = (main_count < FIFO_DEPTH-1) && !internal_rst;
    wire can_push_w    = (w_count < FIFO_DEPTH-1)    && !internal_rst;

    reg [HEADER_TS_WIDTH-1:0] ts_cnt;
    always @(posedge clk) begin
        if (internal_rst) ts_cnt <= {HEADER_TS_WIDTH{1'b0}};
        else ts_cnt <= ts_cnt + 1;
    end

    reg main_pop, w_pop; 

    wire main_push_attempt = logging_arvalid || logging_awvalid || logging_rvalid || logging_bvalid;
    wire actual_main_push  = main_push_attempt && can_push_main;
    
    wire w_push_attempt    = logging_wvalid;
    wire actual_w_push     = w_push_attempt && can_push_w;

    wire main_collision = (logging_arvalid && (logging_awvalid || logging_rvalid || logging_bvalid)) || 
                          (logging_awvalid && (logging_rvalid || logging_bvalid)) || 
                          (logging_rvalid && logging_bvalid);
                          
    wire input_overflow = (logging_arvalid && !can_push_main) || (logging_awvalid && !can_push_main) || 
                          (logging_rvalid && !can_push_main) || (logging_bvalid && !can_push_main) ||
                          (logging_wvalid && !can_push_w) || main_collision;

    always @(posedge clk) begin
        if (internal_rst) begin
            main_wr_ptr <= 0; main_rd_ptr <= 0; main_count <= 0;
            w_wr_ptr <= 0; w_rd_ptr <= 0; w_count <= 0;
        end else begin
            if (logging_arvalid) begin
                if (can_push_main) begin
                    main_fifo[main_wr_ptr] <= {logging_ar_payload, ts_cnt, CH_AR};
                    main_wr_ptr <= main_wr_ptr + 1;
                end
            end else if (logging_awvalid) begin
                if (can_push_main) begin
                    main_fifo[main_wr_ptr] <= {logging_aw_payload, ts_cnt, CH_AW};
                    main_wr_ptr <= main_wr_ptr + 1;
                end
            end else if (logging_rvalid) begin
                if (can_push_main) begin
                    main_fifo[main_wr_ptr] <= {logging_r_payload, ts_cnt, CH_R};
                    main_wr_ptr <= main_wr_ptr + 1;
                end
            end else if (logging_bvalid) begin
                if (can_push_main) begin
                    main_fifo[main_wr_ptr] <= {logging_b_payload, ts_cnt, CH_B};
                    main_wr_ptr <= main_wr_ptr + 1;
                end
            end
            
            if (main_pop && main_count > 0) main_rd_ptr <= main_rd_ptr + 1;
            main_count <= main_count + actual_main_push - (main_pop && main_count > 0);

            if (logging_wvalid) begin
                if (can_push_w) begin
                    w_fifo[w_wr_ptr] <= {logging_w_payload, ts_cnt, CH_W};
                    w_wr_ptr <= w_wr_ptr + 1;
                end
            end
            
            if (w_pop && w_count > 0) w_rd_ptr <= w_rd_ptr + 1;
            w_count <= w_count + actual_w_push - (w_pop && w_count > 0);
        end
    end

    localparam integer DATA_BYTES = DATA_WIDTH/8;
    localparam [ADDR_WIDTH-1:0] CSR_HW_WR_PTR    = 32'h1100_0000;
    localparam [ADDR_WIDTH-1:0] CSR_SW_RD_PTR    = 32'h1100_0004;
    localparam [ADDR_WIDTH-1:0] TRACE_DATA_START = 32'h1100_0010; 
    localparam [ADDR_WIDTH-1:0] TRACE_END_ADDR   = 32'h1102_0000; 

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
    assign m1_axi_awprot  = 3'b000; 

    assign m1_axi_arvalid = m1_arvalid_r;
    assign m1_axi_araddr  = m1_araddr_r;
    assign m1_axi_rready  = m1_rready_r;
    assign m1_axi_arprot  = 3'b000; 

    // [修复 1] 状态机扩容，增加 CSR 并发写入支持
    localparam [3:0]
        S_IDLE           = 4'd0,
        S_AW_W_PREP      = 4'd1, 
        S_AW_W           = 4'd2, 
        S_WAIT_B         = 4'd3,
        S_WRITE_CSR_PREP = 4'd4, // 新增：CSR 并发准备
        S_WRITE_CSR_AW_W = 4'd5, // 新增：CSR 并发等待
        S_WRITE_CSR_B    = 4'd6,
        S_READ_CSR_AR    = 4'd7,
        S_READ_CSR_R     = 4'd8;
        
    reg [3:0] state;
    reg [TOTAL_ENTRY_WIDTH-1:0] cur_payload;
    reg [7:0] cur_beats;
    reg [ADDR_WIDTH-1:0] next_trace_addr;

    reg [ADDR_WIDTH-1:0] hw_wr_ptr_reg;
    reg [ADDR_WIDTH-1:0] sw_rd_ptr_reg;
    reg overflow_flag;

    reg [1:0] wrr_cnt; 
    reg [15:0] poll_timer;
    reg poll_req;

    always @(posedge clk) begin
        if (internal_rst) begin
            poll_timer <= 0;
            poll_req <= 1'b0;
        end else begin
            poll_timer <= poll_timer + 1;
            if (poll_timer == 16'hFFFF) poll_req <= 1'b1; 
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
            sw_rd_ptr_reg <= TRACE_DATA_START; 
            overflow_flag <= 1'b0;

            m1_awvalid_r <= 1'b0; m1_awaddr_r <= 0; m1_wvalid_r <= 1'b0; m1_wdata_r <= 0; m1_bready_r <= 1'b0;
            m1_arvalid_r <= 1'b0; m1_araddr_r <= 0; m1_rready_r <= 1'b0;
            
            main_pop <= 1'b0; w_pop <= 1'b0;
            wrr_cnt <= 2'd0;
        end else begin
            main_pop <= 1'b0; w_pop <= 1'b0;
            
            case (state)
                S_IDLE: begin
                    if (poll_req) begin
                        m1_arvalid_r <= 1'b1;
                        m1_araddr_r  <= CSR_SW_RD_PTR;
                        state <= S_READ_CSR_AR;
                    end
                    else if (main_count > 0 && (w_count == 0 || wrr_cnt < 2'd3)) begin
                        main_pop <= 1'b1; 
                        cur_payload <= main_fifo[main_rd_ptr];
                        cur_beats   <= 8'd4; 
                        
                        if (is_full) begin
                            if (!overflow_flag) begin
                                overflow_flag <= 1'b1;
                                state <= S_WRITE_CSR_PREP; // 修复跳转到新的并发状态
                            end else begin
                                state <= S_IDLE; 
                            end
                        end else begin
                            // [修复 2] 删除了毁掉历史警报的 overflow_flag <= 1'b0;
                            next_trace_addr <= hw_wr_ptr_reg; 
                            state <= S_AW_W_PREP;
                        end

                        if (w_count > 0) wrr_cnt <= wrr_cnt + 1;
                        else wrr_cnt <= 2'd0; 
                    end 
                    else if (w_count > 0) begin
                        w_pop <= 1'b1;
                        cur_payload <= w_fifo[w_rd_ptr];
                        cur_beats   <= 8'd4; 

                        if (is_full) begin
                            if (!overflow_flag) begin
                                overflow_flag <= 1'b1;
                                state <= S_WRITE_CSR_PREP; // 修复跳转到新的并发状态
                            end else begin
                                state <= S_IDLE;
                            end
                        end else begin
                            // [修复 2] 同样删除
                            next_trace_addr <= hw_wr_ptr_reg;
                            state <= S_AW_W_PREP;
                        end

                        wrr_cnt <= 2'd0; 
                    end
                end

                S_AW_W_PREP: begin
                    m1_awvalid_r <= 1'b1;
                    m1_awaddr_r  <= next_trace_addr;
                    m1_wvalid_r  <= 1'b1;
                    m1_wdata_r   <= cur_payload[DATA_WIDTH-1:0];
                    state <= S_AW_W;
                end

                S_AW_W: begin
                    if (m1_axi_awready) m1_awvalid_r <= 1'b0; 
                    if (m1_axi_wready)  m1_wvalid_r  <= 1'b0;
                    
                    if ((m1_axi_awready || !m1_awvalid_r) && (m1_axi_wready || !m1_wvalid_r)) begin
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
                            state <= S_AW_W_PREP; 
                        end else begin
                            hw_wr_ptr_reg <= next_trace_addr_calc; 
                            state <= S_WRITE_CSR_PREP; // 正常写完，跳转至汇报状态
                        end
                    end
                end

                // ----------------------------------------------------
                // [修复 1 落地] CSR 并发写入模块 (彻底消灭死锁)
                // ----------------------------------------------------
                S_WRITE_CSR_PREP: begin
                    m1_awvalid_r <= 1'b1;
                    m1_awaddr_r  <= CSR_HW_WR_PTR;
                    m1_wvalid_r  <= 1'b1;
                    m1_wdata_r   <= {overflow_flag, hw_wr_ptr_reg[30:0]}; 
                    state <= S_WRITE_CSR_AW_W;
                end

                S_WRITE_CSR_AW_W: begin
                    if (m1_axi_awready) m1_awvalid_r <= 1'b0; 
                    if (m1_axi_wready)  m1_wvalid_r  <= 1'b0;
                    
                    if ((m1_axi_awready || !m1_awvalid_r) && (m1_axi_wready || !m1_wvalid_r)) begin
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
                // ----------------------------------------------------

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
                        
                        // 警报解除的唯一合法途径
                        if (next_trace_addr_calc != m1_axi_rdata && !input_overflow) begin
                            overflow_flag <= 1'b0;
                        end
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase

            if (input_overflow) begin
                overflow_flag <= 1'b1;
            end
        end
    end

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