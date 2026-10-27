# Packet FIFO convolution with hardware tiling and address counters

This standalone design computes signed 2-D cross-correlation with batching, independent height/width padding, stride and dilation. The array has 10 rows/columns by default, 8-bit inputs/weights, 32-bit wrapped accumulation and 32-bit configuration/external addresses. No bias or activation function is included. Tensor files use NCHW inputs, KCRS kernels and NKPQ outputs. Unrolling order and tensor-file order are separate conventions.

`conv_accelerator` schedules output-row/horizontal, output-channel and reduction-channel tiles. Kernels or footprints exceeding the local bound use single-tap reduction fallback. Partial sums persist across reduction jobs; completed output tiles are read synchronously and stored externally. The backing interface has one-cycle enabled reads and edge writes, with serialized READ/WRITE states; it is not AXI or a physical memory controller. No transfer overlap or additional data reuse is introduced.

Local base SRAM is 15 KiB (2.5 KiB input, 2.5 KiB kernel, 10 KiB output). Input banks use 32 eight-byte words each. Each channel retains two eight-value queue packets, its existing assembly/retained-word state, and next-tap prefetch. The tile loader uses one 64-bit packing register to assemble serialized external bytes; it adds no transfer cycles or additional tile buffer. The demonstration backing-memory model has 2500000 words outside the accelerator; the runner checks its capacity. Local SRAM addresses remain 8 bits.

Address generation uses shared pitch/stride/dilation coefficients, running input/kernel/output transfer addresses and incremental tap origins. A shared job-level divider calculates tile bounds. Per-core address initialization remains included in each local job's latency. The implementation uses these counters for tile selection, serialized transfers and local compute jobs.

## Run a layer

Install Python 3 and Icarus Verilog (`iverilog` and `vvp` on PATH). From this folder:

```text
python run_case.py --input-file sim/input_tensor.txt --kernel-file sim/kernel_tensor.txt --expected-file sim/output_tensor.txt --out-dir runs/example
```

Use `python3` where appropriate. Tensor headers supply dimensions; without headers provide `--N`, `--C`, `--H`, `--W`, `--K`, `--R`, `--S`. Geometry flags are `--pad_i`, `--pad_j`, `--stride_i`, `--stride_j`, `--dilation_i`, `--dilation_j`. Omit input/kernel files to generate deterministic tensors with `--seed`. For full layers use `--timeout 259200` or the [full-layer validation tools](../../tools/cycles/README.md). Run `python run_case.py --help` for details. Advanced tool paths use `IVERILOG_BIN`, `VVP_BIN`, `IVERILOG_BACKEND`.

The runner checks outputs against Verilog and Python golden models and writes tensors, logs and result metadata under the selected output directory. This repository reports the four selected complete layers per implementation, with [cycle results](../../reports/cycle_results.csv) and [validation details](../../tools/cycles/README.md). RTL simulation does not establish FPGA timing closure or measured board power.

## Credits

im2collette source: https://github.com/ckmalangen/im2collette .

Packet-feeder changes were developed with Codex assistance. The design keeps the existing weight-stationary channel mapping; it is inspired by, rather than a reproduction of, the output-stationary feeder in Fornt et al., *An Energy-Efficient GeMM-based Convolution Accelerator with On-the-fly im2col*, https://doi.org/10.1109/TVLSI.2023.3286122 . Original reference-model and course material are retained.
