"""Native Vivado Simulator compilation and bounded SAIF capture (AMD UG900)."""
from pathlib import Path
import base64
from decimal import Decimal
import re

import comparison_flow as flow

def execute(tool, arguments, cwd, label, timeout=3600):
    flow.execute_tool(tool, arguments, cwd, label, timeout)
    console=(cwd/(label+'_console.log')).read_text(errors='replace')
    if re.search(r'ERROR:|FATAL:|Fatal:',console):
        raise RuntimeError('Native tool failed: '+str(cwd/(label+'_console.log'))+'\n'+console[-2500:])


def compile_sources(sources, cwd):
    execute('xvlog', ['--sv', '--work', 'xil_defaultlib', *[flow.windows_path(p) for p in sources]], cwd, 'xvlog', 3600)
    execute('xelab', ['--debug', 'typical', '--relax', '--mt', '2',
                     '-L', 'unisims_ver', '-L', 'unimacro_ver', '-L', 'secureip',
                     'xil_defaultlib.tb_conv_core', 'xil_defaultlib.glbl',
                     '--snapshot', 'counter_activity'], cwd, 'xelab', 7200)
    assert (cwd/'xsim.dir/counter_activity').is_dir(), 'Native snapshot was not created'


def add_window_markers(tb):
    """Pause XSim at accepted start and done so Tcl can bound native logging."""
    assert 'module tb_conv_core;' in tb
    tb = tb.replace('module tb_conv_core;', 'module tb_conv_core;\n  integer power_stage=0;', 1)
    marker = '$display("[POWER_WINDOW] start_ps: %0t",$time);'
    assert marker in tb
    tb = tb.replace(marker, marker+' power_stage=1; $stop;')
    assert 'wait (done);' in tb
    tb = tb.replace('wait (done);', 'wait (done); power_stage=2; $stop;', 1)
    tb = tb.replace('    $finish;', '    power_stage=3;\n    $finish;')
    tb=re.sub(r'\n  initial begin\n    wait \(nrst && start\);[\s\S]*?\$fatal\(1, "Simulation watchdog:[^;]*;\n  end', '', tb, count=1)
    watchdog='''
  integer native_watchdog_cycles=2000000;
  initial begin
    if($value$plusargs("NATIVE_WATCHDOG_CYCLES=%d",native_watchdog_cycles)) begin end
  end
  always @(posedge clk) begin
    if(nrst && busy && clock_cycles-run_start_cycle>native_watchdog_cycles)
      $fatal(1,"Native simulation exceeded accepted cycle bound");
  end
'''
    tb=tb.replace('module tb_conv_core;', 'module tb_conv_core;'+watchdog,1)
    # XSim requires these module declarations before their first procedural use.
    end=tb.index('endmodule')
    body=tb[:end]
    declarations=re.findall(r'(?m)^  (?:reg|wire|integer|localparam|parameter|string|genvar)\b[^;]*;',body)
    body=re.sub(r'(?m)^  (?:reg|wire|integer|localparam|parameter|string|genvar)\b[^;]*;\n?', '',body)
    body=body.replace('module tb_conv_core;', 'module tb_conv_core;\n'+'\n'.join(declarations),1)
    tb=body+tb[end:]
    return tb


def simulate(cwd, case, config, fixture, cycles):
    def tcl_path(p):
        return '{'+flow.windows_path(p)+'}'
    capture = case/'capture.tcl'
    capture.write_text('''if {[catch {
run all
if {[get_value -radix unsigned /tb_conv_core/power_stage] != 1} {error "Missing accepted-start marker"}
set start_time [current_time]
open_saif SAIF_PATH
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
set result [open SUCCESS_PATH w]
puts $result "Native XSim SAIF capture and final output/netlist checks completed"
close $result
} native_error]} {
puts stderr "NATIVE_CAPTURE_FAILED $native_error"
}
quit
'''.replace('SAIF_PATH', tcl_path(case/'activity.saif')).replace('SUCCESS_PATH', tcl_path(case/'NATIVE_SIM_SUCCESS')))
    args = ['counter_activity', '-tclbatch', flow.windows_path(capture),
            '-log', flow.windows_path(case/'xsim.log'), '-onfinish', 'stop', '-onerror', 'quit']
    plusargs = {**config, 'INPUT_FILE': flow.windows_path(fixture/'input_tensor.txt'),
                'KERNEL_FILE': flow.windows_path(fixture/'kernel_tensor.txt'),
                'OUTPUT_FILE': flow.windows_path(case/'actual.txt'),
                'SRAM_LAYOUT_FILE': flow.windows_path(case/'layout.txt'),
                'NATIVE_WATCHDOG_CYCLES': cycles+64}
    for k, value in plusargs.items():
        args.extend(['-testplusarg', f'{k}={value}'])
    label='xsim_'+case.name
    execute('xsim', args, cwd, label, 604800)
    log = (case/'xsim.log').read_text(errors='replace') if (case/'xsim.log').exists() else ''
    log += '\n'+(cwd/(label+'_console.log')).read_text(errors='replace')
    (case/'run.log').write_text(log)
    assert (case/'NATIVE_SIM_SUCCESS').exists(), 'Native capture/check marker missing: '+str(case)
    assert 'NETLIST_PORT_CHECK_PASS' in log and 'PASS:' in log and not re.search(r'FATAL:|Fatal:|ERROR:', log), case
    # Read the unmodified native file only to verify its recorded job duration.
    saif = (case/'activity.saif').read_text(errors='strict')
    scale = re.search(r'\(TIMESCALE\s+([\d.eE+-]+)\s+(fs|ps|ns|us|ms|s)\s*\)', saif)
    duration = re.search(r'\(DURATION\s+(\d+)\s*\)', saif)
    assert scale and duration, 'Missing native SAIF duration: '+str(case)
    units = dict(fs=Decimal('1e-15'), ps=Decimal('1e-12'), ns=Decimal('1e-9'),
                 us=Decimal('1e-6'), ms=Decimal('1e-3'), s=Decimal(1))
    seconds = Decimal(duration[1])*Decimal(scale[1])*units[scale[2]]
    assert seconds == Decimal(cycles)*Decimal('1e-6'), (case, seconds, cycles)
    return dict(generator='Vivado XSim native open_saif/log_saif/close_saif',
                native_duration_seconds=str(seconds), simulated_clock_mhz=1,
                activity_scope='/tb_conv_core/GATE', native_tcl=str(capture))
