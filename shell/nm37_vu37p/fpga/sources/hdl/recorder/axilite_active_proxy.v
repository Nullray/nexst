`timescale 1ns / 1ps

module axilite_active_proxy #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter BAR_ADDR_WIDTH = 64,
    parameter BAR_DATA_WIDTH = 128,
    parameter AXIS_DATA_WIDTH = 512
) (
    input wire clk,
    input wire rst, // 物理连线接 aresetn (低电平有效)

    // ===================================================================
    // 1. S_AXI (Slave): 现有控制路径代理，去往 XDMA RP S_AXI_LITE
    // ===================================================================
    input  wire [ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire [2:0]            s_axi_awprot,
    input  wire                  s_axi_awvalid,
    output wire                  s_axi_awready,
    input  wire [DATA_WIDTH-1:0] s_axi_wdata,
    input  wire [DATA_WIDTH/8-1:0] s_axi_wstrb,
    input  wire                  s_axi_wvalid,
    output wire                  s_axi_wready,
    output reg  [1:0]            s_axi_bresp,
    output reg                   s_axi_bvalid,
    input  wire                  s_axi_bready,
    input  wire [ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire [2:0]            s_axi_arprot,
    input  wire                  s_axi_arvalid,
    output wire                  s_axi_arready,
    output reg  [DATA_WIDTH-1:0] s_axi_rdata,
    output reg  [1:0]            s_axi_rresp,
    output reg                   s_axi_rvalid,
    input  wire                  s_axi_rready,

    // ===================================================================
    // 2. M_AXI (Master): 透传到 XDMA RP S_AXI_LITE
    // ===================================================================
    output reg  [ADDR_WIDTH-1:0] m_axi_awaddr,
    output reg  [2:0]            m_axi_awprot,
    output reg                   m_axi_awvalid,
    input  wire                  m_axi_awready,
    output reg  [DATA_WIDTH-1:0] m_axi_wdata,
    output reg  [DATA_WIDTH/8-1:0] m_axi_wstrb,
    output reg                   m_axi_wvalid,
    input  wire                  m_axi_wready,
    input  wire [1:0]            m_axi_bresp,
    input  wire                  m_axi_bvalid,
    output reg                   m_axi_bready,
    output reg  [ADDR_WIDTH-1:0] m_axi_araddr,
    output reg  [2:0]            m_axi_arprot,
    output reg                   m_axi_arvalid,
    input  wire                  m_axi_arready,
    input  wire [DATA_WIDTH-1:0] m_axi_rdata,
    input  wire [1:0]            m_axi_rresp,
    input  wire                  m_axi_rvalid,
    output reg                   m_axi_rready,

    // ===================================================================
    // 3. S_BAR_AXI (Slave): 拦截 XDMA RP S_AXI_B 前的 BAR MMIO 流量
    // ===================================================================
    input  wire [BAR_ADDR_WIDTH-1:0] s_bar_axi_araddr,
    input  wire [1:0]            s_bar_axi_arburst,
    input  wire [3:0]            s_bar_axi_arcache,
    input  wire [7:0]            s_bar_axi_arlen,
    input  wire [0:0]            s_bar_axi_arlock,
    input  wire [2:0]            s_bar_axi_arprot,
    input  wire [3:0]            s_bar_axi_arqos,
    output wire                  s_bar_axi_arready,
    input  wire [2:0]            s_bar_axi_arsize,
    input  wire                  s_bar_axi_arvalid,
    input  wire [BAR_ADDR_WIDTH-1:0] s_bar_axi_awaddr,
    input  wire [1:0]            s_bar_axi_awburst,
    input  wire [3:0]            s_bar_axi_awcache,
    input  wire [7:0]            s_bar_axi_awlen,
    input  wire [0:0]            s_bar_axi_awlock,
    input  wire [2:0]            s_bar_axi_awprot,
    input  wire [3:0]            s_bar_axi_awqos,
    output wire                  s_bar_axi_awready,
    input  wire [2:0]            s_bar_axi_awsize,
    input  wire                  s_bar_axi_awvalid,
    input  wire                  s_bar_axi_bready,
    output reg  [1:0]            s_bar_axi_bresp,
    output reg                   s_bar_axi_bvalid,
    output reg  [BAR_DATA_WIDTH-1:0] s_bar_axi_rdata,
    output reg                   s_bar_axi_rlast,
    input  wire                  s_bar_axi_rready,
    output reg  [1:0]            s_bar_axi_rresp,
    output reg                   s_bar_axi_rvalid,
    input  wire [BAR_DATA_WIDTH-1:0] s_bar_axi_wdata,
    input  wire                  s_bar_axi_wlast,
    output wire                  s_bar_axi_wready,
    input  wire [BAR_DATA_WIDTH/8-1:0] s_bar_axi_wstrb,
    input  wire                  s_bar_axi_wvalid,

    // ===================================================================
    // 4. M_BAR_AXI (Master): 无关 BAR 访问透传到 XDMA RP S_AXI_B
    // ===================================================================
    output reg  [BAR_ADDR_WIDTH-1:0] m_bar_axi_araddr,
    output reg  [1:0]            m_bar_axi_arburst,
    output reg  [3:0]            m_bar_axi_arcache,
    output reg  [7:0]            m_bar_axi_arlen,
    output reg  [0:0]            m_bar_axi_arlock,
    output reg  [2:0]            m_bar_axi_arprot,
    output reg  [3:0]            m_bar_axi_arqos,
    input  wire                  m_bar_axi_arready,
    output reg  [2:0]            m_bar_axi_arsize,
    output reg                   m_bar_axi_arvalid,
    output reg  [BAR_ADDR_WIDTH-1:0] m_bar_axi_awaddr,
    output reg  [1:0]            m_bar_axi_awburst,
    output reg  [3:0]            m_bar_axi_awcache,
    output reg  [7:0]            m_bar_axi_awlen,
    output reg  [0:0]            m_bar_axi_awlock,
    output reg  [2:0]            m_bar_axi_awprot,
    output reg  [3:0]            m_bar_axi_awqos,
    input  wire                  m_bar_axi_awready,
    output reg  [2:0]            m_bar_axi_awsize,
    output reg                   m_bar_axi_awvalid,
    output reg                   m_bar_axi_bready,
    input  wire [1:0]            m_bar_axi_bresp,
    input  wire                  m_bar_axi_bvalid,
    input  wire [BAR_DATA_WIDTH-1:0] m_bar_axi_rdata,
    input  wire                  m_bar_axi_rlast,
    output reg                   m_bar_axi_rready,
    input  wire [1:0]            m_bar_axi_rresp,
    input  wire                  m_bar_axi_rvalid,
    output reg  [BAR_DATA_WIDTH-1:0] m_bar_axi_wdata,
    output reg                   m_bar_axi_wlast,
    input  wire                  m_bar_axi_wready,
    output reg  [BAR_DATA_WIDTH/8-1:0] m_bar_axi_wstrb,
    output reg                   m_bar_axi_wvalid,

    // ===================================================================
    // 5. M_VCONF_AXI (Master): 去往 4KB 虚拟配置空间 BRAM (Port A)
    // ===================================================================
    output reg  [ADDR_WIDTH-1:0] m_vconf_axi_araddr,
    output reg  [2:0]            m_vconf_axi_arprot,
    output reg                   m_vconf_axi_arvalid,
    input  wire                  m_vconf_axi_arready,
    input  wire [DATA_WIDTH-1:0] m_vconf_axi_rdata,
    input  wire [1:0]            m_vconf_axi_rresp,
    input  wire                  m_vconf_axi_rvalid,
    output reg                   m_vconf_axi_rready,
    output wire [ADDR_WIDTH-1:0] m_vconf_axi_awaddr,
    output wire [2:0]            m_vconf_axi_awprot,
    output wire                  m_vconf_axi_awvalid,
    input  wire                  m_vconf_axi_awready,
    output wire [DATA_WIDTH-1:0] m_vconf_axi_wdata,
    output wire [DATA_WIDTH/8-1:0] m_vconf_axi_wstrb,
    output wire                  m_vconf_axi_wvalid,
    input  wire                  m_vconf_axi_wready,
    input  wire [1:0]            m_vconf_axi_bresp,
    input  wire                  m_vconf_axi_bvalid,
    output wire                  m_vconf_axi_bready,

    // ===================================================================
    // 6. S_MBX_AXI (Slave): 面向 Host 的 Mailbox/Shadow/Response 寄存器
    // ===================================================================
    input  wire [ADDR_WIDTH-1:0] s_mbx_axi_araddr,
    input  wire [2:0]            s_mbx_axi_arprot,
    input  wire                  s_mbx_axi_arvalid,
    output wire                  s_mbx_axi_arready,
    output reg  [DATA_WIDTH-1:0] s_mbx_axi_rdata,
    output reg  [1:0]            s_mbx_axi_rresp,
    output reg                   s_mbx_axi_rvalid,
    input  wire                  s_mbx_axi_rready,
    input  wire [ADDR_WIDTH-1:0] s_mbx_axi_awaddr,
    input  wire [2:0]            s_mbx_axi_awprot,
    input  wire                  s_mbx_axi_awvalid,
    output wire                  s_mbx_axi_awready,
    input  wire [DATA_WIDTH-1:0] s_mbx_axi_wdata,
    input  wire [DATA_WIDTH/8-1:0] s_mbx_axi_wstrb,
    input  wire                  s_mbx_axi_wvalid,
    output wire                  s_mbx_axi_wready,
    output reg  [1:0]            s_mbx_axi_bresp,
    output reg                   s_mbx_axi_bvalid,
    input  wire                  s_mbx_axi_bready,

    // ===================================================================
    // 7. M_AXIS_C2H (Master): 经 C2H_1 发送通知包到 Host
    // ===================================================================
    output reg                   m_axis_c2h_tvalid,
    input  wire                  m_axis_c2h_tready,
    output reg  [AXIS_DATA_WIDTH-1:0] m_axis_c2h_tdata,
    output reg  [AXIS_DATA_WIDTH/8-1:0] m_axis_c2h_tkeep,
    output reg                   m_axis_c2h_tlast,

    // ===================================================================
    // 8. IRQ: 复用真实 RP 的平台 IRQ 路径，仅对虚拟 NVMe 的 INTx 置位
    // ===================================================================
    output wire                  interrupt_out
);

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

    function [31:0] size_bytes_from_axsize;
        input [2:0] axsize;
        begin
            case (axsize)
                3'd0: size_bytes_from_axsize = 32'd1;
                3'd1: size_bytes_from_axsize = 32'd2;
                3'd2: size_bytes_from_axsize = 32'd4;
                3'd3: size_bytes_from_axsize = 32'd8;
                default: size_bytes_from_axsize = 32'd0;
            endcase
        end
    endfunction

    localparam integer BAR_QWORD_INDEX_BITS = $clog2(BAR_DATA_WIDTH / 64);

    function [63:0] bar_extract_qword64;
        input [BAR_DATA_WIDTH-1:0] value;
        input [BAR_QWORD_INDEX_BITS-1:0] qword_index;
        begin
            bar_extract_qword64 = value[qword_index * 64 +: 64];
        end
    endfunction

    function [7:0] bar_extract_wstrb8;
        input [BAR_DATA_WIDTH/8-1:0] value;
        input [BAR_QWORD_INDEX_BITS-1:0] qword_index;
        begin
            bar_extract_wstrb8 = value[qword_index * 8 +: 8];
        end
    endfunction

    function [BAR_DATA_WIDTH-1:0] bar_scatter_qword64;
        input [63:0] value;
        input [BAR_QWORD_INDEX_BITS-1:0] qword_index;
        begin
            bar_scatter_qword64 = {BAR_DATA_WIDTH{1'b0}};
            bar_scatter_qword64[qword_index * 64 +: 64] = value;
        end
    endfunction

    assign m_vconf_axi_awaddr  = {ADDR_WIDTH{1'b0}};
    assign m_vconf_axi_awprot  = 3'd0;
    assign m_vconf_axi_awvalid = 1'b0;
    assign m_vconf_axi_wdata   = {DATA_WIDTH{1'b0}};
    assign m_vconf_axi_wstrb   = {DATA_WIDTH/8{1'b0}};
    assign m_vconf_axi_wvalid  = 1'b0;
    assign m_vconf_axi_bready  = 1'b1;

    localparam [31:0] AXIS_NOTIFY_MAGIC        = 32'h5844_504b;
    localparam [31:0] AXIS_NOTIFY_TYPE_CFG_WR  = 32'd1;
    localparam [31:0] AXIS_NOTIFY_TYPE_BAR_WR  = 32'd2;
    localparam [31:0] AXIS_NOTIFY_TYPE_BAR_RD  = 32'd3;
    localparam [31:0] AXIS_NOTIFY_LEN          = 32'd32;
    localparam [31:0] AXIS_NOTIFY_CH_AW        = 32'd1;
    localparam [1:0]  AXI_RESP_OKAY            = 2'b00;
    localparam [1:0]  AXI_RESP_SLVERR          = 2'b10;
    localparam [AXIS_DATA_WIDTH/8-1:0] AXIS_PKT_KEEP =
        { {(AXIS_DATA_WIDTH/8-32){1'b0}}, 32'hFFFF_FFFF };

    localparam [11:0] MBX_REG_STATUS           = 12'h000;
    localparam [11:0] MBX_REG_AWADDR           = 12'h004;
    localparam [11:0] MBX_REG_WDATA            = 12'h008;
    localparam [11:0] MBX_REG_WSTRB            = 12'h00C;
    localparam [11:0] MBX_REG_ACK              = 12'h010;
    localparam [11:0] MBX_REG_GUEST_BAR0_LO    = 12'h020;
    localparam [11:0] MBX_REG_GUEST_BAR0_HI    = 12'h024;
    localparam [11:0] MBX_REG_GUEST_BAR0_SIZE  = 12'h028;
    localparam [11:0] MBX_REG_GUEST_BAR0_CTRL  = 12'h02C;
    localparam [11:0] MBX_REG_PROXY_CTRL       = 12'h030;
    localparam [11:0] MBX_REG_BAR_RESP_DATA_LO = 12'h034;
    localparam [11:0] MBX_REG_BAR_RESP_SEQ     = 12'h038;
    localparam [11:0] MBX_REG_BAR_RESP_CTRL    = 12'h03C;
    localparam [11:0] MBX_REG_STAT_BAR_WR_HIT  = 12'h040;
    localparam [11:0] MBX_REG_STAT_BAR_RD_HIT  = 12'h044;
    localparam [11:0] MBX_REG_STAT_BAR_ERR     = 12'h048;
    localparam [11:0] MBX_REG_BAR_RESP_DATA_HI = 12'h04C;
    localparam [11:0] MBX_REG_RP_INTX_CTRL     = 12'h050;
    localparam [11:0] MBX_REG_RP_INTX_STATUS   = 12'h054;
    localparam [11:0] MBX_REG_RP_INTX_COUNT    = 12'h058;

    localparam [11:0] RP_REG_IDR               = 12'h138;
    localparam [11:0] RP_REG_IMR               = 12'h13C;
    localparam [11:0] RP_REG_IDRN              = 12'h160;
    localparam [11:0] RP_REG_IDRN_MASK         = 12'h164;
    localparam [31:0] RP_INTX_BIT              = 32'h0001_0000;

    reg [31:0] mbx_status;
    reg [31:0] mbx_awaddr;
    reg [31:0] mbx_wdata;
    reg [31:0] mbx_wstrb;
    reg [31:0] mbx_ack_seq;
    reg        mbx_ack_toggle;
    reg        mbx_ack_toggle_seen;

    reg [31:0] guest_bar0_lo;
    reg [31:0] guest_bar0_hi;
    reg [31:0] guest_bar0_size;
    reg [31:0] guest_bar0_ctrl;
    reg [31:0] proxy_ctrl;
    reg [31:0] bar_resp_data_lo;
    reg [31:0] bar_resp_data_hi;
    reg [31:0] bar_resp_seq;
    reg [31:0] bar_resp_ctrl;
    reg [31:0] stat_bar_wr_hit;
    reg [31:0] stat_bar_rd_hit;
    reg [31:0] stat_bar_err;
    reg [31:0] rp_intx_ctrl;
    reg [31:0] rp_intr_mask;
    reg [31:0] rp_idrn_mask;
    reg [31:0] rp_intx_count;

    reg [31:0] cfg_seq_counter;
    reg [31:0] cfg_inflight_seq;

    reg [31:0] bar_seq_counter;
    reg [31:0] bar_wr_inflight_seq;
    reg        bar_wr_resp_toggle_seen;
    reg [31:0] bar_rd_inflight_seq;
    reg        bar_rd_resp_toggle_seen;
    reg [BAR_QWORD_INDEX_BITS-1:0] bar_read_qword_idx;

    localparam W_IDLE = 2'd0,
               W_PASS_WAIT_READY = 2'd1,
               W_PASS_WAIT_B = 2'd2,
               W_WAIT_ACK = 2'd3;
    reg [1:0] w_state;

    localparam R_IDLE = 3'd0,
               R_VCONF_WAIT_READY = 3'd1,
               R_VCONF_WAIT_R = 3'd2,
               R_PASS_WAIT_READY = 3'd3,
               R_PASS_WAIT_R = 3'd4;
    reg [2:0] r_state;

    localparam BW_IDLE = 2'd0,
               BW_PASS_WAIT_READY = 2'd1,
               BW_PASS_WAIT_B = 2'd2,
               BW_WAIT_RESP = 2'd3;
    reg [1:0] bar_w_state;

    localparam BR_IDLE = 2'd0,
               BR_PASS_WAIT_READY = 2'd1,
               BR_PASS_WAIT_R = 2'd2,
               BR_WAIT_RESP = 2'd3;
    reg [1:0] bar_r_state;

    wire is_vconf_aw = (s_axi_awaddr[31:12] == 20'h60100);
    wire is_vconf_ar = (s_axi_araddr[31:12] == 20'h60100);
    wire is_rp_local_aw = !is_vconf_aw &&
                          ((s_axi_awaddr[11:0] == RP_REG_IDR) ||
                           (s_axi_awaddr[11:0] == RP_REG_IMR) ||
                           (s_axi_awaddr[11:0] == RP_REG_IDRN) ||
                           (s_axi_awaddr[11:0] == RP_REG_IDRN_MASK));
    wire is_rp_local_ar = !is_vconf_ar &&
                          ((s_axi_araddr[11:0] == RP_REG_IDR) ||
                           (s_axi_araddr[11:0] == RP_REG_IMR) ||
                           (s_axi_araddr[11:0] == RP_REG_IDRN) ||
                           (s_axi_araddr[11:0] == RP_REG_IDRN_MASK));
    wire rp_intx_level = rp_intx_ctrl[0];
    wire rp_intx_irq = rp_intx_level && rp_intr_mask[16] && rp_idrn_mask[16];

    wire [31:0] bar_aw_size_bytes = size_bytes_from_axsize(s_bar_axi_awsize);
    wire [31:0] bar_ar_size_bytes = size_bytes_from_axsize(s_bar_axi_arsize);
    wire [BAR_QWORD_INDEX_BITS-1:0] bar_aw_qword_idx = s_bar_axi_awaddr[3 +: BAR_QWORD_INDEX_BITS];
    wire [BAR_QWORD_INDEX_BITS-1:0] bar_ar_qword_idx = s_bar_axi_araddr[3 +: BAR_QWORD_INDEX_BITS];
    wire [63:0] guest_bar0_base64 = {guest_bar0_hi, guest_bar0_lo};
    wire [63:0] guest_bar0_end64  = guest_bar0_base64 + {32'd0, guest_bar0_size};
    wire        guest_bar0_active = proxy_ctrl[0] &&
                                    guest_bar0_ctrl[0] &&
                                    guest_bar0_ctrl[1] &&
                                    (guest_bar0_hi == 32'd0) &&
                                    (guest_bar0_size != 32'd0);
    wire [63:0] bar_aw_addr64 = s_bar_axi_awaddr[63:0];
    wire [63:0] bar_ar_addr64 = s_bar_axi_araddr[63:0];
    wire [63:0] bar_aw_last64 = bar_aw_addr64 + {32'd0, (bar_aw_size_bytes == 32'd0) ? 32'd1 : bar_aw_size_bytes} - 64'd1;
    wire [63:0] bar_ar_last64 = bar_ar_addr64 + {32'd0, (bar_ar_size_bytes == 32'd0) ? 32'd1 : bar_ar_size_bytes} - 64'd1;
    wire        bar_aw_hit = guest_bar0_active &&
                             (bar_aw_size_bytes != 32'd0) &&
                             (bar_aw_addr64 >= guest_bar0_base64) &&
                             (bar_aw_last64 < guest_bar0_end64);
    wire        bar_ar_hit = guest_bar0_active &&
                             (bar_ar_size_bytes != 32'd0) &&
                             (bar_ar_addr64 >= guest_bar0_base64) &&
                             (bar_ar_last64 < guest_bar0_end64);
    wire [31:0] bar_aw_offset = s_bar_axi_awaddr[31:0] - guest_bar0_lo;
    wire [31:0] bar_ar_offset = s_bar_axi_araddr[31:0] - guest_bar0_lo;
    wire [63:0] bar_aw_req_data = bar_extract_qword64(s_bar_axi_wdata, bar_aw_qword_idx);
    wire [7:0]  bar_aw_req_wstrb = bar_extract_wstrb8(s_bar_axi_wstrb, bar_aw_qword_idx);
    wire        packet_engine_ready = !m_axis_c2h_tvalid;
    wire [31:0] rp_intx_ctrl_next = apply_wstrb32(rp_intx_ctrl, s_mbx_axi_wdata, s_mbx_axi_wstrb);
    wire        cfg_pkt_candidate = (w_state == W_IDLE) &&
                                    s_axi_awvalid &&
                                    s_axi_wvalid &&
                                    !s_axi_bvalid &&
                                    is_vconf_aw;
    wire [31:0] cfg_next_seq = cfg_seq_counter + 32'd1;
    wire        cfg_pkt_issue = cfg_pkt_candidate && packet_engine_ready;
    wire        bar_write_base_grant = (bar_w_state == BW_IDLE) &&
                                       (bar_r_state == BR_IDLE) &&
                                       !s_bar_axi_bvalid &&
                                       s_bar_axi_awvalid &&
                                       s_bar_axi_wvalid;
    wire        bar_write_supported = (s_bar_axi_awlen == 8'd0) &&
                                      (bar_aw_size_bytes != 32'd0) &&
                                      s_bar_axi_wlast;
    wire [31:0] bar_next_seq = bar_seq_counter + 32'd1;
    wire        bar_wr_pkt_issue = bar_write_base_grant &&
                                   bar_aw_hit &&
                                   bar_write_supported &&
                                   packet_engine_ready &&
                                   !cfg_pkt_candidate;
    wire        bar_wr_passthrough_grant = bar_write_base_grant && !bar_aw_hit;
    wire        bar_wr_error_grant = bar_write_base_grant &&
                                     bar_aw_hit &&
                                     !bar_write_supported;
    wire        bar_write_pending_same_cycle = s_bar_axi_awvalid && s_bar_axi_wvalid && !s_bar_axi_bvalid;
    wire        bar_read_base_grant = (bar_r_state == BR_IDLE) &&
                                      (bar_w_state == BW_IDLE) &&
                                      !s_bar_axi_rvalid &&
                                      !bar_write_pending_same_cycle &&
                                      s_bar_axi_arvalid;
    wire        bar_read_supported = (s_bar_axi_arlen == 8'd0) &&
                                     (bar_ar_size_bytes != 32'd0);
    wire        bar_rd_pkt_issue = bar_read_base_grant &&
                                   bar_ar_hit &&
                                   bar_read_supported &&
                                   packet_engine_ready &&
                                   !cfg_pkt_candidate;
    wire        bar_rd_passthrough_grant = bar_read_base_grant && !bar_ar_hit;
    wire        bar_rd_error_grant = bar_read_base_grant &&
                                     bar_ar_hit &&
                                     !bar_read_supported;

    assign interrupt_out = rst && rp_intx_irq;

    assign s_mbx_axi_arready = !s_mbx_axi_rvalid;
    assign s_mbx_axi_awready = !s_mbx_axi_bvalid && s_mbx_axi_awvalid && s_mbx_axi_wvalid;
    assign s_mbx_axi_wready  = s_mbx_axi_awready;

    always @(posedge clk) begin
        if (!rst) begin
            s_mbx_axi_rvalid <= 1'b0;
            s_mbx_axi_rdata  <= 32'd0;
            s_mbx_axi_rresp  <= AXI_RESP_OKAY;
        end else begin
            if (s_mbx_axi_arvalid && s_mbx_axi_arready) begin
                s_mbx_axi_rvalid <= 1'b1;
                s_mbx_axi_rresp  <= AXI_RESP_OKAY;
                case (s_mbx_axi_araddr[11:0])
                    MBX_REG_STATUS:          s_mbx_axi_rdata <= mbx_status;
                    MBX_REG_AWADDR:          s_mbx_axi_rdata <= mbx_awaddr;
                    MBX_REG_WDATA:           s_mbx_axi_rdata <= mbx_wdata;
                    MBX_REG_WSTRB:           s_mbx_axi_rdata <= mbx_wstrb;
                    MBX_REG_GUEST_BAR0_LO:   s_mbx_axi_rdata <= guest_bar0_lo;
                    MBX_REG_GUEST_BAR0_HI:   s_mbx_axi_rdata <= guest_bar0_hi;
                    MBX_REG_GUEST_BAR0_SIZE: s_mbx_axi_rdata <= guest_bar0_size;
                    MBX_REG_GUEST_BAR0_CTRL: s_mbx_axi_rdata <= guest_bar0_ctrl;
                    MBX_REG_PROXY_CTRL:      s_mbx_axi_rdata <= proxy_ctrl;
                    MBX_REG_BAR_RESP_DATA_LO:s_mbx_axi_rdata <= bar_resp_data_lo;
                    MBX_REG_BAR_RESP_SEQ:    s_mbx_axi_rdata <= bar_resp_seq;
                    MBX_REG_BAR_RESP_CTRL:   s_mbx_axi_rdata <= bar_resp_ctrl;
                    MBX_REG_STAT_BAR_WR_HIT: s_mbx_axi_rdata <= stat_bar_wr_hit;
                    MBX_REG_STAT_BAR_RD_HIT: s_mbx_axi_rdata <= stat_bar_rd_hit;
                    MBX_REG_STAT_BAR_ERR:    s_mbx_axi_rdata <= stat_bar_err;
                    MBX_REG_BAR_RESP_DATA_HI:s_mbx_axi_rdata <= bar_resp_data_hi;
                    MBX_REG_RP_INTX_CTRL:    s_mbx_axi_rdata <= rp_intx_ctrl;
                    MBX_REG_RP_INTX_STATUS:  s_mbx_axi_rdata <= {30'd0, rp_intx_irq, rp_intx_level};
                    MBX_REG_RP_INTX_COUNT:   s_mbx_axi_rdata <= rp_intx_count;
                    default:                 s_mbx_axi_rdata <= 32'd0;
                endcase
            end else if (s_mbx_axi_rready && s_mbx_axi_rvalid) begin
                s_mbx_axi_rvalid <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst) begin
            s_mbx_axi_bvalid <= 1'b0;
            s_mbx_axi_bresp  <= AXI_RESP_OKAY;
            mbx_ack_seq      <= 32'd0;
            mbx_ack_toggle   <= 1'b0;
            guest_bar0_lo    <= 32'd0;
            guest_bar0_hi    <= 32'd0;
            guest_bar0_size  <= 32'd0;
            guest_bar0_ctrl  <= 32'd0;
            proxy_ctrl       <= 32'd0;
            bar_resp_data_lo <= 32'd0;
            bar_resp_data_hi <= 32'd0;
            bar_resp_seq     <= 32'd0;
            bar_resp_ctrl    <= 32'd0;
            stat_bar_wr_hit  <= 32'd0;
            stat_bar_rd_hit  <= 32'd0;
            stat_bar_err     <= 32'd0;
            rp_intx_ctrl     <= 32'd0;
            rp_intr_mask     <= 32'd0;
            rp_idrn_mask     <= 32'd0;
            rp_intx_count    <= 32'd0;
        end else begin
            if (s_mbx_axi_awready) begin
                s_mbx_axi_bvalid <= 1'b1;
                s_mbx_axi_bresp  <= AXI_RESP_OKAY;
                case (s_mbx_axi_awaddr[11:0])
                    MBX_REG_ACK: begin
                        mbx_ack_seq    <= apply_wstrb32(mbx_ack_seq, s_mbx_axi_wdata, s_mbx_axi_wstrb);
                        mbx_ack_toggle <= ~mbx_ack_toggle;
                    end
                    MBX_REG_GUEST_BAR0_LO:   guest_bar0_lo   <= apply_wstrb32(guest_bar0_lo,   s_mbx_axi_wdata, s_mbx_axi_wstrb);
                    MBX_REG_GUEST_BAR0_HI:   guest_bar0_hi   <= apply_wstrb32(guest_bar0_hi,   s_mbx_axi_wdata, s_mbx_axi_wstrb);
                    MBX_REG_GUEST_BAR0_SIZE: guest_bar0_size <= apply_wstrb32(guest_bar0_size, s_mbx_axi_wdata, s_mbx_axi_wstrb);
                    MBX_REG_GUEST_BAR0_CTRL: guest_bar0_ctrl <= apply_wstrb32(guest_bar0_ctrl, s_mbx_axi_wdata, s_mbx_axi_wstrb);
                    MBX_REG_PROXY_CTRL:      proxy_ctrl      <= apply_wstrb32(proxy_ctrl,      s_mbx_axi_wdata, s_mbx_axi_wstrb);
                    MBX_REG_BAR_RESP_DATA_LO:bar_resp_data_lo<= apply_wstrb32(bar_resp_data_lo,s_mbx_axi_wdata, s_mbx_axi_wstrb);
                    MBX_REG_BAR_RESP_SEQ:    bar_resp_seq    <= apply_wstrb32(bar_resp_seq,    s_mbx_axi_wdata, s_mbx_axi_wstrb);
                    MBX_REG_BAR_RESP_CTRL:   bar_resp_ctrl   <= apply_wstrb32(bar_resp_ctrl,   s_mbx_axi_wdata, s_mbx_axi_wstrb);
                    MBX_REG_BAR_RESP_DATA_HI:bar_resp_data_hi<= apply_wstrb32(bar_resp_data_hi,s_mbx_axi_wdata, s_mbx_axi_wstrb);
                    MBX_REG_RP_INTX_CTRL: begin
                        if (!rp_intx_ctrl[0] && rp_intx_ctrl_next[0]) begin
                            rp_intx_count <= rp_intx_count + 32'd1;
                        end
                        rp_intx_ctrl <= rp_intx_ctrl_next;
                    end
                    default: begin
                    end
                endcase
            end else if (s_mbx_axi_bready && s_mbx_axi_bvalid) begin
                s_mbx_axi_bvalid <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst) begin
            m_axis_c2h_tvalid <= 1'b0;
            m_axis_c2h_tdata  <= {AXIS_DATA_WIDTH{1'b0}};
            m_axis_c2h_tkeep  <= {AXIS_DATA_WIDTH/8{1'b0}};
            m_axis_c2h_tlast  <= 1'b0;
            cfg_seq_counter   <= 32'd0;
            bar_seq_counter   <= 32'd0;
        end else begin
            if (m_axis_c2h_tvalid && m_axis_c2h_tready) begin
                m_axis_c2h_tvalid <= 1'b0;
            end

            if (!m_axis_c2h_tvalid) begin
                if (cfg_pkt_issue) begin
                    m_axis_c2h_tvalid <= 1'b1;
                    m_axis_c2h_tkeep  <= AXIS_PKT_KEEP;
                    m_axis_c2h_tlast  <= 1'b1;
                    m_axis_c2h_tdata  <= {AXIS_DATA_WIDTH{1'b0}};
                    m_axis_c2h_tdata[31:0]    <= AXIS_NOTIFY_MAGIC;
                    m_axis_c2h_tdata[63:32]   <= AXIS_NOTIFY_TYPE_CFG_WR;
                    m_axis_c2h_tdata[95:64]   <= AXIS_NOTIFY_CH_AW;
                    m_axis_c2h_tdata[127:96]  <= AXIS_NOTIFY_LEN;
                    m_axis_c2h_tdata[159:128] <= cfg_next_seq;
                    m_axis_c2h_tdata[191:160] <= {20'd0, s_axi_awaddr[11:0]};
                    m_axis_c2h_tdata[223:192] <= s_axi_wdata;
                    m_axis_c2h_tdata[255:224] <= {{(25-DATA_WIDTH/8){1'b0}}, s_axi_awprot, s_axi_wstrb};
                    cfg_seq_counter           <= cfg_next_seq;
                end else if (bar_wr_pkt_issue) begin
                    m_axis_c2h_tvalid <= 1'b1;
                    m_axis_c2h_tkeep  <= AXIS_PKT_KEEP;
                    m_axis_c2h_tlast  <= 1'b1;
                    m_axis_c2h_tdata  <= {AXIS_DATA_WIDTH{1'b0}};
                    m_axis_c2h_tdata[31:0]    <= AXIS_NOTIFY_MAGIC;
                    m_axis_c2h_tdata[63:32]   <= AXIS_NOTIFY_TYPE_BAR_WR;
                    m_axis_c2h_tdata[95:64]   <= {16'd0, bar_aw_size_bytes[7:0], bar_aw_req_wstrb};
                    m_axis_c2h_tdata[127:96]  <= AXIS_NOTIFY_LEN;
                    m_axis_c2h_tdata[159:128] <= bar_next_seq;
                    m_axis_c2h_tdata[191:160] <= bar_aw_offset;
                    m_axis_c2h_tdata[223:192] <= bar_aw_req_data[31:0];
                    m_axis_c2h_tdata[255:224] <= bar_aw_req_data[63:32];
                    bar_seq_counter           <= bar_next_seq;
                end else if (bar_rd_pkt_issue) begin
                    m_axis_c2h_tvalid <= 1'b1;
                    m_axis_c2h_tkeep  <= AXIS_PKT_KEEP;
                    m_axis_c2h_tlast  <= 1'b1;
                    m_axis_c2h_tdata  <= {AXIS_DATA_WIDTH{1'b0}};
                    m_axis_c2h_tdata[31:0]    <= AXIS_NOTIFY_MAGIC;
                    m_axis_c2h_tdata[63:32]   <= AXIS_NOTIFY_TYPE_BAR_RD;
                    m_axis_c2h_tdata[95:64]   <= {16'd0, bar_ar_size_bytes[7:0], 8'd0};
                    m_axis_c2h_tdata[127:96]  <= AXIS_NOTIFY_LEN;
                    m_axis_c2h_tdata[159:128] <= bar_next_seq;
                    m_axis_c2h_tdata[191:160] <= bar_ar_offset;
                    m_axis_c2h_tdata[223:192] <= 32'd0;
                    m_axis_c2h_tdata[255:224] <= 32'd0;
                    bar_seq_counter           <= bar_next_seq;
                end
            end
        end
    end

    assign s_axi_awready = (w_state == W_IDLE) &&
                           s_axi_awvalid &&
                           s_axi_wvalid &&
                           !s_axi_bvalid &&
                           (!is_vconf_aw || cfg_pkt_issue);
    assign s_axi_wready  = s_axi_awready;

    always @(posedge clk) begin
        if (!rst) begin
            w_state              <= W_IDLE;
            mbx_status           <= 32'd0;
            cfg_inflight_seq     <= 32'd0;
            mbx_ack_toggle_seen  <= 1'b0;
            s_axi_bvalid         <= 1'b0;
            s_axi_bresp          <= AXI_RESP_OKAY;
            m_axi_awvalid        <= 1'b0;
            m_axi_wvalid         <= 1'b0;
            m_axi_bready         <= 1'b0;
            m_axi_awaddr         <= {ADDR_WIDTH{1'b0}};
            m_axi_awprot         <= 3'd0;
            m_axi_wdata          <= {DATA_WIDTH{1'b0}};
            m_axi_wstrb          <= {DATA_WIDTH/8{1'b0}};
            mbx_awaddr           <= 32'd0;
            mbx_wdata            <= 32'd0;
            mbx_wstrb            <= 32'd0;
        end else begin
            if (s_axi_bready && s_axi_bvalid) begin
                s_axi_bvalid <= 1'b0;
            end

            case (w_state)
                W_IDLE: begin
                    if (s_axi_awready) begin
                        if (is_vconf_aw) begin
                            mbx_awaddr          <= {20'd0, s_axi_awaddr[11:0]};
                            mbx_wdata           <= s_axi_wdata;
                            mbx_wstrb           <= {{(32-DATA_WIDTH/8){1'b0}}, s_axi_wstrb};
                            mbx_status          <= 32'h0000_0001;
                            cfg_inflight_seq    <= cfg_next_seq;
                            mbx_ack_toggle_seen   <= mbx_ack_toggle;
                            w_state               <= W_WAIT_ACK;
                        end else if (is_rp_local_aw) begin
                            case (s_axi_awaddr[11:0])
                                RP_REG_IMR: begin
                                    rp_intr_mask <= apply_wstrb32(rp_intr_mask,
                                                                   s_axi_wdata,
                                                                   s_axi_wstrb);
                                end
                                RP_REG_IDRN_MASK: begin
                                    rp_idrn_mask <= apply_wstrb32(rp_idrn_mask,
                                                                   s_axi_wdata,
                                                                   s_axi_wstrb);
                                end
                                default: begin
                                end
                            endcase
                            s_axi_bvalid <= 1'b1;
                            s_axi_bresp  <= AXI_RESP_OKAY;
                        end else begin
                            m_axi_awvalid <= 1'b1;
                            m_axi_awaddr  <= s_axi_awaddr;
                            m_axi_awprot  <= s_axi_awprot;
                            m_axi_wvalid  <= 1'b1;
                            m_axi_wdata   <= s_axi_wdata;
                            m_axi_wstrb   <= s_axi_wstrb;
                            w_state       <= W_PASS_WAIT_READY;
                        end
                    end
                end

                W_PASS_WAIT_READY: begin
                    if (m_axi_awvalid && m_axi_awready) begin
                        m_axi_awvalid <= 1'b0;
                    end
                    if (m_axi_wvalid && m_axi_wready) begin
                        m_axi_wvalid <= 1'b0;
                    end
                    if (!m_axi_awvalid && !m_axi_wvalid) begin
                        m_axi_bready <= 1'b1;
                        w_state <= W_PASS_WAIT_B;
                    end
                end

                W_PASS_WAIT_B: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready <= 1'b0;
                        s_axi_bvalid <= 1'b1;
                        s_axi_bresp  <= m_axi_bresp;
                        w_state      <= W_IDLE;
                    end
                end

                W_WAIT_ACK: begin
                    if (mbx_ack_toggle_seen != mbx_ack_toggle) begin
                        mbx_ack_toggle_seen <= mbx_ack_toggle;
                        // Legacy config IRQ path only returns an ACK pulse and does
                        // not provide a matching sequence number. Keep the mailbox
                        // sequence register for debug visibility, but only gate
                        // forward progress on the observed ACK toggle.
                        mbx_status   <= 32'd0;
                        s_axi_bvalid <= 1'b1;
                        s_axi_bresp  <= AXI_RESP_OKAY;
                        w_state <= W_IDLE;
                    end
                end
            endcase
        end
    end

    assign s_axi_arready = (r_state == R_IDLE) && !s_axi_rvalid;

    always @(posedge clk) begin
        if (!rst) begin
            r_state             <= R_IDLE;
            s_axi_rvalid        <= 1'b0;
            s_axi_rdata         <= {DATA_WIDTH{1'b0}};
            s_axi_rresp         <= AXI_RESP_OKAY;
            m_vconf_axi_arvalid <= 1'b0;
            m_vconf_axi_araddr  <= {ADDR_WIDTH{1'b0}};
            m_vconf_axi_arprot  <= 3'd0;
            m_vconf_axi_rready  <= 1'b0;
            m_axi_arvalid       <= 1'b0;
            m_axi_araddr        <= {ADDR_WIDTH{1'b0}};
            m_axi_arprot        <= 3'd0;
            m_axi_rready        <= 1'b0;
        end else begin
            if (s_axi_rready && s_axi_rvalid) begin
                s_axi_rvalid <= 1'b0;
            end

            case (r_state)
                R_IDLE: begin
                    if (s_axi_arready && s_axi_arvalid) begin
                        if (is_vconf_ar) begin
                            m_vconf_axi_arvalid <= 1'b1;
                            m_vconf_axi_araddr  <= {20'd0, s_axi_araddr[11:0]};
                            m_vconf_axi_arprot  <= s_axi_arprot;
                            r_state <= R_VCONF_WAIT_READY;
                        end else if (is_rp_local_ar) begin
                            s_axi_rvalid <= 1'b1;
                            s_axi_rresp  <= AXI_RESP_OKAY;
                            case (s_axi_araddr[11:0])
                                RP_REG_IDR:       s_axi_rdata <= rp_intx_level ? RP_INTX_BIT : 32'd0;
                                RP_REG_IMR:       s_axi_rdata <= rp_intr_mask;
                                RP_REG_IDRN:      s_axi_rdata <= rp_intx_level ? RP_INTX_BIT : 32'd0;
                                RP_REG_IDRN_MASK: s_axi_rdata <= rp_idrn_mask;
                                default:          s_axi_rdata <= 32'd0;
                            endcase
                        end else begin
                            m_axi_arvalid <= 1'b1;
                            m_axi_araddr  <= s_axi_araddr;
                            m_axi_arprot  <= s_axi_arprot;
                            r_state <= R_PASS_WAIT_READY;
                        end
                    end
                end

                R_VCONF_WAIT_READY: begin
                    if (m_vconf_axi_arvalid && m_vconf_axi_arready) begin
                        m_vconf_axi_arvalid <= 1'b0;
                        m_vconf_axi_rready  <= 1'b1;
                        r_state <= R_VCONF_WAIT_R;
                    end
                end

                R_VCONF_WAIT_R: begin
                    if (m_vconf_axi_rvalid && m_vconf_axi_rready) begin
                        m_vconf_axi_rready <= 1'b0;
                        s_axi_rvalid <= 1'b1;
                        s_axi_rdata  <= m_vconf_axi_rdata;
                        s_axi_rresp  <= m_vconf_axi_rresp;
                        r_state <= R_IDLE;
                    end
                end

                R_PASS_WAIT_READY: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready  <= 1'b1;
                        r_state <= R_PASS_WAIT_R;
                    end
                end

                R_PASS_WAIT_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        m_axi_rready <= 1'b0;
                        s_axi_rvalid <= 1'b1;
                        s_axi_rdata  <= m_axi_rdata;
                        s_axi_rresp  <= m_axi_rresp;
                        r_state <= R_IDLE;
                    end
                end
            endcase
        end
    end

    assign s_bar_axi_awready = bar_wr_pkt_issue || bar_wr_passthrough_grant || bar_wr_error_grant;
    assign s_bar_axi_wready  = s_bar_axi_awready;

    always @(posedge clk) begin
        if (!rst) begin
            bar_w_state             <= BW_IDLE;
            s_bar_axi_bvalid        <= 1'b0;
            s_bar_axi_bresp         <= AXI_RESP_OKAY;
            bar_wr_inflight_seq     <= 32'd0;
            bar_wr_resp_toggle_seen <= 1'b0;
            m_bar_axi_awvalid       <= 1'b0;
            m_bar_axi_awaddr        <= {BAR_ADDR_WIDTH{1'b0}};
            m_bar_axi_awburst       <= 2'd0;
            m_bar_axi_awcache       <= 4'd0;
            m_bar_axi_awlen         <= 8'd0;
            m_bar_axi_awlock        <= 1'b0;
            m_bar_axi_awprot        <= 3'd0;
            m_bar_axi_awqos         <= 4'd0;
            m_bar_axi_awsize        <= 3'd0;
            m_bar_axi_wvalid        <= 1'b0;
            m_bar_axi_wdata         <= {BAR_DATA_WIDTH{1'b0}};
            m_bar_axi_wlast         <= 1'b0;
            m_bar_axi_wstrb         <= {BAR_DATA_WIDTH/8{1'b0}};
            m_bar_axi_bready        <= 1'b0;
        end else begin
            if (s_bar_axi_bready && s_bar_axi_bvalid) begin
                s_bar_axi_bvalid <= 1'b0;
            end

            case (bar_w_state)
                BW_IDLE: begin
                    if (s_bar_axi_awready && s_bar_axi_awvalid && s_bar_axi_wvalid) begin
                        if (bar_aw_hit) begin
                            if (!bar_write_supported) begin
                                stat_bar_err    <= stat_bar_err + 32'd1;
                                s_bar_axi_bvalid <= 1'b1;
                                s_bar_axi_bresp  <= AXI_RESP_SLVERR;
                            end else begin
                                bar_wr_inflight_seq     <= bar_next_seq;
                                bar_wr_resp_toggle_seen <= bar_resp_ctrl[2];
                                bar_w_state             <= BW_WAIT_RESP;
                            end
                        end else begin
                            m_bar_axi_awvalid <= 1'b1;
                            m_bar_axi_awaddr  <= s_bar_axi_awaddr;
                            m_bar_axi_awburst <= s_bar_axi_awburst;
                            m_bar_axi_awcache <= s_bar_axi_awcache;
                            m_bar_axi_awlen   <= s_bar_axi_awlen;
                            m_bar_axi_awlock  <= s_bar_axi_awlock;
                            m_bar_axi_awprot  <= s_bar_axi_awprot;
                            m_bar_axi_awqos   <= s_bar_axi_awqos;
                            m_bar_axi_awsize  <= s_bar_axi_awsize;
                            m_bar_axi_wvalid  <= 1'b1;
                            m_bar_axi_wdata   <= s_bar_axi_wdata;
                            m_bar_axi_wlast   <= s_bar_axi_wlast;
                            m_bar_axi_wstrb   <= s_bar_axi_wstrb;
                            bar_w_state       <= BW_PASS_WAIT_READY;
                        end
                    end
                end

                BW_PASS_WAIT_READY: begin
                    if (m_bar_axi_awvalid && m_bar_axi_awready) begin
                        m_bar_axi_awvalid <= 1'b0;
                    end
                    if (m_bar_axi_wvalid && m_bar_axi_wready) begin
                        m_bar_axi_wvalid <= 1'b0;
                    end
                    if (!m_bar_axi_awvalid && !m_bar_axi_wvalid) begin
                        m_bar_axi_bready <= 1'b1;
                        bar_w_state <= BW_PASS_WAIT_B;
                    end
                end

                BW_PASS_WAIT_B: begin
                    if (m_bar_axi_bvalid && m_bar_axi_bready) begin
                        m_bar_axi_bready <= 1'b0;
                        s_bar_axi_bvalid <= 1'b1;
                        s_bar_axi_bresp  <= m_bar_axi_bresp;
                        bar_w_state      <= BW_IDLE;
                    end
                end

                BW_WAIT_RESP: begin
                    if (bar_wr_resp_toggle_seen != bar_resp_ctrl[2]) begin
                        bar_wr_resp_toggle_seen <= bar_resp_ctrl[2];
                        if (bar_resp_seq == bar_wr_inflight_seq) begin
                            stat_bar_wr_hit  <= stat_bar_wr_hit + 32'd1;
                            s_bar_axi_bresp  <= bar_resp_ctrl[1:0];
                        end else begin
                            stat_bar_err     <= stat_bar_err + 32'd1;
                            s_bar_axi_bresp  <= AXI_RESP_SLVERR;
                        end
                        s_bar_axi_bvalid <= 1'b1;
                        bar_w_state <= BW_IDLE;
                    end
                end
            endcase
        end
    end

    assign s_bar_axi_arready = bar_rd_pkt_issue || bar_rd_passthrough_grant || bar_rd_error_grant;

    always @(posedge clk) begin
        if (!rst) begin
            bar_r_state             <= BR_IDLE;
            s_bar_axi_rvalid        <= 1'b0;
            s_bar_axi_rdata         <= {BAR_DATA_WIDTH{1'b0}};
            s_bar_axi_rresp         <= AXI_RESP_OKAY;
            s_bar_axi_rlast         <= 1'b1;
            bar_rd_inflight_seq     <= 32'd0;
            bar_rd_resp_toggle_seen <= 1'b0;
            bar_read_qword_idx      <= {BAR_QWORD_INDEX_BITS{1'b0}};
            m_bar_axi_arvalid       <= 1'b0;
            m_bar_axi_araddr        <= {BAR_ADDR_WIDTH{1'b0}};
            m_bar_axi_arburst       <= 2'd0;
            m_bar_axi_arcache       <= 4'd0;
            m_bar_axi_arlen         <= 8'd0;
            m_bar_axi_arlock        <= 1'b0;
            m_bar_axi_arprot        <= 3'd0;
            m_bar_axi_arqos         <= 4'd0;
            m_bar_axi_arsize        <= 3'd0;
            m_bar_axi_rready        <= 1'b0;
        end else begin
            if (s_bar_axi_rready && s_bar_axi_rvalid) begin
                s_bar_axi_rvalid <= 1'b0;
            end

            case (bar_r_state)
                BR_IDLE: begin
                    if (s_bar_axi_arready && s_bar_axi_arvalid) begin
                        if (bar_ar_hit) begin
                            if (!bar_read_supported) begin
                                stat_bar_err    <= stat_bar_err + 32'd1;
                                s_bar_axi_rvalid <= 1'b1;
                                s_bar_axi_rdata  <= {BAR_DATA_WIDTH{1'b0}};
                                s_bar_axi_rresp  <= AXI_RESP_SLVERR;
                                s_bar_axi_rlast  <= 1'b1;
                            end else begin
                                bar_rd_inflight_seq     <= bar_next_seq;
                                bar_rd_resp_toggle_seen <= bar_resp_ctrl[2];
                                bar_read_qword_idx      <= bar_ar_qword_idx;
                                bar_r_state             <= BR_WAIT_RESP;
                            end
                        end else begin
                            m_bar_axi_arvalid <= 1'b1;
                            m_bar_axi_araddr  <= s_bar_axi_araddr;
                            m_bar_axi_arburst <= s_bar_axi_arburst;
                            m_bar_axi_arcache <= s_bar_axi_arcache;
                            m_bar_axi_arlen   <= s_bar_axi_arlen;
                            m_bar_axi_arlock  <= s_bar_axi_arlock;
                            m_bar_axi_arprot  <= s_bar_axi_arprot;
                            m_bar_axi_arqos   <= s_bar_axi_arqos;
                            m_bar_axi_arsize  <= s_bar_axi_arsize;
                            bar_r_state       <= BR_PASS_WAIT_READY;
                        end
                    end
                end

                BR_PASS_WAIT_READY: begin
                    if (m_bar_axi_arvalid && m_bar_axi_arready) begin
                        m_bar_axi_arvalid <= 1'b0;
                        m_bar_axi_rready  <= 1'b1;
                        bar_r_state <= BR_PASS_WAIT_R;
                    end
                end

                BR_PASS_WAIT_R: begin
                    if (m_bar_axi_rvalid && m_bar_axi_rready) begin
                        m_bar_axi_rready <= 1'b0;
                        s_bar_axi_rvalid <= 1'b1;
                        s_bar_axi_rdata  <= m_bar_axi_rdata;
                        s_bar_axi_rresp  <= m_bar_axi_rresp;
                        s_bar_axi_rlast  <= m_bar_axi_rlast;
                        bar_r_state <= BR_IDLE;
                    end
                end

                BR_WAIT_RESP: begin
                    if (bar_rd_resp_toggle_seen != bar_resp_ctrl[2]) begin
                        bar_rd_resp_toggle_seen <= bar_resp_ctrl[2];
                        if (bar_resp_seq == bar_rd_inflight_seq) begin
                            stat_bar_rd_hit  <= stat_bar_rd_hit + 32'd1;
                            s_bar_axi_rdata  <= bar_scatter_qword64({bar_resp_data_hi, bar_resp_data_lo},
                                                                     bar_read_qword_idx);
                            s_bar_axi_rresp  <= bar_resp_ctrl[1:0];
                        end else begin
                            stat_bar_err     <= stat_bar_err + 32'd1;
                            s_bar_axi_rdata  <= {BAR_DATA_WIDTH{1'b0}};
                            s_bar_axi_rresp  <= AXI_RESP_SLVERR;
                        end
                        s_bar_axi_rvalid <= 1'b1;
                        s_bar_axi_rlast  <= 1'b1;
                        bar_r_state      <= BR_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
