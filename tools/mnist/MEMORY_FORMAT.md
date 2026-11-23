# Files, descriptors and external-memory layout

## Spatial CNN files

The CNN notebook exports signed INT8 weights in KCRS order, biases in INT32
and each layer's multiplier, shift, stride, requantization enable and ReLU
enable. The first Dense weight tensor is permuted from Keras HWC feature
order to the accelerator's external CHW order. The original dense release
uses the legacy parameter format described below.

Addresses below are **word addresses**. Each memory word is 32 bits, with
one value per word. AI assistance: Codex.

## Layer descriptor program

`conv_program` starts reading at `program_base` and advances by 27 words per
layer. The table and tensors share backing memory. Each descriptor occupies
108 bytes. Place the table outside regions the accelerator writes.

| Word offset | Field | Bits used |
|---:|---|---:|
| 0–8 | `N, C, H, W, K, R, S, P, Q`, in order | 32 each |
| 9–14 | Vertical and horizontal padding, stride and dilation, in order | 32 each |
| 15–17 | Input, weight and output base word addresses | 32 each |
| 18 | Requantization enable | 1 |
| 19 | Right shift | 5 |
| 20 | Round-to-nearest enable | 1 |
| 21 | `last` flag | 1 |
| 22 | Expected output count for replay verification | 32 in the fixture |
| 23 | Unsigned requantization multiplier | 32 |
| 24 | Bias enable | 1 |
| 25 | Bias base word address | 32 |
| 26 | ReLU enable | 1 |

The controller reads word 22 as part of the fixed record stride. Execution
derives geometry from words 0–14. Flag bits occupy bit 0 and shift occupies
bits 4:0. The exporter stores the addresses of actual tensor buffers, so the
next layer uses the preceding layer's completed writes.

## Inputs and weights

Standalone layer files encode signed INT8 values as unsigned hexadecimal bytes (`7f` = 127, `80` = −128). Inputs flatten in NCHW order; kernels flatten in KCRS order, with the last coordinate varying fastest. Optional `// shape=(...)` headers provide dimensions to `run_case.py`; otherwise supply dimensions explicitly.

`tools/mnist/training/integer_tensors.npz` stores `w0/w1` in `[output,input]` order and signed32 `b0/b1`. The equivalent `export/w0.hex`, `export/w1.hex`, `export/b0.hex` and `export/b1.hex` are included for standalone runners. Dense `[K,C]` weights flatten like KCRS when R=S=1.

## Bias files

Bias files contain one signed INT32 bias per output channel, encoded as eight-digit unsigned hex words:

```text
00000005
fffffffd
0000000c
```

These encode biases 5, −3 and 12. A testbench/host loads them into consecutive external-memory locations:

```text
memory[bias_base + k] = bias for output channel k
```

The descriptor enables bias and supplies `cfg_bias_base`. The RTL issues an external-memory read for each channel in a completed output tile, captures its signed32 bias, adds it with ACC32 wrap, then processes that channel's outputs. Bias is added once to each completed value, never to reduction partial sums. A channel's bias is reused across spatial values in that tile; a later tile can fetch it again.

From an implementation folder, a single-layer example is:

```bash
python3 run_case.py --input-file input.hex --kernel-file weights.hex \
  --bias-file bias.hex --quantize --multiplier 815571 --shift 31 \
  --rounding nearest --N 1 --C 784 --H 1 --W 1 --K 128 --R 1 --S 1 \
  --out-dir runs/custom_dense_layer
```

The runner loads the bias file into its backing memory and drives the descriptor's bias controls. It computes new reference outputs for the supplied tensors. This single-layer command does not perform software ReLU.

## Scales

`training/quantization.json` supplies each layer's integer `multiplier` and `shift`, representing `multiplier / 2**shift`. The real-number scale fields document calibration; the RTL receives only the integer controls.

| Layer | Multiplier | Shift | Requantization | Bias |
|---|---:|---:|---|---|
| 784→128 | 815,571 | 31 | Enabled | Enabled |
| 128→10 | 5,999,190 | 31 | Disabled | Enabled |

The final multiplier/shift are retained exactly as exported, though bypassed by `cfg_quantize=0`; bias remains enabled. Notebook-named exports `dense_weights.hex`/`dense_1_weights.hex` and bias files are byte-identical aliases of the corresponding `w0/w1` and `b0/b1` files.

The scale parameters are stored in the descriptor table. The accelerator captures the multiplier, shift, rounding and requantization enable on descriptor acceptance. One multiplier/shift pair serves the whole layer. Bias is independently enabled, including when final-layer requantization is disabled.

For conventional symmetric quantization, the target requantization factor is `(input_scale * weight_scale) / output_scale`, and a bias is represented in accumulator units using `input_scale * weight_scale`. Supplied biases must already be integer-encoded in those units; the RTL does not convert floating-point biases or derive calibration scales.

## Generated replay files

The MNIST runner creates:

- `memory.hex`: sparse 32-bit `$readmemh` backing-memory initialization containing input, weights, biases and the layer program, with `@` word-address markers.
- `descriptors.hex`: copy of the 27-word records used by the testbench to check execution.
- `expected.hex`: integer reference outputs before applying ReLU, used by the legacy comparison.
- `post.hex`: integer reference outputs with the configured ReLU behavior.

The testbench uses references only to check actual outputs. Each layer reads actual memory writes from its predecessor. Hardware ReLU is applied on writeback.

## Output layout and write sequence

Final external-memory layout is NKPQ in both implementations:

```text
address(n,k,p,q) = output_base + ((n*K + k)*P + p)*Q + q
```

Each completed value occupies one 32-bit word. Quantized −3 is `fffffffd`; raw32 scores retain all 32 bits after optional bias. Bias and scale parameters are not appended to the output tensor.

Writes traverse q positions within an output tile, then channels within its K tile. The scheduler advances q tiles, p rows, K tiles, then batch images. Addresses can jump between channel regions; a flat write transcript need not itself be NKPQ-ordered. Reading memory in increasing tensor-address order recovers NKPQ layout.

For dense MNIST, N=P=Q=1, so output neuron k is at `output_base+k`. The replay's chosen map is:

| Layer | Input base | Weight base | Bias base | Output base | Output words |
|---|---:|---:|---:|---:|---:|
| 784→128 | 0 | 1,024 | 140,000 | 150,000 | 128 |
| 128→10 | 150,000 | 101,376 | 140,128 | 151,000 | 10 |

These addresses are fixture choices, not hardwired RTL addresses. `raw_outputs.hex` and `rtl_outputs.hex` both contain the actual completed outputs, including enabled hardware ReLU, in layer/tensor order. The final ten words are raw signed32 classification scores.

## Complete demo memory ranges

| Word addresses, decimal | Contents |
|---|---|
| 0–783 | Quantized input image, one sign-extended INT8 per word |
| 1,024–101,375 | First-layer weights, neuron-major `[128,784]` |
| 101,376–102,655 | Final-layer weights, neuron-major `[10,128]` |
| 140,000–140,127 | First-layer signed32 biases |
| 140,128–140,137 | Final-layer signed32 biases |
| 150,000–150,127 | First-layer completed INT8 outputs after ReLU |
| 151,000–151,009 | Final biased signed32 scores, classes 0–9 |
| 199,600–199,653 | Two 27-word layer descriptors |

The Dense replay launches with `program_base=199600`. Its output files concatenate 128 hidden values and ten final scores for 138 words per inference.
