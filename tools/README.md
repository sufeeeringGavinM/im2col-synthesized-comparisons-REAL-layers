# Reproduction tools

- Replay the spatial CNN with hardware ReLU and actual RTL memory handoffs. The runner also supports the original dense model via `--model dense`. [MNIST replay](mnist/README.md)
- [Current synthesis preparation](vivado_synthesis/README.md): the shared accepted preset; preparation does not launch Vivado.
- `tiled/NHWC/run_case.py` and `tiled/NCHW/run_case.py`: individual layers with optional bias and requantization.
- [Historical chaining reproduction](chaining/README.md): source-gated earlier release, with original 1 MHz/own-Fmax measurements.
- [Workloads](workloads/README.md), [earlier cycle replay](cycles/README.md), [earlier Vivado flow](vivado/README.md) and [browser tools](browser/README.md): supporting/historical material with their own source identities.

The current pair is NHWC and two-slot NCHW, with `conv_chain` as top. Commands write generated artifacts to new ignored directories. Historical source gates intentionally reject the current release; reproduce older measurements from the documented source commit.
