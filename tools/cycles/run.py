"""Replay the four accepted real-layer geometries with full RTL golden and phase checks."""
from pathlib import Path
import argparse,csv,hashlib,json,os,re,shutil,subprocess
ROOT=Path(__file__).resolve().parents[2]
MAP={'NHWC':'channel_first','NCHW_centralized':'centralized','explicit':'explicit','im2collette_fifo':'im2collette_fifo'}
PHASES=['planning','input_transfers','kernel_transfers','core_execution','output_transfers','tile_transitions']
SUB=['im2col','weights','advances','stalls','transitions','retries']
def words(p):return [int(w,16) for line in p.read_text().splitlines() for w in line.split('//',1)[0].split()]
def run(cmd,cwd,log,timeout):
 with log.open('w') as f:subprocess.run(cmd,cwd=cwd,stdout=f,stderr=subprocess.STDOUT,check=True,timeout=timeout)
def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--variant',choices=['all',*MAP],default='all');parser.add_argument('--layer',action='append');parser.add_argument('--out-dir',type=Path,required=True);parser.add_argument('--timeout',type=int,default=259200);parser.add_argument('--prepare',action='store_true',help='Verify source/fixture identity and write plan without simulation')
 args=parser.parse_args();out=args.out_dir.resolve();out.mkdir(parents=True,exist_ok=False)
 compiler=os.environ.get('IVERILOG_BIN') or shutil.which('iverilog');vvp=os.environ.get('VVP_BIN') or shutil.which('vvp');back=os.environ.get('IVERILOG_BACKEND');assert args.prepare or (compiler and vvp),'Install Icarus or set IVERILOG_BIN/VVP_BIN'
 manifest=json.loads((ROOT/'tools/workloads/manifest.json').read_text());plan=[];results=[]
 for pub,v in MAP.items():
  if args.variant not in ['all',pub]:continue
  src=ROOT/'tiled'/pub;report=ROOT/'reports/tiled'/pub
  provenance=json.loads((report/'provenance.json').read_text())
  for name,digest in provenance['source_sha256'].items():assert hashlib.sha256((src/name).read_bytes()).hexdigest()==digest,'Changed source: '+name
  accepted=json.loads((report/'cycles/accepted.json').read_text());specs=[r for r in accepted if not args.layer or r['layer'] in args.layer];assert specs,'No selected layers'
  dest=out/pub;dest.mkdir();binary=dest/'measurement.vvp'
  if not args.prepare:run([str(compiler),*(['-B',back] if back else []),'-g2012','-Wall','-I',str(src/'sim'),'-s','tb_conv_accelerator','-Ptb_conv_accelerator.ARRAY_SIZE=10','-o',str(binary),str(src/'sim/tb_conv_accelerator.v'),*map(str,sorted((src/'rtl').glob('*.v')))],src,dest/'compile.log',args.timeout)
  for spec in specs:
   layer=spec['layer'];fixture=ROOT/'tools/workloads/tiled'/layer;case=dest/layer
   for name in ['input_tensor.txt','kernel_tensor.txt','output_tensor.txt']:
    digest=hashlib.sha256((fixture/name).read_bytes()).hexdigest();assert digest==manifest['tiled/'+layer+'/'+name]==spec['tensor_hashes'][name],fixture/name
   plan.append(dict(variant=pub,layer=layer,config=spec['config'],accepted_cycles=spec['total']))
   if args.prepare:continue
   case.mkdir();run([str(vvp),*(['-M',back] if back else []),str(binary),*[f'+{k}={val}' for k,val in spec['config'].items()],f'+INPUT_FILE={fixture}/input_tensor.txt',f'+KERNEL_FILE={fixture}/kernel_tensor.txt',f'+OUTPUT_FILE={case}/actual.txt',f'+SRAM_LAYOUT_FILE={case}/layout.txt'],src,case/'run.log',args.timeout)
   text=(case/'run.log').read_text();assert 'PASS:' in text and not re.search(r'FATAL:|ERROR:',text),case
   assert words(case/'actual.txt')==words(fixture/'output_tensor.txt'),case
   total=int(re.search(r'Layer cycles[^:]*:\s*(\d+)',text)[1]);assert total==spec['total'],case
   m=re.search(r'\[TILED_CYCLES\] '+' '.join(k+r'=(\d+)' for k in PHASES)+r' tiles=(\d+) core_jobs=(\d+) tap_jobs=(\d+) signature=([0-9a-f]+)',text);assert m,case
   counts=dict(zip(PHASES,map(int,m.groups()[:6])));assert sum(counts.values())==total
   assert all(counts[k]==spec[k] for k in PHASES),case
   assert (int(m[7]),int(m[8]),int(m[9]),m[10])==(spec['tiles'],spec['core_jobs'],spec['tap_jobs'],spec['transfer_signature']),case
   nested=re.search(r'\[CORE_CYCLES\] '+' '.join(k+r'=(\d+)' for k in SUB),text);assert nested
   assert dict(zip(SUB,map(int,nested.groups())))==spec['nested_core'],case
   results.append(dict(variant=pub,layer=layer,cycles=total,outputs=spec['outputs'],status='PASS'));print(pub,layer,total,'PASS',flush=True)
 (out/'plan.json').write_text(json.dumps(plan,indent=2)+'\n')
 if results:
  with (out/'results.csv').open('w',newline='') as f:
   writer=csv.DictWriter(f,list(results[0]));writer.writeheader();writer.writerows(results)
 (out/'SUCCESS.json').write_text(json.dumps(dict(stage='PREPARED' if args.prepare else 'VALIDATED',cases=len(plan),results=results),indent=2)+'\n')
if __name__=='__main__':main()
