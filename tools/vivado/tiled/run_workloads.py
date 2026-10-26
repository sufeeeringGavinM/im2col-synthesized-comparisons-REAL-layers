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
ROOT = WORK.parents[1]
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
    begin=tb.index('  conv_accelerator #(');end=tb.index('\n  );',begin)+len('\n  );')
    instance=tb[begin:end];connections=instance[instance.index(' DUT (')+len(' DUT ('):]
    for signal in ['busy','done','mem_re','mem_we','mem_raddr','mem_waddr','mem_wdata']:
        connections=connections.replace('.'+signal+'('+signal+')','.'+signal+'(gate_'+signal+')')
    compare="""  wire gate_busy,gate_done,gate_mem_re,gate_mem_we;
  wire [MEM_ADDR_WIDTH-1:0] gate_mem_raddr,gate_mem_waddr;
  wire [MEM_DATA_WIDTH-1:0] gate_mem_wdata;
  integer known_bits=0;
  always @(negedge clk) if(nrst && (busy || done)) begin
    if({gate_busy,gate_done,gate_mem_re,gate_mem_we} !== {busy,done,mem_re,mem_we})
      $fatal(1,"NETLIST_CONTROL_MISMATCH");
    known_bits=known_bits+4;
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
    tb=tb[:begin]+compare+instance.replace('conv_accelerator #(','rtl_conv_accelerator #(')+'\n  conv_accelerator GATE ('+connections+tb[end:]
    tb=tb.replace('always #5 clk','always #500 clk')
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
    native_xsim.compile_sources([UNI/'glbl.v',out/'tb_conv_core.v',*renamed,build/'synthesized.v'],out)
    return out


def power(variant, case):
    flow.execute_tool('vivado', ['-mode','batch','-source',flow.windows_path(WORK/'power.tcl'),
        '-log',flow.windows_path(case/'vivado.log'),'-journal',flow.windows_path(case/'vivado.jou'),
        '-tclargs',flow.windows_path(flow.BATCH/variant/'synthesized.dcp'),flow.windows_path(case)],
        case,'power',3600)
    assert (case/'POWER_SUCCESS').exists(),case


def run_variant(variant, report):
    out = flow.BATCH/'workloads'/variant
    out.mkdir(parents=True, exist_ok=False)
    for f in (flow.BATCH/variant/'rtl').glob('*.v'):
        assert digest(f) == digest(flow.source(variant)/'rtl'/f.name), f
    flow.STATE.update(status='COMPILING_NETLIST', current=variant)
    flow.save_state()
    binary = prepare(variant, out)
    accepted = {r['layer']:r for r in flow.accepted(variant)}
    for name in LAYERS:
        flow.STATE.update(status='SIMULATING_NETLIST', current=variant+'/'+name)
        flow.save_state()
        c = accepted[name]
        case = out/name
        case.mkdir()
        fixture = flow.fixture(name)
        for filename in ['input_tensor.txt', 'kernel_tensor.txt', 'output_tensor.txt']:
            assert digest(fixture/filename)==c['tensor_hashes'][filename], 'Changed workload tensor: '+str(fixture/filename)
            shutil.copy2(fixture/filename, case/filename)
        native_record=native_xsim.simulate(out,case,c['config'],case,c['total'])
        log = (case/'run.log').read_text()
        assert 'NETLIST_PORT_CHECK_PASS' in log and 'PASS:' in log and not re.search(r'FATAL:|ERROR:', log), case
        assert words(case/'actual.txt') == words(case/'output_tensor.txt'), case
        cycles = int(re.search(r'Layer cycles[^:]*:\s*(\d+)', log)[1])
        assert cycles == c['total'], case
        flow.STATE.update(status='REPORTING_WORKLOAD_POWER', current=variant+'/'+name)
        flow.save_state()
        power(variant, case)
        text = (case/'power.rpt').read_text()
        row = dict(variant=variant, layer=name, clock_mhz=1, cycles=cycles, latency_us=cycles,
                   outputs=c['outputs'], known_bits=int(re.search(r'known_bits=(\d+)', log)[1]),
                   annotation_report=str(case/'annotation.rpt'), power_report=str(case/'power.rpt'))
        row['geometry_json']=json.dumps(c['config'],sort_keys=True)
        row['tensor_sha256_json']=json.dumps({filename:digest(case/filename) for filename in ['input_tensor.txt','kernel_tensor.txt','output_tensor.txt']},sort_keys=True)
        row['netlist_sha256']=digest(flow.BATCH/variant/'synthesized.v')
        row['dcp_sha256']=digest(flow.BATCH/variant/'synthesized.dcp')
        row.update(native_record)
        for label, key in [('Dynamic (W)', 'dynamic_w'), ('Device Static (W)', 'static_w'), ('Total On-Chip Power (W)', 'total_w')]:
            match = re.search(r'\|\s*'+re.escape(label)+r'\s*\|\s*([\d.]+)', text)
            assert match, (case, label)
            row[key] = float(match[1])
        for label, key in [('Confidence Level', 'power_confidence'), ('Design Nets Matched', 'design_nets_matched')]:
            match = re.search(r'\|\s*'+re.escape(label)+r'\s*\|\s*([^|]+)', text)
            row[key] = match[1].strip() if match else None
        matched = re.search(r'\((\d+)/(\d+)\)', row['design_nets_matched'] or '')
        assert matched and int(matched[1]) > 0 and int(matched[2]) > 0, 'No verified netlist activity annotation: '+str(case)
        row['timing_1mhz_all_constraints_met'] = 'All user specified timing constraints are met.' in (case/'timing_1mhz.rpt').read_text()
        row['energy_uj'] = row['total_w']*cycles
        row['dynamic_energy_uj'] = row['dynamic_w']*cycles
        flow.STATE.setdefault('workload_results', []).append(row)
        flow.save_state()
        report()
    flow.STATE.setdefault('validated_variants',[]).append(variant)
