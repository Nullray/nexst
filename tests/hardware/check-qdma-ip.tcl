# Check the installed QDMA v5.1 properties and actual pin/interface inference.
# No synthesis, implementation or bitstream generation.
set repo [file normalize [file join [file dirname [info script]] ../..]]
create_project -force scope_qdma_check [file join $repo build qdma-ip-check] \
  -part xcvp1902-vsva6865-2MP-e-S
add_files [file join $repo shell common fpga]
create_bd_design scope_qdma_check
set qdma [create_bd_cell -type ip -vlnv xilinx.com:ip:qdma:5.1 qdma_ep]
set_property -dict [list CONFIG.functional_mode QDMA \
  CONFIG.dma_intf_sel_qdma AXI_MM_and_AXI_Stream_with_Completion \
  CONFIG.c2h_stream_cpl_col_bit_pos0 1 CONFIG.c2h_stream_cpl_err_bit_pos0 2] $qdma
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wizard dut_clk_gen
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset dut_rst_gen
set notify [create_bd_cell -type module -reference scope_qdma_control scope_notify]
source [file join $repo shell common fpga host_proxy.tcl]
scope_add_qdma_notifications $notify
foreach name {s_axis m_axis s_axi} {
  if {[llength [get_bd_intf_pins -quiet scope_notify/$name]] != 1} {
    error "Module interface inference missing: scope_notify/$name"
  }
}
if {[llength [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins scope_cmpt/cmpt]]] != 1} {
  error "Native completion interface is unconnected"
}
if {[get_property VLNV [get_bd_intf_pins scope_cmpt/cmpt]] ne \
    [get_property VLNV [get_bd_intf_pins qdma_ep/s_axis_c2h_cmpt]]} {
  error "Completion adapter uses the wrong vendor interface"
}
save_bd_design
puts "PASS: installed QDMA v5.1 parameters, inferred interfaces and completion wiring"
close_project
