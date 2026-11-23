# NCHW accelerator with bias, output scaling and ReLU

This is a current main implementation, with `conv_program` as the memory-backed top. It includes descriptor chaining, optional signed32 bias per output channel, unsigned32 scale multiplication, shift/rounding and INT8 saturation and optional combinational ReLU on completed external writes. See the [main README](../../README.md) for architecture, interfaces, MNIST results and limitations.

The original scheduler/core, A10 defaults, signed8 operands, ACC32/CFG32, local8/external32 addressing and 15 KiB base SRAM capacity are preserved. Tensor-file order is NCHW input, KCRS kernel and NKPQ output. The fixed-latency external-memory model is testbench-only.

## Run a layer

Requires Python 3 and Icarus Verilog. From this folder:

```bash
python3 run_case.py --input-file sim/input_tensor.txt --kernel-file sim/kernel_tensor.txt \
  --expected-file sim/output_tensor.txt --out-dir runs/raw_example
```

The default has bias disabled and raw32 output. To enable requantization, add `--quantize --multiplier 3 --shift 8 --rounding nearest`; choose `floor` for arithmetic-floor rounding. Add `--bias-file bias.hex` for one signed32 bias per output channel, encoded as unsigned eight-digit hexadecimal words. Bias remains applied when `--quantize` is absent. A supplied `--expected-file` must match the selected processing; omit it to use the Python integer reference.

Tensor headers supply dimensions; without headers provide `--N --C --H --W --K --R --S`. Geometry controls include padding, stride and dilation for each axis. Without supplied input/kernel files the runner generates deterministic fixtures. Use `--help` for options and `--timeout` for large layers. Tool overrides are `IVERILOG_BIN`, `VVP_BIN` and `IVERILOG_BACKEND`.

`conv_golden.py` retains the original course convolution reference; `output_processing.py` models wrapped bias and exact integer requantization. The runner checks actual RTL words against both Verilog and Python references. Generated outputs stay under the selected directory.

Replay the spatial CNN to check actual layer-to-layer memory handoffs and combinational writeback ReLU. [MNIST replay](../../tools/mnist/README.md) · [Local CNN results](../../reports/mnist_cnn_relu/README.md) · [Published dense results](../../reports/current/README.md) · [Historical chaining study](../../reports/chaining/README.md)

## Credits

Original systolic foundation: https://github.com/kaggar11/systolic_4x4arr . Algorithmic reference: Zhou et al., https://doi.org/10.48550/arXiv.2110.03901 . Original course/reference attribution remains in `conv_golden.py`. AI assistance: Codex and GPT-6.1 Sol.
