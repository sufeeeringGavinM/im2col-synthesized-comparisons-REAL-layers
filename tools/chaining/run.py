"""Replay accepted chaining RTL and Nexys Video native-SAIF measurements.

Uses fresh output directories and one sequential tool owner. AI assistance: Codex.
"""
from pathlib import Path
import argparse,json,os,shutil,subprocess,sys,traceback
import comparison_flow as flow
import measure as m


def verify():
 identity=json.loads((flow.ROOT/'reports/chaining/source_identity.json').read_text())
 for arch,record in identity['architectures'].items():
  for name,digest in record['source_sha256'].items():
   assert m.sha(flow.ROOT/'tiled'/arch/name)==digest,'Source changed: '+arch+'/'+name
 fixtures=json.loads((m.E/'fixtures/MANIFEST.json').read_text())
 for name,digest in fixtures.items():assert m.sha(m.E/'fixtures'/name)==digest,'Fixture changed: '+name
 for row in json.loads((m.E/'fixtures/validation/RESULTS.json').read_text())['cases']:
  if row['quantize']==0:flow.fixture(row['layer'])
 return identity


def rtl_replay(out,arches,timeout):
 compiler=os.environ.get('IVERILOG_BIN') or shutil.which('iverilog')
 runtime=os.environ.get('VVP_BIN') or shutil.which('vvp')
 backend=os.environ.get('IVERILOG_BACKEND')
 assert compiler and runtime,'Install Icarus or set IVERILOG_BIN and VVP_BIN'
 def compile_bench(src,bench,binary):
  cmd=[str(compiler),*(['-B',backend] if backend else []),'-g2012','-Wall','-I',str(src/'sim'),'-s',bench.stem,'-o',str(binary),str(bench),*map(str,sorted((src/'rtl').glob('*.v')))]
  flow.run(cmd,out,binary.with_suffix('.compile.log'),timeout)
 def simulate(binary,config,log):
  flow.run([str(runtime),*(['-M',backend] if backend else []),str(binary),*[f'+{k}={v}' for k,v in config.items()]],out,log,timeout)
 accepted=json.loads((m.E/'fixtures/validation/RESULTS.json').read_text())['cases']
 chains=json.loads((m.E/'fixtures/chain/RESULTS.json').read_text())['results']
 results=[]
 for arch in arches:
  src=flow.source(arch);folder=out/arch;folder.mkdir()
  fixture=m.E/'fixtures/chain';bench=fixture/arch/'tb_resnet8_chain.v';binary=folder/'chain.vvp'
  compile_bench(src,bench,binary)
  simulate(binary,dict(INIT=fixture/'chain_memory.hex',DESC=fixture/'chain_descriptors.hex',EXPECTED=fixture/'chain_expected.hex'),folder/'chain.log')
  expected=next(r for r in chains if r['architecture']==arch)
  assert m.chain_metrics(folder/'chain.log')=={k:expected[k] for k in ['cycles','phases','layers']}
  results.append(dict(architecture=arch,layer='resnet8_chain',status='PASS',cycles=expected['cycles']))
  binary=folder/'layer.vvp';compile_bench(src,src/'sim/tb_conv_accelerator.v',binary)
  for row in accepted:
   if row['architecture']!=arch or row['quantize']!=0:continue
   case=folder/row['layer'];case.mkdir();fixture=flow.fixture(row['layer'])
   config={**row['config'],'QUANTIZE':0,'INPUT_FILE':fixture/'input_tensor.txt','KERNEL_FILE':fixture/'kernel_tensor.txt','OUTPUT_FILE':case/'actual.txt','SRAM_LAYOUT_FILE':case/'layout.txt'}
   simulate(binary,config,case/'run.log')
   assert m.metrics(case/'run.log')=={k:row[k] for k in ['cycles','phases']}
   assert m.words(case/'actual.txt')==m.words(fixture/'output_tensor.txt')
   results.append(dict(architecture=arch,layer=row['layer'],status='PASS',cycles=row['cycles']))
  binary=folder/'quantizer.vvp';compile_bench(src,src/'sim/tb_output_quantizer.v',binary)
  simulate(binary,dict(FILE=m.E/'fixtures/quantizer'/arch/'quant_vectors.txt'),folder/'quantizer.log')
  assert 'PASS: 13472 quantization vectors' in (folder/'quantizer.log').read_text()
 m.write_json(out/'rtl_results.json',dict(status='PASS',cases=results,quantizer_vectors_per_architecture=13472))


