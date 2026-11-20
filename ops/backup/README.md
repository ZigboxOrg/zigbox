# Git backup on Forgejo

A second copy of every branch and tag of `ZigboxOrg/zigbox` and `ZigboxOrg/zigcube` lives on a
Forgejo at `https://git.zigbox.org`, on a small VPS of its own. Nobody pushes to it: a systemd
timer on that box fetches from GitHub every five minutes and copies what changed.

- Forgejo 15.0.12 (LTS) with its own TLS (ACME): `/usr/local/bin/forgejo`,
  `/etc/forgejo/app.ini`, data in `/var/lib/forgejo`.
- Settings and secrets in `/etc/zigbox-backup/`: `backup.env`, `github-token`, `forgejo-token`,
  `forgejo-secrets.env`, `admin-password`, `heartbeat-url`.
- The copy job: `sync.sh`, installed as `/usr/local/lib/zigbox-backup/sync.sh`, run by
  `zigbox-backup-sync.timer`. Its test is `sync-test.sh`, run by `zig build test`.
- Working mirrors in `/var/lib/zigbox-backup/mirrors/<owner>/<name>.git`; the last run's result in
  `last-ok` and `status` there.

## What it keeps

- A new branch or tag is copied; a branch GitHub moved forward is moved forward.
- A branch moved any other way (a force push, a rebase) or a moved tag keeps its old tip on Forgejo
  as `archive/<UTC time>/<name>` before it follows GitHub. Nothing is ever deleted: a branch or tag
  deleted on GitHub stays on Forgejo. When GitHub later creates a name that nests with a kept one
  (`claude/x` kept, `claude/x/y` new), Forgejo cannot hold both: the kept ref moves to
  `archive/<UTC time>/claude/x` and the new one is created.
- A ref Forgejo refuses gets its own `FAIL ... pushing refs/...` line; the other refs still copy.
- A GitHub branch or tag named `archive` or `archive/...` is not copied (that namespace is where
  the old tips live); each run says so.
- `vm/*` scratch branches are not copied (`BACKUP_SKIP` in `backup.env`).
- Not covered: issues, pull requests and their reviews, releases and their assets, Actions logs,
  wikis, settings. The code and its history only.

## Set it up

You need: a VPS with Ubuntu 24.04 or Debian 12/13 on x86_64 and root on it (1 vCPU, 1 GiB of
memory and 25 GB of disk are plenty, both repositories are a few MiB; 512 MiB runs, without
headroom), a DNS name for it (below, `git.zigbox.org`) and owner rights on `ZigboxOrg`. Every step
can be run again safely. The commands below use Hetzner Cloud (`hcloud`) and Cloudflare DNS; any
provider with a CLI or API does the same, and only the box's public IPv4 matters to step 3.

