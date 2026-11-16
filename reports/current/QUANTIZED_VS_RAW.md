# Quantization versus raw output

Bias plus scale/multiply, shift, rounding and saturation are all included in quantization. Nonlinear operations such as ReLU are performed in testbench/software.

The retained raw-output controls and current quantized builds use Nexys Video xc7a200tsbg484-1, A10, signed INT8 operands, ACC32 and the same base memory capacity. All common core RTL is token-identical; conv_accelerator changes and conv_chain/output_quantizer are added. The raw controls contain no output_quantizer, bias-enable or multiplier controls.

These are existing full-design results. The historical raw design also predates descriptor chaining, so the deltas are not an isolated synthesis of the postprocessor alone. Requested synthesis thread counts differ (older2, current8).

## NHWC

|Metric|Raw output|Quantization|Change|
|---|---:|---:|---:|
|LUTs|18,792|21,315|+13.426%|
|Registers|9,900|10,293|+3.970%|
|BRAM tiles|15|10|-33.333%|
|DSPs|111|115|+3.604%|
|Estimated Fmax MHz|38.583|36.015|-6.656%|
## NCHW

|Metric|Raw output|Quantization|Change|
|---|---:|---:|---:|
|LUTs|61,055|61,703|+1.061%|
|Registers|17,995|18,083|+0.489%|
|BRAM tiles|15|15|+0.000%|
|DSPs|206|210|+1.942%|
|Estimated Fmax MHz|26.588|26.619|+0.117%|

## Interpretation

NHWC output accumulators changed from one RAMB18 each to distributed RAM: the current hierarchy shows176 LUTRAMs per accumulator and no output-accumulator BRAM. This explains the five-BRAM-tile reduction and contributes1,760 LUTRAMs across ten outputs. Capacity did not shrink; this is a memory-inference/mapping tradeoff, not a quantization-driven reduction in SRAM capacity.

The synthesized quantizer module uses360 LUTs and4 DSPs in NHWC,426 LUTs and4 DSPs in NCHW. Bias addition and captured controls live outside that module. Both full designs add exactly4 DSPs relative to raw output.

NHWC shifts from a scheduler address-update worst path (K register to output_filter_base,25.863ns,22 levels) to an output-quantizer/writeback path (24.757ns,45 levels). Different endpoints and I/O timing budgets mean data-path delay alone does not rank Fmax: estimated Fmax falls6.656%.

NCHW remains limited by tap_mode to scheduler DSP bank/address arithmetic,68 levels. Its estimated Fmax changes only+0.117%, a small whole-design mapping variation rather than a demonstrated quantization speedup.

## 20 MHz

20MHz does not change the resource counts. Existing timing estimates support both designs at that clock. Quantized builds have actual20MHz timing reports; raw20MHz slack inferred from the retained single-clock50MHz report is24.082ns NHWC and12.389ns NCHW, explicitly a projection. Quantized20MHz slack is22.234ns NHWC and12.433ns NCHW.

No matching raw20MHz trained-MNIST native power capture exists in this comparison. Older1MHz/own-Fmax power belongs to different workloads/clocks and cannot be relabeled as20MHz power. Likewise, the prior raw design was not run through the same biased/scaled MNIST handoff, so no matched full-inference latency or accuracy delta is claimed.

Both sides still use INT8 operands and INT32 accumulation. Raw means no output quantization hardware, not floating-point computation. These synthesis results are reused; publication does not rerun EDA.
