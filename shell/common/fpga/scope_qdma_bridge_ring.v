// SPDX-License-Identifier: GPL-2.0-or-later
// SCOPE notifications -> host coherent RAM through QDMA S_AXI_BRIDGE.
// No Address Translation: every AXI address is the driver's full DMA/IOVA.
// Layout: 64-byte header (u32 producer at +0), N 64-byte slots at +64.
// Each slot contains the original 32-byte SCOPE packet followed by padding.
// A separate ordered write publishes producer only after the payload BRESP.
// STOP performs a PCIe read fence before advertising DRAINED; BRESP alone
// does not prove posted writes have reached host memory.
`timescale 1ns / 1ps
module scope_qdma_bridge_ring #(
    parameter integer COHERENT_DMA = 1
) (
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:s_axi:m_axi, ASSOCIATED_RESET aresetn, FREQ_HZ 250000000" *)
    input wire aclk, input wire aresetn,
    input wire [511:0] s_axis_tdata, input wire [63:0] s_axis_tkeep,
    input wire s_axis_tlast, input wire s_axis_tvalid, output wire s_axis_tready,

    input wire [11:0] s_axi_awaddr, input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid, output wire s_axi_awready,
    input wire [31:0] s_axi_wdata, input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid, output wire s_axi_wready,
    output reg [1:0] s_axi_bresp, output reg s_axi_bvalid, input wire s_axi_bready,
    input wire [11:0] s_axi_araddr, input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid, output wire s_axi_arready,
    output reg [31:0] s_axi_rdata, output reg [1:0] s_axi_rresp,
    output reg s_axi_rvalid, input wire s_axi_rready,

    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi, SUPPORTS_NARROW_BURST 0" *)
    output wire [3:0] m_axi_awid, output wire [63:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen, output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst, output wire m_axi_awlock,
    output wire [3:0] m_axi_awcache, output wire [2:0] m_axi_awprot,
    output wire [3:0] m_axi_awqos, output wire [3:0] m_axi_awregion,
    output wire [11:0] m_axi_awuser,
    output wire m_axi_awvalid, input wire m_axi_awready,
    output wire [511:0] m_axi_wdata, output wire [63:0] m_axi_wstrb,
    output wire [63:0] m_axi_wuser,
    output wire m_axi_wlast, output wire m_axi_wvalid, input wire m_axi_wready,
    input wire [3:0] m_axi_bid, input wire [1:0] m_axi_bresp,
    input wire m_axi_bvalid, output wire m_axi_bready,
    output wire [3:0] m_axi_arid, output wire [63:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen, output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst, output wire m_axi_arlock,
    output wire [3:0] m_axi_arcache, output wire [2:0] m_axi_arprot,
    output wire [3:0] m_axi_arqos, output wire [3:0] m_axi_arregion,
    output wire [11:0] m_axi_aruser,
    output wire m_axi_arvalid, input wire m_axi_arready,
    input wire [3:0] m_axi_rid, input wire [511:0] m_axi_rdata,
    input wire [63:0] m_axi_ruser, input wire [1:0] m_axi_rresp,
    input wire m_axi_rlast, input wire m_axi_rvalid, output wire m_axi_rready
);
    localparam IDLE=0, DATA_SEND=1, DATA_RESP=2, PUBLISH_SEND=3,
               PUBLISH_RESP=4, FENCE_SEND=5, FENCE_RESP=6, FAULT=7;
    reg [2:0] state;
    reg enabled, drained, drain_pending, aw_done, w_done;
    reg [63:0] base;
    reg [31:0] entries, credits, producer, slot, errors, accepted;
    reg [255:0] packet;
    reg aw_pending, w_pending;
    reg [11:0] awaddr;
    reg [31:0] wdata;
    reg [3:0] wstrb;
    wire commit = aw_pending && w_pending && !s_axi_bvalid;
    wire stopping = commit && awaddr == 12'h014 && wstrb == 4'hf && wdata == 0;
    wire input_fire = s_axis_tvalid && s_axis_tready;
    wire configuring = !enabled && drained && state == IDLE && errors == 0;
    wire valid_entries = entries >= 4 && entries <= 65536 && (entries & (entries-1)) == 0;
    wire [63:0] allocation_bytes = 64'd64 + ({32'd0, entries} << 6);
    wire valid_base = base != 0 && base[5:0] == 0 && base <= (64'hffffffffffffffff - allocation_bytes);
    wire sending = state == DATA_SEND || state == PUBLISH_SEND;

    assign s_axis_tready = aresetn && enabled && !stopping && state == IDLE && credits != 0;
    assign s_axi_awready = aresetn && !aw_pending && !s_axi_bvalid;
    assign s_axi_wready = aresetn && !w_pending && !s_axi_bvalid;
    assign s_axi_arready = aresetn && !s_axi_rvalid;
    assign m_axi_awid = 0;
    assign m_axi_awaddr = state == DATA_SEND ? base + 64 + ({32'd0,slot} << 6) : base;
    assign m_axi_awlen = 0;
    assign m_axi_awsize = 6; // full 512-bit AXI beat; no narrow bursts
    assign m_axi_awburst = 1;
    assign m_axi_awlock = 0;
    assign m_axi_awcache = 0;
    assign m_axi_awprot = 0;
    assign m_axi_awqos = 0;
    assign m_axi_awregion = 0;
    assign m_axi_awuser = 0; // PF0 requester/function_number
    assign m_axi_awvalid = aresetn && sending && !aw_done;
    assign m_axi_wdata = state == DATA_SEND ? {256'd0, packet} : {480'd0, producer + 32'd1};
    assign m_axi_wstrb = state == DATA_SEND ? 64'hffffffffffffffff : 64'h000000000000000f;
    assign m_axi_wlast = 1;
    assign m_axi_wvalid = aresetn && sending && !w_done;
    assign m_axi_bready = aresetn && (state == DATA_RESP || state == PUBLISH_RESP);
    assign m_axi_arid = 0;
    assign m_axi_araddr = base;
    assign m_axi_arlen = 0;
    assign m_axi_arsize = 6;
    assign m_axi_arburst = 1;
    assign m_axi_arlock = 0;
    assign m_axi_arcache = 0;
    assign m_axi_arprot = 0;
    assign m_axi_arqos = 0;
    assign m_axi_arregion = 0;
    assign m_axi_aruser = 0;
    assign m_axi_arvalid = aresetn && state == FENCE_SEND;
    assign m_axi_rready = aresetn && state == FENCE_RESP;
    genvar b;
    generate for (b=0; b<64; b=b+1) begin: byte_parity
        assign m_axi_wuser[b] = ~^m_axi_wdata[b*8 +: 8];
    end endgenerate

    always @(posedge aclk) begin
        if (!aresetn) begin
            state <= IDLE; enabled <= 0; drained <= 1; drain_pending <= 0;
            base <= 0; entries <= 0; credits <= 0; producer <= 0; slot <= 0;
            errors <= 0; accepted <= 0; packet <= 0; aw_done <= 0; w_done <= 0;
            aw_pending <= 0; w_pending <= 0; awaddr <= 0; wdata <= 0; wstrb <= 0;
            s_axi_bresp <= 0; s_axi_bvalid <= 0;
            s_axi_rdata <= 0; s_axi_rresp <= 0; s_axi_rvalid <= 0;
        end else begin
            case (state)
                IDLE: begin
                    if (drain_pending) begin
                        state <= FENCE_SEND;
                    end else if (input_fire) begin
                        credits <= credits - 1;
                        packet <= s_axis_tdata[255:0];
                        accepted <= accepted + 1;
                        aw_done <= 0; w_done <= 0;
                        if (s_axis_tkeep != 64'hffffffff || !s_axis_tlast) begin
                            errors <= errors | 8; enabled <= 0; state <= FAULT;
                        end else state <= DATA_SEND;
                    end
                end
                DATA_SEND, PUBLISH_SEND: begin
                    if (m_axi_awvalid && m_axi_awready) aw_done <= 1;
                    if (m_axi_wvalid && m_axi_wready) w_done <= 1;
                    if ((aw_done || m_axi_awready) && (w_done || m_axi_wready))
                        state <= state == DATA_SEND ? DATA_RESP : PUBLISH_RESP;
                end
                DATA_RESP, PUBLISH_RESP: if (m_axi_bvalid) begin
                    if (m_axi_bresp != 0 || m_axi_bid != 0) begin
                        errors <= errors | 1; enabled <= 0; state <= FAULT;
                    end else if (state == DATA_RESP) begin
                        aw_done <= 0; w_done <= 0; state <= PUBLISH_SEND;
                    end else begin
                        producer <= producer + 1;
                        slot <= slot == entries-1 ? 0 : slot+1;
                        state <= IDLE;
                    end
                end
                FENCE_SEND: if (m_axi_arready) state <= FENCE_RESP;
                FENCE_RESP: if (m_axi_rvalid) begin
                    if (m_axi_rresp != 0 || m_axi_rid != 0 || !m_axi_rlast) begin
                        errors <= errors | 2; state <= FAULT;
                    end else if (m_axi_rdata[31:0] != producer) begin
                        errors <= errors | 4; state <= FAULT;
                    end else begin
                        drained <= 1; drain_pending <= 0; state <= IDLE;
                    end
                end
                default: begin enabled <= 0; drained <= 0; end
            endcase
            if (s_axi_awvalid && s_axi_awready) begin aw_pending <= 1; awaddr <= s_axi_awaddr; end
            if (s_axi_wvalid && s_axi_wready) begin w_pending <= 1; wdata <= s_axi_wdata; wstrb <= s_axi_wstrb; end
            if (commit) begin
                aw_pending <= 0; w_pending <= 0;
                s_axi_bvalid <= 1; s_axi_bresp <= 2'b10;
                if (wstrb == 15) begin
                    case (awaddr)
                        12'h008: if (configuring) begin base[31:0] <= wdata; s_axi_bresp <= 0; end
                        12'h00c: if (configuring) begin base[63:32] <= wdata; s_axi_bresp <= 0; end
                        12'h010: if (configuring && wdata >= 4 && wdata <= 65536 && (wdata & (wdata-1)) == 0) begin
                            entries <= wdata; credits <= wdata; producer <= 0; slot <= 0;
                            accepted <= 0; s_axi_bresp <= 0;
                        end
                        12'h014: begin
                            if (wdata == 1 && configuring && valid_base && valid_entries) begin
                                enabled <= 1; drained <= 0; s_axi_bresp <= 0;
                            end else if (wdata == 0 && errors == 0) begin
                                enabled <= 0; s_axi_bresp <= 0;
                                if (!drained) drain_pending <= 1;
                            end
                        end
                        12'h024: if (wdata != 0 && wdata <= entries-credits && errors == 0) begin
                            credits <= credits + wdata - (input_fire ? 1 : 0); s_axi_bresp <= 0;
                        end
                        default: begin end
                    endcase
                end
            end else if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1; s_axi_rresp <= 0;
                case (s_axi_araddr)
                    12'h000: s_axi_rdata <= 32'h53434231; // SCB1
                    12'h004: s_axi_rdata <= 1;
                    12'h008: s_axi_rdata <= base[31:0];
                    12'h00c: s_axi_rdata <= base[63:32];
                    12'h010: s_axi_rdata <= entries;
                    12'h014: s_axi_rdata <= {31'd0, enabled};
                    12'h018: s_axi_rdata <= {28'd0, errors != 0, state != IDLE, drained, enabled};
                    12'h01c: s_axi_rdata <= 2 | (COHERENT_DMA != 0 ? 1 : 0);
                    12'h020: s_axi_rdata <= producer;
                    12'h024: s_axi_rdata <= credits;
                    12'h028: s_axi_rdata <= errors;
                    12'h02c: s_axi_rdata <= accepted;
                    12'h030: s_axi_rdata <= 64;
                    12'h034: s_axi_rdata <= 32;
                    default: begin s_axi_rdata <= 0; s_axi_rresp <= 2'b10; end
                endcase
            end else if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
        end
    end
endmodule
