# Current chaining measurement results

AI assistance: Codex. **All 36 cases passed the final audit:** 20 new native workload captures and 16 verified previous-version controls. The [main README](../../README.md) shows the reviewed comparison tables.

- [Exact current source identity](source_identity.json).
- [Resources, timing and matching controls](hardware.json).
- Accepted native workload results: [JSON](results.json) and [CSV](results.csv).
- [Final audit summary](audit.json).
- [Previous-target measurements](previous_target.json).
- [Reused RTL validation](validation_reuse.json).
- [Portable reproduction](../../tools/chaining/README.md).

`current_nexys/` and `previous_nexys/` contain exact synthesis/power/timing reports, native transcripts and received outputs. Receipts pin source, tensor, netlist, DCP and native SAIF identities. Full annotation dumps and large SAIF, netlist, DCP and GUI artifacts are external to this Git snapshot; their hashes identify the accepted original artifacts. Native log paths refer to the original capture host.

The previous four-way reports in the parent report directory describe the previous version. Its source/tools can be checked out at commit `962a23ef5d03b0475fd2113338d6ec59b1ae0e3e`. They are not measurements of the new chaining source.
