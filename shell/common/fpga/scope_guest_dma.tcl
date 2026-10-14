# SPDX-License-Identifier: GPL-2.0-or-later
# Host/peer PCIe requests must enter the ordinary Kunminghu coherent slave.
# Keep the NM37 alias module unchanged and a raw window for loading under reset.
proc scope_add_guest_dma_ingress {} {
  if {![info exists ::env(CPU_KIND)] || $::env(CPU_KIND) ne "kunminghu"} {
    error "SCOPE coherent ingress requires the ordinary kunminghu CPU branch"
  }
  set route [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 scope_dma_route]
  set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 2] $route
  set alias [create_bd_cell -type module -reference axi_alias_attr_bridge scope_dma_alias]
  set_property -dict [list CONFIG.ADDR_WIDTH 64 CONFIG.DATA_WIDTH 512 CONFIG.ID_WIDTH 4 \
    CONFIG.ADDR_SUBTRACT 0x100000000 CONFIG.CACHE_VALUE 15] $alias
  set adapt [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 scope_dma_to_role]
  set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 1 CONFIG.NUM_CLKS 2] $adapt
  connect_bd_intf_net [get_bd_intf_pins qdma_ep/M_AXI_BRIDGE] [get_bd_intf_pins $route/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins $route/M00_AXI] [get_bd_intf_pins axi_ic_ddr_mem_qdma_ep/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins $route/M01_AXI] [get_bd_intf_pins $alias/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins $alias/M_AXI] [get_bd_intf_pins $adapt/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins $adapt/M00_AXI] [get_bd_intf_pins u_role/s_axi_dma]
  assign_bd_address -offset 0x100000000 -range 0x100000000 \
    -target_address_space [get_bd_addr_spaces qdma_ep/M_AXI_BRIDGE] \
    [get_bd_addr_segs $alias/S_AXI/reg0] -force
  assign_bd_address -offset 0x80000000 -range 0x80000000 \
    -target_address_space [get_bd_addr_spaces $alias/M_AXI] \
    [get_bd_addr_segs u_role/s_axi_dma/reg0] -force
}

# Connect only after the board script has created its named clock/reset nets.
proc scope_connect_guest_dma_clocks {} {
  set route scope_dma_route
  set alias scope_dma_alias
  set adapt scope_dma_to_role
  foreach pin [list $route/aclk $alias/clk $adapt/aclk] {
    connect_bd_net [get_bd_pins qdma_ep/axi_aclk] [get_bd_pins $pin]
  }
  foreach pin [list $route/aresetn $alias/rstn $adapt/aresetn] {
    connect_bd_net [get_bd_pins qdma_ep/axi_aresetn] [get_bd_pins $pin]
  }
  connect_bd_net [get_bd_pins dut_clk_gen/clk_out1] [get_bd_pins $adapt/aclk1]
}
