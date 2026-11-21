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
BuildKit, Compose, QEMU, `curl`, `git`, `jq` and `gh`, which step 4's script needs). On your own machine
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
GitHub login (the bot's from step 3a: the Woodpecker admin), and the OAuth app's Client ID and secret (read without echo; it
lands in `/etc/zigbox-ci/github-client-secret`, mode 0640, group 1000: the server image runs as uid
1000). Then it installs Docker, BuildKit, Compose, QEMU, jq and gh, builds the step image, starts Woodpecker and
Caddy, installs the hourly cache bound (`zigbox-ci-prune.timer`), and waits for the certificate
and the agent. The last line must be `ci-bootstrap: OK
https://ci.zigbox.org (...)`. A `FAIL` line says what to fix; fix it and run the same command again.
To change a setting later, edit `/etc/zigbox-ci/ci.env` (or delete a secret file to be asked again)
and rerun.

**3a. Owner steps: a Woodpecker account that cannot change `main`, and `main`'s protection.**
On a fresh box, make the account (1 below) before the bootstrap of step 3, which asks for its
login; the rest follow the bootstrap, in order. Section 4 is the detail of 3a.6, not a separate
step: do not run its script before 3a.5. Steps 1, 2, 3, 5, 7 and 10 run on your own machine or in a
browser; steps 4, 6, 8 and 9 run **on the box, as root** (each says so). The facts behind all of it
are under "What a writer can reach". Values you supply:

- `BOT_LOGIN`: the GitHub login of a new account made for Woodpecker, for example
  `zigbox-ci-bot` (a machine user: GitHub's terms allow one per person, and it needs its own
  e-mail address). It is the only account that ever logs in to Woodpecker and the one that
  activates the repository.
- `OWNER_LOGINS`: the logins that merge into `main`, comma separated: the account the sessions'
  pull requests are authored from (the supervisor merges from it), and any human who merges. Run
  `gh pr view <a recent pull request> --json author --jq .author.login` to see the first.
- The fine-grained check token (below) and the bot's own tokens, which you make in the browser.

Run these in this order. On a fresh box that is all there is. On a box whose repository is
already turned on in Woodpecker, and which an owner's own login owns (the first setup of this
runbook did that), the order is what keeps CI working: the repository is handed to the bot (step
6) **before** the owner's login is deleted (step 8), because Woodpecker looks the repository's
owner up on every webhook, and a repository whose owner is deleted answers every push with a 404
and runs nothing, with no error anywhere.

1. **Make the account** (browser: GitHub has no API to create an account or to enrol two-factor
   authentication): sign up as `BOT_LOGIN`, turn on two-factor authentication, and keep its
   password and recovery codes with the owner. Step 2 makes it a plain member of `ZigboxOrg`
   (never an owner, in no team), because Woodpecker logs in only members of the organisation
   (`WOODPECKER_ORGS`) and GitHub lets only a member make a fine-grained token on one of its
   repositories. A member inherits the organisation's base repository permission on every
   repository, so step 2 sets that to **none**, and gives the bot a role on `ZigboxOrg/zigbox`
   alone.
