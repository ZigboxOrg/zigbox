# CI on the fleet box (Woodpecker)

Zigbox's pull-request CI runs on the fleet box (AMD Ryzen 7 1700X, 8 cores and 16 threads, 64 GiB,
two 512 GB SATA SSDs) under [Woodpecker](https://woodpecker-ci.org) 3.20.1. Code and pull requests
stay on GitHub (`ZigboxOrg`); Woodpecker logs in with GitHub and posts each workflow as a check on
the pull request. GitHub's `ci` workflow keeps running on every push to `main` for 0.6.0, because
`release.yml` starts on it and reads its evidence (docs/decisions/2026-11-19-0.6.0-plan.md,
decision 2). Decision: `docs/decisions/2026-11-19-ci-on-woodpecker.md`.

| What | Where |
|------|-------|
| Woodpecker server, one agent, Caddy (TLS) | `compose.yaml`, `Caddyfile`, run by `bootstrap.sh` from `/opt/zigbox-ci` |
| Settings, secrets | `/etc/zigbox-ci/` (`ci.env`, `github-client-id`, `github-client-secret`, `agent-secret`) |
| The image every step runs in | `image/Dockerfile`, built on the box as `zigbox-ci:0.17.0` |
| Pipelines | `.woodpecker/check.yaml` (code gates), `demos.yaml` (VM demos), `vm.yaml` (`vmw/*` branches) |
| Repository settings, `github_token` secret | `woodpecker-setup.sh` (step 4) |
| Step logic | `zig build ci-*`, `vm-branch` and `vm-branch-delete` (`src/ci_main.zig`, `src/ci/`); the VM image caches are `src/testing/vm/cache.zig` |
| Caches | `/var/lib/zigbox-ci/<scope>/` with `zig`, `zig-root` (Zig's caches) and `vm-entries` (VM images); a scope per event (`push` is `main`, `pull_request`, `pull_request_metadata`, `manual`) and `vm` for `vmw/*` branches; each holds `.prune-lock` |
| Cache bound | `zigbox-ci-prune.timer` (hourly, `/usr/local/sbin/zigbox-ci-prune`), written by `bootstrap.sh` |

The YAML holds only what the build cannot: triggers, the demo matrix, `privileged`, volumes, the
`github_token` secret and these environment values. Each step is one `zig build ...` line.

- `ZBX_CI_USER=tester`, `ZBX_CI_USER_ZIG_CACHE=/cache/zig`: the workspace is cloned as root. The
  driver, run as root with these set, hands the workspace to `tester` (`chown -R`), creates
  `/cache/zig` and makes it `tester`'s (a scope the box has not seen yet is a fresh, root-owned
  bind mount), and runs every nested `zig build` through `runuser` as that user (uid 1001), so the
  tests see an ordinary user.
- `ZIG_GLOBAL_CACHE_DIR=/cache/zig-root`, `ZIG_LOCAL_CACHE_DIR=/cache/zig-root/local`: the outer
  root `zig build` keeps its caches outside the workspace, so nothing root-owned is left in
  `.zig-cache` for `tester` to trip on. `tester` uses `/cache/zig`.
- `ZBX_VM_CACHE=/cache/vm-entries`: switches on the VM image cache for `ci-demos`.
- `/cache` is `/var/lib/zigbox-ci/${CI_PIPELINE_EVENT}` (`/var/lib/zigbox-ci/vm` in `vm.yaml`), so
  a pipeline on `main` (event `push`) never reads a cache a pull request wrote.
- `flock -s /cache/.prune-lock` wraps every command: the hourly prune empties a scope only while it
  holds that lock exclusively, so no step's build loses its cache under it.
- The demos that build an older release (m2b, m3 to m9) need commits that live only on origin's
  `old/*` branches and tags; the clone fetches one ref, so `build_old` fetches those itself when
  the pinned commit is missing (`src/testing/vm/build_old.zig`). A tag that is not on origin yet
  (`v0.3.1`, `v0.5.2` until the owner pushes them) fails with one line naming it.
- `dbus-run-session` for the dbus-live gate is started by the driver, not by YAML.

Not ported yet (they stay in `.github/workflows/` until they are): `release.yml`, `top20.yml`,
`package-refresh.yml`, `pages.yml`, `mac.yml` (needs a Mac), and `vm/m8-push-ghcr` and `demo-m6d`
(they need tokens GitHub gave Actions; in `demos.yaml` m6d says NOT RUN).

Scratch branches: `vm/*` stays on GitHub's `vm.yml` (push or by hand; by hand it refuses any ref
but `vm/*` and deletes nothing else), until a pull-request pipeline is green on the box. The box
runs `vmw/<demo>-<slug>` (`vm.yaml`): the demo, then a separate, unprivileged step that alone holds
`github_token` deletes the branch. The prefixes are disjoint, so each branch has one runner and one
deleter, and both deleters go through the driver's `delete-branch`, which refuses any branch but
`vm/*` and `vmw/*`. Moving `vm/*` to the box later is a change of `vm.yaml`'s and `vm.yml`'s
triggers (docs/decisions/2026-11-19-ci-on-woodpecker.md).

