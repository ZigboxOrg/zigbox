# Git backup on Forgejo

A second copy of every branch and tag of `ZigboxOrg/zigbox` and `ZigboxOrg/zigcube` lives on a
Forgejo at `https://git.zigbox.org`, on a small VPS of its own. Nobody pushes to it: a systemd
timer on that box fetches from GitHub every five minutes and copies what changed.

| What | Where |
|------|-------|
| Forgejo 15.0.12 (LTS), its own TLS (ACME) | `/usr/local/bin/forgejo`, `/etc/forgejo/app.ini`, data in `/var/lib/forgejo` |
| Settings, tokens | `/etc/zigbox-backup/` (`backup.env`, `github-token`, `forgejo-token`, `forgejo-secrets.env`) |
| The copy job | `sync.sh`, installed as `/usr/local/lib/zigbox-backup/sync.sh`; `zigbox-backup-sync.timer` |
| Working mirrors | `/var/lib/zigbox-backup/mirrors/<owner>/<name>.git` |

## What it keeps

- A new branch or tag is copied; a branch GitHub moved forward is moved forward.
- A branch moved any other way (a force push, a rebase) or a moved tag keeps its old tip on Forgejo
  as `archive/<UTC time>/<name>` before it follows GitHub. Nothing is ever deleted: a branch or tag
  deleted on GitHub stays on Forgejo.
- `vm/*` scratch branches are not copied (`BACKUP_SKIP` in `backup.env`).
- Not covered: issues, pull requests and their reviews, releases and their assets, Actions logs,
  wikis, settings. The code and its history only.

## Set it up

You need: a VPS with Ubuntu 24.04 or Debian 12/13 on x86_64, root on it (1 vCPU, 1 GiB of memory
and 25 GB of disk are plenty: both repositories are a few MiB; 512 MiB runs, without headroom), a DNS name for it (below,
`git.zigbox.org`) and owner rights on `ZigboxOrg`. Every step can be run again safely.

**1. DNS.** Add an `A` record from the name to the box's public IPv4 (unproxied, if your DNS
provider is Cloudflare; Forgejo gets its certificate itself over port 80/443). The bootstrap checks
the name resolves to the box.

**2. A read-only GitHub token.** GitHub has no CLI for fine-grained tokens, so this step is in the
browser: <https://github.com/settings/personal-access-tokens/new>, resource owner `ZigboxOrg`,
**Only select repositories** → `zigbox` and `zigcube`, **Repository permissions → Contents:
Read-only** (Metadata: Read-only comes with it), the longest expiry the organisation allows. Copy
it. If the organisation requires approval of fine-grained tokens, approve it under
<https://github.com/organizations/ZigboxOrg/settings/personal-access-token-requests>.

**3. Run the bootstrap on the box,** as root, in an SSH session (it asks questions):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ZigboxOrg/zigbox/main/ops/backup/bootstrap.sh)
```

It clones this repository into `/opt/zigbox-backup/src` (`ZIGBOX_BACKUP_REF=<branch>` before `bash`
picks another branch than `main`) and runs the copy there. On the first run it asks for the DNS
name, the Forgejo admin's login and e-mail (the e-mail also goes to Let's Encrypt), and the token
from step 2 (read without echo, stored in `/etc/zigbox-backup/github-token`, mode 0400). Then it
installs Forgejo (signature checked), starts it, creates the admin with a random first password
(kept in `/etc/zigbox-backup/admin-password`, root only; Forgejo asks for a new one at the first
login, then delete the file), the organisation `ZigboxOrg` and its two private
repositories, and the timer, and runs the first copy. The last line must be
`backup-bootstrap: OK https://git.zigbox.org (...)`; a `FAIL` line says what to fix.

**4. Check it.** Log in at <https://git.zigbox.org> with the admin and the printed password; both
repositories must list `main` and the other branches. On the box:

```bash
systemctl list-timers zigbox-backup-sync.timer
```

```bash
journalctl -u zigbox-backup-sync --since -1h
```

Each run ends in `backup: OK 2 repositories at <time>`; `/var/lib/zigbox-backup/last-ok` holds the
Unix time of the last good run.

## Running it

- **Lost the admin password:** rerun step 3 with `ZIGBOX_BACKUP_RESET_ADMIN=1` before `bash`; it
  writes a new first-login password to `/etc/zigbox-backup/admin-password`.

- **Renew the GitHub token** before it expires: `rm /etc/zigbox-backup/github-token` and rerun the
  bootstrap (step 3), which asks for a new one. A run with an expired token logs
  `FAIL fetching from GitHub`.
- **Upgrade Forgejo:** change `forgejo_version` (and the key, if Forgejo changed it) in
  `bootstrap.sh` on `main` and rerun step 3.
- **Another repository:** add it to `BACKUP_REPOS` in `/etc/zigbox-backup/backup.env` and rerun
  step 3 (it creates the repository on Forgejo).
- **Alerting** is not built yet: nothing tells you when runs fail. Until it is, look at
  `last-ok` now and then (a follow-up is to ping a heartbeat URL from `sync.sh` on OK).

## Restore

Everything is plain git. To recover a repository, or a branch someone force-pushed away:

```bash
git clone https://git.zigbox.org/ZigboxOrg/zigbox.git
```

```bash
git ls-remote https://git.zigbox.org/ZigboxOrg/zigbox.git 'refs/heads/archive/*'
```

The second lists every tip that a force push replaced, by time and branch name. To put a whole
repository back on GitHub (or anywhere): clone it with `--mirror` from Forgejo and `git push
--mirror` to the new remote, leaving out `archive/` refs if they are not wanted there.
