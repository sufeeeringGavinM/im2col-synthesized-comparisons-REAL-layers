set checkpoint [lindex $argv 0]
set out [lindex $argv 1]
set period [lindex $argv 2]
set_param general.maxThreads 2
open_checkpoint $checkpoint
create_clock -name clk -period $period [get_ports clk]
if {abs([get_property PERIOD [get_clocks clk]]-$period)>0.001} {error "Power clock mismatch"}
read_saif -strip_path tb_conv_core/GATE -out_file [file join $out annotation.rpt] [file join $out activity.saif]
report_timing_summary -report_unconstrained -file [file join $out timing_1mhz.rpt]
report_power -file [file join $out power.rpt]
set f [open [file join $out POWER_SUCCESS] w]
puts $f "Job-specific post-synthesis netlist activity at the captured frequency; default environment settings"
close $f
exit 0
