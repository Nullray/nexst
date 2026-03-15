`timescale 1ns / 1ps

module axilite_active_proxy #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32
) (
    input wire clk,
    input wire rst, // 物理连线接 aresetn (低电平有效)

    // ===================================================================
    // 1. S_AXI (Slave): 来自 DUT (XiangShan 经 AXI IC)
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
    // 2. M_AXI (Master): 物理透传，去往物理 XDMA RP
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
    // 3. M_VCONF_AXI (Master): 去往 4KB 虚拟配置空间 BRAM (Port A)
    // ===================================================================
    output reg  [ADDR_WIDTH-1:0] m_vconf_axi_araddr,
    output reg  [2:0]            m_vconf_axi_arprot,
    output reg                   m_vconf_axi_arvalid,
    input  wire                  m_vconf_axi_arready,
    input  wire [DATA_WIDTH-1:0] m_vconf_axi_rdata,
    input  wire [1:0]            m_vconf_axi_rresp,
    input  wire                  m_vconf_axi_rvalid,
    output reg                   m_vconf_axi_rready,
    
    // Vivado 接口自动推断所需占位信号
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
    // 4. S_MBX_AXI (Slave): 面向 QEMU 宿主机轮询的内部 Mailbox 寄存器
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
    input  wire                  s_mbx_axi_bready
);

    // ===================================================================
    // 静态赋值：挂起 M_VCONF_AXI 的写通道，确保 BRAM 只读不写
    // ===================================================================
    assign m_vconf_axi_awaddr  = 0;
    assign m_vconf_axi_awprot  = 0;
    assign m_vconf_axi_awvalid = 0;
    assign m_vconf_axi_wdata   = 0;
    assign m_vconf_axi_wstrb   = 0;
    assign m_vconf_axi_wvalid  = 0;
    assign m_vconf_axi_bready  = 1'b1;

    // ===================================================================
    // 模块 1：Mailbox 寄存器 (与 Host AXI-Lite 交互)
    // ===================================================================
    reg [31:0] mbx_status;   
    reg [31:0] mbx_awaddr;   
    reg [31:0] mbx_wdata;    
    reg [31:0] mbx_wstrb;    
    reg        host_ack_pulse;

    assign s_mbx_axi_arready = !s_mbx_axi_rvalid;
    always @(posedge clk) begin
        if (!rst) begin
            s_mbx_axi_rvalid <= 0;
            s_mbx_axi_rdata  <= 0;
            s_mbx_axi_rresp  <= 0;
        end else begin
            if (s_mbx_axi_arvalid && s_mbx_axi_arready) begin
                s_mbx_axi_rvalid <= 1'b1;
                s_mbx_axi_rresp  <= 2'b00; 
                case (s_mbx_axi_araddr[11:0])
                    12'h000: s_mbx_axi_rdata <= mbx_status;
                    12'h004: s_mbx_axi_rdata <= mbx_awaddr;
                    12'h008: s_mbx_axi_rdata <= mbx_wdata;
                    12'h00C: s_mbx_axi_rdata <= mbx_wstrb;
                    default: s_mbx_axi_rdata <= 32'd0;
                endcase
            end else if (s_mbx_axi_rready && s_mbx_axi_rvalid) begin
                s_mbx_axi_rvalid <= 1'b0;
            end
        end
    end

    assign s_mbx_axi_awready = !s_mbx_axi_bvalid && s_mbx_axi_awvalid && s_mbx_axi_wvalid;
    assign s_mbx_axi_wready  = s_mbx_axi_awready;
    always @(posedge clk) begin
        if (!rst) begin
            s_mbx_axi_bvalid <= 0;
            s_mbx_axi_bresp  <= 0;
            host_ack_pulse   <= 0;
        end else begin
            host_ack_pulse <= 1'b0; 
            if (s_mbx_axi_awready) begin
                s_mbx_axi_bvalid <= 1'b1;
                s_mbx_axi_bresp  <= 2'b00;
                if (s_mbx_axi_awaddr[11:0] == 12'h010) begin
                    host_ack_pulse <= 1'b1;
                end
            end else if (s_mbx_axi_bready && s_mbx_axi_bvalid) begin
                s_mbx_axi_bvalid <= 1'b0;
            end
        end
    end

    // ===================================================================
    // 拦截匹配逻辑：绝对独占 Bus 1，并严防地址混叠漏洞！
    // 强制匹配 32位全量地址的高 20 位，精确定位到 0x60100_XXX 空间
    // ===================================================================
    wire is_vconf_aw = (s_axi_awaddr[31:12] == 20'h60100);
    wire is_vconf_ar = (s_axi_araddr[31:12] == 20'h60100);

    // ===================================================================
    // 模块 2：DUT Write 拦截通道 (接管 AW/W/B)
    // ===================================================================
    reg  write_in_flight;
    localparam W_IDLE = 0, W_MBX_WAIT_ACK = 1, W_PASS_WAIT_READY = 2, W_PASS_WAIT_B = 3;
    reg [1:0] w_state;

    assign s_axi_awready = (w_state == W_IDLE) && s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
    assign s_axi_wready  = s_axi_awready;

    always @(posedge clk) begin
        if (!rst) begin 
            w_state <= W_IDLE;
            write_in_flight <= 0;
            mbx_status <= 0;
            s_axi_bvalid <= 0;
            s_axi_bresp  <= 0;
            m_axi_awvalid <= 0;
            m_axi_wvalid <= 0;
            m_axi_bready <= 0;
        end else begin
            if (host_ack_pulse) begin
                mbx_status <= 0;
                write_in_flight <= 0;
            end

            case (w_state)
                W_IDLE: begin
                    if (s_axi_bready && s_axi_bvalid) s_axi_bvalid <= 0;

                    if (s_axi_awready) begin 
                        if (is_vconf_aw) begin
                            mbx_status <= 32'd1;
                            mbx_awaddr <= {20'd0, s_axi_awaddr[11:0]};
                            mbx_wdata  <= s_axi_wdata;
                            mbx_wstrb  <= { {(32-DATA_WIDTH/8){1'b0}}, s_axi_wstrb };
                            write_in_flight <= 1'b1;
                            w_state <= W_MBX_WAIT_ACK; 
                        end else begin
                            // 透传给物理 XDMA (如配置 Root Port 本身 0x60000000 或其他空间)
                            m_axi_awvalid <= 1; m_axi_awaddr <= s_axi_awaddr; m_axi_awprot <= s_axi_awprot;
                            m_axi_wvalid  <= 1; m_axi_wdata  <= s_axi_wdata;  m_axi_wstrb  <= s_axi_wstrb;
                            w_state <= W_PASS_WAIT_READY;
                        end
                    end
                end

                W_MBX_WAIT_ACK: begin
                    if (!write_in_flight) begin
                        s_axi_bvalid <= 1'b1;
                        s_axi_bresp  <= 2'b00; 
                        w_state <= W_IDLE;
                    end
                end

                W_PASS_WAIT_READY: begin
                    if (m_axi_awvalid && m_axi_awready) m_axi_awvalid <= 0;
                    if (m_axi_wvalid && m_axi_wready)   m_axi_wvalid  <= 0;
                    if (!m_axi_awvalid && !m_axi_wvalid) begin
                        m_axi_bready <= 1;
                        w_state <= W_PASS_WAIT_B;
                    end
                end

                W_PASS_WAIT_B: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready <= 0;
                        s_axi_bvalid <= 1;
                        s_axi_bresp  <= m_axi_bresp;
                        w_state <= W_IDLE;
                    end
                end
            endcase
        end
    end

    // ===================================================================
    // 模块 3：DUT Read 路由通道 (接管 AR/R)
    // ===================================================================
    reg [ADDR_WIDTH-1:0] pending_araddr;
    reg [2:0]            pending_arprot;
    
    localparam R_IDLE = 0, R_WAIT_IN_FLIGHT = 1, R_VCONF_WAIT_READY = 2, R_VCONF_WAIT_R = 3, R_PASS_WAIT_READY = 4, R_PASS_WAIT_R = 5;
    reg [2:0] r_state;

    assign s_axi_arready = (r_state == R_IDLE) && !s_axi_rvalid;

    always @(posedge clk) begin
        if (!rst) begin 
            r_state <= R_IDLE;
            s_axi_rvalid <= 0;
            s_axi_rresp <= 0;
            m_vconf_axi_arvalid <= 0;
            m_vconf_axi_rready <= 0; 
            m_axi_arvalid <= 0;
            m_axi_rready <= 0;       
        end else begin
            case (r_state)
                R_IDLE: begin
                    if (s_axi_rready && s_axi_rvalid) s_axi_rvalid <= 0;

                    if (s_axi_arready && s_axi_arvalid) begin
                        pending_araddr <= s_axi_araddr;
                        pending_arprot <= s_axi_arprot;

                        if (is_vconf_ar) begin
                            r_state <= R_WAIT_IN_FLIGHT; 
                        end else begin
                            // 透传给物理 XDMA
                            m_axi_arvalid <= 1'b1;
                            m_axi_araddr  <= s_axi_araddr;
                            m_axi_arprot  <= s_axi_arprot;
                            r_state <= R_PASS_WAIT_READY; 
                        end
                    end
                end

                R_WAIT_IN_FLIGHT: begin
                    if (!write_in_flight) begin
                        m_vconf_axi_arvalid <= 1;
                        m_vconf_axi_araddr  <= {20'd0, pending_araddr[11:0]};
                        m_vconf_axi_arprot  <= pending_arprot;
                        r_state <= R_VCONF_WAIT_READY;
                    end
                end

                R_VCONF_WAIT_READY: begin
                    if (m_vconf_axi_arvalid && m_vconf_axi_arready) begin
                        m_vconf_axi_arvalid <= 0;
                        m_vconf_axi_rready  <= 1;
                        r_state <= R_VCONF_WAIT_R;
                    end
                end

                R_VCONF_WAIT_R: begin
                    if (m_vconf_axi_rvalid && m_vconf_axi_rready) begin
                        m_vconf_axi_rready <= 0;
                        s_axi_rvalid <= 1;
                        s_axi_rdata  <= m_vconf_axi_rdata;
                        s_axi_rresp  <= m_vconf_axi_rresp;
                        r_state <= R_IDLE;
                    end
                end

                R_PASS_WAIT_READY: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 0;
                        m_axi_rready  <= 1;
                        r_state <= R_PASS_WAIT_R;
                    end
                end

                R_PASS_WAIT_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        m_axi_rready <= 0;
                        s_axi_rvalid <= 1;
                        s_axi_rdata  <= m_axi_rdata;
                        s_axi_rresp  <= m_axi_rresp;
                        r_state <= R_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
