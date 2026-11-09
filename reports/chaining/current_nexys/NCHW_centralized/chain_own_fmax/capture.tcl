if {[catch {
run all
if {[get_value -radix unsigned /tb_conv_core/power_stage] != 1} {error "Missing accepted-start marker"}
set start_time [current_time]
open_saif {C:/Users/RageAgainstW10/eda/designs/196/synthesis/VivadoSynth/conv_chaining_unoptimized_20261108/native_chain/NCHW_centralized/chain_own_fmax/activity.saif}
current_scope /tb_conv_core/GATE
set activity_objects [get_objects -r *]
if {[llength $activity_objects] == 0} {error "Empty synthesized-DUT activity scope"}
log_saif $activity_objects
run all
set end_time [current_time]
if {[get_value -radix unsigned /tb_conv_core/power_stage] != 2} {error "Missing done marker"}
close_saif
puts "NATIVE_SAIF_WINDOW start=$start_time end=$end_time"
run all
if {[get_value -radix unsigned /tb_conv_core/power_stage] != 3} {error "Output/netlist checks did not finish"}
set result [open {C:/Users/RageAgainstW10/eda/designs/196/synthesis/VivadoSynth/conv_chaining_unoptimized_20261108/native_chain/NCHW_centralized/chain_own_fmax/NATIVE_SIM_SUCCESS} w]
puts $result "Native XSim SAIF capture and final output/netlist checks completed"
close $result
} native_error]} {
puts stderr "NATIVE_CAPTURE_FAILED $native_error"
}
quit
