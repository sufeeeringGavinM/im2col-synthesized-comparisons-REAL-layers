"""Native Vivado XSim netlist workloads and SAIF at a common 1 MHz clock."""
from pathlib import Path
import base64
import hashlib
import json
import re
import shutil
import sys

import comparison_flow as flow
import native_xsim

WORK = Path(__file__).resolve().parent
ROOT = flow.ROOT
UNI = flow.UNI
LAYERS = [r['layer'] for r in json.loads((flow.ROOT/'tools/workloads/layers.json').read_text())]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def words(path):
    return [int(w, 16) for line in path.read_text().splitlines()
            for w in line.split('//', 1)[0].split()]


def prepare(variant,out):
    """Same backing-memory stimulus; compare every meaningful synthesized transfer port."""
    folder=flow.source(variant);build=flow.BATCH/variant
    top='conv_accelerator' if variant.startswith('control_') else 'conv_chain'
    sources=sorted((folder/'rtl').glob('*.v'))
    modules=[m for p in sources for m in re.findall(r'\bmodule\s+(\w+)',p.read_text())]
    pattern=r'\b('+('|'.join(map(re.escape,modules)))+r')\b'
    renamed=[]
    for p in sources:
        dest=out/p.name;dest.write_text(re.sub(pattern,lambda m:'rtl_'+m[0],p.read_text()));renamed.append(dest)
    shutil.copy2(folder/'sim/tensor_reader.vh',out/'tensor_reader.vh')
    tb=(folder/'sim/tb_conv_accelerator.v').read_text()
    tb=tb.replace('module tb_conv_accelerator;','module tb_conv_core;',1)
    tb=tb.replace('tb_conv_accelerator','tb_conv_core')
    begin=tb.index('  '+top+' #(');end=tb.index('\n  );',begin)+len('\n  );')
    instance=tb[begin:end];connections=instance[instance.index(' DUT (')+len(' DUT ('):]
    for signal in ['busy','done','mem_re','mem_we','mem_raddr','mem_waddr','mem_wdata','descriptor_ready','chain_busy','chain_done']:
        connections=connections.replace('.'+signal+'('+signal+')','.'+signal+'(gate_'+signal+')')
    compare="""  wire gate_busy,gate_done,gate_mem_re,gate_mem_we,gate_descriptor_ready,gate_chain_busy,gate_chain_done;
  wire [MEM_ADDR_WIDTH-1:0] gate_mem_raddr,gate_mem_waddr;
  wire [MEM_DATA_WIDTH-1:0] gate_mem_wdata;
  integer known_bits=0;
  always @(negedge clk) if(nrst && (busy || done)) begin
    if({gate_busy,gate_done,gate_mem_re,gate_mem_we,gate_descriptor_ready,gate_chain_busy,gate_chain_done} !== {busy,done,mem_re,mem_we,descriptor_ready,chain_busy,chain_done})
      $fatal(1,"NETLIST_CONTROL_MISMATCH");
    known_bits=known_bits+7;
    if(mem_re) begin
      if(gate_mem_raddr !== mem_raddr) $fatal(1,"NETLIST_READ_ADDRESS_MISMATCH");
      known_bits=known_bits+MEM_ADDR_WIDTH;
    end
    if(mem_we) begin
      if(gate_mem_waddr !== mem_waddr || gate_mem_wdata !== mem_wdata)
        $fatal(1,"NETLIST_OUTPUT_TRANSFER_MISMATCH");
      known_bits=known_bits+MEM_ADDR_WIDTH+MEM_DATA_WIDTH;
    end
  end
"""
    if top=='conv_accelerator':
        compare=compare.replace(',gate_descriptor_ready,gate_chain_busy,gate_chain_done','').replace(',descriptor_ready,chain_busy,chain_done','').replace('known_bits+7','known_bits+4')
    tb=tb[:begin]+compare+instance.replace(top+' #(','rtl_'+top+' #(')+'\n  '+top+' GATE ('+connections+tb[end:]
    tb=tb.replace('always #5 clk','always #(clock_half_ns) clk')
    tb=tb.replace('module tb_conv_core;', 'module tb_conv_core;\n  real clock_half_ns=500.0;\n  initial if($value$plusargs("CLOCK_HALF_NS=%f",clock_half_ns)) begin end',1)
    tb=tb.replace('repeat (2) @(negedge clk);','repeat (20) @(negedge clk);')
    tb=tb.replace('start_cycle','run_start_cycle')
    marker='if (start && !busy) run_start_cycle <= clock_cycles + 1;'
    assert marker in tb
    tb=tb.replace(marker,'if (start && !busy) begin run_start_cycle <= clock_cycles + 1; $display("[POWER_WINDOW] start_ps: %0t",$time); end')
    tb=tb.replace('wait (done);','wait (done);',1)
    tb=tb.replace('    $finish;', '    if(known_bits==0) $fatal(1,"No netlist transfer comparisons");\n    $display("NETLIST_PORT_CHECK_PASS known_bits=%0d",known_bits);\n    $finish;')
    tb=tb.replace('$dumpvars(0, tb_conv_core);','$dumpvars(0,GATE);')
    start=tb.index('  // Bound a stalled demonstration')
    tb=tb[:start]+tb[tb.index('endmodule',start):]
    tb=native_xsim.add_window_markers(tb)
    (out/'tb_conv_core.v').write_text(tb)
    native_xsim.compile_sources([flow.UNI/'glbl.v',out/'tb_conv_core.v',*renamed,build/'synthesized.v'],out)
    return out

