set repo [file normalize [file join [file dirname [info script]] ../..]]
set output [file join $repo build role-options-check]
file mkdir $output
set device xcvp1902-vsva6865-2MP-e-S
create_project -force role_options_check $output -part $device
set fd [open [file join $output role_top.v] w]
puts $fd {module role_top(input wire clk, input wire [7:0] data, output reg [7:0] result);
always @(posedge clk) result <= data;
endmodule}
close $fd
read_verilog [file join $output role_top.v]
source [file join $repo shell common fpga vivado_limits.tcl]
set synth_rpt_dir $output
set dcp_dir $output
source [file join $repo kmh fpga scripts flow synth.tcl]
puts "PASS: installed Vivado accepts revised role synthesis options"
close_project