2. **Add it to the repository and set `main`'s protection** (needs `gh`, `jq`; log in with
   `gh auth login` as an owner of `ZigboxOrg`). The role is `admin` on a fresh box, where the bot
   turns the repository on (GitHub lets only an admin do that), and `write` when the repository is
   already on in Woodpecker:

   ```bash
   export BOT_LOGIN=zigbox-ci-bot OWNER_LOGINS=zvozin   # your values
   bash ops/ci/owner-github.sh admin    # or: write, on a box whose repository is already on
   ```

   It first sets `ZigboxOrg`'s base repository permission to `none` and, in the same call, turns
   off members' rights to create repositories (public and private), to create Pages sites and to
   fork private repositories (`members_can_create_repositories`,
   `members_can_create_public_repositories`, `members_can_create_private_repositories`,
   `members_can_create_pages`, `members_can_fork_private_repositories`), so the bot's token, read
   from the box, cannot publish anything under the organisation's name. It reads each one back and
   stops unless all hold. **These apply to every member, not only the bot:** a member then keeps
   only what a team or a direct grant on a repository gives them, and creates nothing (owners of
   the organisation still can); check with `gh api orgs/ZigboxOrg/members --jq '.[].login'` who
   that is before the first run. With the base permission gone, it checks that every
   `OWNER_LOGINS` account can still merge (an owner of the organisation, or a direct `write`,
   `maintain` or `admin` role) and stops, naming the account and the `gh api` line that gives it a
   direct role, before it writes anything else. The first run then invites the bot to `ZigboxOrg` as a
   `member` and stops. Log in as the bot in a private browser window, accept at
   <https://github.com/orgs/ZigboxOrg/invitation> (or `gh api -X PATCH user/memberships/orgs/ZigboxOrg
   -f state=active` with the bot's own `gh` login), and run the same command again. It refuses
   (and fails on any answer it cannot read, never taking it for "not a member") while the bot is
   an owner of the organisation or in any of its teams. It adds the bot to `ZigboxOrg/zigbox` with
   the role, then replaces `main`'s protection (**the whole
   protection: anything set by hand and not listed here is gone**) with: pull requests required
   (**no approving review**, so the supervisor's merges still work), `enforce_admins`, force pushes
   and deletion off, and **pushes and merges restricted to `OWNER_LOGINS`**. It reads everything
   back (the bot is an active `member` with the role on the repository, the base permission is
   `none` and members create and fork nothing, the restrictions are exactly `OWNER_LOGINS` and `ALLOW_APPS`, reviews are required) and
   ends in `owner-github: OK ...`. Before you run it, check that no
   workflow pushes to `main` with a token of its own: `grep -n 'git push' .github/workflows/*.yml`
   (none does today besides tags); if one does, pass its GitHub App's slug in `ALLOW_APPS=slug`.
3. **Make the two read tokens** (browser: GitHub has no API for fine-grained tokens), at
   <https://github.com/settings/personal-access-tokens/new>. As the **owner**: `ZigboxOrg/zigbox`
   only, **Administration: Read** and **Metadata: Read**, expiry 30 days; step 6's script asks for
   it, uses it for its checks and does not store it. As the **bot** (logged in as the bot):
   `ZigboxOrg/zigbox` only, **Contents: Read and write**, for the branch deletion (step 6).
   If `ZigboxOrg` requires administrator approval of fine-grained tokens, the bot's token stays
   *pending*, and every call with it answers 403 until you approve it, so look before step 6.
   Approve it in the browser, at
   <https://github.com/organizations/ZigboxOrg/settings/personal-access-token-requests> (the
   organisation's **Settings → Personal access tokens → Pending requests**): GitHub's API for these
   requests (`orgs/ZigboxOrg/personal-access-token-requests`) answers GitHub Apps only, so `gh`
   logged in as you cannot list or approve them. Approve only a request from `BOT_LOGIN` for
   `ZigboxOrg/zigbox` alone with **Contents: Read and write**; it then appears under **Active
   tokens** on the same page.
4. **Make the bot the Woodpecker admin** (on a fresh box the bootstrap asked for it). On the box,
   as root: set `CI_ADMINS=BOT_LOGIN` in `/etc/zigbox-ci/ci.env`, then run the bootstrap command of
   step 3 again. It installs `sqlite3`, which step 6 uses to check the repository's owner.
5. **Log in to Woodpecker as the bot** (browser, a private window, <https://ci.zigbox.org>, grant
   access to `ZigboxOrg`) and copy its token from **User settings → CLI & API**.
6. **Set the repository up: this makes the bot its owner.** As root on the box (section 4 below
   has the details):

   ```bash
   bash /opt/zigbox-ci/src/ops/ci/woodpecker-setup.sh
   ```

   Run as the bot, it calls `POST /api/repos/ID/chown`, then reads Woodpecker's own database file
   (`sqlite3 -readonly`, because the API does not show a repository's owner) and refuses unless
   the repository's owner is the bot and **no repository has an owner whose user is gone**. On a
   box that still has the owner's login in Woodpecker, this first run does its work and then ends
   in a refusal that names the accounts to delete: that is step 8, then run it again (step 9).
7. **Take the admin role away, if step 2 gave it:**

   ```bash
   bash ops/ci/owner-github.sh write
   ```

   Woodpecker keeps working with `write`: it clones, posts statuses and receives webhooks with it.
   If a pipeline later fails with a 403 from GitHub that names the webhook, repeat `admin`, let
   Woodpecker repair it, and go back to `write`.
8. **Remove every other account Woodpecker knows.** If you (or anyone else) ever logged in to
   Woodpecker, the box holds that account's GitHub token. Delete it from Woodpecker with the bot's
   token, then revoke the grant on GitHub, which only the account itself can do in the browser
   (the API needs the token that is stored): <https://github.com/settings/applications> → Authorized
   OAuth Apps → Zigbox CI → Revoke. `WOODPECKER_TOKEN` is the value you copied in step 5. The
   token stays off the command line (it would show in `ps` and the shell history): it goes in a
   file only you can read, which `curl -H @file` reads.

   ```bash
   umask 077; auth=$(mktemp)
   read -rsp 'Woodpecker token: ' WOODPECKER_TOKEN; echo
   printf 'Authorization: Bearer %s\n' "$WOODPECKER_TOKEN" > "$auth"; unset WOODPECKER_TOKEN
   curl -fsS -H @"$auth" https://ci.zigbox.org/api/users | jq -r '.[].login'
   curl -fsS -X DELETE -H @"$auth" https://ci.zigbox.org/api/users/OWNER_LOGIN   # each one but the bot
   curl -fsS -H @"$auth" https://ci.zigbox.org/api/users | jq -r '.[].login'     # only the bot now
   rm -f "$auth"
   ```

   Approving a fork's pull request (step 5 of the runbook) then means logging in to Woodpecker as
   the bot, in a private window.
9. **Run `woodpecker-setup.sh` again** (step 6's command). It must end `ci-setup: OK`: it refuses
   while any account Woodpecker holds a token for is an admin of the repository, or may push or
   merge into `main`, or if a permission cannot be read.
10. **Check that a webhook is delivered and runs.** Deleting the wrong account breaks this
    silently, so look at GitHub's side. Push a scratch branch and read the delivery:

    ```bash
    git push origin HEAD:refs/heads/vmw/m0-ci-check
    gh api repos/ZigboxOrg/zigbox/hooks --jq '.[] | select(.config.url | test("ci.zigbox.org")) | .id'
    gh api repos/ZigboxOrg/zigbox/hooks/HOOK_ID/deliveries --jq '.[0] | "\(.event) \(.status_code)"'
    ```

    The last line must be `push 200` (a `404` means the repository's owner is gone: run step 6 as
    the bot), and the pipeline must appear in the public API
    (`curl -fsS https://ci.zigbox.org/api/repos/lookup/ZigboxOrg/zigbox` then its `/pipelines`).
    Delete the scratch branch afterwards.

**4. Details of step 3a.6, the repository's set-up.** Logging in is GitHub's OAuth consent, so it is a
browser step: in a private window open <https://ci.zigbox.org>, log in with GitHub as the bot of 3a and grant access to `ZigboxOrg`.
Then copy your personal token from **User settings → CLI & API** (Woodpecker makes its API tokens
only for a logged-in browser session; there is no API call that mints the first one).

The GitHub token that deletes `vmw/*` branches is the bot's from step 3a.3 (a fine-grained token,
`ZigboxOrg/zigbox` only, **Contents: Read and write**, nothing else). Then, as root on the box:

```bash
bash /opt/zigbox-ci/src/ops/ci/woodpecker-setup.sh
```

It asks for the Woodpecker token, the bot's GitHub token and the owner's read-only check token
(none is echoed or put on a command line; press Enter at the second to keep the stored one;
the third is not stored), and through Woodpecker's API it:

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

- Woodpecker's database (`woodpecker-data`), with **the GitHub OAuth token of every account that
  ever logged in to Woodpecker** (scope `repo`);
- the Docker socket, the fleet's token and `/etc/zigbox-ci/*` (the OAuth secret, the agent secret);
- the `github_token` secret (a pipeline can print it; Woodpecker masks the exact string, not a
  transformed copy), and every cache scope.

Woodpecker 3 cannot hold a secret back from one branch or file. What is true of the stored tokens
(corrected 2026-11-20; this section used to say a protected `main` kept them from changing it,
which is false):

- **The forge is GitHub** (`WOODPECKER_GITHUB`, the OAuth app of step 2). Woodpecker stores the
  token of each account that logs in, and uses the token of the account that turned the repository
  on for its clone, statuses and webhook. A token can do what its account can, within the scope
  `repo`; nothing about the OAuth app narrows it to this repository.
- **Today `main` is unprotected.** Checked 2026-11-20 as a repository admin: `GET
  branches/main/protection` answers 404 "Branch not protected", and the repository has no
  rulesets. So a token of an admin, or of anyone with write access, pushes to `main` or deletes
  it directly.
- **The protection the runbook used to prescribe would not have stopped an admin's token.**
  `enforce_admins` makes admins obey the rules; it does not stop an admin from changing them
  (`DELETE .../protection/enforce_admins`, or a `PUT` of the whole protection), and with zero
  required approvals and no required checks a token can open a pull request and merge it at once,
  which is not a bypass. Woodpecker needs an admin only to turn the repository on, and the
  owner's account is an admin.
- **A writer's token is bounded by `main`'s push restrictions, not by its pull requests.** With
  `main` restricted to named users (classic branch protection, organisation repositories), a token
  of an account that is not on the list can neither push to `main` nor merge a pull request into
  it, and, if it is not an admin, cannot change the restriction. It can still do everything else a
  writer can: push and delete other branches, push tags (so anything that trusts the existence of
  a tag or a branch needs its own guard), open pull requests, read the repository, and push `vmw/*`.
  Required reviews are not used: the sessions author the pull requests from the owner's account
  and the supervisor merges them from it, so a required approving review would block every merge.
  A required status check does not help either: the box's own token can post a commit status
  under any name, and a check from GitHub Actions can be satisfied by a workflow the pull request
  itself defines.
- **Releases and the Homebrew tap.** A writer's token can also edit a *published* release's assets
  and re-dispatch `release.yml`, whose `tap` job commits the release's formula to
  `ZigboxOrg/homebrew-tap`, which Homebrew users install from. The Mac zip, its sums and the
  formula are outside the signed `SHA256SUMS`, so a writer can replace all four consistently, on
  the draft after `mac` attaches them or on the release before `tap` reads them. What stops that:
  `mac` gives the zip's SHA-256 as its job output, which no token can change, and both `prepare`
  and `tap` refuse a zip that is not that one (the formula's sha256 and both sums files must match
  the zip, so they are pinned with it). On an already published release `mac` does not run, so a
  re-dispatch waits for the owner's approval (`tap-approve`, on the `release` environment) before
  `tap` runs, and `tap` refuses any zip but the one `plan` hashed and showed the owner (its job
  output), so a zip replaced during the wait is refused. Both also re-check the Linux files against `SHA256SUMS` and its signature by the
  pinned key, the formula's url and version, and that the zip holds only `zbx`; and `tap-formula`
  refuses a formula whose url is not the release's own zip. Left to the approval: on a re-dispatch,
  the owner approves a zip that nothing signed pins, after checking in `plan`'s summary that the
  run is their own and the zip's hash is the one recorded at release time
  (`docs/releases/automation.md`, "The tap").
- **So the control is on accounts, not on the protection alone:** Woodpecker only ever knows a
  dedicated bot account with the `write` role, which is not on `main`'s restriction list; the owner
  accounts that can merge never log in to it (step 3a). `woodpecker-setup.sh` checks this, with a
  read-only token it is given for the run: it lists the accounts Woodpecker holds a token for
  (`GET /api/users`), and refuses unless `main` has `enforce_admins`, push restrictions with no
  team and none of those accounts in them (or in the bypass list), no force pushes and no
  deletion, and, at the end, none of those accounts is a repository admin (the run that turns
  the repository on needs an admin, so it only warns).
- **What stays reachable** from the box even so: every branch other than `main`, tags, the
  repository's contents, whatever the bot's `github_token` can write, and anything the fleet's own
  token (a file on this host) can reach; that token's scope is not checked here and should be
  limited the same way. On Actions a writer reaches only that run's `GITHUB_TOKEN`, not a host.

The steps that set this up, with every value, are 3a above; they are the owner's.

**Why this is accepted (owner, 2026-11-20).** Anyone with write access to `ZigboxOrg/zigbox`, and
anyone holding a writer's credentials (a leaked writer token included), can run privileged steps
on this box without approval, and so can read everything listed above and act as root on the host.
A leaked `github_token` secret alone is narrower (it deletes or pushes scratch branches), but a
leaked writer token is not: it can push `vmw/*`. This is accepted because the writers are the
owner and the owner's sessions, and pull requests from forks, which anyone can open, wait for
approval (`require_approval: forks`). `all_events` stays off. **If write access ever widens** (a
collaborator, a team, an app with `contents: write`; the bot of 3a is the one writer that is
meant to be there, and its token lives only on this box), the box must not stay as it is: before
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
and the accounts rule above (the bot is not on `main`'s push restrictions) is the control for `main`.

It reads the settings back; the last line must be `ci-setup: OK ZigboxOrg/zigbox (id N): ...`
with `"require_approval":"forks"` (or what you set) and `github_token secret: yes`. It needs `gh`
on the box (the bootstrap installs it) but no `gh` login: the check token is given to it for the run. It fails
with one line naming what to fix if `main` could be changed by an account Woodpecker holds a token
for. Run it again at any time: it only sets what is not already so.

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
  most three VM demos run together (a pipeline's 19 demo workflows queue behind them; Woodpecker
  has no per-file limit, and a YAML-side cap would only restate this one). Why 3: the box has 8
  cores (16 threads), 64 GiB and a network link shared with the simulation fleet; a demo boots a
  guest of about 2 vCPUs and 4 GiB, so three guests are 6 vCPUs and 12 GiB, leaving the rest for
  the builds and the fleet, and three at once share the link for their image downloads. This is
  sized from those figures, not measured under load: lower it if the fleet's rounds slow down,
  raise it only after watching a run with the box's load.
- **Warm the caches once** before judging a run's time or its demos: a scope's first demo-m4 builds
  `m4-blobs.img` and pulls the registry images (minutes), and every later one restores them. After
  a bootstrap, or when a scope under `/var/lib/zigbox-ci` is new or emptied, run each scope's m4
  once, alone, for each of the five scopes: push `vmw/m4-warm` for `vm`; open a pull request for
  `pull_request`; add the `full-ci` label to a throwaway pull request (or a label change on one
  that already has it) for `pull_request_metadata`, which runs every demo; start a manual run
  from the Woodpecker UI (repository -> Run pipeline) for `manual`; `push` fills on the first
  push to `main`. Wait for each to finish, then run the rest. A first demo-m4 in a scope you
  have not warmed is expected to miss its 60 s bound.
- **Disk:** VM images are stored per pinned version under `/var/lib/zigbox-ci/<scope>/vm-entries`
  (`src/testing/vm/cache.zig`, switched on by `ZBX_VM_CACHE` or `-Dvm-cache`). Expect, per scope,
  a few GiB per stored key (the Ubuntu image, three guest images, the Alpine rootfs, and the m4
  blob image, a sparse file of up to 1 GiB), two keys at most per entry, so on the order of
  10 to 15 GiB per scope and up to about 75 GiB over the five scopes once all are warm, besides the
  Zig caches (30 GiB each at most). These figures are estimates, not measurements: read the real
  ones with `du -sh /var/lib/zigbox-ci/*/vm-entries/*`. `bootstrap.sh` refuses a box with under
  250 GiB free, counting what `/var/lib/zigbox-ci` already uses, so a rerun on a warm box passes (the steady state of about 225 GiB, with Docker's own on top), and before demo-s2
  the driver prints `df -h` for the workspace and the VM cache and refuses with one line naming the
  shortfall (`demo-s2: 12 GiB free under .; it needs 30`) when either has under 30 GiB. Each stored entry carries the SHA-256 of its files and is checked on every
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
