"""Replay the released MNIST integer pipeline; no training or synthesis. AI: Codex."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess

import numpy as np
import workload
from reference import preprocess

ROOT = Path(__file__).resolve().parents[2]
ARCHES = ['NHWC', 'NCHW_centralized']


def verify():
    identity = json.loads((ROOT / 'reports/current/source_identity.json').read_text())
    for name, digest in identity['files'].items():
        actual = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
        if actual != digest:
            raise RuntimeError('Source or fixture changed: ' + name)
    return identity


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', choices=['prepare', 'rtl'], default='prepare')
    parser.add_argument('--variant', choices=['all', *ARCHES], default='all')
    parser.add_argument('--samples', type=int, default=1, help='First 1..20 retained images')
    parser.add_argument('--directed', action='store_true', help='Also check three reduction/bias edge cases')
    custom = parser.add_mutually_exclusive_group()
    custom.add_argument('--image', type=Path, help='28x28 image: light digit on dark background; requires Pillow')
    custom.add_argument('--input-tensor', type=Path, help='784 already-quantized input values as two-digit hex words')
    parser.add_argument('--label', type=int, choices=range(10), help='Optional true label for a custom input')
    parser.add_argument('--out-dir', type=Path, required=True, help='A new output directory')
    parser.add_argument('--timeout', type=int, default=3600, help='Seconds per tool invocation')
    args = parser.parse_args()
    if not 1 <= args.samples <= 20:
        parser.error('--samples must be 1..20')
    if args.label is not None and not (args.image or args.input_tensor):
        parser.error('--label is for a custom image/input tensor')
    custom_input = None
    provenance = None
    if args.image:
        try:
            from PIL import Image
        except ImportError:
            parser.error('--image requires Pillow: python3 -m pip install pillow')
        with Image.open(args.image) as image:
            if image.size != (28, 28):
                parser.error('Expected a 28x28 image; resizing/inversion/centering are not automatic')
            custom_input = preprocess(np.asarray(image.convert('L'), dtype=np.uint8)).ravel()
        provenance = dict(kind='image', sha256=hashlib.sha256(args.image.read_bytes()).hexdigest(),
                          preprocessing='grayscale then floor((pixel*127+127)/255); row-major flatten')
    elif args.input_tensor:
        tokens = [word for line in args.input_tensor.read_text().splitlines()
                  for word in line.split('//', 1)[0].split()]
        values = [int(word, 16) for word in tokens]
        if len(values) != 784 or any(value < 0 or value > 255 for value in values):
            parser.error('Expected exactly 784 unsigned8 hex encodings')
        custom_input = np.asarray([value - 256 if value >= 128 else value for value in values], dtype=np.int64)
        provenance = dict(kind='quantized_tensor', sha256=hashlib.sha256(args.input_tensor.read_bytes()).hexdigest(),
                          preprocessing='signed INT8 values used directly; no pixel conversion')
    identity = verify()
    output = args.out_dir.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / 'plan.json').write_text(json.dumps(dict(
        stage=args.stage, samples=args.samples, directed=args.directed, custom_input=provenance,
        source_identity=identity), indent=2) + '\n')
    if args.stage == 'prepare':
        print('PASS: released source and fixture hashes match; no simulator launched')
        return
    compiler = os.environ.get('IVERILOG_BIN') or shutil.which('iverilog')
    runtime = os.environ.get('VVP_BIN') or shutil.which('vvp')
    backend = os.environ.get('IVERILOG_BACKEND')
    if not compiler or not runtime:
        raise RuntimeError('Install Icarus Verilog or set IVERILOG_BIN and VVP_BIN')
    if custom_input is not None:
        tensors = np.load(Path(__file__).with_name('training') / 'integer_tensors.npz')
        config = json.loads((Path(__file__).with_name('training') / 'quantization.json').read_text())['layers']
        fixture = output / 'fixtures/custom'
        workload.fixture(fixture, custom_input, [tensors[f'w{i}'] for i in range(len(config))],
                         [tensors[f'b{i}'] for i in range(len(config))], config)
        cases = [dict(id='custom', label=args.label, fixture=str(fixture))]
        if args.directed:
            cases += [case for case in workload.fixtures(output / 'fixtures', 1)['quant']
                      if case['label'] is None]
    else:
        cases = workload.fixtures(output / 'fixtures', args.samples)['quant']
    if not args.directed:
        cases = [case for case in cases if case['label'] is not None or case['id'] == 'custom']
    results = []

    def command(argv, cwd, log):
        with log.open('w') as stream:
            subprocess.run(list(map(str, argv)), cwd=cwd, stdout=stream,
                           stderr=subprocess.STDOUT, timeout=args.timeout, check=True)

    for arch in ARCHES if args.variant == 'all' else [args.variant]:
        folder = output / arch
        folder.mkdir()
        binary = folder / 'mnist.vvp'
        command([compiler, *(['-B', backend] if backend else []), '-g2012', '-Wall',
                 '-s', 'tb_mnist', '-o', binary, Path(__file__).with_name('tb_mnist.v'),
                 *sorted((ROOT / 'tiled' / arch / 'rtl').glob('*.v'))],
                folder, folder / 'compile.log')
        for case in cases:
            dest = folder / str(case['id'])
            dest.mkdir()
            command([runtime, *(['-M', backend] if backend else []), binary,
                     '+CLOCK_HALF_NS=25',
                     *[f'+{k}={v}' for k, v in workload.args(case['fixture']).items()]],
                    dest, dest / 'run.log')
            measured = workload.parse(dest)
            raw = np.array([int(word, 16) for word in
                            (dest / 'raw_outputs.hex').read_text().split()], dtype=np.int64)
            raw = (raw + (1 << 31)) % (1 << 32) - (1 << 31)
            classification = case['label'] is not None or case['id'] == 'custom'
            prediction = int(raw[-10:].argmax()) if classification else None
            if classification:
                expected_cycles = json.loads((ROOT/'reports/current/cycles.json').read_text())[arch]['total_accelerator_cycles']
                if measured['total_accelerator_cycles'] != expected_cycles:
                    raise RuntimeError('Released MNIST cycle count changed')
            results.append(dict(architecture=arch, id=case['id'], label=case['label'],
                                prediction=prediction,
                                correct=(prediction == case['label']) if case['label'] is not None else None,
                                **measured))
            print(f"PASS: {arch}, case {case['id']}, exact raw/post outputs, prediction={prediction}", flush=True)
    verify()
    (output / 'results.json').write_text(json.dumps(dict(status='PASS', cases=results), indent=2) + '\n')


if __name__ == '__main__':
    main()
