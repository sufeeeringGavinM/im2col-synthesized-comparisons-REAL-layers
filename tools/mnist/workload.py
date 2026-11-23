"""Exact matched workload fixtures and phase accounting; no training. AI: Codex."""
from pathlib import Path
import hashlib,json,re
import numpy as np
E=Path(__file__).resolve().parent
from reference import conv_layer, layer

PROGRAM_BASE = 199600


def words(path,values):path.write_text(''.join(f'{int(v)&0xffffffff:08x}\n' for v in np.asarray(values).flat))


def fixture(dest, inputs, weights, biases, configs, expected=None):
    dest.mkdir(parents=True, exist_ok=False)
    x = np.asarray(inputs, dtype=np.int64)
    memory = dict(enumerate(map(int, x.flat)))
    desc, raw, post = [], [], []
    ibase, kbase, bbase, obase = 0, 1024, 140000, 150000
    for i, (w, b, c) in enumerate(zip(weights, biases, configs)):
        if w.ndim == 2:
            w = w[:, :, None, None]
        K, C, R, S = w.shape
        stride = c.get('stride', (1, 1))
        x = ((x + 128) % 256) - 128  # Transfers use the low signed INT8 byte.
        args = (c['multiplier'], c['shift'], c['quantize'], False)
        if (R, S) == (1, 1):
            # Dense gathers the preceding CHW feature map at one position.
            x = x.reshape(1, C, 1, 1)
            before, _ = layer(x.reshape(1, C), w.reshape(K, C), b, *args)
            before = before.reshape(1, K, 1, 1)
        else:
            x = x.reshape(1, C, *x.shape[-2:])
            before, _ = conv_layer(x, w, b, stride, *args)
        _, _, H, W = x.shape
        _, _, P, Q = before.shape
        outputs = K * P * Q
        memory.update({kbase + j: int(v) for j, v in enumerate(w.flat)})
        memory.update({bbase + j: int(v) for j, v in enumerate(b.flat)})
        desc += [1, C, H, W, K, R, S, P, Q, 0, 0, *stride, 1, 1, ibase, kbase, obase,
                 int(c['quantize']), c['shift'], 1, int(i == len(configs) - 1), outputs,
                 c['multiplier'], 1, bbase, int(c['relu'])]
        after = np.maximum(before, 0) if c['relu'] else before
        if expected is not None:
            np.testing.assert_array_equal(after.ravel(), expected[i].ravel())
        raw.extend(before.flat)
        post.extend(after.flat)
        x = after
        kbase += w.size
        bbase += K
        ibase = obase
        obase += max(1000, outputs)
    assert kbase <= 140000 and bbase <= 150000 and obase <= PROGRAM_BASE
    memory.update({PROGRAM_BASE + offset: value for offset, value in enumerate(desc)})
    (dest/'memory.hex').write_text(''.join(f'@{a:x}\n{v & 0xffffffff:08x}\n' for a,v in sorted(memory.items())))
    words(dest/'descriptors.hex', desc)
    words(dest/'expected.hex', raw)
    words(dest/'post.hex', post)
    (dest/'FIXTURE.json').write_text(json.dumps(dict(descriptor_words=27, program_base=PROGRAM_BASE,
        layers=len(configs), outputs=len(post)), indent=2)+'\n')


def model_parameters(model):
    if model == 'dense':
        with np.load(E/'training/integer_tensors.npz') as tensors:
            configs = json.loads((E/'training/quantization.json').read_text())['layers']
            return ([tensors[f'w{j}'] for j in range(len(configs))],
                    [tensors[f'b{j}'] for j in range(len(configs))], configs)
    names = ('conv1', 'conv2', 'dense1', 'dense2')
    with np.load(E/'training_cnn/mnist_quantized_int8.npz') as tensors:
        configs = [dict(multiplier=int(tensors[f'{name}_multiplier']),
                        shift=int(tensors[f'{name}_shift']),
                        stride=tuple(map(int, tensors[f'{name}_stride'])),
                        quantize=bool(tensors[f'{name}_quantize']),
                        relu=bool(tensors[f'{name}_relu'])) for name in names]
        return ([tensors[f'{name}_weights'] for name in names],
                [tensors[f'{name}_biases'] for name in names], configs)


def fixtures(root, sample_count=20, model='dense'):
    weights, biases, configs = model_parameters(model)
    sample_dir = 'training_cnn' if model == 'cnn' else 'training'
    key = 'quant'
    result = {key: []}
    with np.load(E/sample_dir/'rtl_samples.npz') as samples:
        for i, index in enumerate(samples['ids'][:sample_count]):
            dest = root/key/f'mnist_{int(index):05d}'
            fixture(dest, samples['inputs'][i], weights, biases, configs,
                    [samples[f'layer{j}'][i] for j in range(len(configs))])
            result[key].append(dict(id=int(index), label=int(samples['labels'][i]), fixture=str(dest)))
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
    fixture=json.loads((p/'FIXTURE.json').read_text())
    result['LAYERS']=str(fixture['layers'])
    if 'program_base' in fixture:
        result['PROGRAM_BASE']=str(fixture['program_base'])
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
    result = dict(layers=rows,total_accelerator_cycles=sum(r['cycles'] for r in rows),
                outputs_sha256=hashlib.sha256((folder/'rtl_outputs.hex').read_bytes()).hexdigest(),
                post_clamps=int(re.search(r'POST_CLAMPS (\d+)',text)[1]),
                chain_window_ps=int(re.search(r'CHAIN_WINDOW_NS (\d+)',text)[1]))
    fetch = re.search(r'DESCRIPTOR_READS (\d+)', text)
    if fetch:
        result['descriptor_reads'] = int(fetch[1])
        assert result['descriptor_reads'] == 27 * len(rows)
        result['restart_checked'] = 'RESTART_PASS' in text
    return result
