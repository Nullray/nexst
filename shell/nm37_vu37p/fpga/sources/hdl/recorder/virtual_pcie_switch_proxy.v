`timescale 1ns / 1ps

module virtual_pcie_switch_proxy #(
    parameter ECAM_BASE = 32'h6000_0000,
    parameter MMIO_BASE = 32'h5000_0000,
    parameter MMIO_SIZE = 32'h0100_0000
) (
    input  wire         clk,
    input  wire         rst,

    input  wire [31:0]  s_ecam_axi_awaddr,
    input  wire [2:0]   s_ecam_axi_awprot,
    input  wire         s_ecam_axi_awvalid,
    output wire         s_ecam_axi_awready,
    input  wire [31:0]  s_ecam_axi_wdata,
    input  wire [3:0]   s_ecam_axi_wstrb,
    input  wire         s_ecam_axi_wvalid,
    output wire         s_ecam_axi_wready,
    output reg  [1:0]   s_ecam_axi_bresp,
    output reg          s_ecam_axi_bvalid,
    input  wire         s_ecam_axi_bready,
    input  wire [31:0]  s_ecam_axi_araddr,
    input  wire [2:0]   s_ecam_axi_arprot,
    input  wire         s_ecam_axi_arvalid,
    output wire         s_ecam_axi_arready,
    output reg  [31:0]  s_ecam_axi_rdata,
    output reg  [1:0]   s_ecam_axi_rresp,
    output reg          s_ecam_axi_rvalid,
    input  wire         s_ecam_axi_rready,

    output reg  [31:0]  m_ecam_shadow_axi_araddr,
    output reg  [2:0]   m_ecam_shadow_axi_arprot,
    output reg          m_ecam_shadow_axi_arvalid,
    input  wire         m_ecam_shadow_axi_arready,
    input  wire [31:0]  m_ecam_shadow_axi_rdata,
    input  wire [1:0]   m_ecam_shadow_axi_rresp,
    input  wire         m_ecam_shadow_axi_rvalid,
    output reg          m_ecam_shadow_axi_rready,
    output wire [31:0]  m_ecam_shadow_axi_awaddr,
    output wire [2:0]   m_ecam_shadow_axi_awprot,
    output wire         m_ecam_shadow_axi_awvalid,
    input  wire         m_ecam_shadow_axi_awready,
    output wire [31:0]  m_ecam_shadow_axi_wdata,
    output wire [3:0]   m_ecam_shadow_axi_wstrb,
    output wire         m_ecam_shadow_axi_wvalid,
    input  wire         m_ecam_shadow_axi_wready,
    input  wire [1:0]   m_ecam_shadow_axi_bresp,
    input  wire         m_ecam_shadow_axi_bvalid,
    output wire         m_ecam_shadow_axi_bready,

    input  wire [31:0]  s_mbx_axi_awaddr,
    input  wire [2:0]   s_mbx_axi_awprot,
    input  wire         s_mbx_axi_awvalid,
    output wire         s_mbx_axi_awready,
    input  wire [31:0]  s_mbx_axi_wdata,
    input  wire [3:0]   s_mbx_axi_wstrb,
    input  wire         s_mbx_axi_wvalid,
    output wire         s_mbx_axi_wready,
    output reg  [1:0]   s_mbx_axi_bresp,
    output reg          s_mbx_axi_bvalid,
    input  wire         s_mbx_axi_bready,
    input  wire [31:0]  s_mbx_axi_araddr,
    input  wire [2:0]   s_mbx_axi_arprot,
    input  wire         s_mbx_axi_arvalid,
    output wire         s_mbx_axi_arready,
    output reg  [31:0]  s_mbx_axi_rdata,
    output reg  [1:0]   s_mbx_axi_rresp,
    output reg          s_mbx_axi_rvalid,
    input  wire         s_mbx_axi_rready,

    input  wire [63:0]  s_mmio_axi_awaddr,
    input  wire [7:0]   s_mmio_axi_awlen,
    input  wire [2:0]   s_mmio_axi_awsize,
    input  wire [1:0]   s_mmio_axi_awburst,
    input  wire [3:0]   s_mmio_axi_awcache,
    input  wire [0:0]   s_mmio_axi_awlock,
    input  wire [2:0]   s_mmio_axi_awprot,
    input  wire [3:0]   s_mmio_axi_awqos,
    input  wire         s_mmio_axi_awvalid,
    output wire         s_mmio_axi_awready,
    input  wire [127:0] s_mmio_axi_wdata,
    input  wire [15:0]  s_mmio_axi_wstrb,
    input  wire         s_mmio_axi_wlast,
    input  wire         s_mmio_axi_wvalid,
    output wire         s_mmio_axi_wready,
    output reg  [1:0]   s_mmio_axi_bresp,
    output reg          s_mmio_axi_bvalid,
    input  wire         s_mmio_axi_bready,
    input  wire [63:0]  s_mmio_axi_araddr,
    input  wire [7:0]   s_mmio_axi_arlen,
    input  wire [2:0]   s_mmio_axi_arsize,
    input  wire [1:0]   s_mmio_axi_arburst,
    input  wire [3:0]   s_mmio_axi_arcache,
    input  wire [0:0]   s_mmio_axi_arlock,
    input  wire [2:0]   s_mmio_axi_arprot,
    input  wire [3:0]   s_mmio_axi_arqos,
    input  wire         s_mmio_axi_arvalid,
    output wire         s_mmio_axi_arready,
    output reg  [127:0] s_mmio_axi_rdata,
    output reg  [1:0]   s_mmio_axi_rresp,
    output reg          s_mmio_axi_rlast,
    output reg          s_mmio_axi_rvalid,
    input  wire         s_mmio_axi_rready,

    output reg  [511:0] m_axis_c2h_tdata,
    output reg  [63:0]  m_axis_c2h_tkeep,
    output reg          m_axis_c2h_tlast,
    output reg          m_axis_c2h_tvalid,
    input  wire         m_axis_c2h_tready,

    output wire         interrupt_out
);

localparam DMA32_PKT_MAGIC = 32'h5844_504b;
localparam PKT_CFG_WRITE = 32'd1;
localparam PKT_BAR_WRITE = 32'd2;
localparam PKT_BAR_READ  = 32'd3;
localparam PKT_BAR_WRITE_DONE = 32'd4;
localparam PKT_LEN = 32'd32;
localparam BDF_ROOT_PORT = 16'h0000;
localparam BDF_SW_UP     = 16'h0100;
localparam BDF_SW_DOWN   = 16'h0208;
localparam BDF_NVME      = 16'h0300;
localparam BAR_TAG_CFG   = 3'd7;
localparam AXI_OKAY      = 2'b00;
localparam AXI_SLVERR    = 2'b10;

localparam GUEST_BAR0_CTRL_VALID      = 0;
localparam GUEST_BAR0_CTRL_MEM_ENABLE = 1;
localparam GUEST_BAR0_CTRL_IS64       = 2;
localparam PROXY_CTRL_BAR_ROUTE_READY = 0;
localparam PROXY_CTRL_ECAM_SHADOW_READY = 1;

localparam ECAM_R_IDLE    = 2'd0;
localparam ECAM_R_WAIT_AR = 2'd1;
localparam ECAM_R_WAIT_R  = 2'd2;
localparam ECAM_W_IDLE    = 1'd0;
localparam ECAM_W_WAIT_ACK = 1'd1;

localparam MMIO_IDLE = 2'd0;
localparam MMIO_WAIT_WR = 2'd1;
localparam MMIO_WAIT_RD = 2'd2;
localparam MMIO_DONE_PKT = 2'd3;

reg [31:0] seq_counter;

reg [31:0] mbx_ack;
reg [31:0] guest_bar0_lo, guest_bar0_hi, guest_bar0_size, guest_bar0_ctrl;
reg [31:0] proxy_ctrl;
reg [31:0] mbx_bar_resp_data_lo, mbx_bar_resp_data_hi;
reg [31:0] mbx_bar_resp_seq, mbx_bar_resp_ctrl;
reg        mbx_bar_resp_toggle_seen;
reg        mbx_bar_resp_pending;
reg        mbx_aw_pending;
reg [31:0] mbx_awaddr_hold;
reg        mbx_w_pending;
reg [31:0] mbx_wdata_hold;
reg [3:0]  mbx_wstrb_hold;
reg        intx_level;
reg [31:0] intx_count;

reg [1:0]  ecam_r_state;
reg        ecam_w_state;
reg [31:0] ecam_write_seq;
reg        ecam_aw_pending;
reg [31:0] ecam_awaddr_hold;
reg        ecam_w_pending;
reg [31:0] ecam_wdata_hold;
reg [3:0]  ecam_wstrb_hold;

reg [1:0]  mmio_state;
reg [31:0] mmio_active_seq;
reg [31:0] mmio_active_flags;
reg [31:0] mmio_active_off;
reg [63:0] mmio_active_addr;
reg        mmio_active_done_req;
reg        mmio_aw_pending;
reg [63:0] mmio_awaddr_hold;
reg [7:0]  mmio_awlen_hold;
reg [2:0]  mmio_awsize_hold;
reg        mmio_w_pending;
reg [127:0] mmio_wdata_hold;
reg [15:0]  mmio_wstrb_hold;
reg          mmio_wlast_hold;
reg [63:0] mmio_wlane;
reg [7:0]  mmio_wstrb8;
reg        bar_done_pending;
reg [31:0] bar_done_flags;
reg [31:0] bar_done_seq;
reg [31:0] bar_done_off;

assign interrupt_out = intx_level;

assign m_ecam_shadow_axi_awaddr = 32'd0;
assign m_ecam_shadow_axi_awprot = 3'd0;
assign m_ecam_shadow_axi_awvalid = 1'b0;
assign m_ecam_shadow_axi_wdata = 32'd0;
assign m_ecam_shadow_axi_wstrb = 4'd0;
assign m_ecam_shadow_axi_wvalid = 1'b0;
assign m_ecam_shadow_axi_bready = 1'b1;

assign s_ecam_axi_awready = !rst && (ecam_w_state == ECAM_W_IDLE) &&
                            !s_ecam_axi_bvalid && !ecam_aw_pending;
assign s_ecam_axi_wready  = !rst && (ecam_w_state == ECAM_W_IDLE) &&
                            !s_ecam_axi_bvalid && !ecam_w_pending;
assign s_ecam_axi_arready = !rst && (ecam_r_state == ECAM_R_IDLE) &&
                            !s_ecam_axi_rvalid && !m_ecam_shadow_axi_arvalid &&
                            !m_ecam_shadow_axi_rready;

assign s_mbx_axi_awready = !rst && !s_mbx_axi_bvalid && !mbx_aw_pending;
assign s_mbx_axi_wready  = !rst && !s_mbx_axi_bvalid && !mbx_w_pending;
assign s_mbx_axi_arready = !rst && !s_mbx_axi_rvalid;

assign s_mmio_axi_awready = !rst && (mmio_state == MMIO_IDLE) &&
                            !s_mmio_axi_bvalid && !m_axis_c2h_tvalid &&
                            !mmio_aw_pending;
assign s_mmio_axi_wready  = !rst && (mmio_state == MMIO_IDLE) &&
                            !s_mmio_axi_bvalid && !m_axis_c2h_tvalid &&
                            !mmio_w_pending;
assign s_mmio_axi_arready = !rst && (mmio_state == MMIO_IDLE) &&
                            !s_mmio_axi_rvalid && !m_axis_c2h_tvalid &&
                            !mmio_aw_pending && !mmio_w_pending &&
                            !bar_done_pending;

function [31:0] apply_wstrb32;
    input [31:0] oldv;
    input [31:0] newv;
    input [3:0]  strb;
    begin
        apply_wstrb32 = oldv;
        if (strb[0]) apply_wstrb32[7:0]   = newv[7:0];
        if (strb[1]) apply_wstrb32[15:8]  = newv[15:8];
        if (strb[2]) apply_wstrb32[23:16] = newv[23:16];
        if (strb[3]) apply_wstrb32[31:24] = newv[31:24];
    end
endfunction

function [31:0] make_flags;
    input [15:0] bdf;
    input [2:0] bar;
    input [3:0] size;
    input [7:0] wstrb;
    begin
        make_flags = {wstrb, size, 1'b0, bar, bdf};
    end
endfunction

function [3:0] axsize_to_pkt_size;
    input [2:0] axsize;
    begin
        case (axsize)
        3'd0: axsize_to_pkt_size = 4'd1;
        3'd1: axsize_to_pkt_size = 4'd2;
        3'd2: axsize_to_pkt_size = 4'd4;
        3'd3: axsize_to_pkt_size = 4'd8;
        default: axsize_to_pkt_size = 4'd0;
        endcase
    end
endfunction

function [15:0] ecam_bdf;
    input [31:0] addr;
    reg [27:0] rel;
    begin
        rel = addr[27:0] - ECAM_BASE[27:0];
        ecam_bdf = {rel[27:20], rel[19:15], rel[14:12]};
    end
endfunction

function [31:0] ecam_reg_off;
    input [31:0] addr;
    reg [27:0] rel;
    begin
        rel = addr[27:0] - ECAM_BASE[27:0];
        ecam_reg_off = {20'd0, rel[11:0]};
    end
endfunction

function ecam_bdf_supported;
    input [15:0] bdf;
    begin
        ecam_bdf_supported = (bdf == BDF_ROOT_PORT) ||
                             (bdf == BDF_SW_UP) ||
                             (bdf == BDF_SW_DOWN) ||
                             (bdf == BDF_NVME);
    end
endfunction

function [1:0] ecam_bdf_slot;
    input [15:0] bdf;
    begin
        case (bdf)
        BDF_ROOT_PORT: ecam_bdf_slot = 2'd0;
        BDF_SW_UP:     ecam_bdf_slot = 2'd1;
        BDF_SW_DOWN:   ecam_bdf_slot = 2'd2;
        BDF_NVME:      ecam_bdf_slot = 2'd3;
        default:       ecam_bdf_slot = 2'd0;
        endcase
    end
endfunction

function [31:0] ecam_shadow_offset;
    input [31:0] addr;
    reg [31:0] off;
    begin
        off = ecam_reg_off(addr);
        ecam_shadow_offset = {18'd0, ecam_bdf_slot(ecam_bdf(addr)), off[11:0]};
    end
endfunction

function [31:0] mbx_read32;
    input [31:0] addr;
    begin
        case (addr[11:0])
        12'h010: mbx_read32 = mbx_ack;
        12'h020: mbx_read32 = guest_bar0_lo;
        12'h024: mbx_read32 = guest_bar0_hi;
        12'h028: mbx_read32 = guest_bar0_size;
        12'h02c: mbx_read32 = guest_bar0_ctrl;
        12'h030: mbx_read32 = proxy_ctrl;
        12'h034: mbx_read32 = mbx_bar_resp_data_lo;
        12'h038: mbx_read32 = mbx_bar_resp_seq;
        12'h03c: mbx_read32 = mbx_bar_resp_ctrl;
        12'h04c: mbx_read32 = mbx_bar_resp_data_hi;
        12'h050: mbx_read32 = {31'd0, intx_level};
        12'h054: mbx_read32 = {30'd0, intx_level, intx_level};
        12'h058: mbx_read32 = intx_count;
        default: mbx_read32 = 32'h0000_0000;
        endcase
    end
endfunction

function nvme_bar_hit;
    input [63:0] addr;
    reg [63:0] bar_base;
    reg [63:0] bar_limit;
    begin
        bar_base = {guest_bar0_hi, guest_bar0_lo};
        bar_limit = bar_base + {32'd0, guest_bar0_size};
        nvme_bar_hit = proxy_ctrl[PROXY_CTRL_BAR_ROUTE_READY] &&
                       guest_bar0_ctrl[GUEST_BAR0_CTRL_VALID] &&
                       guest_bar0_ctrl[GUEST_BAR0_CTRL_MEM_ENABLE] &&
                       (guest_bar0_size != 32'd0) &&
                       (bar_limit > bar_base) &&
                       (addr >= bar_base) &&
                       (addr < bar_limit);
    end
endfunction

function [63:0] pick_wlane64;
    input [63:0] addr;
    input [127:0] data;
    begin
        pick_wlane64 = addr[3] ? data[127:64] : data[63:0];
    end
endfunction

function [7:0] pick_wstrb8;
    input [63:0] addr;
    input [15:0] strb;
    begin
        pick_wstrb8 = addr[3] ? strb[15:8] : strb[7:0];
    end
endfunction

function [127:0] place_rlane64;
    input [63:0] addr;
    input [31:0] data_lo;
    input [31:0] data_hi;
    begin
        place_rlane64 = addr[3] ? {{data_hi, data_lo}, 64'd0} :
                                  {64'd0, data_hi, data_lo};
    end
endfunction

function [31:0] bar_offset32;
    input [63:0] addr;
    reg [63:0] bar_base;
    begin
        bar_base = {guest_bar0_hi, guest_bar0_lo};
        bar_offset32 = (addr - bar_base) & 32'hffff_ffff;
    end
endfunction

task send_packet;
    input [31:0] typ;
    input [31:0] flags;
    input [31:0] seq;
    input [31:0] off;
    input [31:0] data_lo;
    input [31:0] data_hi;
    begin
        m_axis_c2h_tdata <= {256'd0, data_hi, data_lo, off, seq, PKT_LEN, flags, typ, DMA32_PKT_MAGIC};
        m_axis_c2h_tkeep <= 64'h0000_0000_ffff_ffff;
        m_axis_c2h_tlast <= 1'b1;
        m_axis_c2h_tvalid <= 1'b1;
    end
endtask

always @(posedge clk) begin
    if (rst) begin
        seq_counter <= 32'd0;
        mbx_ack <= 32'd0;
        guest_bar0_lo <= MMIO_BASE;
        guest_bar0_hi <= 32'd0;
        guest_bar0_size <= 32'd0;
        guest_bar0_ctrl <= 32'd0;
        proxy_ctrl <= 32'd0;
        mbx_bar_resp_data_lo <= 32'd0;
        mbx_bar_resp_data_hi <= 32'd0;
        mbx_bar_resp_seq <= 32'd0;
        mbx_bar_resp_ctrl <= 32'd0;
        mbx_bar_resp_toggle_seen <= 1'b0;
        mbx_bar_resp_pending <= 1'b0;
        mbx_aw_pending <= 1'b0;
        mbx_awaddr_hold <= 32'd0;
        mbx_w_pending <= 1'b0;
        mbx_wdata_hold <= 32'd0;
        mbx_wstrb_hold <= 4'd0;
        intx_level <= 1'b0;
        intx_count <= 32'd0;
        ecam_r_state <= ECAM_R_IDLE;
        ecam_w_state <= ECAM_W_IDLE;
        ecam_write_seq <= 32'd0;
        ecam_aw_pending <= 1'b0;
        ecam_awaddr_hold <= 32'd0;
        ecam_w_pending <= 1'b0;
        ecam_wdata_hold <= 32'd0;
        ecam_wstrb_hold <= 4'd0;
        mmio_state <= MMIO_IDLE;
        mmio_active_seq <= 32'd0;
        mmio_active_flags <= 32'd0;
        mmio_active_off <= 32'd0;
        mmio_active_addr <= 64'd0;
        mmio_active_done_req <= 1'b0;
        mmio_aw_pending <= 1'b0;
        mmio_awaddr_hold <= 64'd0;
        mmio_awlen_hold <= 8'd0;
        mmio_awsize_hold <= 3'd0;
        mmio_w_pending <= 1'b0;
        mmio_wdata_hold <= 128'd0;
        mmio_wstrb_hold <= 16'd0;
        mmio_wlast_hold <= 1'b0;
        mmio_wlane <= 64'd0;
        mmio_wstrb8 <= 8'd0;
        bar_done_pending <= 1'b0;
        bar_done_flags <= 32'd0;
        bar_done_seq <= 32'd0;
        bar_done_off <= 32'd0;
        s_ecam_axi_bresp <= AXI_OKAY;
        s_ecam_axi_bvalid <= 1'b0;
        s_ecam_axi_rdata <= 32'd0;
        s_ecam_axi_rresp <= AXI_OKAY;
        s_ecam_axi_rvalid <= 1'b0;
        m_ecam_shadow_axi_araddr <= 32'd0;
        m_ecam_shadow_axi_arprot <= 3'd0;
        m_ecam_shadow_axi_arvalid <= 1'b0;
        m_ecam_shadow_axi_rready <= 1'b0;
        s_mbx_axi_bresp <= AXI_OKAY;
        s_mbx_axi_bvalid <= 1'b0;
        s_mbx_axi_rdata <= 32'd0;
        s_mbx_axi_rresp <= AXI_OKAY;
        s_mbx_axi_rvalid <= 1'b0;
        s_mmio_axi_bresp <= AXI_OKAY;
        s_mmio_axi_bvalid <= 1'b0;
        s_mmio_axi_rdata <= 128'd0;
        s_mmio_axi_rresp <= AXI_OKAY;
        s_mmio_axi_rlast <= 1'b0;
        s_mmio_axi_rvalid <= 1'b0;
        m_axis_c2h_tdata <= 512'd0;
        m_axis_c2h_tkeep <= 64'd0;
        m_axis_c2h_tlast <= 1'b0;
        m_axis_c2h_tvalid <= 1'b0;
    end else begin
        if (m_axis_c2h_tvalid && m_axis_c2h_tready) begin
            m_axis_c2h_tvalid <= 1'b0;
        end
        if (s_ecam_axi_bvalid && s_ecam_axi_bready) s_ecam_axi_bvalid <= 1'b0;
        if (s_ecam_axi_rvalid && s_ecam_axi_rready) s_ecam_axi_rvalid <= 1'b0;
        if (s_mbx_axi_bvalid && s_mbx_axi_bready) s_mbx_axi_bvalid <= 1'b0;
        if (s_mbx_axi_rvalid && s_mbx_axi_rready) s_mbx_axi_rvalid <= 1'b0;
        if (s_mmio_axi_bvalid && s_mmio_axi_bready) begin
            s_mmio_axi_bvalid <= 1'b0;
            if (mmio_state == MMIO_WAIT_WR) begin
                if (mmio_active_done_req) begin
                    bar_done_pending <= 1'b1;
                    bar_done_flags <= mmio_active_flags;
                    bar_done_seq <= mmio_active_seq;
                    bar_done_off <= mmio_active_off;
                    mmio_state <= MMIO_DONE_PKT;
                end else begin
                    mmio_state <= MMIO_IDLE;
                end
            end
        end
        if (s_mmio_axi_rvalid && s_mmio_axi_rready) begin
            s_mmio_axi_rvalid <= 1'b0;
            if (mmio_state == MMIO_WAIT_RD) mmio_state <= MMIO_IDLE;
        end
        if (bar_done_pending && !m_axis_c2h_tvalid) begin
            send_packet(PKT_BAR_WRITE_DONE, bar_done_flags,
                        bar_done_seq, bar_done_off, 32'd0, 32'd0);
            bar_done_pending <= 1'b0;
            if (mmio_state == MMIO_DONE_PKT) begin
                mmio_state <= MMIO_IDLE;
            end
        end
        if (mmio_state == MMIO_DONE_PKT && !bar_done_pending && !m_axis_c2h_tvalid) begin
            mmio_state <= MMIO_IDLE;
        end

        case (ecam_r_state)
        ECAM_R_IDLE: begin
            if (s_ecam_axi_arvalid && s_ecam_axi_arready) begin
                if (proxy_ctrl[PROXY_CTRL_ECAM_SHADOW_READY] &&
                    ecam_bdf_supported(ecam_bdf(s_ecam_axi_araddr))) begin
                    m_ecam_shadow_axi_araddr <= ecam_shadow_offset(s_ecam_axi_araddr);
                    m_ecam_shadow_axi_arprot <= s_ecam_axi_arprot;
                    m_ecam_shadow_axi_arvalid <= 1'b1;
                    ecam_r_state <= ECAM_R_WAIT_AR;
                end else begin
                    s_ecam_axi_rdata <= 32'hffff_ffff;
                    s_ecam_axi_rresp <= AXI_OKAY;
                    s_ecam_axi_rvalid <= 1'b1;
                end
            end
        end
        ECAM_R_WAIT_AR: begin
            if (m_ecam_shadow_axi_arvalid && m_ecam_shadow_axi_arready) begin
                m_ecam_shadow_axi_arvalid <= 1'b0;
                m_ecam_shadow_axi_rready <= 1'b1;
                ecam_r_state <= ECAM_R_WAIT_R;
            end
        end
        ECAM_R_WAIT_R: begin
            if (m_ecam_shadow_axi_rvalid && m_ecam_shadow_axi_rready) begin
                m_ecam_shadow_axi_rready <= 1'b0;
                s_ecam_axi_rdata <= m_ecam_shadow_axi_rdata;
                s_ecam_axi_rresp <= m_ecam_shadow_axi_rresp;
                s_ecam_axi_rvalid <= 1'b1;
                ecam_r_state <= ECAM_R_IDLE;
            end
        end
        default: ecam_r_state <= ECAM_R_IDLE;
        endcase

        case (ecam_w_state)
        ECAM_W_IDLE: begin
            if (s_ecam_axi_awvalid && s_ecam_axi_awready) begin
                ecam_aw_pending <= 1'b1;
                ecam_awaddr_hold <= s_ecam_axi_awaddr;
            end
            if (s_ecam_axi_wvalid && s_ecam_axi_wready) begin
                ecam_w_pending <= 1'b1;
                ecam_wdata_hold <= s_ecam_axi_wdata;
                ecam_wstrb_hold <= s_ecam_axi_wstrb;
            end
            if (ecam_aw_pending && ecam_w_pending && !m_axis_c2h_tvalid && !bar_done_pending) begin
                ecam_aw_pending <= 1'b0;
                ecam_w_pending <= 1'b0;
                if (ecam_bdf_supported(ecam_bdf(ecam_awaddr_hold))) begin
                    seq_counter <= seq_counter + 1'b1;
                    ecam_write_seq <= seq_counter + 1'b1;
                    send_packet(PKT_CFG_WRITE,
                                make_flags(ecam_bdf(ecam_awaddr_hold),
                                           BAR_TAG_CFG, 4'd4, {4'd0, ecam_wstrb_hold}),
                                seq_counter + 1'b1,
                                ecam_reg_off(ecam_awaddr_hold),
                                ecam_wdata_hold, 32'd0);
                    ecam_w_state <= ECAM_W_WAIT_ACK;
                end else begin
                    s_ecam_axi_bresp <= AXI_OKAY;
                    s_ecam_axi_bvalid <= 1'b1;
                end
            end
        end
        ECAM_W_WAIT_ACK: begin
            if (mbx_ack == ecam_write_seq) begin
                s_ecam_axi_bresp <= AXI_OKAY;
                s_ecam_axi_bvalid <= 1'b1;
                ecam_w_state <= ECAM_W_IDLE;
            end
        end
        default: ecam_w_state <= ECAM_W_IDLE;
        endcase

        if (s_mbx_axi_awvalid && s_mbx_axi_awready) begin
            mbx_aw_pending <= 1'b1;
            mbx_awaddr_hold <= s_mbx_axi_awaddr;
        end
        if (s_mbx_axi_wvalid && s_mbx_axi_wready) begin
            mbx_w_pending <= 1'b1;
            mbx_wdata_hold <= s_mbx_axi_wdata;
            mbx_wstrb_hold <= s_mbx_axi_wstrb;
        end
        if (mbx_aw_pending && mbx_w_pending && !s_mbx_axi_bvalid) begin
            mbx_aw_pending <= 1'b0;
            mbx_w_pending <= 1'b0;
            case (mbx_awaddr_hold[11:0])
            12'h010: mbx_ack <= mbx_wdata_hold;
            12'h020: guest_bar0_lo <= apply_wstrb32(guest_bar0_lo, mbx_wdata_hold, mbx_wstrb_hold);
            12'h024: guest_bar0_hi <= apply_wstrb32(guest_bar0_hi, mbx_wdata_hold, mbx_wstrb_hold);
            12'h028: guest_bar0_size <= apply_wstrb32(guest_bar0_size, mbx_wdata_hold, mbx_wstrb_hold);
            12'h02c: guest_bar0_ctrl <= apply_wstrb32(guest_bar0_ctrl, mbx_wdata_hold, mbx_wstrb_hold);
            12'h030: proxy_ctrl <= apply_wstrb32(proxy_ctrl, mbx_wdata_hold, mbx_wstrb_hold);
            12'h034: mbx_bar_resp_data_lo <= mbx_wdata_hold;
            12'h038: mbx_bar_resp_seq <= mbx_wdata_hold;
            12'h03c: begin
                mbx_bar_resp_ctrl <= mbx_wdata_hold;
                if (mbx_wdata_hold[2] != mbx_bar_resp_toggle_seen) begin
                    mbx_bar_resp_toggle_seen <= mbx_wdata_hold[2];
                    mbx_bar_resp_pending <= 1'b1;
                end
            end
            12'h04c: mbx_bar_resp_data_hi <= mbx_wdata_hold;
            12'h050: begin
                if (!intx_level && mbx_wdata_hold[0]) intx_count <= intx_count + 1'b1;
                intx_level <= mbx_wdata_hold[0];
            end
            default: begin end
            endcase
            s_mbx_axi_bresp <= AXI_OKAY;
            s_mbx_axi_bvalid <= 1'b1;
        end
        if (s_mbx_axi_arvalid && s_mbx_axi_arready) begin
            s_mbx_axi_rdata <= mbx_read32(s_mbx_axi_araddr);
            s_mbx_axi_rresp <= AXI_OKAY;
            s_mbx_axi_rvalid <= 1'b1;
        end

        if (s_mmio_axi_awvalid && s_mmio_axi_awready) begin
            mmio_aw_pending <= 1'b1;
            mmio_awaddr_hold <= s_mmio_axi_awaddr;
            mmio_awlen_hold <= s_mmio_axi_awlen;
            mmio_awsize_hold <= s_mmio_axi_awsize;
        end
        if (s_mmio_axi_wvalid && s_mmio_axi_wready) begin
            mmio_w_pending <= 1'b1;
            mmio_wdata_hold <= s_mmio_axi_wdata;
            mmio_wstrb_hold <= s_mmio_axi_wstrb;
            mmio_wlast_hold <= s_mmio_axi_wlast;
        end
        if (mmio_state == MMIO_IDLE && mmio_aw_pending && mmio_w_pending &&
            !s_mmio_axi_bvalid && !m_axis_c2h_tvalid && !bar_done_pending) begin
            mmio_aw_pending <= 1'b0;
            mmio_w_pending <= 1'b0;
            if (nvme_bar_hit(mmio_awaddr_hold) &&
                (mmio_awlen_hold == 8'd0) &&
                mmio_wlast_hold &&
                (axsize_to_pkt_size(mmio_awsize_hold) != 4'd0)) begin
                mmio_wlane = pick_wlane64(mmio_awaddr_hold, mmio_wdata_hold);
                mmio_wstrb8 = pick_wstrb8(mmio_awaddr_hold, mmio_wstrb_hold);
                seq_counter <= seq_counter + 1'b1;
                mmio_active_seq <= seq_counter + 1'b1;
                mmio_active_flags <= make_flags(BDF_NVME, 3'd0,
                                                axsize_to_pkt_size(mmio_awsize_hold),
                                                mmio_wstrb8);
                mmio_active_off <= bar_offset32(mmio_awaddr_hold);
                mmio_active_addr <= mmio_awaddr_hold;
                mmio_active_done_req <= 1'b0;
                send_packet(PKT_BAR_WRITE,
                            make_flags(BDF_NVME, 3'd0,
                                       axsize_to_pkt_size(mmio_awsize_hold),
                                       mmio_wstrb8),
                            seq_counter + 1'b1,
                            bar_offset32(mmio_awaddr_hold),
                            mmio_wlane[31:0], mmio_wlane[63:32]);
                mmio_state <= MMIO_WAIT_WR;
            end else begin
                s_mmio_axi_bresp <= nvme_bar_hit(mmio_awaddr_hold) ? AXI_SLVERR : AXI_OKAY;
                s_mmio_axi_bvalid <= 1'b1;
            end
        end
        if (s_mmio_axi_arvalid && s_mmio_axi_arready && !bar_done_pending) begin
            if (nvme_bar_hit(s_mmio_axi_araddr) &&
                (s_mmio_axi_arlen == 8'd0) &&
                (axsize_to_pkt_size(s_mmio_axi_arsize) != 4'd0)) begin
                seq_counter <= seq_counter + 1'b1;
                mmio_active_seq <= seq_counter + 1'b1;
                mmio_active_flags <= make_flags(BDF_NVME, 3'd0,
                                                axsize_to_pkt_size(s_mmio_axi_arsize), 8'd0);
                mmio_active_off <= bar_offset32(s_mmio_axi_araddr);
                mmio_active_addr <= s_mmio_axi_araddr;
                send_packet(PKT_BAR_READ,
                            make_flags(BDF_NVME, 3'd0,
                                       axsize_to_pkt_size(s_mmio_axi_arsize), 8'd0),
                            seq_counter + 1'b1,
                            bar_offset32(s_mmio_axi_araddr),
                            32'd0, 32'd0);
                mmio_state <= MMIO_WAIT_RD;
            end else begin
                s_mmio_axi_rdata <= {4{32'hffff_ffff}};
                s_mmio_axi_rresp <= nvme_bar_hit(s_mmio_axi_araddr) ? AXI_SLVERR : AXI_OKAY;
                s_mmio_axi_rlast <= 1'b1;
                s_mmio_axi_rvalid <= 1'b1;
            end
        end

        if (mbx_bar_resp_pending && (mbx_bar_resp_seq == mmio_active_seq)) begin
            if (mmio_state == MMIO_WAIT_WR && !s_mmio_axi_bvalid) begin
                s_mmio_axi_bresp <= mbx_bar_resp_ctrl[1:0];
                s_mmio_axi_bvalid <= 1'b1;
                mmio_active_done_req <= mbx_bar_resp_ctrl[3];
                mbx_bar_resp_pending <= 1'b0;
            end else if (mmio_state == MMIO_WAIT_RD && !s_mmio_axi_rvalid) begin
                s_mmio_axi_rdata <= place_rlane64(mmio_active_addr,
                                                   mbx_bar_resp_data_lo,
                                                   mbx_bar_resp_data_hi);
                s_mmio_axi_rresp <= mbx_bar_resp_ctrl[1:0];
                s_mmio_axi_rlast <= 1'b1;
                s_mmio_axi_rvalid <= 1'b1;
                mbx_bar_resp_pending <= 1'b0;
            end
        end
    end
end

endmodule