def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--stage',choices=['prepare','rtl','synthesis','all'],default='prepare')
 parser.add_argument('--variant',choices=['all',*m.ARCHES],default='all')
 parser.add_argument('--out-dir',type=Path,required=True,help='A new output directory')
 parser.add_argument('--vivado-root',type=Path,help='Installation directory containing bin/ and data/')
 parser.add_argument('--timeout',type=int,default=259200,help='Timeout for each RTL command in seconds')
 args=parser.parse_args();identity=verify()
 arches=m.ARCHES if args.variant=='all' else [args.variant]
 if args.stage in ['synthesis','all']:
  assert args.vivado_root,'--vivado-root is required for synthesis/native measurements'
  flow.VIVADO_ROOT=args.vivado_root.expanduser().resolve();flow.WINDOWS_TOOLS=(flow.VIVADO_ROOT/'bin/vivado.bat').is_file()
  flow.UNI=flow.VIVADO_ROOT/'data/verilog/src'
  assert (flow.VIVADO_ROOT/'bin'/('vivado.bat' if flow.WINDOWS_TOOLS else 'vivado')).is_file()
 out=args.out_dir.expanduser().resolve();out.mkdir(parents=True,exist_ok=False)
 flow.BATCH=m.BATCH=out
 flow.STATE.update(status='PREPARING',batch_done=False,runner_pid=os.getpid(),hardware=[],workload_results=[],errors={})
 flow.save_state()
 m.write_json(out/'plan.json',dict(stage=args.stage,architectures=arches,part='xc7a200tsbg484-1',top='conv_chain',new_syntheses=len(arches),native_cases=10*len(arches),source_identity=identity))
 if args.stage=='prepare':
  flow.STATE.update(status='PREPARED',batch_done=True);flow.save_state();print('PASS: exact source and fixture identities verified; no tools launched');return
 if args.stage=='rtl':
  rtl_replay(out,arches,args.timeout);flow.STATE.update(status='COMPLETED',batch_done=True);flow.save_state();return
 for arch in arches:
  try:
   build=out/arch;build.mkdir();shutil.copytree(flow.source(arch)/'rtl',build/'rtl');shutil.copy2(m.E/'timing.xdc',build/'timing.xdc')
   flow.STATE.update(current=arch,status='SYNTHESIS');flow.save_state()
   flow.execute_tool('vivado',['-mode','batch','-source',flow.windows_path(m.E/'synth_compare.tcl'),'-log',flow.windows_path(build/'vivado.log'),'-journal',flow.windows_path(build/'vivado.jou'),'-tclargs',flow.windows_path(build),'conv_chain'],build,'synthesis',43200)
   assert (build/'SUCCESS').exists()
   h=dict(architecture=arch,**m.util(build/'utilization.rpt'),**json.loads((build/'timing_metrics.json').read_text()),worst_path=m.path_metrics(build))
   flow.STATE['hardware'].append(h);flow.save_state();m.report()
  except Exception:m.failure(arch+'/synthesis')
 if args.stage=='all':
  for arch in arches:
   if not (out/arch/'SUCCESS').exists():continue
   try:m.chain_cases(arch)
   except Exception:m.failure(arch+'/chain_preparation')
  for arch in arches:
   if not (out/arch/'SUCCESS').exists():continue
   try:m.layer_cases(arch,False)
   except Exception:m.failure(arch+'/layer_preparation')
  if len(flow.STATE['workload_results'])!=10*len(arches):flow.STATE['errors']['matrix']='Missing native measurements; inspect per-case errors'
 verify()
 flow.STATE.update(status='COMPLETED_WITH_FAILURES' if flow.STATE['errors'] else 'COMPLETED',batch_done=True,current=None)
 flow.save_state();m.report()
 if flow.STATE['errors']:raise SystemExit(1)


if __name__=='__main__':
 try:main()
 except Exception:
  if flow.BATCH is not None:
   flow.STATE.setdefault('errors',{})['runner']=traceback.format_exc();flow.STATE.update(status='FAILED',batch_done=True);flow.save_state()
  raise
