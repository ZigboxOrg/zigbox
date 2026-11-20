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

**What a writer can reach.** A pipeline's YAML comes from the pushed branch, and anyone with write
access can run a pipeline here without approval: a push to `vmw/*`, or a pull request from a branch
of this repository. The repository is Trusted, so that YAML can ask for `privileged: true` and any
host mount, and a privileged step is **root on the host**. The host also holds, and a writer can
therefore read:

- Woodpecker's database (`woodpecker-data`), with the GitHub OAuth token of the admin who activated
  the repository (scope `repo`: write access to everything that account can write);
- the Docker socket, the fleet's token and `/etc/zigbox-ci/*` (the OAuth secret, the agent secret);
- the `github_token` secret (a pipeline can print it; Woodpecker masks the exact string, not a
  transformed copy), and every cache scope.

Woodpecker 3 cannot hold a secret back from one branch or file, and the token's scope limits only
that one secret. The control that limits the rest is **`main`'s protection, which nobody can
bypass**: pull requests required, no bypass allowances, `enforce_admins` on, no force pushes or
deletion. Then even the OAuth token of the activating admin cannot change `main`. (It can still
write other branches and read the repository; this is not a sandbox against a writer.) On Actions a writer
reaches only that run's `GITHUB_TOKEN`, not a host. `woodpecker-setup.sh` reads the protection with `gh api` and refuses to finish unless it is
so. To make it so (as an admin, `gh auth login` first; this replaces `main`'s protection, so add
any status checks the repository requires to `required_status_checks`, or leave it `null`):

```bash
gh api -X PUT repos/ZigboxOrg/zigbox/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "bypass_pull_request_allowances": {"users": [], "teams": [], "apps": []}
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
gh api repos/ZigboxOrg/zigbox/branches/main/protection |
    jq '{enforce_admins: .enforce_admins.enabled, bypass: .required_pull_request_reviews.bypass_pull_request_allowances}'
```

Activate the repository (the first run of the setup script) from an account that has no bypass of
`main`'s protection. Woodpecker needs repository admin to activate, so that account is an admin;
with `enforce_admins` on, an admin has no bypass, which the check above proves. Check the account
itself: `gh api repos/ZigboxOrg/zigbox/collaborators/<login>/permission --jq .permission` (`admin`
or `write`), and that it is in no bypass list (`bypass_pull_request_allowances` above is empty, and
`gh api repos/ZigboxOrg/zigbox/rulesets --jq '.[].name'` lists no ruleset that names it as a bypass
actor; rulesets are not read by the script, so keep protection classic). Prefer a dedicated
machine-user account, so that the token the box stores is not a person's.

**Why this is accepted (owner, 2026-11-20).** Anyone with write access to `ZigboxOrg/zigbox`, and
anyone holding a writer's credentials (a leaked writer token included), can run privileged steps
on this box without approval, and so can read everything listed above and act as root on the host.
A leaked `github_token` secret alone is narrower (it deletes or pushes scratch branches), but a
leaked writer token is not: it can push `vmw/*`. This is accepted because the writers are the
owner and the owner's sessions, and pull requests from forks, which anyone can open, wait for
approval (`require_approval: forks`). `all_events` stays off. **If write access ever widens** (a
collaborator, a team, a bot, an app with `contents: write`), the box must not stay as it is: before
adding the writer, set `ZBX_CI_APPROVAL=all_events ZBX_CI_APPROVED_USERS=<the owner's logins>` and
rerun `woodpecker-setup.sh` (next paragraph), or move the server off the agent's host. Treat
write access to the repository as root on the box until then. Decision:
`docs/decisions/2026-11-20-woodpecker-approval-and-blob-cache.md`.

**Approval.** Woodpecker 3.20.1 (`server/pipeline/gated.go`) offers `require_approval` =
`none`, `forks` (default; set explicitly), `pull_requests` (every pull request, same-repository
ones too) or `all_events` (every push and pull request; cron and manual runs excepted), and
`approval_allowed_users`, logins whose pipelines never wait. The only way to hold a writer's
`vmw/*` push or same-repo pull request is therefore `all_events`, with the allowed logins listed:

```bash
ZBX_CI_APPROVAL=all_events ZBX_CI_APPROVED_USERS=login1,login2 \
    bash /opt/zigbox-ci/src/ops/ci/woodpecker-setup.sh
```

The trade-off: the check is the pipeline's author (the pusher's GitHub login). The sessions push
as the owner's account, so listing it lets them through, and approval then stops nobody who holds
that account's credentials (a prompt-injected session included); it stops only other writers. Every
other push, and every `vmw/*` push by someone not listed, waits for a click in the UI, which
defeats `vmw/*` for them. The script does not set it by default, because that changes who can run
what on the box (the owner decided on 2026-11-20 to keep it off, with the consequence above). The default stays `forks`,
and `main`'s protection above is the control.

