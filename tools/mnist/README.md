# MNIST RTL replay

Requires Python 3 with NumPy and Icarus Verilog. Custom image loading also requires Pillow (`python3 -m pip install pillow`). Install NumPy in your Python environment (`python3 -m pip install numpy`); training frameworks and a dataset download are not needed. AI assistance: Codex.

From the repository root:

```bash
python3 tools/mnist/run.py --stage prepare --out-dir runs/mnist_prepare
python3 tools/mnist/run.py --stage rtl --samples 1 --out-dir runs/mnist_rtl
```

Use `--samples 20 --directed` for all retained images and three directed reduction/bias cases per implementation. Select one architecture with `--variant NHWC` or `--variant NCHW`. `--timeout` sets seconds per invocation. Set `IVERILOG_BIN`, `VVP_BIN` and optionally `IVERILOG_BACKEND` for nonstandard tool installations. Each output directory must be new.

`run.py` verifies released source/model hashes, generates memory fixtures, compiles `tb_mnist.v` against main RTL, and checks actual writes and intermediate handoffs. Per-layer phases/jobs/core cycles, raw/postprocessed outputs and predictions are written under the output folder. It checks accepted MNIST cycle totals as well as exact values; classification correctness is distinct from arithmetic correctness.

`reference.py` is an independent NumPy INT8/ACC32 dense model. `workload.py` generates fixtures. `training/integer_tensors.npz` stores `[output,input]` weights and signed32 biases; `quantization.json` contains calibration provenance and controls. `rtl_samples.npz` contains inputs, labels and expected intermediates. `test_predictions.npz`, metrics and history preserve original evaluation provenance; replay does not retrain.

Descriptors in this **testbench file format** have 27 words per layer: geometry (0–14), input/kernel/output bases (15–17), requantization enable (18), shift (19), nearest mode (20), last flag (21), output count (22), multiplier (23), bias enable/base (24–25), and **software activation flag (26)**. Word 26 is not an RTL port. This is a testbench convention, not a hardware descriptor-fetch interface.

The hidden layer applies software ReLU to actual writes before starting the next layer. The final layer uses bias and raw32 scores. Software transforms have zero assigned simulated time, so cycles exclude offload/host cost. The bench changes live configuration after acceptance to check captured controls and attempts descriptors while busy.

The released parameters follow the supplied `MNIST_Training_Test_3_.ipynb`: 784→128→10, using its final-epoch training and export cells with seed 196. Fresh full-test-set accuracy is 97.53% float and 97.51% integer. RTL coverage of 20 selected images does not establish full-test-set RTL accuracy.

## Use a different image or tensor

```bash
python3 tools/mnist/run.py --stage rtl --image digit.png --label 7 --out-dir runs/my_digit
python3 tools/mnist/run.py --stage rtl --input-tensor input.hex --out-dir runs/my_tensor
```

`--image` accepts images of any dimensions, with a light digit on a dark background. It converts to grayscale, resizes to 28×28 using Lanczos when needed, applies `floor((pixel*127+127)/255)` and flattens in row-major order. Images already at 28×28 retain their grayscale pixels. Non-square images are stretched to the square input size. Use centered digits resembling the MNIST examples; inversion and centering remain manual. The run plan records original dimensions/mode, processed dimensions and the resize method. `--label` is optional and affects only classification reporting, not expected arithmetic.

`--input-tensor` accepts exactly 784 signed INT8 values encoded as unsigned two-digit hex words, with optional `//` comments. It uses them directly, without pixel normalization. Both custom modes run the released two-layer model and generate fresh integer-reference intermediates, then compare every actual RTL output. Source/model checks remain strict; the new input hash and preprocessing are recorded in the output plan. A correct arithmetic match does not guarantee that the model recognizes arbitrary handwriting.

For a convolution of a different shape, use an implementation's `run_case.py` with NCHW input, KCRS weight and optional signed32 bias hex files. Headers carry shapes; otherwise provide dimensions and geometry flags. The runner derives output shape and computes a fresh independent Python reference, so a pre-existing expected-output file is optional. The external-memory/local tiling limits still apply. See the [NHWC layer runner](../../tiled/NHWC/README.md).

See [file and external-memory formats](MEMORY_FORMAT.md) for bias encoding, scale controls, output order and the demo memory map.

## Training provenance and rerun

The included notebook preserves every original cell's source text. Saved outputs and UI metadata are removed; [provenance](training/PROVENANCE.json) records the uploaded/published notebook hashes. `train_notebook.py` executes its training/export cells verbatim, adding seed 196 and environment/output-path setup. The final epoch is exported; no best-validation-checkpoint substitution is made.

Training uses all 60,000 MNIST training images with Keras's last-20% validation split: 48,000 training and 12,000 validation images. Calibration uses only the first 48,000. Both the original notebook validation and an independent NumPy reference match every final integer score on the 10,000-image test set. This is separate from selected-image RTL validation.

To retrain in a separate environment, install `requirements-training.lock`, then run:

```bash
python3 tools/mnist/train_notebook.py --out-dir runs/retrained_notebook
```

Training downloads MNIST and writes new parameters/metrics; it does not replace the released fixtures or refresh their hashes. The lock records the measured Python 3.13.18 / TensorFlow CPU 2.21.0 environment. Different environments can change training results despite a fixed seed. Validate new exports before using them as hardware evidence.

Weights and bias export use NumPy ties-to-even rounding. Runtime hidden-layer requantization uses a wide product and nearest rounding with ties away from zero, followed by software ReLU. The final layer adds bias and bypasses requantization. See [memory formats](MEMORY_FORMAT.md).
