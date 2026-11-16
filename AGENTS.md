# Working on the accelerator

The current release is **NHWC and two-slot NCHW with bias, scale multiplication and output quantization**, selected by the user on November 16, 2026. Main sources are `tiled/NHWC` and `tiled/NCHW_centralized`; `conv_chain` is the top. ReLU and other nonlinear operations run in testbench/software on actual output values.

- Describe ReLU only as a software/testbench operation in current accelerator documentation and discussion.

- Use this pair as the default development parent. Other tiled designs and earlier chaining-only/October studies are historical. Preserve their reports and source identities; publication does not rewrite previously presented evidence.
- Quantization includes optional per-output-channel INT32 bias, unsigned32 scale numerator, full signed64 product, shift 0–31, rounding and INT8 saturation. Bias remains independently enabled when requantization is bypassed. Partial sums stay wrapped INT32; quantize only completed external writes.
- Keep defaults and capacities: A10, INT8 operands, ACC32/CFG32, local8/external32, base SRAM 15 KiB. Preserve the original scheduler/core and two NCHW activation-vector slots unless explicitly requested.
- Use `tools/mnist/run.py` for current hash checks/replay and each implementation's `run_case.py` for individual layers. Historical `tools/chaining` commands are source-gated to their old release; do not refresh old report hashes to imply new RTL was measured there.
- MNIST parameters follow the supplied `MNIST_Training_Test_3_.ipynb`: 784→128→10, final-epoch weights, calibrated on 48,000 training images, seed 196. Preserve notebook source and exact export identities. Validate future parameter changes separately.
- Explain cycle/timing differences alongside tables. Give absolute values and percentage changes with named baselines; distinguish advancing computation, startup, transfer, layer setup and descriptor gaps. Do not generalize one network into universal layout superiority.
- Identify simulation, post-synthesis, routed, power-estimation and board evidence separately. Report clock, part, source identity and activity coverage. Estimated Fmax is not a board result. Use native XSim SAIF for new workload power.
- Use `tools/vivado_synthesis` for authorized synthesis, Nexys Video `xc7a200tsbg484-1` by default. Reuse unchanged hash-matched accepted work; do not rerun synthesis for documentation/publication.
- Prefer native scheduled follow-ups for long runs. Keep monitors quiet while healthy, report failures/completion, and disable after the authorized work is finished. Never duplicate a job to monitor it.
- Preserve numbered before/after source and tensor checkpoints for behavioral RTL/testbench/generator/mapping changes, with hashes, provenance and actual validation. Documentation edits need factual/link checks.
- Preserve course/reference attribution and AI disclosures. Keep binaries, large builds, waveforms and private paths out of Git. Do not commit/push without user authorization; this release publication is explicitly authorized.