It reads the settings back; the last line must be `ci-setup: OK ZigboxOrg/zigbox (id N): ...`
with `"require_approval":"forks"` (or what you set) and `github_token secret: yes`. It needs `gh`
logged in on the box (`gh auth login`) for the protection check, and fails with one line naming what
to fix if `main` can be bypassed. Run it again at any time: it only
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
to `vmw/*`, need no approval: only people with write access can make them, and what such a
writer can reach is listed under "What a writer can reach" above.

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
- **Load:** `CI_MAX_WORKFLOWS` (3) workflows at once, box-wide: the agent starts no fourth, so at
  most three VM demos run together (a pipeline's 18 demo workflows queue behind them; Woodpecker
  has no per-file limit, and a YAML-side cap would only restate this one). Why 3: the box has 8
  cores (16 threads), 64 GiB and a network link shared with the simulation fleet; a demo boots a
  guest of about 2 vCPUs and 4 GiB, so three guests are 6 vCPUs and 12 GiB, leaving the rest for
  the builds and the fleet, and three at once share the link for their image downloads. This is
  sized from those figures, not measured under load: lower it if the fleet's rounds slow down,
  raise it only after watching a run with the box's load.
- **Warm the caches once** before judging a run's time or its demos: a scope's first demo-m4 builds
  `m4-blobs.img` and pulls the registry images (minutes), and every later one restores them. After
  a bootstrap, or when a scope under `/var/lib/zigbox-ci` is new or emptied, run each scope's m4
  once, alone: push `vmw/m4-warm` for the `vm` scope and open a pull request for `pull_request`
  (`push` fills on the first push to `main`), wait for it to finish, then run the rest.
- **Disk:** VM images are stored per pinned version under `/var/lib/zigbox-ci/<scope>/vm-entries`
  (`src/testing/vm/cache.zig`, switched on by `ZBX_VM_CACHE` or `-Dvm-cache`). Expect, per scope,
  a few GiB per stored key (the Ubuntu image, three guest images, the Alpine rootfs, and the m4
  blob image, a sparse file of up to 1 GiB), two keys at most per entry, so on the order of
  10 to 15 GiB per scope and up to about 75 GiB over the five scopes once all are warm, besides the
  Zig caches (30 GiB each at most). These figures are estimates, not measurements: read the real
  ones with `du -sh /var/lib/zigbox-ci/*/vm-entries/*`. `bootstrap.sh` refuses a box with under
  100 GiB free. Each stored entry carries the SHA-256 of its files and is checked on every
  restore: a file that does not match is not used, and the entry is deleted and stored again from
  a fresh download. A stored entry is also replaced, atomically (the new copy is written under a
  temporary name, the old one renamed aside, the new one renamed in, the old one deleted, all
  under the store's lock `vm-entries/.lock`, so it is safe beside the prune and the other
  pipelines), when its list is missing or unreadable, and, for the m4 blob image, when a run whose
  steps all passed leaves a different image (a cold copy saved by a first run is replaced by the
  warm one, so the next demo-m4 does not pull again and stays inside its 60 s). Directories a
  killed save left (names starting with a dot) are removed by the next save. Each save keeps at
  most two keys per entry (the current pin and the newest older one). **To clear one entry by
  hand** (a stale or suspect copy; the next run rebuilds it), take the store's lock and delete its
  key directory, the key being the prefix and the first 16 hex digits of the SHA-256 of its pin
  file (`vm-m4-blobs-` and `sha256sum src/testing/vm/zbx.lock | cut -c1-16`):
  `flock -x /var/lib/zigbox-ci/<scope>/vm-entries/.lock rm -rf
  /var/lib/zigbox-ci/<scope>/vm-entries/vm-m4-blobs-<16 hex>`; `rm -rf` of every directory in
  `vm-entries` (the lock file stays) clears the scope's VM images. The Zig caches (`zig`,
  `zig-root`) are bounded by the hourly `zigbox-ci-prune` timer: a scope whose Zig caches pass
  30 GiB is emptied while it holds the scope's `.prune-lock` exclusively, which no step holds
  then. The prune waits up to 30 minutes for that gap and logs `SKIPPED` when it gets none
  (`journalctl -u zigbox-ci-prune`), so a scope kept busy by back-to-back pipelines can pass the
  bound for hours (steps that start while it waits are not held back, so it needs a gap
  between steps). If
  `SKIPPED` repeats for a scope, empty it by hand the same way:
  `flock -x /var/lib/zigbox-ci/<scope>/.prune-lock find /var/lib/zigbox-ci/<scope>/zig
  /var/lib/zigbox-ci/<scope>/zig-root -mindepth 1 -delete`. Docker's own: `docker system prune -f`.
- **Full CI on a pull request:** the `full-ci` label starts `check` and `demos` again at once
  (the `pull_request_metadata` event); if Woodpecker does not pass the labels with that event,
  nothing starts and the next push to the pull request runs everything. The label is matched
  whole (`no-full-ci` does not count). While `full-ci` is on a pull request, adding or removing any
  other label starts everything again too; remove `full-ci` first if that is not wanted.
