# NCHW convolution with quantized layer chaining

`conv_chain` is the top-level module. Its valid/ready layer configuration interface supplies geometry, input/kernel/output addresses, quantization controls and the final-layer flag. Completed outputs may be shifted, rounded and saturated to INT8 on external writes; disabled quantization preserves raw32. Each external word still holds one value. `conv_accelerator` and `conv_core` implement the inherited tiled execution.

This standalone design computes signed 2-D cross-correlation with batching, independent height/width padding, stride and dilation. The array has 10 rows/columns by default, 8-bit inputs/weights, 32-bit wrapped accumulation and 32-bit configuration/external addresses. No bias or activation function is included. Tensor files use NCHW inputs, KCRS kernels and NKPQ outputs. Unrolling order and tensor-file order are separate conventions.

`conv_accelerator` schedules output-row/horizontal, output-channel and reduction-channel tiles. Kernels or footprints exceeding the local bound use single-tap reduction fallback. Partial sums persist across reduction jobs; completed output tiles are read synchronously and stored externally. The external-memory interface has one-cycle enabled reads and edge writes, with serialized READ/WRITE states; it is not AXI or a physical memory controller. No transfer overlap or additional data reuse is introduced.

Local base SRAM is 15 KiB (2.5 KiB input, 2.5 KiB kernel, 10 KiB output). The demonstration external-memory model has 2500000 words outside the accelerator; the runner checks its capacity. Local SRAM addresses remain 8 bits.

Address generation uses shared pitch/stride/dilation coefficients, running input/kernel/output transfer addresses and incremental tap origins. A shared job-level divider calculates tile bounds. Centralized NCHW additionally increments swizzled bank/address residues using a shared per-patch initializer. Per-core address initialization remains included in each local job's latency. The implementation uses these counters for tile selection, serialized transfers and local compute jobs.

The centralized input feeder retains partially assembled vectors during SRAM bank-conflict retries and overlaps bank service, synchronous read returns and array consumption.

## Run a layer

Install Python 3 and Icarus Verilog (`iverilog` and `vvp` on PATH). From this folder:

```text
python run_case.py --input-file sim/input_tensor.txt --kernel-file sim/kernel_tensor.txt --expected-file sim/output_tensor.txt --out-dir runs/example
```

Use `python3` where appropriate. Tensor headers supply dimensions; without headers provide `--N`, `--C`, `--H`, `--W`, `--K`, `--R`, `--S`. Geometry flags are `--pad_i`, `--pad_j`, `--stride_i`, `--stride_j`, `--dilation_i`, `--dilation_j`. Omit input/kernel files to generate deterministic tensors with `--seed`. For full layers use `--timeout 259200` or the [chaining validation tools](../../tools/chaining/README.md). Run `python run_case.py --help` for details. Advanced tool paths use `IVERILOG_BIN`, `VVP_BIN`, `IVERILOG_BACKEND`.

The runner checks outputs against Verilog and Python golden models and writes tensors, logs and result metadata under the selected output directory. The [current results](../../reports/chaining/README.md) distinguish accepted measurements from pending entries. The [chaining reproduction tools](../../tools/chaining/README.md) replay the real three-layer memory chain, the four independent raw-output layers and quantizer checks. Previous-version measurements remain in the repository history and historical reports.

## Credits

Original systolic-array foundation: https://github.com/kaggar11/systolic_4x4arr . Algorithmic reference: Zhou et al., *Characterizing and Demystifying the Implicit Convolution Algorithm on Commercial Matrix-Multiplication Accelerators*, https://doi.org/10.48550/arXiv.2110.03901 . The course material and reference-model attribution are retained in `conv_golden.py`.

AI assistance: Codex and GPT-6.1 Sol contributed to the project and Python tooling.
