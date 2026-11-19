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

What is ported (`.woodpecker/`, logic in `ops/ci/step.sh`):

- `check.yaml`: build (with release, trust-wasm, fuzz-macos), tidy, test, errors-site-check, fuzz
  (all but provenance), fuzz-provenance, dbus-live. Each runs as the ordinary user `tester`.
- `demos.yaml`: one workflow per VM demo, under KVM. The affected-demo rules are
  `.github/ci-changes.sh`'s, unchanged (docs/decisions/2026-11-04-ci-affected-demos.md).
- `vm.yaml`: a push to `vm/<demo>-<slug>` runs that demo and deletes the branch, as `vm.yml` does.
- VM images are cached on the box per pinned version (`ops/ci/cache.sh`), copied, never linked.

Not ported yet; these stay on GitHub Actions until a later change moves them: `release.yml`,
`top20.yml`, `package-refresh.yml`, `pages.yml`, `mac.yml` (needs a Mac), `vm/m8-push-ghcr` and
`demo-m6d` (both need credentials GitHub gave Actions; on Woodpecker they say NOT RUN).

AGENTS.md's CI rules change only once the first pull request is green on Woodpecker; until then
`.github/workflows/` stays the record. Runbook: `ops/ci/README.md`.
