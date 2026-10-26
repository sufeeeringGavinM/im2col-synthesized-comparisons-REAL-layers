"""Generate the validated compiled RTL measurement bench; accelerator source is unchanged."""
from pathlib import Path
import re

def make_bench(src):
 src=Path(src);tb=(src/'sim/tb_conv_accelerator.v').read_text().replace('tb_conv_accelerator','tb_conv_core')
 for old,new in [('    read_tensor(input_file,','    $display("PROFILE_INPUT_BEGIN"); $fflush();\n    read_tensor(input_file,'),('    read_tensor(kernel_file,','    $display("PROFILE_KERNEL_BEGIN"); $fflush();\n    read_tensor(kernel_file,'),('    build_reference;','    $display("PROFILE_GOLDEN_BEGIN"); $fflush();\n    build_reference;\n    $display("PROFILE_GOLDEN_DONE"); $fflush();'),('    start = 1;','    $display("PROFILE_RTL_BEGIN"); $fflush();\n    start = 1;'),('    wait (done);','    wait (done);\n    $display("PROFILE_RTL_DONE"); $fflush();')]:
  assert old in tb;tb=tb.replace(old,new,1)
 tb=tb.replace('module tb_conv_core;','module tb_conv_core;\n  always @(posedge clk) if(nrst && busy && ((clock_cycles-start_cycle)%100000)==0) begin $display("PROFILE_CYCLE %0d",clock_cycles-start_cycle); $fflush(); end',1)
 start=tb.index('  // Bound a stalled demonstration');tb=tb[:start]+tb[tb.index('endmodule',start):]
 tb=tb.replace('module tb_conv_core;','module tb_conv_core;\n  integer profile_stage=0;\n  always @(posedge clk) if(nrst && busy && clock_cycles-start_cycle>1000000000) $fatal(1,"Profile cycle watchdog exceeded");',1)
 for label,stage in [('PROFILE_GOLDEN_BEGIN',1),('PROFILE_GOLDEN_DONE',2),('PROFILE_RTL_DONE',3)]:tb=tb.replace(f'$display("{label}"); $fflush();',f'$display("{label}"); $fflush(); profile_stage={stage}; $stop;')
 tb=tb.replace('    $finish;','    profile_stage=4; $finish;',1)
 end=tb.index('endmodule');body=tb[:end];declarations=re.findall(r'(?m)^  (?:reg|wire|integer|localparam|parameter|string|genvar)\b[^;]*;',body);body=re.sub(r'(?m)^  (?:reg|wire|integer|localparam|parameter|string|genvar)\b[^;]*;\n?', '',body)
 return body.replace('module tb_conv_core;','module tb_conv_core;\n'+'\n'.join(declarations),1)+tb[end:]
