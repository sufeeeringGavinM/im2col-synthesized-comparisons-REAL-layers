"""Replay the released MNIST integer pipeline; no training or synthesis. AI: Codex."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile

import numpy as np
import workload
from reference import preprocess

ROOT = Path(__file__).resolve().parents[2]
ARCHES = ['NHWC', 'NCHW']


def verify():
    identity = json.loads((Path(__file__).with_name('source_identity.json')).read_text())
    for name, digest in identity['files'].items():
        actual = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
        if actual != digest:
            raise RuntimeError('Source or fixture changed: ' + name)
    return identity


def load_image(path):
    """Convert a manual image to the model's 784 grayscale INT8 inputs."""
    from PIL import Image

    with Image.open(path) as image:
        original_size = image.size
        original_mode = image.mode
        grayscale = image.convert('L')
        resized = original_size != (28, 28)
        if resized:
            grayscale = grayscale.resize((28, 28), Image.Resampling.LANCZOS)
        inputs = preprocess(np.asarray(grayscale, dtype=np.uint8)).ravel()
    provenance = dict(kind='image', sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                      original_size=list(original_size), original_mode=original_mode,
                      processed_size=[28, 28], resized=resized,
                      resampling='lanczos' if resized else 'none',
                      preprocessing='grayscale; resize to 28x28 with Lanczos if needed; '
                                    'floor((pixel*127+127)/255); row-major flatten')
    return inputs, provenance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', choices=['prepare', 'py_sim', 'rtl'], default='prepare')
    parser.add_argument('--variant', choices=['all', *ARCHES], default='all')
    parser.add_argument('--model', choices=['cnn', 'dense'], default='cnn')
    parser.add_argument('--samples', type=int, default=1, help='First 1..20 retained images')
    parser.add_argument('--directed', action='store_true', help='Also check three reduction/bias edge cases')
    custom = parser.add_mutually_exclusive_group()
    custom.add_argument('--image', type=Path, help='Image auto-converted to grayscale and resized to 28x28; light digit on dark background; requires Pillow')
    custom.add_argument('--input-tensor', type=Path, help='784 already-quantized input values as two-digit hex words')
    parser.add_argument('--label', type=int, choices=range(10), help='Optional true label for a custom input')
    parser.add_argument('--out-dir', type=Path, help='A new output directory (default: unique runs/mnist_<stage>_* folder)')
    parser.add_argument('--program-base-input', action='store_true',
                        help='Enable the optional relocatable program base input in RTL')
    parser.add_argument('--timeout', type=int, default=3600, help='Seconds per tool invocation')
    args = parser.parse_args()
    max_samples = 20
    if not 1 <= args.samples <= max_samples:
        parser.error(f'--samples must be 1..{max_samples} for {args.model}')
    if args.label is not None and not (args.image or args.input_tensor):
        parser.error('--label is for a custom image/input tensor')
    custom_input = None
    provenance = None
    if args.image:
        try:
            custom_input, provenance = load_image(args.image)
        except ImportError:
            parser.error('--image requires Pillow: python3 -m pip install pillow')
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
    if args.out_dir is not None:
        output = args.out_dir.expanduser().resolve()
        output.mkdir(parents=True, exist_ok=False)
    else:
        runs = Path('runs').resolve()
        runs.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix=f'mnist_{args.stage}_', dir=runs))
    print(f'Output directory: {output}', flush=True)
    (output / 'plan.json').write_text(json.dumps(dict(
        stage=args.stage, model=args.model, samples=args.samples, directed=args.directed,
        program_base_input=args.program_base_input, custom_input=provenance,
        source_identity=identity), indent=2) + '\n')
    if args.stage == 'prepare':
        print('PASS: released source and fixture hashes match; no simulator launched')
        return
    if custom_input is not None:
        weights, biases, configs = workload.model_parameters(args.model)
        fixture = output / 'fixtures/custom'
        if args.model == 'cnn':
            custom_input = custom_input.reshape(1, 28, 28)
        workload.fixture(fixture, custom_input, weights, biases, configs)
        cases = [dict(id='custom', label=args.label, fixture=str(fixture))]
        if args.directed:
            cases += [case for case in workload.fixtures(output / 'fixtures', 1, args.model)['quant']
                      if case['label'] is None]
    else:
        cases = workload.fixtures(output / 'fixtures', args.samples, args.model)['quant']
    if not args.directed:
        cases = [case for case in cases if case['label'] is not None or case['id'] == 'custom']
    results = []
    if args.stage == 'py_sim':
        for case in cases:
            fixture = Path(case['fixture'])
            dest = output / 'python' / str(case['id'])
            dest.mkdir(parents=True)
            # Fixtures evaluate the integer reference layer by layer, feeding
            # computed post-ReLU values into the next layer (not saved goldens).
            shutil.copyfile(fixture / 'post.hex', dest / 'raw_outputs.hex')
            shutil.copyfile(fixture / 'post.hex', dest / 'rtl_outputs.hex')
            raw = [int(word, 16) for word in (dest / 'raw_outputs.hex').read_text().split()]
            raw = [(value + (1 << 31)) % (1 << 32) - (1 << 31) for value in raw]
            classification = case['label'] is not None or case['id'] == 'custom'
            prediction = int(np.argmax(raw[-10:])) if classification else None
            results.append(dict(engine='python', id=case['id'], label=case['label'],
                                prediction=prediction,
                                correct=(prediction == case['label']) if case['label'] is not None else None,
                                outputs=len(raw),
                                outputs_sha256=hashlib.sha256((dest / 'rtl_outputs.hex').read_bytes()).hexdigest()))
            print(f"PASS: python, case {case['id']}, integer inference, prediction={prediction}", flush=True)
        verify()
        (output / 'results.json').write_text(json.dumps(dict(
            status='PASS', stage='py_sim', cases=results), indent=2) + '\n')
        return

    compiler = os.environ.get('IVERILOG_BIN') or shutil.which('iverilog')
    runtime = os.environ.get('VVP_BIN') or shutil.which('vvp')
    backend = os.environ.get('IVERILOG_BACKEND')
    if not compiler or not runtime:
        raise RuntimeError('Install Icarus Verilog or set IVERILOG_BIN and VVP_BIN')

    def command(argv, cwd, log):
        with log.open('w') as stream:
            subprocess.run(list(map(str, argv)), cwd=cwd, stdout=stream,
                           stderr=subprocess.STDOUT, timeout=args.timeout, check=True)

    for arch in ARCHES if args.variant == 'all' else [args.variant]:
        folder = output / arch
        folder.mkdir()
        binary = folder / 'mnist.vvp'
        command([compiler, *(['-B', backend] if backend else []), '-g2012', '-Wall',
                 '-s', 'tb_mnist_program',
                 f'-Ptb_mnist_program.USE_PROGRAM_BASE_INPUT={int(args.program_base_input)}', '-o', binary, Path(__file__).with_name('tb_mnist_program.v'),
                 *sorted((ROOT / 'tiled' / arch / 'rtl').glob('*.v'))],
                folder, folder / 'compile.log')
        for case in cases:
            dest = folder / str(case['id'])
            dest.mkdir()
            command([runtime, *(['-M', backend] if backend else []), binary,
                     '+CLOCK_HALF_NS=25',
                     *(['+RESTART'] if case['id'] == 'raw' else []),
                     *[f'+{k}={v}' for k, v in workload.args(case['fixture']).items()]],
                    dest, dest / 'run.log')
            measured = workload.parse(dest)
            total, remainder = divmod(measured['chain_window_ps'], 50_000)
            if remainder or measured['descriptor_reads'] != 27 * len(measured['layers']):
                raise RuntimeError('Unexpected chain window or descriptor-read count')
            if case['id'] == 'raw' and not measured['restart_checked']:
                raise RuntimeError('Missing consecutive launch check')
            measured['total_chain_cycles'] = total
            measured['descriptor_control_cycles'] = total - measured['total_accelerator_cycles']
            raw = np.array([int(word, 16) for word in
                            (dest / 'raw_outputs.hex').read_text().split()], dtype=np.int64)
            raw = (raw + (1 << 31)) % (1 << 32) - (1 << 31)
            classification = case['label'] is not None or case['id'] == 'custom'
            prediction = int(raw[-10:].argmax()) if classification else None
            if classification and args.model == 'dense':
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
