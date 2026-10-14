`timescale 1ns/1ps
module tb_qdma_bridge_ring;
  reg  aclk;
  reg  aresetn;
  reg [511:0] s_axis_tdata;
  reg [63:0] s_axis_tkeep;
  reg  s_axis_tlast;
  reg  s_axis_tvalid;
  wire  s_axis_tready;
  reg [11:0] s_axi_awaddr;
  reg [2:0] s_axi_awprot;
  reg  s_axi_awvalid;
  wire  s_axi_awready;
  reg [31:0] s_axi_wdata;
  reg [3:0] s_axi_wstrb;
  reg  s_axi_wvalid;
  wire  s_axi_wready;
  wire [1:0] s_axi_bresp;
  wire  s_axi_bvalid;
  reg  s_axi_bready;
  reg [11:0] s_axi_araddr;
  reg [2:0] s_axi_arprot;
  reg  s_axi_arvalid;
  wire  s_axi_arready;
  wire [31:0] s_axi_rdata;
  wire [1:0] s_axi_rresp;
  wire  s_axi_rvalid;
  reg  s_axi_rready;
  wire [3:0] m_axi_awid;
  wire [63:0] m_axi_awaddr;
  wire [7:0] m_axi_awlen;
  wire [2:0] m_axi_awsize;
  wire [1:0] m_axi_awburst;
  wire  m_axi_awlock;
  wire [3:0] m_axi_awcache;
  wire [2:0] m_axi_awprot;
  wire [3:0] m_axi_awqos;
  wire [3:0] m_axi_awregion;
  wire [11:0] m_axi_awuser;
  wire  m_axi_awvalid;
  reg  m_axi_awready;
  wire [511:0] m_axi_wdata;
  wire [63:0] m_axi_wstrb;
  wire [63:0] m_axi_wuser;
  wire  m_axi_wlast;
  wire  m_axi_wvalid;
  reg  m_axi_wready;
  reg [3:0] m_axi_bid;
  reg [1:0] m_axi_bresp;
  reg  m_axi_bvalid;
  wire  m_axi_bready;
  wire [3:0] m_axi_arid;
  wire [63:0] m_axi_araddr;
  wire [7:0] m_axi_arlen;
  wire [2:0] m_axi_arsize;
  wire [1:0] m_axi_arburst;
  wire  m_axi_arlock;
  wire [3:0] m_axi_arcache;
  wire [2:0] m_axi_arprot;
  wire [3:0] m_axi_arqos;
  wire [3:0] m_axi_arregion;
  wire [11:0] m_axi_aruser;
  wire  m_axi_arvalid;
  reg  m_axi_arready;
  reg [3:0] m_axi_rid;
  reg [511:0] m_axi_rdata;
  reg [63:0] m_axi_ruser;
  reg [1:0] m_axi_rresp;
  reg  m_axi_rlast;
  reg  m_axi_rvalid;
  wire  m_axi_rready;
  scope_qdma_bridge_ring dut(.*);
  localparam [63:0] BASE=64'h1234567800000040;
  reg [7:0] mem[0:4095];
  reg have_aw=0,have_w=0;
  reg [63:0] aw_addr=0,w_strb=0;
  reg [511:0] w_data=0;
  reg [63:0] post_addr[0:1023],post_strb[0:1023];
  reg [511:0] post_data[0:1023];
  integer head=0,tail=0,bdelay=0,rdelay=0,seed=32'h12345678;
  integer i,j,k,fences=0,writes=0;
  reg hold_posted=0,read_pending=0,write_error=0,read_error=0;
  reg response_error=0;
  always #2 aclk=~aclk;
  initial begin #2000000;$fatal(1,"timeout state=%d producer=%h",dut.state,dut.producer);end
  // Independent randomized AXI AW/W backpressure and delayed B/R responses.
  // BRESP can precede host RAM visibility. Posted writes reach RAM in order;
  // a read completion waits behind those writes, modelling the PCIe fence.
  always @(posedge aclk) begin
    if (!aresetn) begin
      m_axi_awready<=0;m_axi_wready<=0;m_axi_bvalid<=0;
      m_axi_arready<=0;m_axi_rvalid<=0;m_axi_rdata<=0;m_axi_rresp<=0;m_axi_rlast<=1;
      m_axi_bid<=0;m_axi_bresp<=0;m_axi_rid<=0;m_axi_ruser<=0;
      have_aw<=0;have_w<=0;bdelay<=0;rdelay<=0;read_pending<=0;head<=0;tail<=0;
    end else begin
      m_axi_awready<=!have_aw && !m_axi_bvalid && bdelay==0 && ($urandom(seed)%3!=0);
      m_axi_wready<=!have_w && !m_axi_bvalid && bdelay==0 && ($urandom(seed)%3!=0);
      m_axi_arready<=!read_pending && !m_axi_rvalid && ($urandom(seed)%3!=0);
      if (m_axi_awvalid && m_axi_awready) begin
        if (have_aw || m_axi_awaddr<BASE || m_axi_awaddr>=BASE+320 || m_axi_awaddr[5:0]!=0)
          $fatal(1,"bad/duplicate/full-width AW address %h",m_axi_awaddr);
        if (m_axi_awlen!=0 || m_axi_awsize!=6 || m_axi_awburst!=1 || m_axi_awid!=0 || m_axi_awuser!=0)
          $fatal(1,"invalid QDMA bridge AW fields");
        aw_addr<=m_axi_awaddr;have_aw<=1;
      end
      if (m_axi_wvalid && m_axi_wready) begin
        if (have_w || !m_axi_wlast) $fatal(1,"duplicate W or missing LAST");
        for (j=0;j<64;j=j+1)
          if (m_axi_wuser[j] !== ~^m_axi_wdata[j*8+:8]) $fatal(1,"byte parity");
        w_data<=m_axi_wdata;w_strb<=m_axi_wstrb;have_w<=1;
      end
      if (have_aw && have_w && bdelay==0 && !m_axi_bvalid) begin
        post_addr[tail]<=aw_addr;post_data[tail]<=w_data;post_strb[tail]<=w_strb;
        tail<=tail+1;writes<=writes+1;
        have_aw<=0;have_w<=0;bdelay<=2+($urandom(seed)%5);response_error<=write_error;
      end
      if (bdelay>0) begin
        bdelay<=bdelay-1;
        if (bdelay==1) begin m_axi_bvalid<=1;m_axi_bresp<=response_error?2:0;end
      end
      if (m_axi_bvalid && m_axi_bready)m_axi_bvalid<=0;
      if (head<tail && !hold_posted && ($urandom(seed)%3!=0)) begin
        for (j=0;j<64;j=j+1)
          if (post_strb[head][j])mem[post_addr[head]-BASE+j]<=post_data[head][j*8+:8];
        head<=head+1;
      end
      if (m_axi_arvalid && m_axi_arready) begin
        if (m_axi_araddr!=BASE || m_axi_arlen!=0 || m_axi_arsize!=6 || m_axi_arburst!=1 || m_axi_aruser!=0)
          $fatal(1,"invalid fence request");
        read_pending<=1;fences<=fences+1;rdelay<=3;
      end
      if (read_pending && head==tail) begin
        if (rdelay>0)rdelay<=rdelay-1;
        else begin
          for (j=0;j<64;j=j+1)m_axi_rdata[j*8+:8]<=mem[j];
          m_axi_rresp<=read_error?2:0;m_axi_rvalid<=1;read_pending<=0;
        end
      end
      if (m_axi_rvalid && m_axi_rready)m_axi_rvalid<=0;
    end
  end
  function [31:0] producer;
    producer={mem[3],mem[2],mem[1],mem[0]};
  endfunction
  function [255:0] make_packet(input integer n);
    begin
      make_packet[31:0]=32'h5844504b;
      make_packet[63:32]=32'd32;
      make_packet[95:64]=1+n;
      make_packet[127:96]=1+n%4;
      make_packet[159:128]=32'h08000000|((n%2)<<28);
      make_packet[191:160]=32'h50001234+n;
      make_packet[255:192]=64'h9abcdef012345678^n;
    end
  endfunction
  task wr(input [11:0] addr,input [31:0] data,input [1:0] response);
    reg ad,wd;
    begin
      @(negedge aclk);s_axi_awaddr=addr;s_axi_wdata=data;s_axi_wstrb=15;
      s_axi_awvalid=1;s_axi_wvalid=1;ad=0;wd=0;
      while(!ad || !wd) begin
        @(posedge aclk);if(s_axi_awvalid&&s_axi_awready)ad=1;if(s_axi_wvalid&&s_axi_wready)wd=1;
        @(negedge aclk);if(ad)s_axi_awvalid=0;if(wd)s_axi_wvalid=0;
      end
      while(!s_axi_bvalid)@(negedge aclk);
      if(s_axi_bresp!==response)$fatal(1,"CSR %h response=%d expected=%d",addr,s_axi_bresp,response);
      @(posedge aclk);@(negedge aclk);
    end
  endtask
  task rd(input [11:0] addr,output [31:0] data);
    begin
      @(negedge aclk);s_axi_araddr=addr;s_axi_arvalid=1;
      do @(posedge aclk);while(!s_axi_arready);
      @(negedge aclk);s_axi_arvalid=0;
      while(!s_axi_rvalid)@(negedge aclk);
      data=s_axi_rdata;
      if(s_axi_rresp!=0)$fatal(1,"CSR read error");
      @(posedge aclk);@(negedge aclk);
    end
  endtask
  task send_packet(input integer n);
    begin
      @(negedge aclk);s_axis_tdata={256'd0,make_packet(n)};s_axis_tvalid=1;
      do @(posedge aclk);while(!s_axis_tready);
      @(negedge aclk);s_axis_tvalid=0;
    end
  endtask
  task check_slot(input integer slot_id,input integer n);
    reg [255:0] p;
    begin
      for(k=0;k<32;k=k+1)p[k*8+:8]=mem[64+slot_id*64+k];
      if(p!==make_packet(n))$fatal(1,"packet corruption slot %d got %h expected %h",slot_id,p,make_packet(n));
    end
  endtask
  task reset_all;
    begin
      @(negedge aclk);aresetn=0;s_axi_awvalid=0;s_axi_wvalid=0;s_axi_arvalid=0;s_axis_tvalid=0;
      hold_posted=0;write_error=0;read_error=0;
      for(i=0;i<4096;i=i+1)mem[i]=0;
      repeat(5)@(negedge aclk);aresetn=1;repeat(3)@(negedge aclk);
    end
  endtask
  task configure;
    begin wr(12'h008,BASE[31:0],0);wr(12'h00c,BASE[63:32],0);wr(12'h010,4,0);wr(12'h014,1,0);end
  endtask
  reg [31:0] value;
  initial begin
    aclk=0;aresetn=0;s_axis_tdata=0;s_axis_tkeep=64'hffffffff;s_axis_tlast=1;s_axis_tvalid=0;
    s_axi_awaddr=0;s_axi_awprot=0;s_axi_awvalid=0;s_axi_wdata=0;s_axi_wstrb=0;s_axi_wvalid=0;
    s_axi_bready=1;s_axi_araddr=0;s_axi_arprot=0;s_axi_arvalid=0;s_axi_rready=1;
    reset_all();
    rd(0,value);if(value!=32'h53434231)$fatal(1,"magic");
    wr(12'h014,1,2); // unconfigured DMA cannot start
    configure();wr(12'h008,0,2); // live DMA address cannot change
    for(integer n=0;n<4;n=n+1)send_packet(n);
    while(producer()!=4)@(negedge aclk);@(negedge aclk);
    for(integer n=0;n<4;n=n+1)check_slot(n,n);
    repeat(20)begin @(negedge aclk);if(s_axis_tready)$fatal(1,"full ring overrun");end
    wr(12'h024,5,2);wr(12'h024,2,0);
    send_packet(4);send_packet(5);while(producer()!=6)@(negedge aclk);@(negedge aclk);
    check_slot(0,4);check_slot(1,5);
    wr(12'h024,2,0);hold_posted=1;send_packet(6);
    wait(dut.producer==7);wr(12'h014,0,0);
    repeat(20)@(negedge aclk);
    if(dut.drained || !read_pending)$fatal(1,"STOP freed pending posted writes");
    hold_posted=0;wait(dut.drained);@(negedge aclk);
    if(producer()!=7)$fatal(1,"fence did not publish final packet");
    check_slot(2,6);rd(12'h018,value);if(value!=2)$fatal(1,"not safely drained");
    // START after a clean drain uses a freshly cleared/reconfigured allocation.
    for(i=0;i<4096;i=i+1)mem[i]=0;
    wr(12'h010,4,0);wr(12'h014,1,0);
    @(negedge aclk);dut.producer=32'hfffffffe;
    send_packet(8);send_packet(9);wait(dut.producer==0);while(producer()!=0)@(negedge aclk);
    wr(12'h014,0,0);wait(dut.drained);check_slot(0,8);check_slot(1,9);
    reset_all();configure();write_error=1;send_packet(10);wait(dut.errors!=0);
    if(dut.enabled || dut.drained)$fatal(1,"write fault allowed reuse");wr(12'h008,0,2);
    reset_all();configure();read_error=1;wr(12'h014,0,0);wait(dut.errors!=0);
    if(dut.drained)$fatal(1,"failed fence claimed drain");
    reset_all();configure();s_axis_tlast=0;send_packet(11);wait(dut.errors!=0);
    if(dut.errors!=8)$fatal(1,"malformed notification was accepted");
    $display("PASS: bridge full DMA address, packet/BAR preservation, AXI backpressure, credits, wrap, posted-write fence and faults");
    $finish;
  end
endmodule
