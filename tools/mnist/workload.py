"""Exact matched workload fixtures and phase accounting; no training. AI: Codex."""
from pathlib import Path
import hashlib,json,re
import numpy as np
E=Path(__file__).resolve().parent
from reference import layer


def words(path,values):path.write_text(''.join(f'{int(v)&0xffffffff:08x}\n' for v in np.asarray(values).flat))


def fixture(dest,inputs,weights,biases,configs,expected=None):
    dest.mkdir(parents=True,exist_ok=False)
    memory={i:int(v) for i,v in enumerate(inputs)};desc=[];raw=[];post=[]
    x=np.asarray(inputs,dtype=np.int64).reshape(1,-1)
    ibase,kbase,bbase=0,1024,140000
    for i,(w,b,c) in enumerate(zip(weights,biases,configs)):
        K,C=w.shape;obase=150000+i*1000
        memory.update({kbase+j:int(v) for j,v in enumerate(w.flat)})
        memory.update({bbase+j:int(v) for j,v in enumerate(b.flat)})
        desc += [1,C,1,1,K,1,1,1,1,0,0,1,1,1,1,ibase,kbase,obase,int(c['quantize']),c['shift'],1,int(i==len(configs)-1),K,c['multiplier'],1,bbase,int(c['relu'])]
        x=((x+128)%256)-128
        before,_=layer(x,w,b,c['multiplier'],c['shift'],c['quantize'],False)
        after=np.maximum(before,0) if c['relu'] else before
        if expected is not None:assert np.array_equal(after.ravel(),expected[i].ravel())
        raw.extend(before.flat);post.extend(after.flat);x=after
        kbase+=w.size;bbase+=K;ibase=obase
    assert max(memory)<140200 and kbase<=140000
    (dest/'memory.hex').write_text(''.join(f'@{a:x}\n{v&0xffffffff:08x}\n' for a,v in sorted(memory.items())))
    words(dest/'descriptors.hex',desc);words(dest/'expected.hex',raw);words(dest/'post.hex',post)
    (dest/'FIXTURE.json').write_text(json.dumps(dict(descriptor_words=27,layers=len(configs),
        host_relu=True,source='MNIST_Training_Test_3_.ipynb rerun',
        outputs=len(post),host_latency_model='unmeasured; testbench transform has zero simulated time'),indent=2)+'\n')


def fixtures(root,sample_count=20):
    samples=np.load(E/'training/rtl_samples.npz');t=np.load(E/'training/integer_tensors.npz')
    config=json.loads((E/'training/quantization.json').read_text())['layers']
    result={}
    key='quant';result[key]=[]
    for i,index in enumerate(samples['ids'][:sample_count]):
        dest=root/key/f'mnist_{int(index):05d}'
        fixture(dest,samples['inputs'][i],[t[f'w{j}'] for j in range(len(config))],
                [t[f'b{j}'] for j in range(len(config))],config,
                [samples[f'layer{j}'][i] for j in range(len(config))])
        result[key].append(dict(id=int(index),label=int(samples['labels'][i]),fixture=str(dest)))
    # Reduction continuation with opposite-sign prefixes, bias wrap, shift0
    # and quantized/raw ReLU enabled/disabled in successive descriptors.
    x=np.full(300,127,dtype=np.int64);w=np.zeros((5,300),dtype=np.int64)
    w[0,:256]=1;w[0,256:]=-10;w[1,:256]=-1;w[1,256:]=10;w[2]=1;w[3]=-1
    weights=[w,-np.eye(5,dtype=np.int64),np.eye(5,dtype=np.int64)]
    biases=[np.array([0,0,2147483647,-2147483648,-1]),np.array([0,1,-1,127,-128]),np.zeros(5,dtype=np.int64)]
    for name,q,activations in [('raw',False,[True,False,False]),('quantized',True,[True,True,False]),('disabled',False,[False]*3)]:
        cfg=[dict(quantize=q and j<2,shift=8 if q and j<2 else 0,multiplier=3 if q and j<2 else 1,relu=activations[j]) for j in range(3)]
        dest=root/key/name;fixture(dest,x,weights,biases,cfg)
        result[key].append(dict(id=name,label=None,fixture=str(dest)))
    return result


def args(fix,convert=str):
    p=Path(fix)
    result={k:convert(p/n) for k,n in [('INIT','memory.hex'),('DESC','descriptors.hex'),('EXPECTED','expected.hex'),('POST','post.hex')]}
    result['LAYERS']=str(json.loads((p/'FIXTURE.json').read_text())['layers'])
    return result


def parse(folder,log_name='run.log'):
    text=(folder/log_name).read_text(errors='replace')
    assert re.search(r'PASS: matched \d+-layer pipeline',text) and not re.search(r'FATAL|%Error|ERROR:',text),folder
    rows=[]
    for m in re.finditer(r'LAYER_PASS layer=(\d+) outputs=(\d+) cycles=(\d+) phases=(\d+) reads=(\d+) writes=(\d+) jobs=(\d+) core_busy=(\d+)',text):
        row=dict(zip(['layer','outputs','cycles','phase_total','reads','writes','jobs','core_busy'],map(int,m.groups())))
        row['phases']={s:int(n) for l,s,n in re.findall(r'PHASE layer=(\d+) state=(\d+) cycles=(\d+)',text) if int(l)==row['layer']}
        assert sum(row['phases'].values())==row['phase_total']==row['cycles']
        rows.append(row)
    assert len(rows)==int(re.search(r'PASS: matched (\d+)-layer pipeline',text)[1])
    return dict(layers=rows,total_accelerator_cycles=sum(r['cycles'] for r in rows),
                outputs_sha256=hashlib.sha256((folder/'rtl_outputs.hex').read_bytes()).hexdigest(),
                post_clamps=int(re.search(r'POST_CLAMPS (\d+)',text)[1]),
                chain_window_ps=int(re.search(r'CHAIN_WINDOW_NS (\d+)',text)[1]))
