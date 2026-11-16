# Files, descriptors and external-memory layout

Addresses below are **word addresses**. The external interface stores one value per word; no INT8 packing is implemented. These are testbench file conventions, not a hardware descriptor-fetch protocol. AI assistance: Codex.

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

Scales do **not** occupy external output-memory words. The host/testbench drives `cfg_output_multiplier`, `cfg_output_shift`, `cfg_round_nearest` and `cfg_quantize`; the accelerator captures them on descriptor acceptance. One multiplier/shift pair serves the whole layer. Bias is independently enabled, including when final-layer requantization is disabled.

For conventional symmetric quantization, the target requantization factor is `(input_scale * weight_scale) / output_scale`, and a bias is represented in accumulator units using `input_scale * weight_scale`. Supplied biases must already be integer-encoded in those units; the RTL does not convert floating-point biases or derive calibration scales.

## Generated replay files

The MNIST runner creates:

- `memory.hex`: sparse 32-bit `$readmemh` backing-memory initialization containing input, weights and biases, with `@` word-address markers.
- `descriptors.hex`: 27 words per layer, including geometry, memory bases, bias/scale controls and testbench-only bookkeeping.
- `expected.hex`: completed pre-software outputs from the integer reference.
- `post.hex`: reference outputs after any software activation.

The testbench uses references only to check actual outputs. Software transforms the actual memory writes before the next layer begins.

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

These addresses are fixture choices, not hardwired RTL addresses. `raw_outputs.hex` concatenates actual completed outputs before software activation; `rtl_outputs.hex` concatenates the actual values after that activation, both in layer/tensor order. The final ten words are raw signed32 classification scores.

## Complete demo memory ranges

| Word addresses, decimal | Contents |
|---|---|
| 0–783 | Quantized input image, one sign-extended INT8 per word |
| 1,024–101,375 | First-layer weights, neuron-major `[128,784]` |
| 101,376–102,655 | Final-layer weights, neuron-major `[10,128]` |
| 140,000–140,127 | First-layer signed32 biases |
| 140,128–140,137 | Final-layer signed32 biases |
| 150,000–150,127 | First-layer completed INT8 outputs; software ReLU updates these actual words |
| 151,000–151,009 | Final biased signed32 scores, classes 0–9 |

Unused addresses are not parameter arrays. The two 27-word descriptors are held by the testbench, outside this data-memory map. `multiplier`, `shift`, rounding and bias controls are driven from those descriptor records. The output files concatenate 128 hidden values and ten final scores: 138 words per inference.
