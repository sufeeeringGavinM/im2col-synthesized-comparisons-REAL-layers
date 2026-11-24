# MNIST RTL replay

## Spatial CNN replay

The default workload is the University of Florida CNN. It runs two stride-2
spatial convolutions and two Dense layers, using hardware ReLU on completed writes from the first three weighted layers. See [the training notebook](MNIST_Training_Test_3_CNN.ipynb),
[training and checkpoint selection](training_cnn/METRICS.json), and
[current RTL, timing and power results](../../reports/layer_program/README.md).

```bash
python3 tools/mnist/run.py --stage py_sim
python3 tools/mnist/run.py --stage rtl --samples 20 --directed
```

The original dense workload is available through `--model dense`. The commands
below that refer to the published dense model use that flag. This legacy
workload runs with hardware ReLU on the updated RTL. The retained November 16
measurements used the original software/testbench clamp.


Requires Python 3 with NumPy; RTL replay also requires Icarus Verilog, and custom images require Pillow. For Ubuntu/WSL installation, stage selection, output files and troubleshooting, see the [main running instructions](../../README.md#run-the-accelerator). Training frameworks and a dataset download are not needed. AI assistance: Codex.

From the repository root:

```bash
python3 tools/mnist/run.py --model dense --stage prepare --out-dir runs/mnist_prepare
python3 tools/mnist/run.py --model dense --stage rtl --samples 1 --out-dir runs/mnist_rtl
```

Use `--samples 20 --directed` for all retained images and three directed reduction/bias cases per implementation. Select one architecture with `--variant NHWC` or `--variant NCHW`. `--timeout` sets seconds per invocation. Set `IVERILOG_BIN`, `VVP_BIN` and optionally `IVERILOG_BACKEND` for nonstandard tool installations. `--out-dir` is optional: by default, each run creates a unique `runs/mnist_<stage>_*` folder under the current working directory and prints its absolute path. An explicitly supplied output directory must be new.

`run.py` verifies released source/model hashes, generates memory fixtures, compiles `tb_mnist_program.v` against the `conv_program` top, and checks actual writes and intermediate handoffs. It records per-layer phases, jobs and core cycles, start-to-done chain cycles, descriptor reads, output words and predictions. Classification correctness is recorded separately from the exact output check.

`reference.py` is an independent NumPy INT8/ACC32 dense model. `workload.py` generates fixtures. `training/integer_tensors.npz` stores `[output,input]` weights and signed32 biases; `quantization.json` contains calibration provenance and controls. `rtl_samples.npz` contains inputs, labels and expected intermediates. `test_predictions.npz`, metrics and history preserve original evaluation provenance; replay does not retrain.

The [27-word descriptor records](MEMORY_FORMAT.md#layer-descriptor-program)
are embedded in `memory.hex`. The testbench presents the table base and pulses
`start` once. It checks sequential fetch addresses and every output word, and
attempts an extra launch during fetch. The `raw` directed case also tests a
fresh launch from a different program address after completion.

The published dense baseline applied software ReLU to actual writes. Current
RTL applies ReLU during writeback. The final layer uses bias and emits raw INT32
scores for software argmax.

The released parameters follow the supplied `MNIST_Training_Test_3_.ipynb`: 784→128→10, using its final-epoch training and export cells with seed 196. Fresh full-test-set accuracy is 97.53% float and 97.51% integer. RTL coverage of 20 selected images does not establish full-test-set RTL accuracy.

## Use a different image or tensor

```bash
python3 tools/mnist/run.py --model dense --stage rtl --image digit.png --label 7 --out-dir runs/my_digit
python3 tools/mnist/run.py --model dense --stage rtl --input-tensor input.hex --out-dir runs/my_tensor
```

`--image` accepts images of any dimensions, with a light digit on a dark background. It converts to grayscale, resizes to 28×28 using Lanczos when needed, applies `floor((pixel*127+127)/255)` and flattens in row-major order. Images already at 28×28 retain their grayscale pixels. Non-square images are stretched to the square input size. Use centered digits resembling the MNIST examples; inversion and centering remain manual. The run plan records original dimensions/mode, processed dimensions and the resize method. `--label` is optional and affects only classification reporting, not expected arithmetic.

`--input-tensor` accepts exactly 784 signed INT8 values encoded as unsigned two-digit hex words, with optional `//` comments. It uses them directly, without pixel normalization. Both custom input modes run the selected model and generate fresh integer-reference intermediates for comparison against every actual RTL output. Source/model checks remain strict; the new input hash and preprocessing are recorded in the output plan. A correct arithmetic match does not guarantee that the model recognizes arbitrary handwriting.

For a convolution of a different shape, use an implementation's `run_case.py` with NCHW input, KCRS weight and optional signed32 bias hex files. Headers carry shapes; otherwise provide dimensions and geometry flags. The runner derives output shape and computes a fresh independent Python reference, so a pre-existing expected-output file is optional. The external-memory/local tiling limits still apply. See the [NHWC layer runner](../../tiled/NHWC/README.md).

See [file and external-memory formats](MEMORY_FORMAT.md) for bias encoding, scale controls, output order and the demo memory map.

## Published dense model training provenance and rerun

The included notebook preserves every original cell's source text. Saved outputs and UI metadata are removed; [provenance](training/PROVENANCE.json) records the uploaded/published notebook hashes. `train_notebook.py` executes its training/export cells verbatim, adding seed 196 and environment/output-path setup. The final epoch is exported; no best-validation-checkpoint substitution is made.

Training uses all 60,000 MNIST training images with Keras's last-20% validation split: 48,000 training and 12,000 validation images. Calibration uses only the first 48,000. Both the original notebook validation and an independent NumPy reference match every final integer score on the 10,000-image test set. This is separate from selected-image RTL validation.

To retrain in a separate environment, install `requirements-training.lock`, then run:

```bash
python3 tools/mnist/train_notebook.py --out-dir runs/retrained_notebook
```

Training downloads MNIST and writes new parameters/metrics; it does not replace the released fixtures or refresh their hashes. The lock records the measured Python 3.13.18 / TensorFlow CPU 2.21.0 environment. Different environments can change training results despite a fixed seed. Validate new exports before using them as hardware evidence.

Weights and bias export use NumPy ties-to-even rounding. Runtime hidden-layer requantization uses a wide product and nearest rounding with ties away from zero, followed by ReLU. The final layer adds bias and bypasses requantization. See [memory formats](MEMORY_FORMAT.md).

## Python-only inference

```bash
python3 tools/mnist/run.py --model dense --stage py_sim --samples 1 --out-dir runs/python_demo
python3 tools/mnist/run.py --model dense --stage py_sim --image digit.png --out-dir runs/python_image
```

`py_sim` requires NumPy (and Pillow for images), without Icarus Verilog. It uses the same integer reference as RTL replay: signed INT8 inputs, wrapped INT32 accumulation/bias, integer scale multiplication, nearest rounding with ties away from zero, saturation, and ReLU. Computed outputs feed the next layer. It supports the same retained images, custom tensors/images, and `--directed` cases. `--variant` has no effect because both architectures implement the same arithmetic.

Outputs are in `python/<case>/raw_outputs.hex` and `python/<case>/rtl_outputs.hex` (both model completed writes with enabled ReLU). Each file concatenates layer outputs as eight-digit, lowercase, two's-complement hex words, one per line, exactly like RTL dumps. For the dense commands above, each file contains 128 hidden values followed by ten final scores. Predictions are in `results.json`. These are Python-computed tensors, not RTL execution or cycle measurements.

The runner identity hash tracks this CLI extension; historical RTL/synthesis measurements remain unchanged. Byte equality is checked against accepted RTL output hashes during development; a Python-only run does not itself verify the hardware.
