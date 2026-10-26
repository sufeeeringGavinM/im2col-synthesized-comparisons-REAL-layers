"""Sequential synthesis/GUI export and native-XSim-SAIF power reproduction."""
import argparse,csv,hashlib,importlib,json,os,shutil,sys,traceback
from pathlib import Path
import comparison_flow as flow

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--scope',choices=['tiled'],default='tiled')
    p.add_argument('--variant',choices=['all',*flow.MAP.values()],default='all')
    p.add_argument('--vivado-root',type=Path,required=True,help='Installation root containing bin/ and data/')
    p.add_argument('--out-dir',type=Path,required=True,help='NEW build directory; existing folders are refused')
    p.add_argument('--stage',choices=['synthesis','all','prepare'],default='all',help='prepare checks inputs only and writes a plan; all includes native workloads')
    p.add_argument('--reuse-build-root',type=Path,help='Existing accepted per-variant build folders; reuse matching synthesized.v/.dcp/rtl instead of synthesis')
    a=p.parse_args();flow.SCOPE=a.scope;flow.VIVADO_ROOT=a.vivado_root.resolve()
    flow.WINDOWS_TOOLS=(flow.VIVADO_ROOT/'bin/vivado.bat').is_file()
    flow.UNI=flow.VIVADO_ROOT/'data/verilog/src'
    assert (flow.VIVADO_ROOT/'bin'/('vivado.bat' if flow.WINDOWS_TOOLS else 'vivado')).is_file(),'Vivado installation missing'
    flow.BATCH=a.out_dir.resolve();flow.BATCH.mkdir(parents=True,exist_ok=False)
    flow.STATE.update(runner_pid=os.getpid(),status='PREPARING',scope=a.scope,batch_done=False,results={},workload_results=[],errors={})
    sys.path.insert(0,str(Path(__file__).parent/a.scope));workloads=importlib.import_module('run_workloads')
    variants=[v for v,pub in flow.MAP.items() if a.variant in ['all',pub]]
    settings=Path(__file__).parent/a.scope
    for v in variants:
        provenance=json.loads((flow.ROOT/'reports'/a.scope/flow.MAP[v]/'provenance.json').read_text())
        for name,digest in provenance['source_sha256'].items():
            assert hashlib.sha256((flow.source(v)/name).read_bytes()).hexdigest()==digest,'Source changed: '+name
        for row in flow.accepted(v):
            for name in ['input_tensor.txt','kernel_tensor.txt','output_tensor.txt']:
                assert (flow.fixture(row['layer'])/name).is_file()
        flow.STATE['results'][v]='QUEUED'
    flow.save_state()
    if a.stage=='prepare':
        flow.STATE.update(status='PREPARED',batch_done=True);flow.save_state();return
    for v in variants:
        try:
            flow.STATE.update(status='REUSING_HARDWARE' if a.reuse_build_root else 'SYNTHESIS_POWER_PROJECT',current=v);flow.STATE['results'][v]='RUNNING';flow.save_state()
            build=flow.BATCH/v;build.mkdir();shutil.copytree(flow.source(v)/'rtl',build/'rtl');shutil.copy2(settings/'timing.xdc',build/'timing.xdc')
            if a.reuse_build_root:
                original=a.reuse_build_root.resolve()/v
                provenance=json.loads((flow.ROOT/'reports'/a.scope/flow.MAP[v]/'provenance.json').read_text())
                for name,digest in provenance['rtl_sha256'].items():
                    assert hashlib.sha256((original/'rtl'/name).read_bytes()).hexdigest()==digest,'Reused RTL mismatch: '+name
                for name,key in [('synthesized.v','netlist_sha256'),('synthesized.dcp','dcp_sha256')]:
                    assert hashlib.sha256((original/name).read_bytes()).hexdigest()==provenance[key],'Reused hardware mismatch: '+name
                    shutil.copy2(original/name,build/name)
            else:
                flow.execute_tool('vivado',['-mode','batch','-source',flow.windows_path(settings/'synth_compare.tcl'),'-log',flow.windows_path(build/'vivado.log'),'-journal',flow.windows_path(build/'vivado.jou'),'-tclargs',flow.windows_path(build)],build,'synthesis',21600)
                assert (build/'SUCCESS').exists(),'Synthesis/export success marker missing'
            flow.STATE['results'][v]='SUCCEEDED'
        except Exception:
            flow.STATE['results'][v]='FAILED';flow.STATE['errors'][v+'/synthesis']=traceback.format_exc()
        flow.save_state()
    if a.stage=='all':
        for v in variants:
            if flow.STATE['results'][v]!='SUCCEEDED':continue
            try:workloads.run_variant(v,lambda:None)
            except Exception:flow.STATE['errors'][v+'/workloads']=traceback.format_exc()
            flow.save_state()
    rows=flow.STATE['workload_results']
    if rows:
        with (flow.BATCH/'workloads.csv').open('w',newline='') as f:
            w=csv.DictWriter(f,list(rows[0]));w.writeheader();w.writerows(rows)
    flow.STATE.update(status='COMPLETED_WITH_FAILURES' if flow.STATE['errors'] else 'COMPLETED',batch_done=True,current=None);flow.save_state()
    if flow.STATE['errors']:raise SystemExit(1)
if __name__=='__main__':main()
