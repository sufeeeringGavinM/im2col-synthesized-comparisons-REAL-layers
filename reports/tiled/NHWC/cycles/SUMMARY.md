# Full-layer cycle validation

Four selected N1 real-model geometries pass the complete Verilog reference and immutable Python-generated golden outputs. Six exclusive phases sum exactly to latency; tile/core/tap-job counts, transfer diagnostics and nested counters are recorded in [results.csv](results.csv) and [accepted.json](accepted.json). Retries overlap core work. Existing batch correctness is reused; no batch performance sweep. RTL simulation is not timing closure.
