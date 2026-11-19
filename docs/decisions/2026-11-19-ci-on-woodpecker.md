# CI runs on the fleet box under Woodpecker

*Decided 2026-11-19, by the owner.*

GitHub Actions minutes are limited, and the work must not depend on GitHub's runners. CI therefore
moves to the fleet box (Ryzen 7 1700X, 64 GiB, two 512 GB SSDs, KVM). It runs
[Woodpecker](https://woodpecker-ci.org) 3.20.1 (server, one docker agent, Caddy for TLS), set up by
one re-runnable script the owner runs (`ops/ci/bootstrap.sh`). Code, pull requests and reviews stay
on GitHub; Woodpecker logs in with a GitHub OAuth app and posts its workflows as checks on pull
requests.

Why Woodpecker: it is self-hosted and small, has a docker backend whose steps can be privileged (for
`/dev/kvm`), and reports to GitHub. A GitHub self-hosted Actions runner was the alternative; it
still ties CI to GitHub's control plane and its queue, which is what we are moving away from.

What is ported (`.woodpecker/`; logic in the build, below):

- `check.yaml`: build (with release, trust-wasm, fuzz-macos), tidy, test, errors-site-check, fuzz
  (all but provenance), fuzz-provenance, dbus-live. Each is a build step (`zig build ci-build`,
  `ci-tidy`, `ci-test`, `ci-errors-site`, `ci-fuzz`, `ci-fuzz-provenance`, `ci-dbus-live`) and runs
  as the ordinary user `tester`. A gate the change cannot affect prints one line and passes.
- `demos.yaml`: one workflow per VM demo, under KVM: `zig build ci-demos -- --demo ID`, which skips
  with a line when the change cannot affect it.
- `vm.yaml`: `zig build vm-branch -- vm/<demo>-<slug>` maps the name as `vm.yml` does, runs the
  demos and deletes the branch through the GitHub REST API (`GITHUB_TOKEN`); with no token it says
  the branch stays and passes.
- VM images are cached on the box per pinned version by the Zig harness
  (`src/testing/vm/cache.zig`): opt-in, copied never linked, saved under a lock into a temp
  directory then renamed, never overwriting a key.

Policy (owner, 2026-11-19): CI YAML is not the source of truth; whatever can go into `zig build`
does. So the logic is a Zig driver (`src/ci_main.zig`, `src/ci/`) behind `zig build` steps, and
the YAML keeps only triggers, the matrix, `privileged`, volumes, secrets and environment values.

Choices:

- Change detection is Zig (`src/ci/changes.zig`), with every row of the old table test in
  `src/ci/changes_tests.zig`. `ci.yml`'s `changes` job calls `zig build ci-changes` too, so there is
  one rule set and no agreement test between two. The rules equal the old shell's except three
  paths that select no demo: `src/ci_main.zig`, `src/ci/*`, `src/testing/vm/cache.zig`.
- The driver runs the work as nested `zig build` commands. The workspace is cloned as root: with
  `ZBX_CI_USER` set it chowns the workspace to that user and uses `runuser`. The outer root build
  uses its own Zig caches outside the workspace so no root-owned cache file is left behind.
- The driver cannot inherit stdin through `zig build` (a Run step's stdin is none, bytes or a
  file), so the file list comes as `--files` or `CI_PIPELINE_FILES`.
- `ZBX_REGISTRY_MIRRORS=mirror.gcr.io` is set per demo by the driver (m4 m5 m6 m6b m7 m8 m8-packages
  m9), not in YAML. The cache is driven by the driver around the demo, not inside each demo main.
- `bootstrap.sh` stays shell (it installs Docker and Woodpecker, before any Zig exists) and is on
  tidy's `shell_allowlist` with that reason. `step.sh` and `cache.sh` are deleted.
- Untested here: the `ZBX_CI_USER` runuser path end to end and any VM demo; no VM or KVM exists in
  the cloud container.

Not ported yet; these stay on GitHub Actions until a later change moves them: `release.yml`,
`top20.yml`, `package-refresh.yml`, `pages.yml`, `mac.yml` (needs a Mac), `vm/m8-push-ghcr` and
`demo-m6d` (both need credentials GitHub gave Actions; on Woodpecker they say NOT RUN).

AGENTS.md's CI rules change only once the first pull request is green on Woodpecker; until then
`.github/workflows/` stays the record. Runbook: `ops/ci/README.md`.