def prepare_chain(variant,out):
    """Same accepted ResNet8 bench, shadow vs synthesized ports, whole-chain SAIF window."""
    folder=flow.source(variant);build=flow.BATCH/variant
    sources=sorted((folder/'rtl').glob('*.v'))
    modules=[m for p in sources for m in re.findall(r'\bmodule\s+(\w+)',p.read_text())]
    pattern=r'\b('+('|'.join(map(re.escape,modules)))+r')\b'
    renamed=[]
    for p in sources:
        dest=out/p.name;dest.write_text(re.sub(pattern,lambda m:'rtl_'+m[0],p.read_text()));renamed.append(dest)
    tb=(flow.E/'fixtures/chain'/variant/'tb_resnet8_chain.v').read_text().replace('module tb_resnet8_chain;','module tb_conv_core;',1)
    outputs=['descriptor_ready','busy','done','chain_busy','chain_done','mem_re','mem_we','mem_raddr','mem_waddr','mem_wdata']
    inputs=['clk','nrst','descriptor_valid','descriptor_last','cfg_quantize','cfg_round_nearest','cfg_output_shift','mem_rdata',
            *['cfg_'+x for x in ['N','C','H','W','K','R','S','P','Q','pad_i','pad_j','stride_i','stride_j','dilation_i','dilation_j','input_base','kernel_base','output_base']]]
    gates='  conv_chain GATE ('+','.join('.'+x+'('+x+')' for x in inputs)+','+','.join('.'+x+'(gate_'+x+')' for x in outputs)+');'
    compare='''  wire gate_descriptor_ready,gate_busy,gate_done,gate_chain_busy,gate_chain_done,gate_mem_re,gate_mem_we;
  wire [31:0] gate_mem_raddr,gate_mem_waddr,gate_mem_wdata;
  integer known_bits=0,power_stage=0,actual_fd;
  string actual_file;
  initial begin
    if(!$value$plusargs("OUTPUT_FILE=%s",actual_file))$fatal(1,"Missing actual output path");
    actual_fd=$fopen(actual_file,"w");if(!actual_fd)$fatal(1,"Cannot export chain outputs");
  end
  always @(negedge clk) if(nrst && (chain_busy || chain_done)) begin
    if({gate_descriptor_ready,gate_busy,gate_done,gate_chain_busy,gate_chain_done,gate_mem_re,gate_mem_we} !==
       {descriptor_ready,busy,done,chain_busy,chain_done,mem_re,mem_we})$fatal(1,"NETLIST_CONTROL_MISMATCH");
    known_bits=known_bits+7;
    if(mem_re)begin
      if(gate_mem_raddr !== mem_raddr)$fatal(1,"NETLIST_READ_ADDRESS_MISMATCH");known_bits=known_bits+32;
    end
    if(mem_we)begin
      if({gate_mem_waddr,gate_mem_wdata} !== {mem_waddr,mem_wdata})$fatal(1,"NETLIST_OUTPUT_TRANSFER_MISMATCH");known_bits=known_bits+64;
    end
  end
'''
    tb=tb.replace('  conv_chain DUT(.*);',compare+'\n  rtl_conv_chain DUT(.*);\n'+gates)
    tb=tb.replace('repeat(3)@(negedge clk);nrst=1;','repeat(20)@(negedge clk);nrst=1;')
    tb=tb.replace('if(layer==0)chain_start_ns=$realtime;','if(layer==0)begin chain_start_ns=$realtime;power_stage=1;$stop;end',1)
    tb=tb.replace('wait(done);','wait(done);if(layer==2)begin power_stage=2;$stop;end ',1)
    marker='if(memory[base+j]!==expected[off+j])$fatal(1,"Chain layer%0d output%0d want%h got%h",layer,j,expected[off+j],memory[base+j]);'
    assert marker in tb
    tb=tb.replace(marker,'begin '+marker+' $fdisplay(actual_fd,"%h",memory[base+j]);end',1)
    tb=tb.replace('$finish;', '$fclose(actual_fd);if(known_bits==0)$fatal(1,"No netlist checks");$display("NETLIST_PORT_CHECK_PASS known_bits=%0d",known_bits);power_stage=3;$finish;',1)
    # Same global-declaration ordering convention as the accepted native harness.
    end=tb.index('endmodule');body=tb[:end]
    declarations=re.findall(r'(?m)^  (?:reg|wire|real|integer|localparam|parameter|string|genvar)\b[^;]*;',body)
    body=re.sub(r'(?m)^  (?:reg|wire|real|integer|localparam|parameter|string|genvar)\b[^;]*;\n?','',body)
    tb=body.replace('module tb_conv_core;','module tb_conv_core;\n'+'\n'.join(declarations),1)+tb[end:]
    (out/'tb_conv_core.v').write_text(tb)
    native_xsim.compile_sources([flow.UNI/'glbl.v',out/'tb_conv_core.v',*renamed,build/'synthesized.v'],out)
    return out
