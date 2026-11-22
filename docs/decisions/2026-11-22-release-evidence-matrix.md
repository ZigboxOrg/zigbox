# The release evidence table reads one matrix shape

*Decided 2026-11-22, by the slice (release-pipeline fix for 0.6.0).*

Supersedes nothing: it narrows one refusal of
[2026-11-18-release-evidence-table.md](2026-11-18-release-evidence-table.md), which listed a
matrix among the shapes whose job names the renderer cannot predict.

**What broke.** The 0.6.0 release run 45050090867 (a dispatch from main 4be0c623, release commit
82981d00c300de2806abfef2bdaee2caf84f670c) failed in `draft the release` with
`release-evidence: refused: ci: line 155 of the workflow file holds a job name with an
expression`. `ci.yml` at the release commit has one matrix job:

```yaml
  fuzz:
    name: fuzz (shard ${{ matrix.shard }} of 4, every fuzzer, fresh seeds)
    ...
    strategy:
      fail-fast: false
      matrix:
        shard: [1, 2, 3, 4]
```

The renderer refused any `strategy:` and any `${{` in a job name, by design, and its fixtures
(0.5.3's ci.yml) had no matrix, so nothing showed that the real `ci.yml` could not pass. The
release reads `ci.yml` at the release commit, which cannot change, so the fix is in the renderer,
which `draft` runs from the workflow's commit.

**The decision.** `src/release_evidence.zig` reads exactly this shape and nothing wider:

- a job's `strategy:` holds `matrix:` and at most `fail-fast:` and `max-parallel:`, each at the
  indentation `ci.yml` uses (6 spaces, the matrix key at 8); any other line under it refuses;
- the matrix has exactly one key, whose value is a one-line flow list (`[1, 2, 3, 4]`) of plain
  values: a decimal number of at most 9 digits without a leading zero, or a word of letters,
  digits, `-` and `_` that starts with a letter and is not a YAML boolean or null
  (`y n yes no on off true false null`, any case). GitHub renders each as written: the run of
  82981d00 (45039162888) lists `fuzz (shard 1 of 4, every fuzzer, fresh seeds)` for the value 1.
  `1.10`, `010`, `-1`, a quoted value and an empty list refuse, since YAML may read them as
  something other than their text;
- the job's `name:` holds `${{ matrix.<key> }}`, spelled with one space inside each brace pair as
  `ci.yml` writes it, at least once, and no other expression. `${{matrix.shard}}` (valid for
  GitHub) refuses: one spelling is read, and a second can be added when a workflow needs it;
- the job is then one predicted name per value, each of which must be in the run exactly once,
  like any other job.

Still refused: `include` or `exclude`, a second matrix key, a block-style list, a matrix from an
expression (`fromJSON`), a second `matrix:` or `strategy:`, a matrix job with no `name:`
(GitHub's own `id (value, ...)` form), a name that does not hold the matrix value, and `uses:`.

**The run may hold no job the file does not define.** Before, `ci`'s check only required each
defined name once; a job beside them was rendered as a row. With names now predicted, a job the
prediction missed (a value GitHub rendered otherwise, or a matrix job skipped by its `if:`, which
the API lists under its unexpanded name, as release.yml's `install and run (${{ matrix.os }})`
is listed in run 45050090867) must refuse, not pass as an extra row. The release gate
(`--current`) names only some of its run's jobs, so it is not held to this.

**The bound.** Expanded names are in no input text, so they are written to a buffer in `Names`
of `release_evidence_expanded_bytes_max` (32 KiB: 100 names of 256 bytes; `constants.zig`), and
past it the table refuses. It is a build-host tool's input bound, not a user-visible limit.

**Evidence.** 0.6.0's real API answers (`src/release_evidence/0.6.0-*`, trimmed as 0.5.3's) are
the fixture: the unit test and the release `test` job render them and compare with
`0.6.0-table.md`, which is the tool's output on the untrimmed answers fetched with `gh api` as
`draft` fetches them (29 ci jobs, four of them the fuzz shards, demo-m6d skipped as allowed, and
the release run's three named jobs).
