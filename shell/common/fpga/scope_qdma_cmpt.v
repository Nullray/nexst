// SPDX-License-Identifier: GPL-2.0-or-later
// PG302 v5.1 immediate completions, NO_PLD_NO_WAIT. PCIe clock domain.
`timescale 1ns / 1ps
module scope_qdma_cmpt (
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:cmpt, ASSOCIATED_RESET aresetn" *)
    input wire aclk,
    input wire aresetn,
    input wire [511:0] s_axis_tdata, input wire [63:0] s_axis_tkeep,
    input wire s_axis_tlast, input wire s_axis_tvalid,
    output wire s_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:display_eqdma:s_axis_c2h_cmpt:1.0 cmpt data" *)
    output wire [511:0] cmpt_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:display_eqdma:s_axis_c2h_cmpt:1.0 cmpt size" *)
    output wire [1:0] cmpt_size,
    (* X_INTERFACE_INFO = "xilinx.com:display_eqdma:s_axis_c2h_cmpt:1.0 cmpt dpar" *)
    output wire [15:0] cmpt_dpar,
    (* X_INTERFACE_INFO = "xilinx.com:display_eqdma:s_axis_c2h_cmpt:1.0 cmpt tvalid" *)
    output wire cmpt_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:display_eqdma:s_axis_c2h_cmpt:1.0 cmpt tready" *)
    input wire cmpt_tready,
    (* X_INTERFACE_INFO = "xilinx.com:display_eqdma:s_axis_c2h_cmpt:1.0 cmpt qid" *)
    output wire [10:0] cmpt_ctrl_qid,
    (* X_INTERFACE_INFO = "xilinx.com:display_eqdma:s_axis_c2h_cmpt:1.0 cmpt cmpt_type" *)
    output wire [1:0] cmpt_ctrl_cmpt_type,
    (* X_INTERFACE_INFO = "xilinx.com:display_eqdma:s_axis_c2h_cmpt:1.0 cmpt wait_pld_pkt_id" *)
    output wire [15:0] cmpt_ctrl_wait_pld_pkt_id,
    (* X_INTERFACE_INFO = "xilinx.com:display_eqdma:s_axis_c2h_cmpt:1.0 cmpt port_id" *)
    output wire [2:0] cmpt_ctrl_port_id,
    (* X_INTERFACE_INFO = "xilinx.com:display_eqdma:s_axis_c2h_cmpt:1.0 cmpt marker" *)
    output wire cmpt_ctrl_marker,
    (* X_INTERFACE_INFO = "xilinx.com:display_eqdma:s_axis_c2h_cmpt:1.0 cmpt user_trig" *)
    output wire cmpt_ctrl_user_trig,
    (* X_INTERFACE_INFO = "xilinx.com:display_eqdma:s_axis_c2h_cmpt:1.0 cmpt col_idx" *)
    output wire [2:0] cmpt_ctrl_col_idx,
    (* X_INTERFACE_INFO = "xilinx.com:display_eqdma:s_axis_c2h_cmpt:1.0 cmpt err_idx" *)
    output wire [2:0] cmpt_ctrl_err_idx,
    (* X_INTERFACE_INFO = "xilinx.com:display_eqdma:s_axis_c2h_cmpt:1.0 cmpt no_wrb_marker" *)
    output wire cmpt_ctrl_no_wrb_marker,
    input wire [7:0] qsts_out_op, input wire [63:0] qsts_out_data,
    input wire [12:0] qsts_out_qid, input wire qsts_out_vld,
    output wire qsts_out_rdy, output reg flush_ack_toggle
);
    reg flush_wait;
    reg [10:0] flush_qid;
    wire marker = s_axis_tdata[331];
    // qid and marker are transport metadata, not completion payload.
    assign cmpt_tdata = {192'd0, s_axis_tdata[319:0]};
    assign cmpt_size = 2'b11; // 64 bytes; packet occupies bytes 8..39.
    assign cmpt_tvalid = aresetn && s_axis_tvalid && !flush_wait;
    assign s_axis_tready = aresetn && cmpt_tready && !flush_wait;
    assign cmpt_ctrl_qid = s_axis_tdata[330:320];
    assign cmpt_ctrl_cmpt_type = 2'b00; // NO_PLD_NO_WAIT, no data descriptor
    assign cmpt_ctrl_wait_pld_pkt_id = 0;
    assign cmpt_ctrl_port_id = 0;
    assign cmpt_ctrl_marker = marker;
    assign cmpt_ctrl_user_trig = 1;
    assign cmpt_ctrl_col_idx = 0; // option 0: color at bit 1
    assign cmpt_ctrl_err_idx = 0; // option 0: error at bit 2
    assign cmpt_ctrl_no_wrb_marker = marker; // flush even when host ring is full
    assign qsts_out_rdy = 1;
    genvar i;
    generate for (i = 0; i < 16; i = i + 1) begin : parity
        assign cmpt_dpar[i] = ~^cmpt_tdata[i*32 +: 32];
    end endgenerate
    always @(posedge aclk) begin
        if (!aresetn) begin
            flush_wait <= 0; flush_qid <= 0; flush_ack_toggle <= 0;
        end else begin
            if (cmpt_tvalid && cmpt_tready && marker) begin
                flush_wait <= 1; flush_qid <= cmpt_ctrl_qid;
            end
            if (flush_wait && qsts_out_vld && qsts_out_op == 0 &&
                qsts_out_qid == {2'd0, flush_qid} &&
                qsts_out_data[26] && qsts_out_data[1:0] == 0 &&
                qsts_out_data[25:11] == 15'h5343) begin
                flush_wait <= 0; flush_ack_toggle <= ~flush_ack_toggle;
            end
        end
    end
endmodule
