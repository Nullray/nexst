# SPDX-License-Identifier: GPL-2.0-or-later
source [file join [file dirname [info script]] scope_guest_dma.tcl]

proc scope_add_qdma_notifications {proxy} {
  set cdc [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_clock_converter:1.1 scope_notify_cdc]
  set_property -dict [list CONFIG.TDATA_NUM_BYTES 64 CONFIG.HAS_TKEEP 1 \
    CONFIG.HAS_TLAST 1 CONFIG.IS_ACLK_ASYNC 1] $cdc
  set ring [create_bd_cell -type module -reference scope_qdma_bridge_ring scope_notify]
  set_property CONFIG.COHERENT_DMA 1 $ring
  connect_bd_intf_net [get_bd_intf_pins $proxy/m_axis_c2h] [get_bd_intf_pins $cdc/S_AXIS]
  connect_bd_intf_net [get_bd_intf_pins $cdc/M_AXIS] [get_bd_intf_pins $ring/s_axis]
  connect_bd_intf_net [get_bd_intf_pins $ring/m_axi] [get_bd_intf_pins qdma_ep/S_AXI_BRIDGE]
  connect_bd_net [get_bd_pins dut_clk_gen/clk_out1] [get_bd_pins $cdc/s_axis_aclk]
  connect_bd_net [get_bd_pins dut_rst_gen/peripheral_aresetn] [get_bd_pins $cdc/s_axis_aresetn]
  foreach pin [list $cdc/m_axis_aclk $ring/aclk] {
    connect_bd_net [get_bd_pins qdma_ep/axi_aclk] [get_bd_pins $pin]
  }
  foreach pin [list $cdc/m_axis_aresetn $ring/aresetn] {
    connect_bd_net [get_bd_pins qdma_ep/axi_aresetn] [get_bd_pins $pin]
  }
  # Preserve all 64 address bits. No fixed CPU physical address or AXI aperture
  # translation is used: the host driver supplies the FPGA function's DMA/IOVA.
  assign_bd_address -offset 0 -range 0x10000000000000000 \
    -target_address_space [get_bd_addr_spaces $ring/m_axi] \
    [get_bd_addr_segs qdma_ep/S_AXI_BRIDGE/BAR0] -force
  foreach pin [get_bd_pins -quiet qdma_ep/s_axis_c2h_*] {
    if {[get_property DIR $pin] ne "I" || [llength [get_bd_nets -quiet -of_objects $pin]]} {continue}
    set name [file tail [get_property NAME $pin]]
    set left [get_property LEFT $pin]
    set right [get_property RIGHT $pin]
    set width 1
    if {$left ne "" && $right ne ""} {set width [expr {abs($left - $right) + 1}]}
    set constant [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 scope_zero_$name]
    set_property -dict [list CONFIG.CONST_WIDTH $width CONFIG.CONST_VAL 0] $constant
    connect_bd_net [get_bd_pins $constant/dout] $pin
  }
  set h2c_ready [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 scope_h2c_ready]
  set_property CONFIG.CONST_VAL 1 $h2c_ready
  if {![llength [get_bd_nets -quiet -of_objects [get_bd_pins qdma_ep/m_axis_h2c_tready]]]} {
    connect_bd_net [get_bd_pins $h2c_ready/dout] [get_bd_pins qdma_ep/m_axis_h2c_tready]
  }
  return $ring
}

