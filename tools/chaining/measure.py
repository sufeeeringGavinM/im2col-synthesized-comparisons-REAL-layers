"""Repository-relative version of the accepted native measurement flow.
AI assistance: Codex. Native activity and all simulator transcripts stay unchanged.
"""
from pathlib import Path
from decimal import Decimal,ROUND_CEILING
import csv,hashlib,json,re,shutil,traceback
import comparison_flow as flow
import native_xsim,run_workloads
from metrics import words,quant,signed,metrics,get_metrics as chain_metrics
E=Path(__file__).resolve().parent
ROOT=E.parents[1]
OFFICIAL=ROOT
BATCH=None
ARCHES=['NHWC','NCHW_centralized']
def sha(p):
 with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def write_json(p,data):
 p=Path(p);tmp=p.with_suffix('.tmp');tmp.write_text(json.dumps(data,indent=2)+'\n');tmp.replace(p)
def report():
 rows=flow.STATE['workload_results']
 write_json(BATCH/'results.json',flow.STATE)
 if rows:
  keys=list(dict.fromkeys(k for r in rows for k in r))
  with (BATCH/'results.csv').open('w',newline='') as f:
   w=csv.DictWriter(f,keys);w.writeheader();w.writerows([{k:json.dumps(v) if isinstance(v,(dict,list)) else v for k,v in r.items()} for r in rows])

def util(p):
 t=flow.table_values(p);o={}
 for label,key in [('Slice LUTs','lut'),('Slice Registers','ff'),('Block RAM Tile','bram'),('DSPs','dsp')]:
  v=t[label];o[key]=float(v[0]);o[key+'_available']=float(v[-2]);o[key+'_percent']=float(v[-1])
 return o

def path_metrics(build):
 t=(build/'worst_path.rpt').read_text()
 return dict(source=re.search(r'Source:\s+([^\n]+)',t)[1].strip(),destination=re.search(r'Destination:\s+([^\n]+)',t)[1].strip(),data_path_delay_ns=float(re.search(r'Data Path Delay:\s+([\d.]+)',t)[1]),logic_levels=int(re.search(r'Logic Levels:\s+(\d+)',t)[1]))

def failure(key):
 flow.STATE['errors'][key]=traceback.format_exc();flow.save_state();report()

def periods(timing):
 p=Decimal(str(timing['estimated_minimum_period_ns']));own=(p/Decimal('.002')).to_integral_value(rounding=ROUND_CEILING)*Decimal('.002')
 return [('1mhz',Decimal(1000)),('own_fmax',own)]

def collect_power(arch,variant,case,frequency,period,metric,layer,mode,role,native):

 capture=dict(architecture=arch,variant=variant,layer=layer,role=role,frequency=frequency,period_ns=str(period),metric=metric,native=native,sha256={n:sha(case/n) for n in ['activity.saif','actual.txt','capture.tcl','run.log']},netlist_sha256=sha(BATCH/variant/'synthesized.v'),dcp_sha256=sha(BATCH/variant/'synthesized.dcp'))
 capture['source_sha256']={p.name:sha(p) for p in (ROOT/'tiled'/arch/'rtl').glob('*.v')}
 capture['harness_sha256']=sha(case.parent/'tb_conv_core.v')
 capture['tensor_sha256']={p.name:sha(p) for p in ((E/'fixtures/chain').glob('*.hex') if layer=='resnet8_chain' else case.glob('*_tensor.txt'))}
 (case/'CAPTURE_ACCEPTED.json').write_text(json.dumps(capture,indent=2)+'\n')
 flow.STATE.update(current=variant+'/'+case.name,status='POWER');flow.save_state()
 flow.execute_tool('vivado',['-mode','batch','-source',flow.windows_path(E/'flow/power.tcl'),'-log',flow.windows_path(case/'vivado.log'),'-journal',flow.windows_path(case/'vivado.jou'),'-tclargs',flow.windows_path(BATCH/variant/'synthesized.dcp'),flow.windows_path(case),str(period)],case,'power',7200)
 assert (case/'POWER_SUCCESS').exists(),case
 t=(case/'power.rpt').read_text();row=dict(architecture=arch,role=role,part='xc7a200tsbg484-1',layer=layer,quantize=mode,frequency=frequency,clock_mhz=float(Decimal(1000)/period),cycles=metric['cycles'],phases=metric['phases'],layers=metric.get('layers',[]),latency_us=float(period*Decimal(metric['cycles'])/1000),**native)
 for label,key in [('Dynamic (W)','dynamic_w'),('Device Static (W)','static_w'),('Total On-Chip Power (W)','total_w')]:row[key]=float(re.search(r'\|\s*'+re.escape(label)+r'\s*\|\s*([\d.]+)',t)[1])
 for label,key in [('Confidence Level','power_confidence'),('Design Nets Matched','design_nets_matched')]:row[key]=re.search(r'\|\s*'+re.escape(label)+r'\s*\|\s*([^|]+)',t)[1].strip()
 match=re.search(r'\((\d+)/(\d+)\)',row['design_nets_matched']);assert match and int(match[1])>0
 row['timing_at_simulated_frequency_all_constraints_met']='All user specified timing constraints are met.' in (case/'timing_1mhz.rpt').read_text()
 row['static_energy_uj']=row['static_w']*row['latency_us']
 row['energy_uj']=row['total_w']*row['latency_us'];row['dynamic_energy_uj']=row['dynamic_w']*row['latency_us']
 if layer!='resnet8_chain' and role=='derivative':
  matches=[r for r in flow.STATE['workload_results'] if r['role']=='control' and r['architecture']==arch and r['layer']==layer and r['frequency']==frequency]
  if matches:
   baseline=matches[0];row['same_target_control']=dict(case=baseline['case'],clock_mhz=baseline['clock_mhz'])
   for k in ['cycles','latency_us','dynamic_w','static_w','total_w','energy_uj','dynamic_energy_uj','static_energy_uj']:row[k+'_delta_vs_nexys_control']=row[k]-baseline[k]
 for n in ['synthesized.v','synthesized.dcp']:row[n+'_sha256']=sha(BATCH/variant/n)
 row['saif_sha256']=sha(case/'activity.saif');row['actual_sha256']=sha(case/'actual.txt');row['case']=str(case)
 row['evidence_reused']=False
 row['planning_share_percent']=100*row['phases']['planning']/row['cycles']
 flow.STATE['workload_results'].append(row);flow.save_state();report()

