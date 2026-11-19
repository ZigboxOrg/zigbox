# CI on the fleet box (Woodpecker)

Zigbox's CI runs on the fleet box (AMD Ryzen 7 1700X, 8 cores and 16 threads, 64 GiB, two 512 GB
SATA SSDs) under [Woodpecker](https://woodpecker-ci.org) 3.20.1. Code and pull requests stay on
GitHub (`ZigboxOrg`); Woodpecker logs in with GitHub and posts each workflow as a check on the pull
request. Decision: `docs/decisions/2026-11-19-ci-on-woodpecker.md`.

| What | Where |
|------|-------|
| Woodpecker server, one agent, Caddy (TLS) | `compose.yaml`, `Caddyfile`, run by `bootstrap.sh` from `/opt/zigbox-ci` |
| Settings, secrets | `/etc/zigbox-ci/` (`ci.env`, `github-client-id`, `github-client-secret`, `agent-secret`) |
| The image every step runs in | `image/Dockerfile`, built on the box as `zigbox-ci:0.17.0` |
| Pipelines | `.woodpecker/check.yaml` (code gates), `demos.yaml` (VM demos), `vm.yaml` (`vm/*` branches) |
| Step logic | `zig build ci-*` and `vm-branch` (`src/ci_main.zig`, `src/ci/`); the VM image caches are `src/testing/vm/cache.zig` |
| Caches | `/var/lib/zigbox-ci/zig` (Zig's global cache), `/var/lib/zigbox-ci/vm-entries` (VM images) |

The YAML holds only what the build cannot: triggers, the demo matrix, `privileged`, volumes, the
`github_token` secret and these environment values. Each step is one `zig build ...` line.

- `ZBX_CI_USER=tester`, `ZBX_CI_USER_ZIG_CACHE=/cache/zig`: the workspace is cloned as root. The
  driver, run as root with these set, hands the workspace to `tester` (`chown -R`) and runs every
  nested `zig build` through `runuser` as that user (uid 1001), so the tests see an ordinary user.
- `ZIG_GLOBAL_CACHE_DIR=/cache/zig-root`, `ZIG_LOCAL_CACHE_DIR=/cache/zig-root/local`: the outer
  root `zig build` keeps its caches outside the workspace, so nothing root-owned is left in
  `.zig-cache` for `tester` to trip on. `tester` uses `/cache/zig`.
- `ZBX_VM_CACHE=/cache/vm-entries`: switches on the VM image cache for `ci-demos`.
- `dbus-run-session` for the dbus-live gate is started by the driver, not by YAML.

Not ported yet (they stay in `.github/workflows/` until they are): `release.yml`, `top20.yml`,
`package-refresh.yml`, `pages.yml`, `mac.yml` (needs a Mac), and `vm/m8-push-ghcr` and `demo-m6d`
(they need tokens GitHub gave Actions; each says NOT RUN).

## Set it up

You need: a bare-metal server with Ubuntu 24.04 and root on it (a cloud VM has no `/dev/kvm`; the
bootstrap refuses one), a DNS name for it (below, `ci.zigbox.org`), and owner rights on the GitHub
organisation `ZigboxOrg`. Every step can be run again safely.

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
another branch than `main`) and runs the copy there. On the first run it asks for the DNS name,
your GitHub login (the Woodpecker admin), and the OAuth app's Client ID and secret (read without
echo; it lands in `/etc/zigbox-ci/github-client-secret`, mode 0640). Then it installs Docker,
Compose and QEMU, builds the step image, starts Woodpecker and Caddy, and waits for the certificate
and the agent. The last line must be `ci-bootstrap: OK https://ci.zigbox.org (...)`. A `FAIL` line
says what to fix; fix it and run the same command again. To change a setting later, edit
`/etc/zigbox-ci/ci.env` (or delete a secret file to be asked again) and rerun.

**4. Log in and turn the repositories on.** Logging in is GitHub's OAuth consent, a browser step:
open <https://ci.zigbox.org>, log in with GitHub and grant access to `ZigboxOrg`. Then, in
Woodpecker:

1. **Add repository** → `ZigboxOrg/zigbox` → enable. (Woodpecker adds the webhook on GitHub.)
2. Repository **Settings → Project**: turn on **Trusted** (every box it offers: security, volumes),
   **Cancel previous pipelines** for push and pull request, and set **Timeout** to `180` minutes.
   Trusted is what gives the demo steps `/dev/kvm` and the `/var/lib/zigbox-ci` mount; only an admin
   (`CI_ADMINS`) sees it.

Then copy your personal token from **User settings → CLI & API** for the next steps.

**5. The token that deletes `vm/*` branches.** A fine-grained token, `ZigboxOrg/zigbox` only,
**Contents: Read and write**, made at <https://github.com/settings/personal-access-tokens/new>
(GitHub has no CLI for fine-grained tokens). Store it as the Woodpecker secret `github_token`, with
the token from step 4:

```bash
export WOODPECKER_SERVER=https://ci.zigbox.org
```

```bash
read -rs WOODPECKER_TOKEN && export WOODPECKER_TOKEN
```

```bash
read -rs GH_PAT && REPO_ID=$(curl -fsS "$WOODPECKER_SERVER/api/repos/lookup/ZigboxOrg/zigbox" -H "Authorization: Bearer $WOODPECKER_TOKEN" | jq -r .id) && jq -n --arg v "$GH_PAT" '{name:"github_token", value:$v, events:["push"]}' | curl -fsS -X POST "$WOODPECKER_SERVER/api/repos/$REPO_ID/secrets" -H "Authorization: Bearer $WOODPECKER_TOKEN" -H 'Content-Type: application/json' -d @- >/dev/null && echo "secret github_token: stored"; unset GH_PAT
```

**6. Check that it works.** Push a scratch branch that runs the first demo:

```bash
git push origin HEAD:vm/m0-ci-check
```

Open <https://ci.zigbox.org/repos> → `ZigboxOrg/zigbox`: the run of `vm/m0-ci-check` must end green
within about ten minutes, its log must end with `demo-m0` passing and `deleted the scratch branch`,
and the branch must be gone:

```bash
git ls-remote origin vm/m0-ci-check
```

prints nothing. Then open a pull request: `check` and the `demos` workflows appear as checks on it.

## Sessions reading results

A cloud session reads runs through Woodpecker's API, `https://ci.zigbox.org/api/repos/<id>/pipelines`,
with a read token. To allow it, the session's environment needs `ci.zigbox.org` in its allowed hosts
and the token as a network secret for that host (the session asks for it with its credential form;
it never goes in chat or the repository).

## Running it

- **Restart or upgrade:** change the tags in `compose.yaml` on `main`, then rerun the bootstrap
  command (step 3); it fetches the new files. Zig upgrades change `image/Dockerfile` and every
  pipeline's `image:` line together.
- **Logs:** `docker compose -f /opt/zigbox-ci/compose.yaml logs -f woodpecker-agent`.
- **Load:** `CI_MAX_WORKFLOWS` (3) workflows at once, each a VM guest or a set of builds; the
  simulation fleet shares the box. Lower it if the fleet's rounds slow down.
- **Disk:** VM images are stored once per pinned version under `/var/lib/zigbox-ci/vm-entries`
  (`src/testing/vm/cache.zig`, switched on by `ZBX_VM_CACHE` or `-Dvm-cache`); an old pin's directory is never read again and can be deleted. Zig's cache
  (`/var/lib/zigbox-ci/zig`) can be emptied when no pipeline runs. Docker's own:
  `docker system prune -f`.
