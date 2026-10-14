`timescale 1ns/1ps
module tb_qdma_notifications;
    reg clk = 0; always #5 clk = ~clk;
    reg rstn = 0;
    reg [511:0] input_data = 0;
    reg input_valid = 0;
    wire input_ready;
    wire [511:0] wire_data;
    wire [63:0] wire_keep;
    wire wire_last, wire_valid, wire_ready;
    reg [11:0] awaddr = 0, araddr = 0;
    reg awvalid = 0, wvalid = 0, arvalid = 0;
    reg [31:0] wdata = 0;
    wire awready, wready, arready, bvalid, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;
    wire [511:0] cmpt_data;
    wire [15:0] dpar;
    wire [1:0] cmpt_size, cmpt_type;
    wire cmpt_valid, marker, no_wrb, user_trig;
    wire [10:0] cmpt_qid;
    wire [2:0] col_idx, err_idx;
    reg cmpt_ready = 0;
    reg qsts_valid = 0;
    reg [7:0] qsts_op = 0;
    reg [63:0] qsts_data = 0;
    reg [12:0] qsts_qid = 0;
    wire ack_toggle;
    integer sent = 0, received = 0, markers = 0;
    reg random_ready = 0;
    reg was_stalled = 0;
    reg [511:0] stalled_data;

    scope_qdma_control ctrl (
        .aclk(clk), .aresetn(rstn),
        .s_axis_tdata(input_data), .s_axis_tkeep(64'hffffffff),
        .s_axis_tlast(1'b1), .s_axis_tvalid(input_valid), .s_axis_tready(input_ready),
        .m_axis_tdata(wire_data), .m_axis_tkeep(wire_keep),
        .m_axis_tlast(wire_last), .m_axis_tvalid(wire_valid), .m_axis_tready(wire_ready),
        .flush_ack_toggle(ack_toggle),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hf), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(1'b1),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(1'b1)
    );
    scope_qdma_cmpt adapter (
        .aclk(clk), .aresetn(rstn), .s_axis_tdata(wire_data), .s_axis_tkeep(wire_keep),
        .s_axis_tlast(wire_last), .s_axis_tvalid(wire_valid), .s_axis_tready(wire_ready),
        .cmpt_tdata(cmpt_data), .cmpt_size(cmpt_size), .cmpt_dpar(dpar),
        .cmpt_tvalid(cmpt_valid), .cmpt_tready(cmpt_ready), .cmpt_ctrl_qid(cmpt_qid),
        .cmpt_ctrl_cmpt_type(cmpt_type), .cmpt_ctrl_marker(marker), .cmpt_ctrl_user_trig(user_trig),
        .cmpt_ctrl_col_idx(col_idx), .cmpt_ctrl_err_idx(err_idx), .cmpt_ctrl_no_wrb_marker(no_wrb),
        .qsts_out_op(qsts_op), .qsts_out_data(qsts_data), .qsts_out_qid(qsts_qid),
        .qsts_out_vld(qsts_valid), .flush_ack_toggle(ack_toggle)
    );
    function automatic [255:0] packet(input integer n);
        reg [31:0] flags, seq, offset, kind;
        begin
            flags = 32'hf0400300 | ((n & 1) << 16);
            seq = 1 + n; offset = 'h1000 + n; kind = 1 + (n % 4);
            packet = {32'h87654321, 32'h12345678, offset,
                      seq, 32'd32, flags, kind, 32'h5844504b};
        end
    endfunction
    task write_reg(input [11:0] address, input [31:0] value, input [1:0] response);
        begin
            @(negedge clk); awaddr = address; awvalid = 1;
            do @(posedge clk); while (!awready);
            @(negedge clk); awvalid = 0;
            // Deliberately separate AW and W to verify AXI-Lite independence.
            repeat (2) @(negedge clk);
            wdata = value; wvalid = 1;
            do @(posedge clk); while (!wready);
            @(negedge clk); wvalid = 0;
            wait (bvalid);
            if (bresp != response) $fatal(1, "wrong write response");
            @(negedge clk);
        end
    endtask
    task read_reg(input [11:0] address, input [31:0] value);
        begin
            @(negedge clk); araddr = address; arvalid = 1;
            do @(posedge clk); while (!arready);
            @(negedge clk); arvalid = 0;
            wait (rvalid);
            if (rresp != 0 || rdata != value) $fatal(1, "wrong CSR %h: %h", address, rdata);
            @(negedge clk);
        end
    endtask
    always @(negedge clk) if (random_ready) cmpt_ready = $urandom_range(0, 3) != 0;
    always @(posedge clk) if (rstn) begin
        if (was_stalled && (!cmpt_valid || cmpt_data != stalled_data))
            $fatal(1, "completion changed while backpressured");
        was_stalled <= cmpt_valid && !cmpt_ready;
        stalled_data <= cmpt_data;
        if (cmpt_valid && cmpt_ready) begin
            if (cmpt_size != 3 || cmpt_type != 0 || cmpt_qid != 37 || col_idx != 0 || err_idx != 0)
                $fatal(1, "QDMA metadata mismatch");
            for (integer i = 0; i < 16; i = i + 1)
                if (dpar[i] != (~^cmpt_data[i*32 +: 32])) $fatal(1, "parity error");
            if (marker) begin
                if (!no_wrb || received != sent || cmpt_data[23:8] != 16'h5343)
                    $fatal(1, "flush did not follow accepted notifications");
                markers = markers + 1;
            end else begin
                if (no_wrb || cmpt_data[319:64] != packet(received) || cmpt_data[63:0] != 0 || cmpt_data[511:320] != 0)
                    $fatal(1, "SCOPE packet lost, reordered, duplicated or BAR tag changed");
                received = received + 1;
            end
        end
    end
    initial begin
        #1000000; $fatal(1, "test timed out");
    end
    initial begin
        repeat (4) @(negedge clk); rstn = 1;
        read_reg(0, 32'h53435131); read_reg(4, 1); read_reg(16, 2);
        write_reg(8, 37, 0); write_reg(28, 4, 0); write_reg(12, 1, 0);
        write_reg(8, 38, 2); // cannot reroute a live queue
        @(negedge clk); input_data = {256'd0, packet(0)}; input_valid = 1;
        do @(posedge clk); while (!input_ready);
        sent = sent + 1;
        @(negedge clk); input_valid = 0;
        repeat (20) @(negedge clk);
        if (input_ready) $fatal(1, "full transport did not backpressure source");
        random_ready = 1;
        for (integer n = 1; n < 256; n = n + 1) begin
            if (n % 4 == 0) begin
                wait(received == sent);
                repeat (4) @(negedge clk);
                if (input_ready) $fatal(1, "producer exceeded host ring credits");
                write_reg(32, 5, 2); // cannot return more credits than consumed
                write_reg(32, 4, 0);
            end
            @(negedge clk); input_data = {256'd0, packet(n)}; input_valid = 1;
            do @(posedge clk); while (!input_ready);
            sent = sent + 1;
            @(negedge clk); input_valid = 0;
        end
        write_reg(12, 0, 0);
        wait (markers == 1);
        read_reg(16, 0);
        write_reg(12, 1, 2); // cannot re-enable before actual QDMA marker response
        @(negedge clk); qsts_qid = 37;
        qsts_data = (64'h00534300 << 3) | (64'd1 << 26) | 1; qsts_valid = 1;
        @(negedge clk); qsts_valid = 0;
        repeat (6) @(negedge clk);
        read_reg(16, 0); // an error response must not authorize buffer freeing
        @(negedge clk); qsts_data = (64'h00534300 << 3) | (64'd1 << 26); qsts_valid = 1;
        @(negedge clk); qsts_valid = 0;
        repeat (6) @(negedge clk);
        read_reg(16, 2); read_reg(24, 256);
        if (received != 256) $fatal(1, "notification count mismatch");
        $display("PASS: all four SCOPE packet types, BAR tags, order, backpressure, parity and ordered shutdown");
        $finish;
    end
endmodule
