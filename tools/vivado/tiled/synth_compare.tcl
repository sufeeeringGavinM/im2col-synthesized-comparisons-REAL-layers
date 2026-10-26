set build [file normalize [lindex $argv 0]]
set variant [file tail $build]
cd $build
set_param general.maxThreads 2
puts STRATEGY_CONFIGURATION_BEGIN
report_config_flows
puts STRATEGY_CONFIGURATION_END
set tool_version [open tool_version.txt w]
puts $tool_version [version]
close $tool_version
foreach source [lsort [glob [file join $build rtl *.v]]] {read_verilog -sv $source}
read_xdc [file join $build timing.xdc]
set generics {ARRAY_SIZE=10 BIT_WIDTH=8 ACC_WIDTH=32 CFG_WIDTH=32 INPUT_ADDR_WIDTH=8 OUTPUT_ADDR_WIDTH=8 KERNEL_ADDR_WIDTH=8 MEM_ADDR_WIDTH=32}
synth_design -top conv_accelerator -part xc7a200tfbg676-2 -mode out_of_context -flatten_hierarchy rebuilt -generic $generics
report_utilization -file utilization.rpt
report_utilization -hierarchical -file utilization_hierarchy.rpt
report_timing_summary -report_unconstrained -file timing_50mhz.rpt
check_timing -verbose -file timing_checks.rpt
report_drc -file drc.rpt
set paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $paths] == 0} {error "No timed setup path found"}
set slack [get_property SLACK [lindex $paths 0]]
set period [expr {20.0-$slack}]
if {$period <= 0} {error "Invalid estimated period"}
set maximum [expr {1000.0/$period}]
report_timing -of_objects $paths -file worst_path.rpt
set metrics [open timing_metrics.json w]
puts $metrics "{\"target_period_ns\":20.0,\"wns_ns\":$slack,\"estimated_minimum_period_ns\":$period,\"estimated_fmax_mhz\":$maximum}"
close $metrics
write_checkpoint synthesized.dcp
write_verilog -mode funcsim synthesized.v
create_clock -name clk -period 1000.000 [get_ports clk]
report_timing_summary -report_unconstrained -file timing_1mhz.rpt
report_power -file power_1mhz.rpt
write_checkpoint power_1mhz.dcp
close_project
set project_dir [file join $build project]
create_project $variant $project_dir -part xc7a200tfbg676-2
set_property design_mode GateLvl [current_fileset]
import_files -norecurse -fileset sources_1 [file join $build synthesized.dcp]
set_property top conv_accelerator [current_fileset]
close_project
open_project [file join $project_dir ${variant}.xpr]
link_design -top conv_accelerator -part xc7a200tfbg676-2 -mode out_of_context
if {[llength [get_cells -hierarchical]] == 0} {error "Empty project netlist"}
if {abs([get_property PERIOD [get_clocks clk]]-20.0)>0.001} {error "Saved project clock mismatch"}
close_project
set marker [open SUCCESS w]
puts $marker "Synthesis, default power reporting and project reopen/link completed."
close $marker
puts COMPARISON_SUCCESS
exit 0