## Set it up

You need: a bare-metal server with Ubuntu 24.04 and root on it (a cloud VM has no `/dev/kvm`; the
bootstrap refuses one), a DNS name for it (below, `ci.zigbox.org`), and owner rights on the GitHub
organisation `ZigboxOrg`. On the box everything else is installed by the bootstrap (Docker,
BuildKit, Compose, QEMU, `curl`, `git` and `jq`, which step 4's script needs). On your own machine
you need only `git` and an SSH client. Every step can be run again safely.

**1. DNS.** Add an `A` record from the name to the box's public IPv4 (unproxied, if your DNS
provider is Cloudflare). The bootstrap checks that the name resolves to an address of the box.

**2. The GitHub OAuth app.** GitHub has no API or CLI for creating OAuth apps, so this one step is in
the browser: open <https://github.com/organizations/ZigboxOrg/settings/applications/new> and fill
in

- Application name: `Zigbox CI`
- Homepage URL: `https://ci.zigbox.org`
- Authorization callback URL: `https://ci.zigbox.org/authorize`

Register it, copy the **Client ID**, then **Generate a new client secret** and copy it (GitHub shows
it once).

**3. Run the bootstrap on the box,** as root, in an SSH session (it asks questions, so it needs a
terminal):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ZigboxOrg/zigbox/main/ops/ci/bootstrap.sh)
```

It clones this repository into `/opt/zigbox-ci/src` (`ZIGBOX_CI_REF=<branch>` before `bash` picks
another branch than `main`) and runs the copy there. On the first run it asks for the DNS name, your
GitHub login (the Woodpecker admin), and the OAuth app's Client ID and secret (read without echo; it
lands in `/etc/zigbox-ci/github-client-secret`, mode 0640, group 1000: the server image runs as uid
1000). Then it installs Docker, BuildKit, Compose, QEMU and jq, builds the step image, starts Woodpecker and
Caddy, installs the hourly cache bound (`zigbox-ci-prune.timer`), and waits for the certificate
and the agent. The last line must be `ci-bootstrap: OK
https://ci.zigbox.org (...)`. A `FAIL` line says what to fix; fix it and run the same command again.
To change a setting later, edit `/etc/zigbox-ci/ci.env` (or delete a secret file to be asked again)
and rerun.

**4. Log in, then set the repository up.** Logging in is GitHub's OAuth consent, so it is a
browser step: open <https://ci.zigbox.org>, log in with GitHub and grant access to `ZigboxOrg`.
Then copy your personal token from **User settings → CLI & API** (Woodpecker makes its API tokens
only for a logged-in browser session; there is no API call that mints the first one).

Make the GitHub token that deletes `vmw/*` branches: a fine-grained token, `ZigboxOrg/zigbox`
only, **Contents: Read and write** and nothing else, from an account that cannot bypass `main`'s
branch protection, at <https://github.com/settings/personal-access-tokens/new>
(GitHub has no API or CLI that creates fine-grained tokens). Then, as root on the box:

```bash
bash /opt/zigbox-ci/src/ops/ci/woodpecker-setup.sh
```

It asks for the Woodpecker token and the GitHub token (neither is echoed or put on a command line;
press Enter at the second to keep the stored one), and through Woodpecker's API it:

- turns `ZigboxOrg/zigbox` on (Woodpecker adds the webhook on GitHub);
- sets **Trusted** (security and volumes: the demo steps' `/dev/kvm` and the `/var/lib/zigbox-ci`
  mount), **approval required for pull requests from forks** (`require_approval: forks`, set
  explicitly rather than left to the default), cancel-previous for push, pull request and
  pull-request-metadata events, and a 180-minute timeout;
- creates the secret `github_token` (push events only), or updates it if it exists.

The risk this token carries: a pipeline's YAML comes from the pushed branch, so anyone who can push
a branch to this repository can write a pipeline that prints `github_token` (Woodpecker masks the
exact string in logs, not a transformed copy). Woodpecker 3 cannot hold a secret back for one
branch or one pipeline file (a secret's image filter applies only to plugin steps, and every step
here is the same image), so the scope of the token is the control: contents:write on this
repository only, from an account that cannot push past `main`'s protection, so a leaked token can
delete or push scratch branches and nothing more. The same was true of `vm.yml`'s
`GITHUB_TOKEN` on Actions. Rotate it by running the script again.

It reads the settings back; the last line must be `ci-setup: OK ZigboxOrg/zigbox (id N): ...`
with `"require_approval":"forks"` and `github_token secret: yes`. Run it again at any time: it only
sets what is not already so.

**5. Before approving a fork's pull request.** The repository is Trusted, so a pipeline that runs
is root on the box: the demo steps are privileged, every step mounts `/var/lib/zigbox-ci`, and the
steps run whatever `build.zig` and the driver say. Woodpecker therefore holds every pipeline of a
pull request from a fork until a maintainer approves it in its UI. Approving means running the
pull request's code as root on the box, so before approving read every change to:

