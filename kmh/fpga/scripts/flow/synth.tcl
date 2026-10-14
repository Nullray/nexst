set_param synth.elaboration.rodinMoreOptions "rt::set_parameter var_size_limit 8355840"

# Preserve hierarchy reconstruction but use the lighter optimization strategy.
set scope_synth_directive RuntimeOptimized
set scope_synth_flatten rebuilt
if {[info exists ::env(ROLE_SYNTH_DIRECTIVE)]} {set scope_synth_directive $::env(ROLE_SYNTH_DIRECTIVE)}
if {[info exists ::env(ROLE_SYNTH_FLATTEN)]} {set scope_synth_flatten $::env(ROLE_SYNTH_FLATTEN)}
puts "INFO: role synthesis directive=$scope_synth_directive hierarchy=$scope_synth_flatten"

# synthesizing full design
synth_design -top role_top -part ${device} -mode out_of_context \
    -directive $scope_synth_directive -flatten_hierarchy $scope_synth_flatten

# setup output logs and reports
report_timing_summary -file ${synth_rpt_dir}/synth_timing.rpt -delay_type max -max_paths 1000

# setup output logs and reports
report_utilization -hierarchical -file ${synth_rpt_dir}/synth_util_hier.rpt
report_utilization -file ${synth_rpt_dir}/synth_util.rpt

# write checkpoint
write_checkpoint -force ${dcp_dir}/synth.dcp

