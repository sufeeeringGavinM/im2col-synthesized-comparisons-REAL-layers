# Reproduction tools

- [Current chaining reproduction](chaining/README.md): exact source/fixture checks, RTL replay, Nexys Video synthesis and native-XSim activity at1MHz and own estimatedFmax.
- [Workloads](workloads/README.md): deterministic independent-layer tensors, model geometries and provenance.
- [Previous cycle replay](cycles/README.md) and [previous Vivado/XSim flow](vivado/README.md): reproduce the earlier four-way study from its source commit.
- [Browser tools](browser/README.md): educational mappings with stated limitations.

The current main implementations are tiled/NHWC and tiled/NCHW_centralized, with conv_chain as the top. The previous version is commit `962a23ef5d03b0475fd2113338d6ec59b1ae0e3e`; use a separate checkout of that commit for historical source-gated commands. Current standalone run_case.py scripts replay individual raw-output layers.
