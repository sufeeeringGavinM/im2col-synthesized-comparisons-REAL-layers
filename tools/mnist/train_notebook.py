"""Execute the supplied notebook's training/export cells verbatim. AI: Codex.

The only training reproducibility addition is seed 196. No architecture,
optimizer, split, epoch, preprocessing or calibration substitutions are made.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import random
import sys
import time

E = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out-dir',type=Path,required=True,help='New training output directory')
args=parser.parse_args()
B=args.out_dir.expanduser().resolve().parent
os.environ['MPLBACKEND'] = 'Agg'
os.environ['KERAS_HOME'] = str(B / 'keras_cache')
os.environ['TF_CPP_MIN_LOG_LEVEL'] = '2'
os.environ['TF_NUM_INTRAOP_THREADS'] = '4'
os.environ['TF_NUM_INTEROP_THREADS'] = '1'
os.environ['TF_ENABLE_ONEDNN_OPTS'] = '0'
os.environ['TF_DETERMINISTIC_OPS'] = '1'
if hasattr(os, 'sched_setaffinity'):
    os.sched_setaffinity(0, sorted(os.sched_getaffinity(0))[:4])

import numpy as np
import tensorflow as tf
from reference import infer, preprocess


def save(path, data):
    Path(path).write_text(json.dumps(data, indent=2) + '\n')


def main():
    out = args.out_dir.expanduser().resolve()
    out.mkdir(parents=True, exist_ok=False)
    os.chdir(out)
    original = E / 'MNIST_Training_Test_3_.ipynb'
    notebook = json.loads(original.read_text())
    cells = [2, 4, 7, 9, 11, 13, 19, 21, 23, 25]
    ns = {'__name__': '__main__'}
    random.seed(196)
    np.random.seed(196)
    tf.keras.utils.set_random_seed(196)
    tf.config.threading.set_intra_op_parallelism_threads(4)
    tf.config.threading.set_inter_op_parallelism_threads(1)
    manifest = dict(notebook='MNIST_Training_Test_3_.ipynb',
                    notebook_sha256=hashlib.sha256(original.read_bytes()).hexdigest(),
                    seed=196, seed_note='Notebook has no fixed seed; this rerun fixes seed 196.',
                    python=platform.python_version(), tensorflow=tf.__version__,
                    numpy=np.__version__, executed_cells={}, skipped_cells='Markdown, example test-image plot and training-history plots only')
    start = time.monotonic()
    for index in cells:
        source = ''.join(notebook['cells'][index]['source'])
        manifest['executed_cells'][str(index)] = hashlib.sha256(source.encode()).hexdigest()
        print(f'NOTEBOOK_CELL_START {index}', flush=True)
        exec(compile(source, f'MNIST_Training_Test_3_.ipynb:cell{index}', 'exec'), ns)
        save(out / 'EXECUTION.json', dict(manifest, last_completed_cell=index))
        print(f'NOTEBOOK_CELL_PASS {index}', flush=True)
    model = ns['model']
    assert [layer.units for layer in model.layers if isinstance(layer, tf.keras.layers.Dense)] == [128, 10]
    assert ns['history'].params['epochs'] == 12
    tensors, config = {}, []
    input_scale = float(ns['s_input_initial'])
    sx = input_scale
    for i, p in enumerate(ns['layer_params']):
        tensors[f'w{i}'] = p['q_weights'].T.astype(np.int64)
        tensors[f'b{i}'] = p['q_biases'].astype(np.int64)
        quantize = i != len(ns['layer_params']) - 1
        so = p['s_bias'] / p['multiplier']
        config.append(dict(layer=i, input_channels=tensors[f'w{i}'].shape[1],
                           output_channels=tensors[f'w{i}'].shape[0], input_scale=sx,
                           weight_scale=float(p['s_w']), output_scale=float(so),
                           target_ratio=float(p['multiplier']), multiplier=int(p['q_multiplier']),
                           shift=int(p['q_shift']), quantize=quantize,
                           relu=bool(p['has_relu']), rounding='nearest_ties_away'))
        sx = so
    q_input = np.clip(np.round(ns['x_test'].reshape(-1, 784) / input_scale), -127, 127).astype(np.int64)
    pixels = np.round(ns['x_test'] * 255).astype(np.uint8)
    assert np.array_equal(preprocess(pixels.reshape(-1, 784)), q_input)
    # Independently reproduce every biased raw score, not only argmax accuracy.
    layers, stats = infer(q_input, tensors, config)
    assert np.array_equal(layers[-1], ns['q_x'])
    assert np.array_equal(layers[-1].argmax(1), ns['q_pred'])
    ids = np.array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 15, 17, 18, 21, 30, 35, 61, 84])
    np.savez(out / 'integer_tensors.npz', **tensors)
    np.savez(out / 'rtl_samples.npz', ids=ids, labels=ns['y_test'][ids], inputs=q_input[ids],
             pixels=pixels[ids], **{f'layer{i}': x[ids] for i, x in enumerate(layers)})
    np.savez(out / 'test_predictions.npz', labels=ns['y_test'],
             float_predictions=ns['y_pred'], integer_predictions=ns['q_pred'])
    save(out / 'quantization.json', dict(layers=config, input_scale=input_scale,
         calibration_images=48000, calibration_selection='x_train[:48000], excludes validation',
         weights_bias_rounding='NumPy round, ties to even, exactly as notebook',
         output_rounding='nearest ties away from zero, exactly as notebook integer validation',
         zero_point=0, final_output='biased INT32 without requantization'))
    history = {key: [float(x) for x in values] for key, values in ns['history'].history.items()}
    save(out / 'history.json', history)
    model.save(out / 'model.keras')
    metrics = dict(architecture=[784, 128, 10], epochs=12, batch_size=128,
                   optimizer='Keras Adam(0.001)', loss='SparseCategoricalCrossentropy(from_logits=True)',
                   validation_split=0.2, training_images=48000, validation_images=12000,
                   test_images=10000, calibration_images=48000, seed=196,
                   float_test_accuracy=float(ns['accuracy_score'](ns['y_test'], ns['y_pred'])),
                   integer_test_accuracy=float(ns['q_acc']),
                   independent_reference_matches_all_10000_raw_scores=True,
                   notebook_preprocessing_matches_runtime_preprocessing=True,
                   parameters=int(model.count_params()), integer_statistics=stats,
                   training_environment=manifest, wall_seconds=time.monotonic() - start)
    save(out / 'METRICS.json', metrics)
    save(out / 'MANIFEST.json', {str(p.relative_to(out)): hashlib.sha256(p.read_bytes()).hexdigest()
         for p in sorted(out.rglob('*')) if p.is_file() and p.name != 'MANIFEST.json'})
    print('NOTEBOOK_TRAINING_EXPORT_PASS', json.dumps(metrics), flush=True)


if __name__ == '__main__':
    main()
