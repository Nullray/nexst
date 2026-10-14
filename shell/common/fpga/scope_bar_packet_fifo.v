// SPDX-License-Identifier: GPL-2.0-or-later
// Ordered DMA32 packet transport for QDMA AXI-MM shells. Single host consumer.
`timescale 1ns / 1ps
module scope_bar_packet_fifo #(
    parameter integer DEPTH = 32,
    // Set only after the shell provides a validated coherent DMA ingress.
    parameter integer COHERENT_DMA = 0
) (
    input wire aclk,
    input wire aresetn,
    input wire [511:0] s_axis_tdata,
    input wire [63:0] s_axis_tkeep,
    input wire s_axis_tlast,
    input wire s_axis_tvalid,
    output wire s_axis_tready,
    input wire [11:0] s_axi_awaddr,
    input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid,
    output wire s_axi_awready,
    input wire [31:0] s_axi_wdata,
    input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid,
    output wire s_axi_wready,
    output reg [1:0] s_axi_bresp,
    output reg s_axi_bvalid,
    input wire s_axi_bready,
    input wire [11:0] s_axi_araddr,
    input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid,
    output wire s_axi_arready,
    output reg [31:0] s_axi_rdata,
    output reg [1:0] s_axi_rresp,
    output reg s_axi_rvalid,
    input wire s_axi_rready
);
    localparam integer PTR_BITS = $clog2(DEPTH);
    reg [255:0] packets [0:DEPTH-1];
    reg [PTR_BITS-1:0] rd_ptr, wr_ptr;
    reg [PTR_BITS:0] count;
    reg [31:0] ticket;
    reg aw_pending, w_pending;
    reg [11:0] awaddr;
    reg [31:0] wdata;
    reg [3:0] wstrb;
    wire push = s_axis_tvalid && s_axis_tready;
    wire commit = aw_pending && w_pending && !s_axi_bvalid;
    wire pop = commit && awaddr == 12'h010 && wstrb == 4'hf &&
               count != 0 && wdata == ticket;

    initial begin
        if (DEPTH < 2 || DEPTH > 256 || (DEPTH & (DEPTH-1)) != 0)
            $fatal(1, "FIFO DEPTH must be a power of two in [2,256]");
    end

    assign s_axis_tready = aresetn && count < DEPTH;
    assign s_axi_awready = aresetn && !aw_pending && !s_axi_bvalid;
    assign s_axi_wready = aresetn && !w_pending && !s_axi_bvalid;
    assign s_axi_arready = aresetn && !s_axi_rvalid;

    always @(posedge aclk) begin
        if (!aresetn) begin
            rd_ptr <= 0;
            wr_ptr <= 0;
            count <= 0;
            ticket <= 1;
            aw_pending <= 0;
            w_pending <= 0;
            awaddr <= 0;
            wdata <= 0;
            wstrb <= 0;
            s_axi_bresp <= 0;
            s_axi_bvalid <= 0;
            s_axi_rdata <= 0;
            s_axi_rresp <= 0;
            s_axi_rvalid <= 0;
        end else begin
            if (push) begin
                packets[wr_ptr] <= s_axis_tdata[255:0];
                wr_ptr <= wr_ptr + 1'b1;
`ifndef SYNTHESIS
                if (!s_axis_tlast || s_axis_tkeep != 64'h00000000ffffffff)
                    $fatal(1, "Expected one 32-byte DMA32 packet per AXIS beat");
`endif
            end
            if (pop) begin
                rd_ptr <= rd_ptr + 1'b1;
                ticket <= ticket == 32'hffffffff ? 32'd1 : ticket + 1'b1;
            end
            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase

            if (s_axi_awvalid && s_axi_awready) begin
                aw_pending <= 1;
                awaddr <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_pending <= 1;
                wdata <= s_axi_wdata;
                wstrb <= s_axi_wstrb;
            end
            if (commit) begin
                aw_pending <= 0;
                w_pending <= 0;
                s_axi_bresp <= pop ? 2'b00 : 2'b10;
                s_axi_bvalid <= 1;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 0;
            end

            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1;
                s_axi_rresp <= 2'b00;
                case (s_axi_araddr)
                    12'h000: s_axi_rdata <= 32'h53465131; // SFQ1
                    12'h004: s_axi_rdata <= DEPTH;
                    12'h008: s_axi_rdata <= {{(31-PTR_BITS){1'b0}}, count};
                    12'h00c: s_axi_rdata <= ticket;
                    12'h014: s_axi_rdata <= COHERENT_DMA != 0 ? 32'd1 : 32'd0;
                    default: begin
                        if (s_axi_araddr >= 12'h020 && s_axi_araddr < 12'h040 &&
                            s_axi_araddr[1:0] == 0) begin
                            s_axi_rdata <= count != 0 ?
                                packets[rd_ptr][s_axi_araddr[4:2]*32 +: 32] : 32'd0;
                        end else begin
                            s_axi_rdata <= 0;
                            s_axi_rresp <= 2'b10;
                        end
                    end
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 0;
            end
        end
    end
endmodule
