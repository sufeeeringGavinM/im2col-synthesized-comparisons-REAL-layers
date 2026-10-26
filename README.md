# Synthesized im2col comparisons — real model layers

All16 selected full-layer RTL cases and all16 matching native-XSim SAIF/power cases pass. See the [phase, physical and power comparison](reports/README.md), [cycle CSV](reports/cycle_results.csv) and [workload power CSV](reports/workload_results.csv).

This experiment compares four accepted tiled address-counter accelerators on four complete convolution layers from the official PyTorch CIFAR10 tutorial, current MNIST example and historical MNISTConvNet tutorial, batch1 at their original network input sizes. Deterministic signed8 synthetic inputs and kernels isolate geometry/activity; they do not represent trained weights or real activation statistics. Accumulation wraps to32bits. Bias, normalization, activation, pooling and complete-network inference are outside scope.

| Layer | Input C×H×W | Filters / kernel | Stride / padding | Output K×P×Q |
|---|---|---|---|---|
| CIFAR10 tutorial conv1 |3×32×32|6 /5×5|1 /0|6×28×28|
| CIFAR10 tutorial conv2 |6×14×14|16 /5×5|1 /0|16×10×10|
| MNIST example conv1 |1×28×28|32 /3×3|1 /0|32×26×26|
| Historical MNISTConvNet tutorial conv2 |10×12×12|20 /5×5|1 /0|20×8×8|

All use groups1 and dilation1. [Pinned model identities](tools/workloads/model_geometries.json) include primary source URLs, commits and source hashes. Every filter and valid output position is included. No pretrained weights or datasets are needed.

The designs are [NHWC](tiled/NHWC/README.md), [centralized NCHW](tiled/NCHW_centralized/README.md) with two activation-vector slots, [explicit im2col](tiled/explicit/README.md), and [im2collette FIFO](tiled/im2collette_fifo/README.md) with two eight-value packets per input channel and existing prefetch/pipelining. Channel-first here means NHWC unrolling; tensor files retain NCHW/KCRS/NKPQ order. Per-row and non-tiled designs are excluded.

Hardware is reused unchanged from the [accepted synthesized comparison](https://github.com/sufeeeringGavinM/synthesized-im2col-comparisons/tree/b8472fa86e73f32d447778a477026a9a330f87c5/tiled). Array10, CFG32, signed8/32 arithmetic, local8/external32 addresses, local SRAM capacities, scheduling, reuse and PE behavior are preserved. External simulation memory retains the validated2500000-word depth; backing memory is outside the synthesized accelerator. This retained simulation capacity covers all selected layers. No resynthesis is needed for this workload-only study.

[Compiled four-state RTL validation](tools/cycles/README.md) retains the complete Verilog golden calculation and all phase/output checks. [Tools](tools/README.md) provide small standalone examples, full-layer cycle replay, deterministic tensor generation and portable Vivado/XSim reproduction. Native activity uses actual1MHz and the full accepted-start-to-final-store window, with native open_saif/log_saif/close_saif on /tb_conv_core/GATE. Exact outputs, meaningful gate ports, accepted cycle count, native duration, annotation coverage/confidence and1MHz timing must pass before results are accepted. Six exclusive phases sum to latency; nested diagnostics and retries must not be added to those phases.

Reused resources/timing are Vivado2026.1 post-synthesis estimates for xc7a200tfbg676-2, OOC/rebuilt hierarchy/two threads,50MHz target and2ns I/O. All four fit resource counts and meet1MHz; all four miss50MHz. Estimated Fmax=1000/(20-WNS). No placement/routing, board-power measurement or matched-baseline power-saving claim is made. Workload power is quantized to1mW and static power dominates at1MHz. Existing vectorless power remains separate. The original-arithmetic baseline is omitted because this compares workloads on accepted counter hardware.

Original source credits, algorithmic citations, course material and AI disclosures remain in each implementation. Foundation: [kaggar11/systolic_4x4arr](https://github.com/kaggar11/systolic_4x4arr); explicit source: [jmbino/im2col](https://github.com/jmbino/im2col); FIFO source: [ckmalangen/im2collette](https://github.com/ckmalangen/im2collette). Codex and GPT-6.1 Sol contributed to tooling and project development. Browser tools retain historical modeling limitations and are not cycle/power evidence.

Native SAIF annotation is incomplete: matched design-net coverage is89% NHWC,85% centralized NCHW,84% explicit and72% FIFO, with High tool-reported confidence. These are zero-delay post-synthesis estimates. Reported totals/components are rounded independently to1mW, so displayed components may not sum exactly to the displayed total; energy uses the reported total. These results do not establish routed glitch power or board power.

The reported run used memory-bounded independent architecture workers (peak3) and serialized heavy compilation/power phases; portable replay is sequential. See [validation/optimization provenance](reports/validation_engine.json), [RTL runtimes](reports/rtl_runtime.json), [native session runtimes](reports/native_runtime.json) and [inherited cross-simulator checks](reports/rtl_engine_migration.json). The small native optimization trial gave40.694s default versus40.223s with --O3, with identical outputs/cycles/duration/annotation; this single short sample did not justify changing the default.

Raw Vivado reports and native SAIF are preserved byte-for-byte. Original report command headers can contain the analysis machine's output paths; these are provenance metadata and are not reproduction dependencies. Reproduction tools use installation/output arguments and normal user licensing. No license files, hardware host IDs or compiled implementation artifacts are distributed.
