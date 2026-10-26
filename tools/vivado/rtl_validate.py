"""Replay full-layer cycles with compiled four-state XSim and the complete Verilog golden."""
from pathlib import Path
import argparse,csv,hashlib,json,os,re,shutil
import comparison_flow as flow
import native_xsim
from rtl_bench import make_bench
PHASES=['planning','input_transfers','kernel_transfers','core_execution','output_transfers','tile_transitions']
SUB=['im2col','weights','advances','stalls','transitions','retries']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def words(p):return [int(w,16) for line in p.read_text().splitlines() for w in line.split('//',1)[0].split()]
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--variant',choices=['all',*flow.MAP.values()],default='all');p.add_argument('--layer',action='append');p.add_argument('--vivado-root',type=Path,required=True);p.add_argument('--out-dir',type=Path,required=True);p.add_argument('--prepare',action='store_true');p.add_argument('--timeout',type=int,default=259200);a=p.parse_args()
 root=Path(__file__).resolve().parents[2];flow.ROOT=root;flow.SCOPE='tiled';flow.VIVADO_ROOT=a.vivado_root.resolve();flow.WINDOWS_TOOLS=(flow.VIVADO_ROOT/'bin/vivado.bat').is_file();flow.UNI=flow.VIVADO_ROOT/'data/verilog/src';out=a.out_dir.resolve();out.mkdir(parents=True,exist_ok=False);flow.BATCH=out;flow.STATE.update(status='PREPARING_RTL',runner_pid=os.getpid(),batch_done=False,results=[]);plan=[];results=[]
 for v,pub in flow.MAP.items():
  if a.variant not in ['all',pub]:continue
  src=flow.source(v);provenance=json.loads((root/'reports/tiled'/pub/'provenance.json').read_text())
  for name,digest in provenance['source_sha256'].items():assert sha(src/name)==digest,'Changed source: '+name
  specs=[s for s in flow.accepted(v) if not a.layer or s['layer'] in a.layer];assert specs,'No selected layers'
  build=out/pub;build.mkdir();(build/'tb_conv_core.v').write_text(make_bench(src));shutil.copy2(src/'sim/tensor_reader.vh',build/'tensor_reader.vh')
  if not a.prepare:
   flow.STATE.update(status='COMPILING_RTL',current=pub);flow.save_state();native_xsim.compile_sources([flow.UNI/'glbl.v',build/'tb_conv_core.v',*sorted((src/'rtl').glob('*.v'))],build)
  for spec in specs:
   fixture=flow.fixture(spec['layer']);plan.append(dict(variant=pub,layer=spec['layer'],config=spec['config'],accepted_cycles=spec['total']))
   for name,digest in spec['tensor_hashes'].items():assert sha(fixture/name)==digest
   if a.prepare:continue
   case=build/spec['layer'];case.mkdir();script=case/'run.tcl';script.write_text('''if {[catch {
set before [clock milliseconds]
foreach stage {1 2 3 4} {
run all
if {[get_value -radix unsigned /tb_conv_core/profile_stage] != $stage} {error "Bad RTL stage"}
set now [clock milliseconds]
puts "PROFILE_WALL stage=$stage milliseconds=[expr {$now-$before}]"
set before $now
}
set f [open {SUCCESS_PATH} w]
puts $f "Complete RTL golden, layer and export"
close $f
} err]} {puts stderr "RTL_CAPTURE_FAILED $err"}
quit
'''.replace('SUCCESS_PATH',flow.windows_path(case/'RTL_SIM_SUCCESS')))
   args=['counter_activity','-tclbatch',flow.windows_path(script),'-log',flow.windows_path(case/'xsim.log'),'-onfinish','stop','-onerror','quit'];plus={**spec['config'],'INPUT_FILE':flow.windows_path(fixture/'input_tensor.txt'),'KERNEL_FILE':flow.windows_path(fixture/'kernel_tensor.txt'),'OUTPUT_FILE':flow.windows_path(case/'actual.txt'),'SRAM_LAYOUT_FILE':flow.windows_path(case/'layout.txt')}
   for key,value in plus.items():args+=['-testplusarg',f'{key}={value}']
   flow.STATE.update(status='VALIDATING_RTL',current=pub+'/'+spec['layer']);flow.save_state();native_xsim.execute('xsim',args,build,'rtl_'+spec['layer'],a.timeout)
   text=(build/('rtl_'+spec['layer']+'_console.log')).read_text();assert (case/'RTL_SIM_SUCCESS').exists() and 'PASS:' in text and not re.search(r'Fatal:|FATAL:|ERROR:',text)
   assert words(case/'actual.txt')==words(fixture/'output_tensor.txt');total=int(re.search(r'Layer cycles[^:]*:\s*(\d+)',text)[1]);assert total==spec['total']
   m=re.search(r'\[TILED_CYCLES\] '+' '.join(k+r'=(\d+)' for k in PHASES)+r' tiles=(\d+) core_jobs=(\d+) tap_jobs=(\d+) signature=([0-9a-f]+)',text);assert m
   counts=dict(zip(PHASES,map(int,m.groups()[:6])));assert total==sum(counts.values()) and all(counts[k]==spec[k] for k in PHASES)
   traffic=re.search(r'Backing reads: (\d+); writes: (\d+)',text);assert traffic and (int(traffic[1]),int(traffic[2]))==(spec['backing_reads'],spec['backing_writes'])
   assert (int(m[7]),int(m[8]),int(m[9]),m[10])==(spec['tiles'],spec['core_jobs'],spec['tap_jobs'],spec['transfer_signature'])
   sub=re.search(r'\[CORE_CYCLES\] '+' '.join(k+r'=(\d+)' for k in SUB),text);assert sub and dict(zip(SUB,map(int,sub.groups())))==spec['nested_core']
   timing={int(k):int(value)/1000 for k,value in re.findall(r'PROFILE_WALL stage=(\d+) milliseconds=(\d+)',text)};assert set(timing)=={1,2,3,4}
   results.append(dict(variant=pub,layer=spec['layer'],cycles=total,outputs=spec['outputs'],tensor_loading_seconds=timing[1],golden_seconds=timing[2],accelerator_seconds=timing[3],export_seconds=timing[4],status='PASS'));flow.STATE['results']=results;flow.save_state();print(pub,spec['layer'],total,'PASS',flush=True)
 (out/'plan.json').write_text(json.dumps(plan,indent=2)+'\n')
 if results:
  with (out/'results.csv').open('w',newline='') as f:
   writer=csv.DictWriter(f,list(results[0]));writer.writeheader();writer.writerows(results)
 flow.STATE.update(status='PREPARED' if a.prepare else 'COMPLETED',batch_done=True,current=None);flow.save_state()
if __name__=='__main__':main()
