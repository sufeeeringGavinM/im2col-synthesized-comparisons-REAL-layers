# Quantized convolution chaining reproduction

The current NHWC and NCHW sources are `tiled/NHWC` and `tiled/NCHW_centralized`, with `conv_chain` as the top. These tools adapt the accepted sequential RTL/native measurement flow. AI assistance: Codex.

From the repository root, verify the exact source/fixture identities and write a plan without launching simulation or synthesis:

```text
python3 tools/chaining/run.py --stage prepare --out-dir runs/chaining_prepare
```

Replay both real three-layer memory chains, all eight independent raw-output RTL cases and the 13,472 quantizer test vectors per architecture:

```text
python3 tools/chaining/run.py --stage rtl --out-dir runs/chaining_rtl
```

Python3 and Icarus Verilog are required for RTL replay. Set `IVERILOG_BIN`, `VVP_BIN` and, when necessary, `IVERILOG_BACKEND` if the tools are not on PATH. Select one architecture with `--variant NHWC` or `--variant NCHW_centralized`. Each output directory must be new. Sources and fixtures are read only; generated outputs go under the selected directory.

Freshly synthesize both current designs, replay the actual external-memory chains first, then the four raw-only independent layers at1MHz and each design's own estimatedFmax:

```text
python3 tools/chaining/run.py --stage all --vivado-root /path/to/Vivado --out-dir runs/chaining_native
```

Use `--stage synthesis` for synthesis and verified synthesized-netlist GUI exports only. The installed Vivado root must contain `bin/` and `data/`; the flow uses native Windows launchers through the established WSL/PowerShell bridge, or native executable paths on Linux. Normal user license configuration is inherited. No license or private configuration files are distributed.

The synthesis settings are Nexys Video `xc7a200tsbg484-1`, A10, signed8/ACC32/CFG32/local8/external32, unchanged SRAM capacities, out-of-context rebuilt hierarchy, two threads,20ns synthesis and2ns I/O. Runtime descriptor and quantization inputs stay observable.

The default native matrix is20 new captures: two architectures × (one whole chain plus four independent raw-output layers) × two frequencies. Previous-version controls are separately accepted report evidence; this command does not resynthesize or recapture them. The stages use one sequential owner and generous bounded tool timeouts.

Native XSim SAIF covers accepted start through final completion at `/tb_conv_core/GATE`. Gate/shadow controls, meaningful transfer ports, received outputs, total/phase cycles and exact native SAIF duration are checked before power. The chain parser reads each native and console transcript separately. Raw native activity is not rescaled or rewritten. Power is reported from the matching DCP at the same simulated period, with annotation/confidence and timing reports. Latency in microseconds is `cycles * period_ns / 1000`; energy in microjoules is `watts * latency_us`.

`fixtures/chain/` contains the exact synthetic descriptors, external-memory initialization, expected outputs and accepted chain benches. It uses the first three MLPerf Tiny v1.1 ResNet8 CONV geometries, shifts3/5 nearest for intermediates and raw32 for the final output. Original bias/BN/ReLU/residual add are omitted. No trained inference is claimed. The independent layers use the shared `tools/workloads/` fixtures with quantization disabled.

The [current partial snapshot](../../reports/chaining/README.md) pins exact current sources and accepted evidence. Preserve completed stage outputs when inspecting an interrupted local reproduction; do not treat compilation alone as native validation or rerun accepted activity merely because power reporting needs attention. The earlier four-way source-gated reproduction commands apply to the previous source commit linked in the report README.