# SCOPE control plane; guest RAM enters CPU DMA through scope_guest_dma.tcl.
proc scope_add_host_proxy {board} {
  scope_connect_guest_dma_clocks
  if {$board ni {pdas uvhs2}} {error "Unsupported host-proxy board: $board"}
  if {$board eq "pdas"} {
    set upstream axi_axil_adapter/M00_AXI
    set host_base 0
    set io [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 scope_role_io]
    set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 2] $io
    connect_bd_intf_net [get_bd_intf_pins u_role/m_axi_io] [get_bd_intf_pins $io/S00_AXI]
    set mmio $io/M00_AXI
    set ecam $io/M01_AXI
  } else {
    set upstream axi_ic_role_ctrl/M00_AXI
    set host_base 0x10000000
    set io [get_bd_cells axi_ic_role_io]
    set_property CONFIG.NUM_MI 3 $io
    set mmio $io/M01_AXI
    set ecam $io/M02_AXI
  }

  # Split the existing role control aperture, after its clock-domain converter.
  set old_net [get_bd_intf_nets -of_objects [get_bd_intf_pins $upstream]]
  disconnect_bd_intf_net $old_net [get_bd_intf_pins u_role/s_axi_ctrl]
  set host [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 scope_host_ctrl]
  set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 5 CONFIG.NUM_CLKS 2] $host
  connect_bd_net [get_bd_pins qdma_ep/axi_aclk] [get_bd_pins $host/aclk1]
  connect_bd_intf_net [get_bd_intf_pins $upstream] [get_bd_intf_pins $host/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins $host/M00_AXI] [get_bd_intf_pins u_role/s_axi_ctrl]

  set proxy [create_bd_cell -type module -reference virtual_pcie_switch_proxy scope_proxy]
  set fifo [scope_add_qdma_notifications $proxy]
  connect_bd_intf_net [get_bd_intf_pins $host/M01_AXI] [get_bd_intf_pins $proxy/s_mbx_axi]
  connect_bd_intf_net [get_bd_intf_pins $host/M03_AXI] [get_bd_intf_pins $fifo/s_axi]
  connect_bd_intf_net [get_bd_intf_pins $mmio] [get_bd_intf_pins $proxy/s_mmio_axi]
  connect_bd_intf_net [get_bd_intf_pins $ecam] [get_bd_intf_pins $proxy/s_ecam_axi]
  connect_bd_intf_net [get_bd_intf_pins $host/M04_AXI] [get_bd_intf_pins qdma_ep/S_AXI_LITE_CSR]

  # The proxy reads ECAM through port A; the host updates it through port B.
  foreach port {a b} {
    set bram_$port [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 scope_ecam_$port]
    set_property -dict [list CONFIG.SINGLE_PORT_BRAM 1 CONFIG.DATA_WIDTH 32 \
      CONFIG.PROTOCOL AXI4LITE] [set bram_$port]
  }
  set memory [create_bd_cell -type ip -vlnv xilinx.com:ip:emb_mem_gen:1.0 scope_ecam_mem]
  # emb_mem_gen expresses MEMORY_SIZE in bits: 128 KiB compact ECAM storage.
  set_property -dict [list CONFIG.MEMORY_PRIMITIVE BRAM \
    CONFIG.MEMORY_TYPE True_Dual_Port_RAM CONFIG.MEMORY_SIZE 1048576] $memory
  connect_bd_intf_net [get_bd_intf_pins $proxy/m_ecam_shadow_axi] [get_bd_intf_pins $bram_a/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins $host/M02_AXI] [get_bd_intf_pins $bram_b/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins $bram_a/BRAM_PORTA] [get_bd_intf_pins $memory/BRAM_PORTA]
  connect_bd_intf_net [get_bd_intf_pins $bram_b/BRAM_PORTA] [get_bd_intf_pins $memory/BRAM_PORTB]

  set irq [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 scope_irq]
  set_property -dict [list CONFIG.NUM_PORTS 3 CONFIG.IN0_WIDTH 1 \
    CONFIG.IN1_WIDTH 1 CONFIG.IN2_WIDTH 62] $irq
  set zero [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 scope_irq_zero]
  set_property -dict [list CONFIG.CONST_WIDTH 62 CONFIG.CONST_VAL 0] $zero
  connect_bd_net [get_bd_pins const_gnd/dout] [get_bd_pins $irq/In0]
  connect_bd_net [get_bd_pins $proxy/interrupt_out] [get_bd_pins $irq/In1]
  connect_bd_net [get_bd_pins $zero/dout] [get_bd_pins $irq/In2]
  connect_bd_net [get_bd_pins $irq/dout] [get_bd_pins u_role/s2r_intr]

  foreach pin [list $proxy/clk $host/aclk $bram_a/s_axi_aclk $bram_b/s_axi_aclk] {
    connect_bd_net [get_bd_pins dut_clk_gen/clk_out1] [get_bd_pins $pin]
  }
  foreach pin [list $host/aresetn $bram_a/s_axi_aresetn $bram_b/s_axi_aresetn] {
    connect_bd_net [get_bd_pins dut_rst_gen/peripheral_aresetn] [get_bd_pins $pin]
  }
  connect_bd_net [get_bd_pins dut_rst_gen/peripheral_reset] [get_bd_pins $proxy/rst]
  if {$board eq "pdas"} {
    connect_bd_net [get_bd_pins dut_clk_gen/clk_out1] [get_bd_pins $io/aclk]
    connect_bd_net [get_bd_pins dut_rst_gen/peripheral_aresetn] [get_bd_pins $io/aresetn]
  }

  set host_space [get_bd_addr_spaces qdma_ep/M_AXI_LITE]
  assign_bd_address -offset $host_base -range 0x00200000 \
    -target_address_space $host_space [get_bd_addr_segs u_role/s_axi_ctrl/reg0] -force
  foreach {offset range segment} [list \
      0x200000 0x1000 $proxy/s_mbx_axi/reg0 \
      0x220000 0x20000 $bram_b/S_AXI/Mem0 \
      0x240000 0x1000 $fifo/s_axi/reg0 \
      0x260000 0x10000 qdma_ep/S_AXI_LITE_CSR/CTL0] {
    assign_bd_address -offset [expr {$host_base + $offset}] -range $range \
      -target_address_space $host_space [get_bd_addr_segs $segment] -force
  }
  assign_bd_address -offset 0x50000000 -range 0x01000000 \
    -target_address_space [get_bd_addr_spaces u_role/m_axi_io] \
    [get_bd_addr_segs $proxy/s_mmio_axi/reg0] -force
  assign_bd_address -offset 0x60000000 -range 0x01000000 \
    -target_address_space [get_bd_addr_spaces u_role/m_axi_io] \
    [get_bd_addr_segs $proxy/s_ecam_axi/reg0] -force
  assign_bd_address -offset 0 -range 0x00020000 \
    -target_address_space [get_bd_addr_spaces $proxy/m_ecam_shadow_axi] \
    [get_bd_addr_segs $bram_a/S_AXI/Mem0] -force
}
