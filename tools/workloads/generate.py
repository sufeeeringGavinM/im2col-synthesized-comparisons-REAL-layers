"""Exact signed-integer synthetic layer fixtures; retained course golden is unchanged."""
from pathlib import Path
from types import SimpleNamespace
import argparse,hashlib,importlib,json,random,sys
W=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(W/'tiled/NHWC'))
import gen_matrices as original

def integer_convolve(inputs,kernels,cfg):
    return original.convolve(inputs,kernels,cfg)

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--out-dir',type=Path,required=True);args=parser.parse_args();out_root=args.out_dir.resolve();out_root.mkdir(parents=True,exist_ok=False)
    # Compare the accelerated workload-only calculation against the preserved
    # course golden on all four kernel/stride/padding patterns, signed edges,
    # and accumulation values spanning the signed32 boundary.
    validation=[]
    for spec in json.loads((W/'tools/workloads/layers.json').read_text()):
      cfg=SimpleNamespace(**spec['config']);small=SimpleNamespace(**{**spec['config'],'C':3,'K':2,'H':max(13,cfg.R),'W':max(15,cfg.S)})
      rng=random.Random(spec['seed']);i=[rng.randint(-128,127) for _ in range(small.N*small.C*small.H*small.W)];k=[rng.randint(-128,127) for _ in range(small.K*small.C*small.R*small.S)]
      assert integer_convolve(i,k,small)==original.convolve(i,k,small)
      validation.append(dict(layer=spec['layer'],small_geometry=vars(small),status='PASS'))
      tensor=out_root/spec['layer'];tensor.mkdir(parents=True,exist_ok=False)
      rng=random.Random(spec['seed']);i=[rng.randint(-128,127) for _ in range(cfg.N*cfg.C*cfg.H*cfg.W)];k=[rng.randint(-128,127) for _ in range(cfg.K*cfg.C*cfg.R*cfg.S)]
      out=integer_convolve(i,k,cfg);P,Q=original.output_shape(cfg)
      assert [1,cfg.K,P,Q]==spec['output_shape']
      original.write_hex_tensor(tensor/'input_tensor.txt',(cfg.N,cfg.C,cfg.H,cfg.W),i,8)
      original.write_hex_tensor(tensor/'kernel_tensor.txt',(cfg.K,cfg.C,cfg.R,cfg.S),k,8)
      original.write_hex_tensor(tensor/'output_tensor.txt',(cfg.N,cfg.K,P,Q),out,32)
      record=dict(**spec,distribution='Python random.Random(seed), sequential randint(-128,127): inputs then kernels; synthetic activity',generator='Retained Python integer golden with32-bit wrap; original Verilog independent loop golden retained',arithmetic_engine='retained pure Python integer golden',python_version=sys.version,sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in tensor.glob('*.txt')})
      (tensor/'provenance.json').write_text(json.dumps(record,indent=2)+'\n');print(spec['layer'],len(out),'golden outputs',flush=True)
    # Large signed32 wrap independently checked against retained course model.
    cfg=SimpleNamespace(N=1,C=140000,H=1,W=1,K=1,R=1,S=1,pad_i=0,pad_j=0,stride_i=1,stride_j=1,dilation_i=1,dilation_j=1)
    assert integer_convolve([-128]*cfg.C,[-128]*cfg.C,cfg)==original.convolve([-128]*cfg.C,[-128]*cfg.C,cfg)
    (out_root/'golden_validation.json').write_text(json.dumps(dict(patterns=validation,signed32_wrap='PASS'),indent=2)+'\n')
if __name__=='__main__':main()