**0. Tools and logins, on your laptop.** `hcloud` (`brew install hcloud`, or the release page at
<https://github.com/hetznercloud/cli/releases>), `curl`, `jq` and an SSH key (`ssh-keygen -t
ed25519` if you have none). Two API tokens exist only in a browser, because no CLI can mint
the first token of an account: a Hetzner project token (console → project → Security → API
tokens, Read & Write), and a Cloudflare token (My Profile → API Tokens → Edit zone DNS, for the
zone `zigbox.org`). Store them where the commands below read them, never on a command line:

```bash
hcloud context create zigbox-backup
```

```bash
(umask 077; read -r -s -p 'Cloudflare token: ' t; echo
 printf 'Authorization: Bearer %s\n' "$t" > ~/.zigbox-cloudflare-header)
```

**1. The box and its DNS name,** one re-runnable block. It creates the VPS (a second run finds
it), then the `A` record (a second run finds that too). The record must be unproxied (grey cloud),
because Forgejo gets its certificate itself over ports 80 and 443:

```bash
name=git.zigbox.org
cf=https://api.cloudflare.com/client/v4
hcloud ssh-key describe zigbox-backup >/dev/null 2>&1 ||
    hcloud ssh-key create --name zigbox-backup --public-key-from-file ~/.ssh/id_ed25519.pub
hcloud server describe zigbox-backup >/dev/null 2>&1 ||
    hcloud server create --name zigbox-backup --type cx22 --image ubuntu-24.04 \
        --location fsn1 --ssh-key zigbox-backup
ip=$(hcloud server ip zigbox-backup)
zone=$(curl -fsS -H @$HOME/.zigbox-cloudflare-header "$cf/zones?name=${name#*.}" |
    jq -r '.result[0].id')
curl -fsS -H @$HOME/.zigbox-cloudflare-header "$cf/zones/$zone/dns_records?name=$name&type=A" |
    jq -e '.result[0]' >/dev/null ||
    curl -fsS -X POST -H @$HOME/.zigbox-cloudflare-header -H 'Content-Type: application/json' \
        --data "{\"type\":\"A\",\"name\":\"$name\",\"content\":\"$ip\",\"proxied\":false}" \
        "$cf/zones/$zone/dns_records" | jq -e .success
echo "$name -> $ip"
```

(`cx22` is an x86 type; if `hcloud server create` says it is gone, take the smallest x86 type
`hcloud server-type list` shows. The bootstrap refuses an arm64 box.) Wait until
`dig +short $name` prints the address.

**2. A read-only GitHub token.** GitHub has no CLI or API for fine-grained tokens, so this step is
in the browser: <https://github.com/settings/personal-access-tokens/new>, resource owner
`ZigboxOrg`, **Only select repositories** → `zigbox` and `zigcube`, **Repository permissions →
Contents: Read-only** (Metadata: Read-only comes with it), the longest expiry the organisation
allows. Copy it. If the organisation requires approval of fine-grained tokens, approve it under
<https://github.com/organizations/ZigboxOrg/settings/personal-access-token-requests>.

**3. Run the bootstrap on the box,** as root, over SSH with a terminal (it asks questions; `-t`
gives it one):

```bash
raw=https://raw.githubusercontent.com/ZigboxOrg/zigbox/main/ops/backup/bootstrap.sh
ssh -t root@$ip "bash <(curl -fsSL $raw)"
```

It clones this repository into `/opt/zigbox-backup/src` (`ZIGBOX_BACKUP_REF=<branch>` before `bash`
picks another branch than `main`) and runs the copy there. On the first run it asks for the DNS
name, the Forgejo admin's login and e-mail (the e-mail also goes to Let's Encrypt), and the token
from step 2 (read without echo, stored in `/etc/zigbox-backup/github-token`, mode 0400). Then it
installs Forgejo (signature checked), starts it, creates the admin with a random password that
never has to be changed (kept in `/etc/zigbox-backup/admin-password`, root only, and not printed),
the organisation `ZigboxOrg` and its two private repositories, and the timer, and runs the first
copy. The last line must be `backup-bootstrap: OK https://git.zigbox.org (...)`; any failure ends
in a `backup-bootstrap: FAIL <what>` line, with the failing step's own message above it.

**4. A heartbeat, so a failing backup is noticed.** Create a check at a heartbeat service that
alerts when pings stop and accepts `<url>/fail` for an explicit failure (healthchecks.io does;
its project API key makes the check through its API, or use the browser), and give the box its
ping URL. The URL is a secret, so it goes in a root-written file, read by the sync as its own user:

```bash
ssh -t root@$ip "read -r -s -p 'Heartbeat URL: ' u; echo
  (umask 077; printf '%s' \"\$u\" > /etc/zigbox-backup/heartbeat-url)
  chown zigbox-backup:zigbox-backup /etc/zigbox-backup/heartbeat-url"
```

Every good run pings the URL, and every failing run pings `<url>/fail`, so an expired GitHub token,
a refused ref or a dead box all raise the alert. Set the check's period to 10 minutes and its
grace to 10 more.

**5. Check it.** Log in at <https://git.zigbox.org> as the admin, with the password from
`ssh root@$ip cat /etc/zigbox-backup/admin-password`; both repositories must list `main` and the
other branches. On the box:

```bash
systemctl list-timers zigbox-backup-sync.timer
```

```bash
journalctl -u zigbox-backup-sync --since -1h
```

Each run ends in `backup: OK 2 repositories at <time>`; `/var/lib/zigbox-backup/last-ok` holds the
Unix time of the last good run, and `status` the last run's result.

## Running it

- **Lost the admin password:** rerun step 3 with `ZIGBOX_BACKUP_RESET_ADMIN=1` before `bash`; it
  writes a new password to `/etc/zigbox-backup/admin-password`.

- **Renew the GitHub token** before it expires: `rm /etc/zigbox-backup/github-token` and rerun the
  bootstrap (step 3), which asks for a new one. A run with an expired token logs
  `FAIL fetching from GitHub`.
- **Upgrade Forgejo:** change `forgejo_version` (and the key, if Forgejo changed it) in
  `bootstrap.sh` on `main` and rerun step 3.
- **Another repository:** add it to `BACKUP_REPOS` in `/etc/zigbox-backup/backup.env` and rerun
  step 3 (it creates the repository on Forgejo).
- **Alerting** is the heartbeat of step 4. Without `heartbeat-url`, nothing tells you when runs
  fail: look at `status` now and then.

## Restore

Everything is plain git. Both repositories are private and need sign-in, so every command below
needs the Forgejo admin's name (`ADMIN`) and the sync's token, which is on the box:

```bash
export ADMIN=<the admin login>
export FJ_TOKEN=$(ssh root@git.zigbox.org cat /etc/zigbox-backup/forgejo-token)
fj() { git -c credential.helper='!f() { echo username=$ADMIN; echo password=$FJ_TOKEN; }; f' "$@"; }
```

The token stays in this shell's environment, never on a command line. To list the tips a force
push replaced (by time and branch name):

```bash
fj ls-remote https://git.zigbox.org/ZigboxOrg/zigbox.git 'refs/heads/archive/*'
```

To put a repository back on a new remote `NEW` (an empty GitHub repository, or any URL you can
push to), clone a mirror, drop the archive refs, and push branches and tags by explicit
refspecs. Nothing here deletes anything on `NEW`:

```bash
fj clone --mirror https://git.zigbox.org/ZigboxOrg/zigbox.git zigbox.git
cd zigbox.git
git for-each-ref --format='delete %(refname)' refs/heads/archive refs/tags/archive |
    git update-ref --stdin
git push --all NEW
git push --tags NEW
```

To bring one branch back from before a force push, run this in the mirror clone *before* the
`update-ref` line above (or clone again), with the ref name `ls-remote` printed:

```bash
git push NEW 'refs/heads/archive/<stamp>/<name>:refs/heads/<name>'
```

`sync-test.sh` runs these same `clone --mirror`, `update-ref` and push lines against local
repositories, so they are tested.
