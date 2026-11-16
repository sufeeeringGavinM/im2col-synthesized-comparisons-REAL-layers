# Current Vivado synthesis preset

`synth_preset.tcl` and `prepare_run.py` are the exact shared preset v2/preparer used by accepted synthesis. They preserve the direct XDC clock/I/O constraints and report-clock reapplication fix. Preparation freezes sources, constraints, preset and hashes into a new directory; it does not launch Vivado.

From WSL/Bash, for a newly authorized run:

```bash
python3 tools/vivado_synthesis/prepare_run.py \
  --source-dir tiled/NHWC/rtl --top conv_chain \
  --generic ARRAY_SIZE=10 --generic BIT_WIDTH=8 --generic ACC_WIDTH=32 \
  --generic CFG_WIDTH=32 --generic INPUT_ADDR_WIDTH=8 \
  --generic OUTPUT_ADDR_WIDTH=8 --generic KERNEL_ADDR_WIDTH=8 \
  --generic MEM_ADDR_WIDTH=32 --common-period-ns 50 \
  --block 'quantizer=*u_quantizer*/*' --block 'core=*u_core*/*' \
  --out runs/new_nhwc_synthesis --vivado-root 'C:/path/to/Vivado'
```

Use `tiled/NCHW_centralized/rtl` for NCHW. Defaults: `xc7a200tsbg484-1`, OOC rebuilt hierarchy, 20 ns synthesis clock, 2 ns I/O delays and eight requested threads. The explicit common period above is 50 ns (20 MHz). Runtime controls remain observable. The converter uses WSL's `wslpath`; the generated launcher targets Windows Vivado.

For an authorized measurement, invoke generated `launch.cmd`, retain native exit code and `SUCCESS`, and inspect constraints/reports. Reuse accepted measurements for unchanged release RTL. This preset performs no placement/routing, bitstream, simulation or power estimation. New workload-power claims require native XSim activity and a matching DCP.
