// SPDX-License-Identifier: GPL-2.0-or-later
`timescale 1ns / 1ps
module tb_bar_packet_fifo;
    reg clk = 0;
    always #5 clk = ~clk;
    reg resetn = 0;
    reg [511:0] data = 0;
    reg valid = 0;
    wire ready;
    reg [11:0] awaddr = 0, araddr = 0;
    reg awvalid = 0, wvalid = 0, arvalid = 0;
    reg [31:0] wdata = 0;
    reg [3:0] wstrb = 4'hf;
    wire awready, wready, arready;
    wire [1:0] bresp, rresp;
    wire bvalid, rvalid;
    reg bready = 0, rready = 0;
    wire [31:0] rdata;
    integer i;

    scope_bar_packet_fifo #(.DEPTH(4)) dut (
        .aclk(clk), .aresetn(resetn),
        .s_axis_tdata(data), .s_axis_tkeep(64'hffffffff),
        .s_axis_tlast(1'b1), .s_axis_tvalid(valid), .s_axis_tready(ready),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b0),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b0),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready)
    );
    task push(input integer sequence_number);
        @(negedge clk);
        for (integer word_index = 0; word_index < 8; word_index++)
            data[word_index*32 +: 32] = sequence_number * 16 + word_index;
        valid = 1;
        @(posedge clk);
        while (!ready) @(posedge clk);
        @(negedge clk);
        valid = 0;
    endtask
    task read_check(input [11:0] address, input [31:0] expected,
                    input [1:0] response);
        @(negedge clk);
        araddr = address;
        arvalid = 1;
        @(posedge clk);
        while (!arready) @(posedge clk);
        @(negedge clk);
        arvalid = 0;
        while (!rvalid) @(negedge clk);
        repeat (3) begin
            if (rdata !== expected || rresp !== response)
                $fatal(1, "read %h expected=%h actual=%h resp=%h", address,
                       expected, rdata, rresp);
            @(negedge clk); // response must survive backpressure
        end
        rready = 1;
        @(negedge clk);
        rready = 0;
    endtask
    task pop_check(input [31:0] token, input bit data_first,
                   input [1:0] response);
        @(negedge clk);
        awaddr = 12'h010;
        wdata = token;
        if (data_first) wvalid = 1; else awvalid = 1;
        @(negedge clk);
        awvalid = 0;
        wvalid = 0;
        repeat (2) @(negedge clk);
        if (data_first) awvalid = 1; else wvalid = 1;
        @(negedge clk);
        awvalid = 0;
        wvalid = 0;
        while (!bvalid) @(negedge clk);
        repeat (3) begin
            if (bresp !== response) $fatal(1, "POP response %h", bresp);
            @(negedge clk);
        end
        bready = 1;
        @(negedge clk);
        bready = 0;
    endtask
    initial begin
        #100000 $fatal(1, "watchdog timeout");
    end
    initial begin
        repeat (3) @(negedge clk);
        resetn = 1;
        read_check(12'h000, 32'h53465131, 0);
        read_check(12'h004, 4, 0);
        read_check(12'h014, 0, 0); // never claim unimplemented coherency
        read_check(12'h008, 0, 0);
        pop_check(1, 1, 2); // empty POP rejected
        for (i = 1; i <= 4; i++) push(i);
        if (ready) $fatal(1, "full FIFO must backpressure");
        read_check(12'h008, 4, 0);
        for (i = 0; i < 8; i++) read_check(12'h020 + i*4, 16 + i, 0);
        pop_check(99, 0, 2); // wrong ticket must not consume
        read_check(12'h00c, 1, 0);
        wstrb = 1;
        pop_check(1, 1, 2); // partial POP rejected
        wstrb = 15;
        pop_check(1, 0, 0);
        pop_check(1, 1, 2); // repeated POP cannot drop the next packet
        push(5); // wrap the write pointer
        for (i = 2; i <= 5; i++) begin
            read_check(12'h00c, i, 0);
            read_check(12'h020, i*16, 0);
            pop_check(i, i[0], 0);
        end
        read_check(12'h008, 0, 0);
        read_check(12'h020, 0, 0);
        read_check(12'h044, 0, 2);
        push(6);
        @(negedge clk);
        resetn = 0;
        repeat (2) @(negedge clk);
        resetn = 1;
        read_check(12'h008, 0, 0);
        read_check(12'h00c, 1, 0);
        $display("PASS: FIFO ordering, wrap, backpressure, split AW/W, reset and stale POP");
        $finish;
    end
endmodule
