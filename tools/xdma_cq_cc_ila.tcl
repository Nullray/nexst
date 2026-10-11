# Source in the fully linked synthesized NM37 design BEFORE opt_design.
# Fail closed if the generated PCIe hierarchy is not visible. No IP edits.
set scope_pcie [get_cells -hier -quiet -filter {NAME =~ *xdma_ep* && NAME =~ *pcie4c_ip_i}]
if {[llength $scope_pcie] != 1} {
    error "Expected one XDMA pcie4c_ip_i, found: $scope_pcie; open/link the shell OOC checkpoints first"
}
proc scope_pin_nets {cell port} {
    set pins {}
    foreach pin [get_pins -quiet -of_objects $cell] {
        if {[regexp [format {^%s(\[[0-9]+\])?$} $port] [get_property REF_PIN_NAME $pin]]} {
            lappend pins $pin
        }
    }
    set nets [lsort -dictionary -unique [get_nets -quiet -of_objects $pins]]
    if {[llength $nets] == 0} { error "Missing PCIe port $cell/$port" }
    return $nets
}
set scope_groups {}
foreach name {m_axis_cq_tdata m_axis_cq_tkeep m_axis_cq_tuser m_axis_cq_tlast m_axis_cq_tvalid m_axis_cq_tready s_axis_cc_tdata s_axis_cc_tkeep s_axis_cc_tuser s_axis_cc_tlast s_axis_cc_tvalid s_axis_cc_tready user_reset user_lnk_up pcie_cq_np_req pcie_cq_np_req_count} {
    lappend scope_groups [list $name [scope_pin_nets $scope_pcie $name]]
}
set scope_clk [scope_pin_nets $scope_pcie user_clk]
if {[llength $scope_clk] != 1} { error "Ambiguous PCIe user_clk" }
if {[llength [get_debug_cores -quiet scope_cq_cc_ila]]} { error "ILA already exists" }
create_debug_core scope_cq_cc_ila ila
set_property C_DATA_DEPTH 4096 [get_debug_cores scope_cq_cc_ila]
connect_debug_port scope_cq_cc_ila/clk $scope_clk
set scope_i 0
foreach group $scope_groups {
    lassign $group name nets
    if {$scope_i > 0} { create_debug_port scope_cq_cc_ila probe }
    set port [get_debug_ports scope_cq_cc_ila/probe$scope_i]
    set_property port_width [llength $nets] $port
    connect_debug_port $port $nets
    puts "CQCC probe$scope_i = $name width=[llength $nets] nets=$nets"
    incr scope_i
}
# Bit indices must be checked against the printed net list before decoding.
puts "CQ/CC ILA inserted; implement design and export matching bit/ltx. No hardware programmed."
