# Shared synthesis/reporting preset. AI-assisted; adapted from the retained
# counter_architecture_20261113 and original comparison flows. See README.md.
# A prepared run executes its immutable copy of this file, never the live copy.
namespace eval ::synthesis_preset {
    variable version 2

    proc write_text {name value} {
        set handle [open $name w]
        puts $handle $value
        close $handle
    }

    proc analysis_clock {cfg period} {
        set port [get_ports [dict get $cfg clock_port]]
        if {[llength $port] != 1} {error "Expected exactly one primary clock port"}
        set name [dict get $cfg clock_name]
        # PERIOD/WAVEFORM are read-only: replace the existing primary clock.
        create_clock -name $name -period $period -waveform [list 0 [expr {$period/2.0}]] $port
        set inputs [get_ports -filter [format {DIRECTION == IN && NAME != "%s"} [dict get $cfg clock_port]]]
        set outputs [get_ports -filter {DIRECTION == OUT}]
        if {[llength $inputs]} {set_input_delay [dict get $cfg input_delay_ns] -clock $name $inputs}
        if {[llength $outputs]} {set_output_delay [dict get $cfg output_delay_ns] -clock $name $outputs}
        if {[llength [get_clocks]] != 1 || abs([get_property PERIOD [get_clocks $name]]-$period)>0.001} {
            error "Expected one primary clock with the requested analysis period"
        }
    }

    proc worst_setup {} {
        set paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
        if {![llength $paths]} {error "No timed setup path found"}
        return [lindex $paths 0]
    }

    proc run {cfg} {
        variable version
        set build [file normalize [dict get $cfg build_dir]]
        cd $build
        if {[file exists PRESET_STARTED]} {error "This run already started; preserve it and prepare a fresh run"}
        write_text PRESET_STARTED "Preset v$version started at [clock format [clock seconds] -gmt 1]"
        set threads [dict get $cfg max_threads]
        set_param general.maxThreads $threads
        if {[get_param general.maxThreads] != $threads} {error "Requested thread setting not accepted"}
        write_text tool_version.txt [version]
        set top [dict get $cfg top]
        set part [dict get $cfg part]
        set period [dict get $cfg synthesis_period_ns]
        set mode [dict get $cfg mode]
        if {$mode eq "synthesis"} {
            create_project -in_memory -part $part
            set_property include_dirs [dict get $cfg include_dirs] [current_fileset]
            foreach source [dict get $cfg sources] {read_verilog -sv $source}
            read_xdc [dict get $cfg xdc]
            set command [list synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy rebuilt]
            if {[llength [dict get $cfg generics]]} {lappend command -generic [dict get $cfg generics]}
            {*}$command
        } elseif {$mode eq "reports"} {
            open_checkpoint [dict get $cfg checkpoint]
        } else {error "Mode must be synthesis or reports"}
        # Reapply configured I/O constraints before the first checkpoint/reports,
        # including reports-mode DCPs. Tcl control flow belongs here, not in XDC.
        analysis_clock $cfg $period
        set clock [get_clocks [dict get $cfg clock_name]]
        if {[llength [get_clocks]] != 1 || [llength $clock] != 1 || abs([get_property PERIOD $clock]-$period)>0.001} {
            error "Input design does not have the configured single synthesis clock"
        }
        if {[get_property PART [current_design]] ne $part} {error "Input design part mismatch"}
        # Save the valid synthesis-clock design before any reporting/export step.
        write_checkpoint synthesized.dcp
        write_verilog -mode funcsim synthesized.v
        report_utilization -file utilization.rpt
        report_utilization -hierarchical -file utilization_hierarchy.rpt
        report_timing_summary -report_unconstrained -file timing_synthesis.rpt
        check_timing -verbose -file timing_checks.rpt
        report_drc -file drc.rpt
        set worst [worst_setup]
        set slack [get_property SLACK $worst]
        set minimum [expr {$period-$slack}]
        if {$minimum <= 0} {error "Invalid estimated minimum period"}
        set fmax [expr {1000.0/$minimum}]
        report_timing -of_objects $worst -file worst_path.rpt
        report_timing -delay_type max -max_paths 10 -nworst 1 -file worst_paths_10.rpt
        set profile [open block_profile.tsv w]
        puts $profile "label\tpins\tpaths\tstatus"
        dict for {label pattern} [dict get $cfg block_patterns] {
            set pins [get_pins -hierarchical -quiet -filter [format {NAME =~ "%s"} $pattern]]
            set paths {}
            if {[llength $pins]} {
                set paths [get_timing_paths -quiet -through $pins -delay_type max -max_paths 5 -nworst 1]
            }
            set status unavailable_or_optimized
            if {[llength $paths]} {
                report_timing -of_objects $paths -file "block_${label}.rpt"
                set status reported
            }
            puts $profile "$label\t[llength $pins]\t[llength $paths]\t$status"
        }
        close $profile
        set common {}
        foreach other [dict get $cfg common_periods_ns] {
            analysis_clock $cfg $other
            report_timing_summary -report_unconstrained -file "timing_common_${other}ns.rpt"
            check_timing -verbose -file "timing_checks_common_${other}ns.rpt"
            set value [get_property SLACK [worst_setup]]
            lappend common "\"$other\":$value"
        }
        analysis_clock $cfg $period
        set fields [join $common ,]
        write_text timing_metrics.json "{\"preset_version\":$version,\"target_period_ns\":$period,\"wns_ns\":$slack,\"estimated_minimum_period_ns\":$minimum,\"estimated_fmax_mhz\":$fmax,\"common_period_wns_ns\":{$fields}}"
        close_project
        if {[dict get $cfg export_gui]} {
            set project_dir [file join $build project]
            create_project gui $project_dir -part $part
            set_property design_mode GateLvl [current_fileset]
            import_files -norecurse -fileset sources_1 [file join $build synthesized.dcp]
            set_property top $top [current_fileset]
            close_project
            open_project [file join $project_dir gui.xpr]
            link_design -top $top -part $part -mode out_of_context
            set cells [llength [get_cells -hierarchical]]
            if {$cells == 0} {error "Empty reopened GUI netlist"}
            set actual [get_property PERIOD [get_clocks [dict get $cfg clock_name]]]
            if {abs($actual-$period)>0.001} {error "Reopened GUI clock mismatch"}
            write_text gui_reopen.json "{\"reopen_link_passed\":true,\"netlist_cells\":$cells,\"clock_period_ns\":$actual}"
            close_project
        }
        write_text SUCCESS "Preset v$version: $mode, constrained OOC reports and requested GUI verification complete."
    }
}

if {![info exists ::synthesis_preset_library_only]} {
    if {[llength $argv] != 1} {error "Usage: vivado -mode batch -source preset.tcl -tclargs run_config.tcl"}
    source [file normalize [lindex $argv 0]]
    if {![info exists preset_config]} {error "Run config must set preset_config"}
    ::synthesis_preset::run $preset_config
    exit 0
}
