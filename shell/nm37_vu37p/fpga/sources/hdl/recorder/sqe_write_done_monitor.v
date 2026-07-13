`timescale 1ns / 1ps

module sqe_write_done_monitor #(
    parameter ADDR_WIDTH = 36,
    parameter CFG_ADDR_WIDTH = 32,
    parameter AXI_DATA_WIDTH = 256,
    parameter AXIS_DATA_WIDTH = 512,
    parameter FIFO_DEPTH = 64,
    parameter FIFO_INDEX_WIDTH = 6
) (
    input  wire                         clk,
    input  wire                         rstn,

    input  wire [CFG_ADDR_WIDTH-1:0]    s_cfg_axi_araddr,
    input  wire [2:0]                   s_cfg_axi_arprot,
    input  wire                         s_cfg_axi_arvalid,
    output wire                         s_cfg_axi_arready,
    output reg  [31:0]                  s_cfg_axi_rdata,
    output reg  [1:0]                   s_cfg_axi_rresp,
    output reg                          s_cfg_axi_rvalid,
    input  wire                         s_cfg_axi_rready,
    input  wire [CFG_ADDR_WIDTH-1:0]    s_cfg_axi_awaddr,
    input  wire [2:0]                   s_cfg_axi_awprot,
    input  wire                         s_cfg_axi_awvalid,
    output wire                         s_cfg_axi_awready,
    input  wire [31:0]                  s_cfg_axi_wdata,
    input  wire [3:0]                   s_cfg_axi_wstrb,
    input  wire                         s_cfg_axi_wvalid,
    output wire                         s_cfg_axi_wready,
    output reg  [1:0]                   s_cfg_axi_bresp,
    output reg                          s_cfg_axi_bvalid,
    input  wire                         s_cfg_axi_bready,

    input  wire [ADDR_WIDTH-1:0]        s_mon_axi_araddr,
    input  wire [1:0]                   s_mon_axi_arburst,
    input  wire [3:0]                   s_mon_axi_arcache,
    input  wire [7:0]                   s_mon_axi_arlen,
    input  wire [0:0]                   s_mon_axi_arlock,
    input  wire [2:0]                   s_mon_axi_arprot,
    input  wire [3:0]                   s_mon_axi_arqos,
    output wire                         s_mon_axi_arready,
    input  wire [2:0]                   s_mon_axi_arsize,
    input  wire                         s_mon_axi_arvalid,
    input  wire [ADDR_WIDTH-1:0]        s_mon_axi_awaddr,
    input  wire [1:0]                   s_mon_axi_awburst,
    input  wire [3:0]                   s_mon_axi_awcache,
    input  wire [7:0]                   s_mon_axi_awlen,
    input  wire [0:0]                   s_mon_axi_awlock,
    input  wire [2:0]                   s_mon_axi_awprot,
    input  wire [3:0]                   s_mon_axi_awqos,
    output wire                         s_mon_axi_awready,
    input  wire [2:0]                   s_mon_axi_awsize,
    input  wire                         s_mon_axi_awvalid,
    input  wire                         s_mon_axi_bready,
    output wire [1:0]                   s_mon_axi_bresp,
    output wire                         s_mon_axi_bvalid,
    output wire [AXI_DATA_WIDTH-1:0]    s_mon_axi_rdata,
    output wire                         s_mon_axi_rlast,
    input  wire                         s_mon_axi_rready,
    output wire [1:0]                   s_mon_axi_rresp,
    output wire                         s_mon_axi_rvalid,
    input  wire [AXI_DATA_WIDTH-1:0]    s_mon_axi_wdata,
    input  wire                         s_mon_axi_wlast,
    output wire                         s_mon_axi_wready,
    input  wire [AXI_DATA_WIDTH/8-1:0]  s_mon_axi_wstrb,
    input  wire                         s_mon_axi_wvalid,

    output wire [ADDR_WIDTH-1:0]        m_mon_axi_araddr,
    output wire [1:0]                   m_mon_axi_arburst,
    output wire [3:0]                   m_mon_axi_arcache,
    output wire [7:0]                   m_mon_axi_arlen,
    output wire [0:0]                   m_mon_axi_arlock,
    output wire [2:0]                   m_mon_axi_arprot,
    output wire [3:0]                   m_mon_axi_arqos,
    input  wire                         m_mon_axi_arready,
    output wire [2:0]                   m_mon_axi_arsize,
    output wire                         m_mon_axi_arvalid,
    output wire [ADDR_WIDTH-1:0]        m_mon_axi_awaddr,
    output wire [1:0]                   m_mon_axi_awburst,
    output wire [3:0]                   m_mon_axi_awcache,
    output wire [7:0]                   m_mon_axi_awlen,
    output wire [0:0]                   m_mon_axi_awlock,
    output wire [2:0]                   m_mon_axi_awprot,
    output wire [3:0]                   m_mon_axi_awqos,
    input  wire                         m_mon_axi_awready,
    output wire [2:0]                   m_mon_axi_awsize,
    output wire                         m_mon_axi_awvalid,
    output wire                         m_mon_axi_bready,
    input  wire [1:0]                   m_mon_axi_bresp,
    input  wire                         m_mon_axi_bvalid,
    input  wire [AXI_DATA_WIDTH-1:0]    m_mon_axi_rdata,
    input  wire                         m_mon_axi_rlast,
    output wire                         m_mon_axi_rready,
    input  wire [1:0]                   m_mon_axi_rresp,
    input  wire                         m_mon_axi_rvalid,
    output wire [AXI_DATA_WIDTH-1:0]    m_mon_axi_wdata,
    output wire                         m_mon_axi_wlast,
    input  wire                         m_mon_axi_wready,
    output wire [AXI_DATA_WIDTH/8-1:0]  m_mon_axi_wstrb,
    output wire                         m_mon_axi_wvalid,

    output reg                          m_axis_c2h_tvalid,
    input  wire                         m_axis_c2h_tready,
    output reg  [AXIS_DATA_WIDTH-1:0]   m_axis_c2h_tdata,
    output reg  [AXIS_DATA_WIDTH/8-1:0] m_axis_c2h_tkeep,
    output reg                          m_axis_c2h_tlast
);

    localparam [31:0] AXIS_NOTIFY_MAGIC = 32'h5844_504b;
    localparam [31:0] AXIS_NOTIFY_TYPE_SQE_WRITE_DONE = 32'd5;
    localparam [31:0] AXIS_NOTIFY_LEN = 32'd32;
    localparam [1:0]  AXI_RESP_OKAY = 2'b00;
    localparam MAX_BACKENDS = 13;
    localparam [11:0] MON_REG_STATUS = 12'h3F0;

    localparam [11:0] MON_REG_ADMIN_SQ_BASE_LO = 12'h000;
    localparam [11:0] MON_REG_ADMIN_SQ_BASE_HI = 12'h004;
    localparam [11:0] MON_REG_ADMIN_SQ_BYTES   = 12'h008;
    localparam [11:0] MON_REG_ADMIN_SQ_CTRL    = 12'h00C;

    localparam [AXIS_DATA_WIDTH/8-1:0] AXIS_PKT_KEEP =
        { {(AXIS_DATA_WIDTH/8-32){1'b0}}, 32'hFFFF_FFFF };

    localparam [FIFO_INDEX_WIDTH:0] FIFO_DEPTH_VALUE = FIFO_DEPTH;
    localparam [15:0] OUTSTANDING_MAX = 16'hFFFF;

    function [31:0] apply_wstrb32;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0]  wstrb;
        integer i;
        begin
            apply_wstrb32 = old_value;
            for (i = 0; i < 4; i = i + 1) begin
                if (wstrb[i]) begin
                    apply_wstrb32[i*8 +: 8] = new_value[i*8 +: 8];
                end
            end
        end
    endfunction

    reg [31:0] admin_sq_base_lo [0:MAX_BACKENDS-1];
    reg [31:0] admin_sq_base_hi [0:MAX_BACKENDS-1];
    reg [31:0] admin_sq_bytes_reg [0:MAX_BACKENDS-1];
    reg [31:0] admin_sq_ctrl [0:MAX_BACKENDS-1];
    reg [7:0] config_generation [0:MAX_BACKENDS-1];
    integer cfg_i;

    reg [FIFO_INDEX_WIDTH:0] meta_count;
    reg [FIFO_INDEX_WIDTH-1:0] meta_wr_ptr;
    reg [FIFO_INDEX_WIDTH-1:0] meta_rd_ptr;
    reg meta_hit_fifo [0:FIFO_DEPTH-1];
    reg [7:0] meta_generation_fifo [0:FIFO_DEPTH-1];
    reg [3:0] meta_backend_fifo [0:FIFO_DEPTH-1];
    reg [15:0] meta_first_slot_fifo [0:FIFO_DEPTH-1];
    reg [15:0] meta_last_slot_fifo  [0:FIFO_DEPTH-1];
    reg [ADDR_WIDTH-1:0] meta_first_addr_fifo [0:FIFO_DEPTH-1];
    reg [31:0] meta_bytes_fifo [0:FIFO_DEPTH-1];

    // Completed-write job FIFO. One job can cover multiple SQE slots.
    reg [FIFO_INDEX_WIDTH:0] job_count;
    reg [FIFO_INDEX_WIDTH-1:0] job_wr_ptr;
    reg [FIFO_INDEX_WIDTH-1:0] job_rd_ptr;
    reg [15:0] job_first_slot_fifo [0:FIFO_DEPTH-1];
    reg [15:0] job_last_slot_fifo  [0:FIFO_DEPTH-1];
    reg [ADDR_WIDTH-1:0] job_first_addr_fifo [0:FIFO_DEPTH-1];
    reg [31:0] job_bytes_fifo [0:FIFO_DEPTH-1];
    reg [1:0] job_bresp_fifo [0:FIFO_DEPTH-1];
    reg job_overflow_fifo [0:FIFO_DEPTH-1];
    reg [3:0] job_backend_fifo [0:FIFO_DEPTH-1];

    reg        emit_active;
    reg [15:0] emit_slot;
    reg [15:0] emit_last_slot;
    reg [ADDR_WIDTH-1:0] emit_addr;
    reg [31:0] emit_bytes;
    reg [1:0]  emit_bresp;
    reg        emit_overflow;
    reg [3:0]  emit_backend;

    reg [31:0] sqe_done_seq;
    reg        overflow_sticky;
    reg        meta_desync;
    reg [15:0] outstanding_count;

    wire cfg_wr_fire = s_cfg_axi_awvalid && s_cfg_axi_awready;
    wire cfg_rd_fire = s_cfg_axi_arvalid && s_cfg_axi_arready;
    wire [3:0] cfg_index = s_cfg_axi_awaddr[8:5];
    wire [3:0] cfg_read_index = s_cfg_axi_araddr[8:5];
    wire cfg_index_valid = (cfg_index < MAX_BACKENDS);
    wire cfg_read_index_valid = (cfg_read_index < MAX_BACKENDS);
    wire [3:0] cfg_safe_index = cfg_index_valid ? cfg_index : 4'd0;
    wire [4:0] cfg_field = s_cfg_axi_awaddr[4:0];
    wire [4:0] cfg_read_field = s_cfg_axi_araddr[4:0];

    wire aw_fire = s_mon_axi_awvalid && s_mon_axi_awready;
    wire b_fire  = s_mon_axi_bvalid  && s_mon_axi_bready;

    wire meta_full  = (meta_count == FIFO_DEPTH_VALUE);
    wire meta_empty = (meta_count == {(FIFO_INDEX_WIDTH+1){1'b0}});
    wire job_full   = (job_count == FIFO_DEPTH_VALUE);
    wire job_empty  = (job_count == {(FIFO_INDEX_WIDTH+1){1'b0}});

    wire [31:0] cfg_next_base_lo =
        apply_wstrb32(admin_sq_base_lo[cfg_safe_index], s_cfg_axi_wdata, s_cfg_axi_wstrb);
    wire [31:0] cfg_next_base_hi =
        apply_wstrb32(admin_sq_base_hi[cfg_safe_index], s_cfg_axi_wdata, s_cfg_axi_wstrb);
    wire [31:0] cfg_next_bytes =
        apply_wstrb32(admin_sq_bytes_reg[cfg_safe_index], s_cfg_axi_wdata, s_cfg_axi_wstrb);
    wire [31:0] cfg_next_ctrl =
        apply_wstrb32(admin_sq_ctrl[cfg_safe_index], s_cfg_axi_wdata, s_cfg_axi_wstrb);

    wire cfg_wr_base_lo = cfg_wr_fire && cfg_index_valid && (cfg_field == MON_REG_ADMIN_SQ_BASE_LO[4:0]);
    wire cfg_wr_base_hi = cfg_wr_fire && cfg_index_valid && (cfg_field == MON_REG_ADMIN_SQ_BASE_HI[4:0]);
    wire cfg_wr_bytes   = cfg_wr_fire && cfg_index_valid && (cfg_field == MON_REG_ADMIN_SQ_BYTES[4:0]);
    wire cfg_wr_ctrl    = cfg_wr_fire && cfg_index_valid && (cfg_field == MON_REG_ADMIN_SQ_CTRL[4:0]);

    wire cfg_window_changed =
        (cfg_wr_base_lo && (cfg_next_base_lo != admin_sq_base_lo[cfg_safe_index])) ||
        (cfg_wr_base_hi && (cfg_next_base_hi != admin_sq_base_hi[cfg_safe_index])) ||
        (cfg_wr_bytes   && (cfg_next_bytes   != admin_sq_bytes_reg[cfg_safe_index])) ||
        (cfg_wr_ctrl    && (cfg_next_ctrl    != admin_sq_ctrl[cfg_safe_index]));

    wire [31:0] aw_bytes = ({24'd0, s_mon_axi_awlen} + 32'd1) << s_mon_axi_awsize;

    reg aw_hit_sq;
    reg aw_multi_hit;
    reg [3:0] aw_backend;
    reg [15:0] aw_first_slot;
    reg [15:0] aw_last_slot;
    reg [ADDR_WIDTH-1:0] overlap_start_addr;
    reg [31:0] overlap_bytes;
    reg [ADDR_WIDTH:0] match_aw_start, match_aw_end, match_sq_start, match_sq_end;
    reg [ADDR_WIDTH:0] match_overlap_start, match_overlap_end;
    integer match_i;
    always @* begin
        aw_hit_sq = 1'b0;
        aw_multi_hit = 1'b0;
        aw_backend = 4'd0;
        aw_first_slot = 16'd0;
        aw_last_slot = 16'd0;
        overlap_start_addr = {ADDR_WIDTH{1'b0}};
        overlap_bytes = 32'd0;
        match_aw_start = {1'b0, s_mon_axi_awaddr};
        match_aw_end = match_aw_start + {1'b0, aw_bytes};
        match_sq_start = {(ADDR_WIDTH+1){1'b0}};
        match_sq_end = {(ADDR_WIDTH+1){1'b0}};
        match_overlap_start = {(ADDR_WIDTH+1){1'b0}};
        match_overlap_end = {(ADDR_WIDTH+1){1'b0}};
        for (match_i = 0; match_i < MAX_BACKENDS; match_i = match_i + 1) begin
            match_sq_start = {1'b0, admin_sq_base_hi[match_i][3:0], admin_sq_base_lo[match_i]};
            match_sq_end = match_sq_start + {1'b0, admin_sq_bytes_reg[match_i]};
            if (admin_sq_ctrl[match_i][0] && (admin_sq_bytes_reg[match_i] != 0) &&
                (match_aw_start < match_sq_end) && (match_aw_end > match_sq_start)) begin
                if (aw_hit_sq) begin
                    aw_multi_hit = 1'b1;
                end else begin
                    aw_hit_sq = 1'b1;
                    aw_backend = match_i[3:0];
                    match_overlap_start = (match_aw_start < match_sq_start) ? match_sq_start : match_aw_start;
                    match_overlap_end = (match_aw_end > match_sq_end) ? match_sq_end : match_aw_end;
                    overlap_start_addr = match_overlap_start[ADDR_WIDTH-1:0];
                    overlap_bytes = match_overlap_end - match_overlap_start;
                    aw_first_slot = ((match_overlap_start - match_sq_start) >> 6);
                    aw_last_slot = (((match_overlap_end - 1'b1) - match_sq_start) >> 6);
                end
            end
        end
    end

    wire meta_pop = b_fire && !meta_empty && !meta_desync;
    wire meta_push_space = !meta_full || meta_pop;
    wire meta_push = aw_fire && !meta_desync && meta_push_space;
    wire meta_overflow = aw_fire && !meta_desync && !meta_push_space;

    wire meta_pop_hit = meta_hit_fifo[meta_rd_ptr];
    wire [7:0] meta_pop_generation = meta_generation_fifo[meta_rd_ptr];
    wire [3:0] meta_pop_backend = meta_backend_fifo[meta_rd_ptr];
    wire [15:0] meta_pop_first_slot = meta_first_slot_fifo[meta_rd_ptr];
    wire [15:0] meta_pop_last_slot  = meta_last_slot_fifo[meta_rd_ptr];
    wire [ADDR_WIDTH-1:0] meta_pop_first_addr = meta_first_addr_fifo[meta_rd_ptr];
    wire [31:0] meta_pop_bytes = meta_bytes_fifo[meta_rd_ptr];

    wire meta_pop_current_generation =
        (meta_pop_generation == config_generation[meta_pop_backend]);

    wire axis_can_advance = !m_axis_c2h_tvalid || m_axis_c2h_tready;
    wire job_load = axis_can_advance && !emit_active && !job_empty;
    wire job_push_space = !job_full || job_load;

    wire job_candidate = !meta_desync &&
                         meta_pop &&
                         meta_pop_hit &&
                         meta_pop_current_generation;

    wire job_push = job_candidate && job_push_space;
    wire job_drop = job_candidate && !job_push_space;

    wire pkt_from_emit = emit_active;
    wire pkt_from_job  = job_load && !emit_active;

    wire [15:0] pkt_slot =
        pkt_from_emit ? emit_slot : job_first_slot_fifo[job_rd_ptr];

    wire [15:0] pkt_last_slot =
        pkt_from_emit ? emit_last_slot : job_last_slot_fifo[job_rd_ptr];

    wire [ADDR_WIDTH-1:0] pkt_addr =
        pkt_from_emit ? emit_addr : job_first_addr_fifo[job_rd_ptr];

    wire [31:0] pkt_remaining =
        pkt_from_emit ? emit_bytes : job_bytes_fifo[job_rd_ptr];

    wire [31:0] pkt_slot_capacity =
        32'd64 - {26'd0, pkt_addr[5:0]};

    wire [31:0] pkt_bytes =
        (pkt_remaining < pkt_slot_capacity) ? pkt_remaining : pkt_slot_capacity;

    wire [1:0] pkt_bresp =
        pkt_from_emit ? emit_bresp : job_bresp_fifo[job_rd_ptr];

    wire pkt_overflow =
        pkt_from_emit ? emit_overflow : job_overflow_fifo[job_rd_ptr];
    wire [3:0] pkt_backend =
        pkt_from_emit ? emit_backend : job_backend_fifo[job_rd_ptr];

    wire pkt_emit = axis_can_advance && (emit_active || job_load);

    wire [31:0] pkt_seq = sqe_done_seq + 32'd1;
    wire [31:0] pkt_flags =
        {pkt_overflow | overflow_sticky, 1'd0, pkt_backend, pkt_bresp, 8'd0, pkt_slot};

    wire [ADDR_WIDTH-1:0] pkt_next_addr =
        pkt_addr + {{(ADDR_WIDTH-32){1'b0}}, pkt_bytes};

    wire [31:0] pkt_next_remaining = pkt_remaining - pkt_bytes;

    wire outstanding_inc_only = aw_fire && !b_fire;
    wire outstanding_dec_only = b_fire && !aw_fire;
    wire outstanding_overflow = outstanding_inc_only && (outstanding_count == OUTSTANDING_MAX);
    wire outstanding_underflow = outstanding_dec_only && (outstanding_count == 16'd0);
    wire [15:0] outstanding_count_next =
        outstanding_overflow ? OUTSTANDING_MAX :
        outstanding_underflow ? 16'd0 :
        outstanding_inc_only ? (outstanding_count + 16'd1) :
        outstanding_dec_only ? (outstanding_count - 16'd1) :
        outstanding_count;

    // ------------------------------------------------------------------------
    // AXI-Lite config slave
    // ------------------------------------------------------------------------
    assign s_cfg_axi_arready = !s_cfg_axi_rvalid;
    assign s_cfg_axi_awready = !s_cfg_axi_bvalid && s_cfg_axi_awvalid && s_cfg_axi_wvalid;
    assign s_cfg_axi_wready  = s_cfg_axi_awready;

    // ------------------------------------------------------------------------
    // Transparent AXI pass-through
    // ------------------------------------------------------------------------
    assign m_mon_axi_araddr  = s_mon_axi_araddr;
    assign m_mon_axi_arburst = s_mon_axi_arburst;
    assign m_mon_axi_arcache = s_mon_axi_arcache;
    assign m_mon_axi_arlen   = s_mon_axi_arlen;
    assign m_mon_axi_arlock  = s_mon_axi_arlock;
    assign m_mon_axi_arprot  = s_mon_axi_arprot;
    assign m_mon_axi_arqos   = s_mon_axi_arqos;
    assign m_mon_axi_arsize  = s_mon_axi_arsize;
    assign m_mon_axi_arvalid = s_mon_axi_arvalid;
    assign s_mon_axi_arready = m_mon_axi_arready;

    assign m_mon_axi_awaddr  = s_mon_axi_awaddr;
    assign m_mon_axi_awburst = s_mon_axi_awburst;
    assign m_mon_axi_awcache = s_mon_axi_awcache;
    assign m_mon_axi_awlen   = s_mon_axi_awlen;
    assign m_mon_axi_awlock  = s_mon_axi_awlock;
    assign m_mon_axi_awprot  = s_mon_axi_awprot;
    assign m_mon_axi_awqos   = s_mon_axi_awqos;
    assign m_mon_axi_awsize  = s_mon_axi_awsize;
    assign m_mon_axi_awvalid = s_mon_axi_awvalid;
    assign s_mon_axi_awready = m_mon_axi_awready;

    assign m_mon_axi_wdata   = s_mon_axi_wdata;
    assign m_mon_axi_wlast   = s_mon_axi_wlast;
    assign m_mon_axi_wstrb   = s_mon_axi_wstrb;
    assign m_mon_axi_wvalid  = s_mon_axi_wvalid;
    assign s_mon_axi_wready  = m_mon_axi_wready;

    assign s_mon_axi_bresp   = m_mon_axi_bresp;
    assign s_mon_axi_bvalid  = m_mon_axi_bvalid;
    assign m_mon_axi_bready  = s_mon_axi_bready;

    assign s_mon_axi_rdata   = m_mon_axi_rdata;
    assign s_mon_axi_rlast   = m_mon_axi_rlast;
    assign s_mon_axi_rresp   = m_mon_axi_rresp;
    assign s_mon_axi_rvalid  = m_mon_axi_rvalid;
    assign m_mon_axi_rready  = s_mon_axi_rready;

    always @(posedge clk) begin
        if (!rstn) begin
            s_cfg_axi_rvalid <= 1'b0;
            s_cfg_axi_rdata  <= 32'd0;
            s_cfg_axi_rresp  <= AXI_RESP_OKAY;
            s_cfg_axi_bvalid <= 1'b0;
            s_cfg_axi_bresp  <= AXI_RESP_OKAY;

            for (cfg_i = 0; cfg_i < MAX_BACKENDS; cfg_i = cfg_i + 1) begin
                admin_sq_base_lo[cfg_i] <= 32'd0;
                admin_sq_base_hi[cfg_i] <= 32'd0;
                admin_sq_bytes_reg[cfg_i] <= 32'd0;
                admin_sq_ctrl[cfg_i] <= 32'd0;
                config_generation[cfg_i] <= 8'd0;
            end

            meta_count  <= {(FIFO_INDEX_WIDTH+1){1'b0}};
            meta_wr_ptr <= {FIFO_INDEX_WIDTH{1'b0}};
            meta_rd_ptr <= {FIFO_INDEX_WIDTH{1'b0}};

            job_count  <= {(FIFO_INDEX_WIDTH+1){1'b0}};
            job_wr_ptr <= {FIFO_INDEX_WIDTH{1'b0}};
            job_rd_ptr <= {FIFO_INDEX_WIDTH{1'b0}};

            emit_active   <= 1'b0;
            emit_slot     <= 16'd0;
            emit_last_slot <= 16'd0;
            emit_addr     <= {ADDR_WIDTH{1'b0}};
            emit_bytes    <= 32'd0;
            emit_bresp    <= AXI_RESP_OKAY;
            emit_overflow <= 1'b0;
            emit_backend  <= 4'd0;

            sqe_done_seq      <= 32'd0;
            overflow_sticky   <= 1'b0;
            meta_desync       <= 1'b0;
            outstanding_count <= 16'd0;

            m_axis_c2h_tvalid <= 1'b0;
            m_axis_c2h_tdata  <= {AXIS_DATA_WIDTH{1'b0}};
            m_axis_c2h_tkeep  <= {AXIS_DATA_WIDTH/8{1'b0}};
            m_axis_c2h_tlast  <= 1'b0;
        end else begin
            // ----------------------------------------------------------------
            // AXI-Lite read path
            // ----------------------------------------------------------------
            if (cfg_rd_fire) begin
                s_cfg_axi_rvalid <= 1'b1;
                s_cfg_axi_rresp  <= AXI_RESP_OKAY;
                if (s_cfg_axi_araddr[11:0] == MON_REG_STATUS)
                    s_cfg_axi_rdata <= {23'd0, meta_desync, meta_count[5:0],
                                         job_full, overflow_sticky};
                else if (cfg_read_index_valid) begin
                    case (cfg_read_field)
                    MON_REG_ADMIN_SQ_BASE_LO[4:0]: s_cfg_axi_rdata <= admin_sq_base_lo[cfg_read_index];
                    MON_REG_ADMIN_SQ_BASE_HI[4:0]: s_cfg_axi_rdata <= admin_sq_base_hi[cfg_read_index];
                    MON_REG_ADMIN_SQ_BYTES[4:0]: s_cfg_axi_rdata <= admin_sq_bytes_reg[cfg_read_index];
                    MON_REG_ADMIN_SQ_CTRL[4:0]: s_cfg_axi_rdata <= admin_sq_ctrl[cfg_read_index];
                    default: s_cfg_axi_rdata <= 32'd0;
                    endcase
                end else s_cfg_axi_rdata <= 32'd0;
            end else if (s_cfg_axi_rready && s_cfg_axi_rvalid) begin
                s_cfg_axi_rvalid <= 1'b0;
            end

            // ----------------------------------------------------------------
            // AXI-Lite write path
            // ----------------------------------------------------------------
            if (cfg_wr_fire) begin
                s_cfg_axi_bvalid <= 1'b1;
                s_cfg_axi_bresp  <= AXI_RESP_OKAY;

                if (s_cfg_axi_awaddr[11:0] == MON_REG_STATUS) begin
                    if (s_cfg_axi_wstrb[0] && s_cfg_axi_wdata[0])
                        overflow_sticky <= 1'b0;
                end else if (cfg_index_valid) begin
                    case (cfg_field)
                    MON_REG_ADMIN_SQ_BASE_LO[4:0]: admin_sq_base_lo[cfg_index] <= cfg_next_base_lo;
                    MON_REG_ADMIN_SQ_BASE_HI[4:0]: admin_sq_base_hi[cfg_index] <= cfg_next_base_hi;
                    MON_REG_ADMIN_SQ_BYTES[4:0]: admin_sq_bytes_reg[cfg_index] <= cfg_next_bytes;
                    MON_REG_ADMIN_SQ_CTRL[4:0]: admin_sq_ctrl[cfg_index] <= cfg_next_ctrl;
                    default: begin end
                    endcase
                end

                if (cfg_window_changed)
                    config_generation[cfg_index] <= config_generation[cfg_index] + 1'b1;
            end else if (s_cfg_axi_bready && s_cfg_axi_bvalid) begin
                s_cfg_axi_bvalid <= 1'b0;
            end

            // ----------------------------------------------------------------
            // Outstanding write tracker. Used only to recover safely after
            // metadata FIFO overflow. This does not affect AXI ready/valid.
            // ----------------------------------------------------------------
            outstanding_count <= outstanding_count_next;
            if (outstanding_overflow || outstanding_underflow) begin
                overflow_sticky <= 1'b1;
            end
            if (aw_fire && aw_multi_hit)
                overflow_sticky <= 1'b1;

            // ----------------------------------------------------------------
            // Metadata FIFO and overflow/desync handling.
            // Once an AW metadata entry is lost, stop matching B responses with
            // stale metadata. Clear the FIFO immediately and resume only after
            // all outstanding writes on this AXI path have drained.
            // ----------------------------------------------------------------
            if (meta_overflow) begin
                overflow_sticky <= 1'b1;
                meta_desync <= 1'b1;
                meta_count  <= {(FIFO_INDEX_WIDTH+1){1'b0}};
                meta_wr_ptr <= {FIFO_INDEX_WIDTH{1'b0}};
                meta_rd_ptr <= {FIFO_INDEX_WIDTH{1'b0}};
            end else if (meta_desync) begin
                meta_count  <= {(FIFO_INDEX_WIDTH+1){1'b0}};
                meta_wr_ptr <= {FIFO_INDEX_WIDTH{1'b0}};
                meta_rd_ptr <= {FIFO_INDEX_WIDTH{1'b0}};
                if (outstanding_count_next == 16'd0) begin
                    meta_desync <= 1'b0;
                end
            end else begin
                // Record every AW while synchronized. Non-SQ writes are stored
                // as miss entries so B responses stay aligned with AW order.
                if (meta_push) begin
                    meta_hit_fifo[meta_wr_ptr]        <= aw_hit_sq;
                    meta_generation_fifo[meta_wr_ptr] <= config_generation[aw_backend];
                    meta_backend_fifo[meta_wr_ptr]    <= aw_backend;
                    meta_first_slot_fifo[meta_wr_ptr] <= aw_first_slot;
                    meta_last_slot_fifo[meta_wr_ptr]  <= aw_last_slot;
                    meta_first_addr_fifo[meta_wr_ptr] <= overlap_start_addr;
                    meta_bytes_fifo[meta_wr_ptr]      <= overlap_bytes;
                    meta_wr_ptr <= meta_wr_ptr + {{(FIFO_INDEX_WIDTH-1){1'b0}}, 1'b1};
                end

                if (meta_pop) begin
                    meta_rd_ptr <= meta_rd_ptr + {{(FIFO_INDEX_WIDTH-1){1'b0}}, 1'b1};
                end

                case ({meta_push, meta_pop})
                    2'b10: meta_count <= meta_count + {{FIFO_INDEX_WIDTH{1'b0}}, 1'b1};
                    2'b01: meta_count <= meta_count - {{FIFO_INDEX_WIDTH{1'b0}}, 1'b1};
                    default: begin
                    end
                endcase
            end

            if (job_drop) begin
                overflow_sticky <= 1'b1;
            end

            // ----------------------------------------------------------------
            // Completed-write job FIFO.
            // A job can cover multiple slots; the AXIS emitter expands it into
            // one SQE_WRITE_DONE packet per slot.
            // ----------------------------------------------------------------
            begin
                if (job_push) begin
                    job_first_slot_fifo[job_wr_ptr] <= meta_pop_first_slot;
                    job_last_slot_fifo[job_wr_ptr]  <= meta_pop_last_slot;
                    job_first_addr_fifo[job_wr_ptr] <= meta_pop_first_addr;
                    job_bytes_fifo[job_wr_ptr]      <= meta_pop_bytes;
                    job_bresp_fifo[job_wr_ptr]      <= s_mon_axi_bresp;
                    job_overflow_fifo[job_wr_ptr]   <= overflow_sticky;
                    job_backend_fifo[job_wr_ptr]    <= meta_pop_backend;
                    job_wr_ptr <= job_wr_ptr + {{(FIFO_INDEX_WIDTH-1){1'b0}}, 1'b1};
                end

                if (job_load) begin
                    job_rd_ptr <= job_rd_ptr + {{(FIFO_INDEX_WIDTH-1){1'b0}}, 1'b1};
                end

                case ({job_push, job_load})
                    2'b10: job_count <= job_count + {{FIFO_INDEX_WIDTH{1'b0}}, 1'b1};
                    2'b01: job_count <= job_count - {{FIFO_INDEX_WIDTH{1'b0}}, 1'b1};
                    default: begin
                    end
                endcase

                // ------------------------------------------------------------
                // AXIS packet emitter
                // ------------------------------------------------------------
                if (pkt_emit) begin
                    m_axis_c2h_tvalid <= 1'b1;
                    m_axis_c2h_tkeep  <= AXIS_PKT_KEEP;
                    m_axis_c2h_tlast  <= 1'b1;
                    m_axis_c2h_tdata  <= {AXIS_DATA_WIDTH{1'b0}};

                    m_axis_c2h_tdata[31:0]    <= AXIS_NOTIFY_MAGIC;
                    m_axis_c2h_tdata[63:32]   <= AXIS_NOTIFY_TYPE_SQE_WRITE_DONE;
                    m_axis_c2h_tdata[95:64]   <= pkt_flags;
                    m_axis_c2h_tdata[127:96]  <= AXIS_NOTIFY_LEN;
                    m_axis_c2h_tdata[159:128] <= pkt_seq;
                    m_axis_c2h_tdata[191:160] <= pkt_addr[31:0];
                    m_axis_c2h_tdata[223:192] <= pkt_bytes;
                    m_axis_c2h_tdata[255:224] <= {28'd0, pkt_addr[35:32]};

                    sqe_done_seq <= pkt_seq;

                    if (pkt_next_remaining != 32'd0) begin
                        emit_active    <= 1'b1;
                        emit_slot      <= pkt_slot + 16'd1;
                        emit_last_slot <= pkt_last_slot;
                        emit_addr      <= pkt_next_addr;
                        emit_bytes     <= pkt_next_remaining;
                        emit_bresp     <= pkt_bresp;
                        emit_overflow  <= pkt_overflow | overflow_sticky;
                        emit_backend   <= pkt_backend;
                    end else begin
                        emit_active <= 1'b0;
                    end
                end else if (axis_can_advance) begin
                    m_axis_c2h_tvalid <= 1'b0;
                    m_axis_c2h_tlast  <= 1'b0;
                    m_axis_c2h_tkeep  <= {AXIS_DATA_WIDTH/8{1'b0}};
                    m_axis_c2h_tdata  <= {AXIS_DATA_WIDTH{1'b0}};
                end
            end
        end
    end

endmodule
