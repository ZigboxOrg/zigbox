# Fuzz runs are sharded by iterations, every fuzzer in every shard

*Decided 2026-11-19, by the C4b slice (0.6.0 plan, Lane C; the 0.5.3 retro's fuzz sharding).*

The 0.5.3 retro asked for the slowest fuzzers (`provenance`, `lazy_resolver`) to be split into at
least 4 shards, so one lost run costs under an hour. `zig build fuzz -- shard I N [iterations]`
(I from 1 to N, N at most `fuzz_shards_max`, 64) does it for the whole set: every shard runs every
fuzzer, each with a fresh seed, for its share of the iterations. The shares add up to exactly
`iterations` (default `fuzz_check_iterations`), so the total per fuzzer is what the unsharded run
would do, and every shard has the same cost profile without a table of fuzzer weights to keep.

Why not assign fuzzers to shards (as `all-but` does for `provenance`): a fuzzer is one indivisible
unit there, so the slowest sets the length of the run, and the table of which fuzzer goes where
must be kept as fuzzers are added. Iterations divide for free.

Unchanged: `fuzz_iterations_default`, `fuzz_check_iterations`, the meaning of a seed (a seed
still replays one fuzzer, `fuzz <name> <seed> <iterations>`), `all` and `all-but`.

The release's extended run (100 times the default) is `shard I N 1000000` for I = 1 .. N; the
runbook and how the shards combine are in [automation.md](../releases/automation.md).
