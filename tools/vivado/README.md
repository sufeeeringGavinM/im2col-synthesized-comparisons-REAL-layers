# Portable native Vivado/XSim reproduction

Use Python 3, Vivado 2026.1 with Artix-7 support, AMD primitives/glbl, and a simulation license sufficient for the synthesized DUT plus shadow RTL. Use normal user licenses. Installation/output paths are explicit; Linux, Windows and WSL with Windows tools are supported. Use a new output directory for each run.

From the repository root:

```sh
python3 tools/vivado/run.py --variant all --vivado-root /opt/AMD/Vivado/2026.1 --out-dir runs/preparation --stage prepare
python3 tools/vivado/run.py --variant all --vivado-root /opt/AMD/Vivado/2026.1 --out-dir runs/native-reuse --reuse-build-root /data/accepted-tiled-build --stage all
python3 tools/vivado/run.py --variant all --vivado-root /opt/AMD/Vivado/2026.1 --out-dir runs/independent-reproduction --stage all
```

The reuse root must follow the per-design directory layout defined in [run.py](run.py), with each design directory containing `rtl/`, `synthesized.v` and `synthesized.dcp`. Hashes must match the published hardware provenance. Those compiled artifacts are deliberately excluded from this repository. The actual reported study reused accepted matching netlists/checkpoints without resynthesis. If no reuse root is supplied, the optional independent reproduction synthesizes the published unchanged RTL; new tool builds need not produce byte-identical DCPs. `prepare` verifies source/fixture identity without EDA; `synthesis` runs only physical preparation; `all` continues with all four full layers per design and native annotated power. One sequential owner updates status.json and continues independent variants after a failure. Do not start duplicate heavy jobs or overwrite published reports.

Settings: xc7a200tfbg676-2, OOC rebuilt hierarchy, two threads, array 10/CFG 32, signed 8-bit operands/32-bit wrapped sums, 8-bit local / 32-bit external addresses, original local SRAM and explicit scratch/FIFO capacities. Physical synthesis targets 20 ns / 50 MHz and 2 ns I/O; vectorless analysis is separate at 1 MHz. Tcl records utilization/hierarchy/timing/checks/worstpath/DRC/settings and GUI exports for optional new builds.

Native capture uses the exact accepted enlarged-capacity bench mechanism. It compares synthesized controls/enables/enabled external addresses/output data cycle-by-cycle against renamed shadow RTL and checks every completed output against golden. XSim runs at actual 1 MHz. At accepted start, Tcl opens native SAIF and recursively logs /tb_conv_core/GATE only; at final-store done, it closes SAIF. Reset, tensor preload, full reference computation and export are excluded; all planning/setup/serialized transfers/repeated local jobs/transitions are included. Backing memory/shadow RTL are outside DUT power. SAIF duration must equal accepted cycles * 1 us and raw native bytes are preserved. The accepted-cycle watchdog is distinct from the generous 604800-second native wall timeout.

Power Tcl opens the matching DCP, verifies a 1000 ns analysis clock, annotates native SAIF using tb_conv_core/GATE, and records coverage/confidence, 1 MHz timing and dynamic/static/total watts. Energy_uJ = watts * cycles at 1 MHz. Report power rounds to 1 mW; static dominates. These estimates do not establish power savings, routed glitch power, timing closure or board power; capture does not use SDF. Native SAIF may retain a vendor header VERSION 2020.2; actual tool provenance establishes Vivado 2026.1. Published capture Tcl uses relative output paths with the same capture mechanism.

Official native writer workflow: [AMD UG900](https://docs.amd.com/r/en-US/ug900-vivado-logic-simulation/Generating-SAIF-Dumping).

## Compiled RTL validation before native activity

Use [rtl_validate.py](rtl_validate.py) for the selected full-layer RTL checks. It compiles the unchanged RTL into XSim with [rtl_bench.py](rtl_bench.py), retains the full Verilog golden and all output/cycle checks, and records separate tensor-loading/golden/accelerator/export host times. See [cycle commands](../cycles/README.md). This stage contains no synthesized GATE or SAIF. Native synthesized-netlist power is a separate flow with its original 1 MHz window and mandatory gate-port/output checks. The portable replay is sequential; the reported study uses memory-bounded architecture workers with isolated builds and serialized heavy compilation/power phases.
