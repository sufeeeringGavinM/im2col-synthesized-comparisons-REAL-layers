# Working on the accelerator

The current release is **NHWC and two-slot NCHW with bias, scale multiplication, output quantization and combinational ReLU**, with the CNN update selected on November 19, 2026. Main sources are `tiled/NHWC` and `tiled/NCHW`; `conv_chain` is the top. The current RTL captures an optional ReLU enable and clamps negative completed writes combinationally.

- The November 16 quantization-only publication used testbench/software ReLU. The current CNN uses hardware ReLU. Tie `cfg_relu_enable` low for the original raw/writeback behavior.

- Use this pair as the default development parent. Other tiled designs and earlier chaining-only/October studies are historical. Preserve their reports and source identities; publication does not rewrite previously presented evidence.
- Quantization includes optional per-output-channel INT32 bias, unsigned32 scale numerator, full signed64 product, shift 0–31, rounding and INT8 saturation. Bias remains independently enabled when requantization is bypassed. Partial sums stay wrapped INT32; quantize only completed external writes.
- Keep defaults and capacities: A10, INT8 operands, ACC32/CFG32, local8/external32, base SRAM 15 KiB. Preserve the original scheduler/core and two NCHW activation-vector slots unless explicitly requested.
- Use `tools/mnist/run.py` for hash-checked RTL replay or Python-only inference (`--stage py_sim`). The runner creates a unique output directory when `--out-dir` is omitted. Use each implementation's `run_case.py` for individual layers. Historical `tools/chaining` commands are source-gated to their old release; do not refresh old report hashes to imply new RTL was measured there.
- The default MNIST parameters come from `MNIST_Training_Test_3_CNN.ipynb` and the selected epoch-17 checkpoint. The original dense notebook and parameters are available through `--model dense`. Preserve notebook source and exact export identities. Validate future parameter changes separately.
- Explain cycle/timing differences alongside tables. Give absolute values and percentage changes with named baselines; distinguish advancing computation, startup, transfer, layer setup and descriptor gaps. Do not generalize one network into universal layout superiority.
- Identify simulation, post-synthesis, routed, power-estimation and board evidence separately. Report clock, part, source identity and activity coverage. Estimated Fmax is not a board result. Use native XSim SAIF for new workload power.
- Use `tools/vivado_synthesis` for authorized synthesis, Nexys Video `xc7a200tsbg484-1` by default. Reuse unchanged hash-matched accepted work; do not rerun synthesis for documentation/publication.
- Prefer native scheduled follow-ups for long runs. Keep monitors quiet while healthy, report failures/completion, and disable after the authorized work is finished. Never duplicate a job to monitor it.
- Preserve numbered before/after source and tensor checkpoints for behavioral RTL/testbench/generator/mapping changes, with hashes, provenance and actual validation. Documentation edits need factual/link checks.
- Preserve course/reference attribution and AI disclosures. Keep binaries, large builds, waveforms and private paths out of Git. The CNN/ReLU update is authorized for the local checkout. Commits, pushes and publication require separate user authorization.