- `.woodpecker/*` (what runs, privileged or not, which volumes and secrets);
- `build.zig` and `build.zig.zon` (what any `zig build` runs, including fetched dependencies);
- `src/ci_main.zig`, `src/ci/*` and `src/testing/vm/*` (the driver and the harness the steps run
  as root or in the KVM guest);
- `ops/ci/*` (the image and the box's scripts);
- anything else a privileged step runs: a demo's code, test scripts, and any file one of the
  above reads or executes.

If any of it is unclear, do not approve; ask for the change to be split out. An approved run can
also write to the pull-request cache scope (`/var/lib/zigbox-ci/pull_request`), which only other
pull requests read; `main` uses its own. Pull requests from branches of this repository, and pushes
to `vmw/*`, need no approval: only people with write access can make them.

**6. Check that it works.** Push a scratch branch that runs the first demo:

```bash
git push origin HEAD:vmw/m0-ci-check
```

Open <https://ci.zigbox.org/repos> → `ZigboxOrg/zigbox`: the run of `vmw/m0-ci-check` must end green
within about ten minutes, the `demo` step must end with `demo-m0` passing, the `delete-branch` step
with `deleted the scratch branch`, and the branch must be gone:

```bash
git ls-remote origin vmw/m0-ci-check
```

prints nothing. On the box, the run used its own cache scope:

```bash
ls /var/lib/zigbox-ci/vm/vm-entries
```

lists `vm-image-...` (if instead a directory named `${CI_PIPELINE_EVENT}` appears under
`/var/lib/zigbox-ci`, this Woodpecker does not substitute variables in `volumes:`; stop and report
it). Then open a pull request: `check` and the `demos` workflows appear as checks on it, and
`ls /var/lib/zigbox-ci/pull_request` fills.

## Sessions reading results

The box's API is public for this repository: reads need no token, only `ci.zigbox.org` in the
session environment's allowed hosts. The repository id is 1.

```bash
api=https://ci.zigbox.org/api/repos/1
curl -fsS "$api/pipelines" | jq -r '.[] | "\(.number) \(.branch) \(.commit[:12]) \(.status)"' | head
n=42  # the pipeline number for your branch or commit, from the list above
curl -fsS "$api/pipelines/$n" |
    jq -r '.workflows[] | .name as $w | .children[] | "\($w) \(.id) \(.name) \(.state)"'
step=7  # a step id from the list above
curl -fsS "$api/logs/$n/$step" | jq -r '.[].data' | while read -r line; do
    printf '%s' "$line" | base64 -d; echo
done
```

Each log line comes back base64-encoded in `.data`. The run's page is
`https://ci.zigbox.org/repos/1/pipeline/<n>`; quote that link in a report.

## Running it

- **Restart or upgrade:** change the tags and their digests in `compose.yaml` (and the
  `plugin-git` digest in `.woodpecker/*.yaml`) on `main`, then rerun the bootstrap
  command (step 3); it fetches the new files. Zig upgrades change `image/Dockerfile` and every
  pipeline's `image:` line together.
- **Logs:** `docker compose -f /opt/zigbox-ci/compose.yaml logs -f woodpecker-agent`.
- **Load:** `CI_MAX_WORKFLOWS` (3) workflows at once, each a VM guest or a set of builds; the
  simulation fleet shares the box. Lower it if the fleet's rounds slow down.
- **Disk:** VM images are stored per pinned version under `/var/lib/zigbox-ci/<scope>/vm-entries`
  (`src/testing/vm/cache.zig`, switched on by `ZBX_VM_CACHE` or `-Dvm-cache`). Each stored entry
  carries the SHA-256 of its files and is checked on every restore: a file that does not match is
  not used, and the entry is deleted and stored again from a fresh download. Each save keeps at
  most two keys per entry (the current pin and the newest older one), so a scope holds at most two
  copies of each image set. The Zig caches (`zig`, `zig-root`) are bounded by the hourly
  `zigbox-ci-prune` timer: a scope whose Zig caches pass 30 GiB is emptied while it holds the
  scope's `.prune-lock` exclusively, which no step holds then (a scope in use is skipped until the
  next hour; `journalctl -u zigbox-ci-prune` shows when). Empty one by hand the same way:
  `flock -x /var/lib/zigbox-ci/<scope>/.prune-lock find /var/lib/zigbox-ci/<scope>/zig
  /var/lib/zigbox-ci/<scope>/zig-root -mindepth 1 -delete`. Docker's own: `docker system prune -f`.
- **Full CI on a pull request:** the `full-ci` label starts `check` and `demos` again at once
  (the `pull_request_metadata` event); if Woodpecker does not pass the labels with that event,
  nothing starts and the next push to the pull request runs everything. The label is matched
  whole (`no-full-ci` does not count). While `full-ci` is on a pull request, adding or removing any
  other label starts everything again too; remove `full-ci` first if that is not wanted.
