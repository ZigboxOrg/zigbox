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
- `vm.yaml`: a push to `vmw/<demo>-<slug>` runs `zig build vm-branch`, which maps the name as
  `vm.yml` does and runs the demos; a second, unprivileged step, `zig build vm-branch-delete`, which
  alone gets `GITHUB_TOKEN`, deletes the branch through the GitHub REST API whether the demos passed
  or failed (with no token it says the branch stays and passes). `vm/*` stays on GitHub's `vm.yml`
  until a pull-request pipeline is green on the box (supervisor, 2026-11-20, review of PR 5): the
  prefixes are disjoint, so each branch has one runner and one deleter. `vm.yml` deletes through
  the same driver step, and its `workflow_dispatch` refuses any ref but `refs/heads/vm/*`; the
  driver itself refuses to delete any branch but `vm/*` and `vmw/*`. Moving `vm/*` to the box later
  is a change of the two files' triggers and AGENTS.md's implementer bullet.
- VM images are cached on the box per pinned version by the Zig harness
  (`src/testing/vm/cache.zig`): opt-in, copied never linked, saved under a lock into a temp
  directory then renamed, never overwriting a key. Each entry carries the SHA-256 of its files and
  is checked on restore (a mismatch deletes it); a save keeps at most two keys per entry. The
  `/cache` mount is per event (`/var/lib/zigbox-ci/<event>`, and `vm` for `vm.yaml`), so `main`
  never reads a cache a pull request wrote; an hourly timer empties a scope's Zig caches past
  30 GiB, holding the scope's `.prune-lock` exclusively, while every step runs under
  `flock -s` on it (amended 2026-11-20). The hashes catch corruption and truncation, not
  tampering: a step that can write the cache can rewrite a hash too, which is why the scopes, not
  the hashes, keep `main`'s cache apart from pull requests'.
- Every image is pinned by digest: the compose services, `ubuntu:24.04` in the step image, and
  `plugin-git` in the pipelines. The repository is Trusted, so pull requests from forks wait for a
  maintainer's approval (`require_approval: forks`, set by `ops/ci/woodpecker-setup.sh`, which
  sets every repository setting through the API); the runbook says what to read before approving,
  and the bullet "What a repository writer can reach" below says what approval does not cover.

Policy (owner, 2026-11-19): CI YAML is not the source of truth; whatever can go into `zig build`
does. So the logic is a Zig driver (`src/ci_main.zig`, `src/ci/`) behind `zig build` steps, and
the YAML keeps only triggers, the matrix, `privileged`, volumes, secrets and environment values.

Choices:

- Change detection is Zig (`src/ci/changes.zig`), with every row of the old table test in
  `src/ci/changes_tests.zig`. `ci.yml`'s `changes` job calls `zig build ci-changes` too, so there is
  one rule set and no agreement test between two. The rules equal the old shell's: the driver
  (`src/ci_main.zig`, `src/ci/*` but its tests) and `src/testing/vm/cache.zig` select every demo,
  as `.github/*` did, and so do `.woodpecker/*` and `ops/ci/image/*`, which decide how every demo
  runs (amended 2026-11-20; the first version selected none).
- The driver runs the work as nested `zig build` commands. The workspace is cloned as root: with
  `ZBX_CI_USER` set it chowns the workspace to that user, creates the user's Zig cache
  (`ZBX_CI_USER_ZIG_CACHE`, a bind mount that is root's when the scope is new) and makes it the
  user's, and uses `runuser`. The outer root build
  uses its own Zig caches outside the workspace so no root-owned cache file is left behind.
- The driver cannot inherit stdin through `zig build` (a Run step's stdin is none, bytes or a
  file), so the file list comes as `--files`, `--files-from FILE` (what `ci.yml` uses: one argument
  is capped at 128 KiB on Linux) or `CI_PIPELINE_FILES`.
- `full-ci`: `check` and `demos` also run on Woodpecker's `pull_request_metadata` event when the
  labels change and `full-ci` is one of them (matched whole); that event has no file list, so
  everything runs.
- The clone fetches one ref, so the demos that build an older release fetch origin's `old/*`
  branches and tags themselves when a pinned commit is missing (`src/testing/vm/build_old.zig`).
  `v0.3.1` and `v0.5.2` are not on origin yet; until the owner pushes them, m2b and m8 fail with a
  line naming the missing tag, on GitHub as on the box.
- What a repository writer can reach (amended 2026-11-20, after the round-2 review of PR 5; the
  first text said a leaked `github_token` "can delete or push scratch branches and nothing more",
  which was wrong). Pipeline YAML comes from the pushed branch; a push to `vmw/*` and a pull
  request from a branch of this repository run without approval; the repository is Trusted. So any
  writer can run a privileged step, which is root on the host, and the host holds Woodpecker's
  database (with the activating admin's GitHub OAuth token, scope `repo`), the Docker socket, the
  fleet's token, `/etc/zigbox-ci/*` and `github_token`. Woodpecker 3 cannot hold a secret back from
  one branch or file. Control: `main`'s protection cannot be bypassed by anyone (`enforce_admins`
  on, no bypass allowances, no force push or deletion), checked by `woodpecker-setup.sh` with
  `gh api`, which fails otherwise; the repository is activated from an account with no bypass; and
  `github_token` is a fine-grained token, this repository only, Contents read and write. What a
  writer can still do is write other branches and read what the activating account can read. The
  runbook says this plainly and has the `gh api` command that sets the protection.
- Approval: Woodpecker 3.20.1 has `require_approval` `none`, `forks` (kept, the default),
  `pull_requests` and `all_events`, and `approval_allowed_users` (`server/pipeline/gated.go`).
  Only `all_events` with the owner's login(s) listed holds a non-owner writer's `vmw/*` push or
  same-repo pull request; but the author is the pusher's login, and sessions push as the owner, so
  it does not stop a session acting as the owner. It is available as
  `ZBX_CI_APPROVAL=all_events ZBX_CI_APPROVED_USERS=...` and off by default: turning it on changes
  who can run what on the box, which is the owner's call.
- Longer term, not built: the Woodpecker server (its database, OAuth token and the fleet's token)
  on a separate host from the agent that runs privileged steps, so a writer's root on the agent
  reaches neither.
- Tests that cannot run in an unprivileged docker step skip with a reason rather than fail (the
  host_real signal test, whose `clone3` Docker's default seccomp refuses).
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
`.github/workflows/` stays the record, and AGENTS.md mentions only `vmw/*` as the box's way to run
one demo. Runbook: `ops/ci/README.md`.
