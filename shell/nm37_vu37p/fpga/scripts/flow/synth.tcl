# synthesizing full design
synth_design -top xiangshan_wrapper -part ${device} \
    -directive default -flatten_hierarchy rebuilt

# PCIe RP GT physical location.
# The virtual PCIe switch path removes the DUT-facing XDMA RP, so these GT
# cells do not exist in that build.  Keep the legacy placement fix only when
# the old RP GT cells are present.
set rp_gt_loc_pairs [list \
    [list GTYE4_CHANNEL_X0Y12 {NAME =~ *gen_channel_container[3].*gen_gtye4_channel_inst[3].GTYE4_CHANNEL_PRIM_INST}] \
    [list GTYE4_CHANNEL_X0Y13 {NAME =~ *gen_channel_container[3].*gen_gtye4_channel_inst[2].GTYE4_CHANNEL_PRIM_INST}] \
    [list GTYE4_CHANNEL_X0Y14 {NAME =~ *gen_channel_container[3].*gen_gtye4_channel_inst[1].GTYE4_CHANNEL_PRIM_INST}] \
    [list GTYE4_CHANNEL_X0Y15 {NAME =~ *gen_channel_container[3].*gen_gtye4_channel_inst[0].GTYE4_CHANNEL_PRIM_INST}] \
]
foreach rp_gt_loc_pair $rp_gt_loc_pairs {
    set rp_gt_loc [lindex $rp_gt_loc_pair 0]
    set rp_gt_filter [lindex $rp_gt_loc_pair 1]
    set rp_gt_cells [get_cells -hierarchical -filter $rp_gt_filter]

    if {[llength $rp_gt_cells] > 0} {
        reset_property LOC $rp_gt_cells
        set_property LOC $rp_gt_loc $rp_gt_cells
    }
}
unset rp_gt_loc_pairs

# setup output logs and reports
report_timing_summary -file ${synth_rpt_dir}/synth_timing.rpt -delay_type max -max_paths 1000

# setup output logs and reports
report_utilization -hierarchical -file ${synth_rpt_dir}/synth_util_hier.rpt
report_utilization -file ${synth_rpt_dir}/synth_util.rpt
    
# write checkpoint
write_checkpoint -force ${dcp_dir}/synth.dcp