def chain_cases(arch):
 out=BATCH/'native_chain'/arch;out.mkdir(parents=True);flow.STATE.update(current=arch+'/chain',status='COMPILING_CHAIN');flow.save_state();run_workloads.prepare_chain(arch,out)
 accepted=next(r for r in json.loads((E/'fixtures/chain/RESULTS.json').read_text())['results'] if r['architecture']==arch)
 timing=next(r for r in flow.STATE['hardware'] if r['architecture']==arch)
 fixture=E/'fixtures/chain'
 for frequency,period in periods(timing):
  try:
   case=out/('chain_'+frequency);case.mkdir();flow.STATE.update(current=arch+'/'+case.name,status='NATIVE_CHAIN');flow.save_state()
   config=dict(CLOCK_HALF_NS=str(period/2),INIT=flow.windows_path(fixture/'chain_memory.hex'),DESC=flow.windows_path(fixture/'chain_descriptors.hex'),EXPECTED=flow.windows_path(fixture/'chain_expected.hex'))
   native=native_xsim.simulate(out,case,config,fixture,accepted['cycles'],period)
   actual=chain_metrics(case/'xsim.log');assert actual=={k:accepted[k] for k in ['cycles','phases','layers']}
   assert chain_metrics(out/('xsim_'+case.name+'_console.log'))==actual
   write_json(case/'ACCOUNTING_ACCEPTED.json',dict(status='PASS',parser='Unchanged strict parser on each transcript separately',metric=actual,sha256={str(p):sha(p) for p in [case/'xsim.log',out/('xsim_'+case.name+'_console.log'),case/'run.log']}))
   assert words(case/'actual.txt')==words(fixture/'chain_expected.hex')
   shutil.copy2(fixture/'chain.json',case/'chain.json')
   collect_power(arch,arch,case,frequency,period,actual,'resnet8_chain',1,'derivative',native)
  except Exception:failure(arch+'/chain/'+frequency)

def layer_cases(arch,control):
 variant=('control_' if control else '')+arch;role='control' if control else 'derivative'
 out=BATCH/'native_layers'/variant;out.mkdir(parents=True);flow.STATE.update(current=variant,status='COMPILING_LAYERS');flow.save_state();run_workloads.prepare(variant,out)
 timing=json.loads((BATCH/variant/'timing_metrics.json').read_text())
 assert not control,'Controls are reused, never launched by this queue'
 evidence=E/'fixtures/validation/RESULTS.json'
 accepted=[r for r in json.loads(evidence.read_text())['cases'] if r['architecture']==arch and r['quantize']==0]
 for frequency,period in periods(timing):
  for c in accepted:
   for mode in [0]:
    try:
     layer=c['layer'];case=out/(frequency+'_'+layer+'_q'+str(mode));case.mkdir();flow.STATE.update(current=variant+'/'+case.name,status='NATIVE_LAYER');flow.save_state()
     fixture=flow.fixture(layer)
     for n in ['input_tensor.txt','kernel_tensor.txt','output_tensor.txt']:shutil.copy2(fixture/n,case/n)
     config={**c['config'],'CLOCK_HALF_NS':str(period/2),'QUANTIZE':mode,'ROUND_NEAREST':1,'OUTPUT_SHIFT':4}
     native=native_xsim.simulate(out,case,config,case,c['cycles'],period)
     m=metrics(case/'run.log');assert m['cycles']==c['cycles'] and m['phases']==c['phases']
     assert words(case/'actual.txt')==[quant(signed(v),mode,4,1) for v in words(fixture/'output_tensor.txt')]
     collect_power(arch,variant,case,frequency,period,m,layer,mode,role,native)
    except Exception:failure(variant+'/'+frequency+'/'+c['layer']+'_q'+str(mode))
