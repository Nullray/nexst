// SPDX-License-Identifier: GPL-2.0-or-later
// Configure a host notification queue. The host never reads packet data here.
`timescale 1ns / 1ps
module scope_qdma_control #(
    parameter integer COHERENT_DMA = 0
) (
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis:s_axi, ASSOCIATED_RESET aresetn" *)
    input wire aclk,
    input wire aresetn,
    input wire [511:0] s_axis_tdata, input wire [63:0] s_axis_tkeep,
    input wire s_axis_tlast, input wire s_axis_tvalid,
    output wire s_axis_tready,
    output reg [511:0] m_axis_tdata, output wire [63:0] m_axis_tkeep,
    output wire m_axis_tlast, output reg m_axis_tvalid,
    input wire m_axis_tready,
    input wire flush_ack_toggle,
    input wire [11:0] s_axi_awaddr, input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid, output wire s_axi_awready,
    input wire [31:0] s_axi_wdata, input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid, output wire s_axi_wready,
    output reg [1:0] s_axi_bresp, output reg s_axi_bvalid,
    input wire s_axi_bready,
    input wire [11:0] s_axi_araddr, input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid, output wire s_axi_arready,
    output reg [31:0] s_axi_rdata, output reg [1:0] s_axi_rresp,
    output reg s_axi_rvalid, input wire s_axi_rready
);
    reg enabled, flush_pending, flush_wait;
    reg [10:0] qid;
    reg [31:0] accepted;
    reg [31:0] capacity, credits;
    reg aw_pending, w_pending;
    reg [11:0] awaddr;
    reg [31:0] wdata;
    reg [3:0] wstrb;
    (* ASYNC_REG = "TRUE" *) reg ack_meta, ack_sync;
    reg ack_seen;
    wire commit = aw_pending && w_pending && !s_axi_bvalid;
    wire vacant = !m_axis_tvalid || m_axis_tready;
    wire stopping = commit && awaddr == 12'h00c && wstrb == 4'hf && !wdata[0];
    wire input_fire = s_axis_tvalid && s_axis_tready;
    assign s_axis_tready = aresetn && enabled && !stopping && vacant && credits != 0;
    assign m_axis_tkeep = 64'hffffffffffffffff;
    assign m_axis_tlast = 1'b1;
    assign s_axi_awready = aresetn && !aw_pending && !s_axi_bvalid;
    assign s_axi_wready = aresetn && !w_pending && !s_axi_bvalid;
    assign s_axi_arready = aresetn && !s_axi_rvalid;

    always @(posedge aclk) begin
        if (!aresetn) begin
            enabled <= 0; flush_pending <= 0; flush_wait <= 0;
            qid <= 0; accepted <= 0; capacity <= 0; credits <= 0;
            m_axis_tvalid <= 0; m_axis_tdata <= 0;
            ack_meta <= 0; ack_sync <= 0; ack_seen <= 0;
            aw_pending <= 0; w_pending <= 0;
            awaddr <= 0; wdata <= 0; wstrb <= 0;
            s_axi_bvalid <= 0; s_axi_bresp <= 0;
            s_axi_rvalid <= 0; s_axi_rresp <= 0; s_axi_rdata <= 0;
        end else begin
            ack_meta <= flush_ack_toggle; ack_sync <= ack_meta;
            if (input_fire) credits <= credits - 1'b1;
            if (ack_sync != ack_seen) begin
                ack_seen <= ack_sync;
                flush_wait <= 0;
            end
            if (vacant) begin
                m_axis_tvalid <= 0;
                if (flush_pending) begin
                    // Internal bit 331 marks a flush; qid is internal bits 330:320.
                    // Low 24 completion bits identify our no-writeback marker.
                    m_axis_tdata <= {180'd0, 1'b1, qid, 288'd0, 32'h00534300};
                    m_axis_tvalid <= 1;
                    flush_pending <= 0;
                end else if (s_axis_tvalid && s_axis_tready) begin
                    // Reserve the first 8 bytes for QDMA flags; preserve all 32
                    // bytes of the existing SCOPE packet, including its BAR tag.
                    m_axis_tdata <= {181'd0, qid, s_axis_tdata[255:0], 64'd0};
                    m_axis_tvalid <= 1;
                    accepted <= accepted + 1'b1;
`ifndef SYNTHESIS
                    if (!s_axis_tlast || s_axis_tkeep != 64'h00000000ffffffff)
                        $fatal(1, "Expected one 32-byte SCOPE packet");
`endif
                end
            end
            if (s_axi_awvalid && s_axi_awready) begin
                aw_pending <= 1; awaddr <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_pending <= 1; wdata <= s_axi_wdata; wstrb <= s_axi_wstrb;
            end
            if (commit) begin
                aw_pending <= 0; w_pending <= 0;
                s_axi_bvalid <= 1; s_axi_bresp <= 2'b10;
                if (wstrb == 4'hf) begin
                    if (awaddr == 12'h008 && !enabled && !flush_wait && wdata < 2048) begin
                        qid <= wdata[10:0]; s_axi_bresp <= 0;
                    end else if (awaddr == 12'h01c && !enabled && !flush_wait &&
                                 !m_axis_tvalid && wdata >= 3 && wdata <= 65534) begin
                        capacity <= wdata; credits <= wdata; s_axi_bresp <= 0;
                    end else if (awaddr == 12'h020 && wdata != 0 &&
                                 wdata <= capacity - credits) begin
                        // Reserve a host ring slot before accepting a packet,
                        // including all packets in the CDC/FIFO/QDMA pipeline.
                        credits <= credits + wdata - (input_fire ? 1 : 0);
                        s_axi_bresp <= 0;
                    end else if (awaddr == 12'h00c && wdata <= 1 && !flush_wait &&
                                 (!wdata[0] || capacity != 0)) begin
                        s_axi_bresp <= 0;
                        enabled <= wdata[0];
                        if (enabled && !wdata[0]) begin
                            flush_pending <= 1; flush_wait <= 1;
                        end
                    end
                end
            end else if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1; s_axi_rresp <= 0;
                case (s_axi_araddr)
                    12'h000: s_axi_rdata <= 32'h53435131; // SCQ1, not BAR FIFO
                    12'h004: s_axi_rdata <= 1; // ABI version
                    12'h008: s_axi_rdata <= {21'd0, qid};
                    12'h00c: s_axi_rdata <= {31'd0, enabled};
                    12'h010: s_axi_rdata <= {30'd0, !flush_wait, enabled};
                    12'h014: s_axi_rdata <= COHERENT_DMA != 0 ? 1 : 0;
                    12'h018: s_axi_rdata <= accepted;
                    12'h01c: s_axi_rdata <= capacity;
                    12'h020: s_axi_rdata <= credits;
                    default: begin s_axi_rdata <= 0; s_axi_rresp <= 2'b10; end
                endcase
            end else if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
        end
    end
endmodule
