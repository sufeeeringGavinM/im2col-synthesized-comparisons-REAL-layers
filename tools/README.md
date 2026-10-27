# Reproduction tools

- [Cycle replay](cycles/README.md): full RTL golden checks, six exclusive phases and nested diagnostics for the four selected layers.
- [Vivado/XSim](vivado/README.md): portable sequential native capture/power, with exact matching hardware reuse or optional independent synthesis.
- [Workloads](workloads/README.md): shared deterministic signed 8-bit tensors, seed/hash/config/model identities and an exact integer generator.
- [Browser tools](browser/README.md): historical educational mappings with explicit limitations.

The standalone implementation runners use Python 3 and Icarus. Tensor generation uses the retained Python integer golden and requires Python 3; the independent full Verilog golden remains enabled in simulation. Native capture requires Vivado 2026.1 with Artix-7 primitives/glbl and a simulation license adequate for both synthesized and shadow-reference instances. Tools accept installation/output paths and inherit normal user license configuration. No licenses, private configuration, compiled simulator outputs or synthesized netlists/checkpoints are distributed.
