# The release key is replaced

*Decided 2026-11-20, by the owner (key made by the owner; repository change by the fix session).*

## Why

The secret half of the release key (primary `09991DC39816D3C914E2A22C5AB00BC328B7DBB7`) was lost when
the project moved from the GitHub organization `Zigbox` to `ZigboxOrg`: the `release` and
`package-refresh` environment secrets did not move, and the offline backup the runbook describes
(`docs/releases/packaging.md`, "One-off key setup") could not be recovered. Nothing can sign for
that key any more, so no release or weekly refresh could run.

## The decision

A new key, made on 2026-11-20 with `ops/owner/release-setup.sh` and stored as the signing subkey in
the `release` and `package-refresh` environments:

| | Fingerprint |
|---|---|
| Old primary (retired) | `09991DC39816D3C914E2A22C5AB00BC328B7DBB7` |
| New primary (RSA 4096, certify-only, "Zigbox releases <releases@zigbox.org>") | `1207CB8600CE25FFDD3CC87ECCBEC141C3348787` |
| New signing subkey (RSA 4096, expires 2027-11-20) | `4A1D7E3AD844177A496A072EC07B2441C39645B7` |

The new primary is pinned in `.github/workflows/release.yml` and `package-refresh.yml`
(`ZIGBOX_SIGNING_FPR`), named in `docs/releases/packaging.md`, and its public key replaces
`docs/releases/zigbox-release-key.asc` (sha256 `fcc3a9aeaeb47da1683ea20ba12cd33e91a95ef040bd09893b7f5f4399c2ae53`;
the owner also published it at https://gist.github.com/zvozin/e2c49e735b4efc02c280f8dfc12302bd).
The subkey's first renewal falls due 28 days before 2027-11-20, as the runbook says. Records of what
was true when written (`src/release_evidence/0.5.3-release.yml`, `docs/releases/0.5.x.md`, retros,
earlier decisions) keep the old fingerprint.

## The old key is not revoked

No revocation certificate for the old key is known to survive. The runbook told the owner to write one
(`gpg --gen-revoke`) to offline media at setup; it was not checked in, and a copy lost with the
secret key cannot be used. **If that offline copy exists, the owner should publish it** (import it
into a keyring that holds the old public key, `gpg --export -a 09991DC39816D3C914E2A22C5AB00BC328B7DBB7`,
and publish that where users look for keys). Until then the old public key stays valid in users'
keyrings. That is harmless while nobody can sign with it, and it is why users must replace the file
rather than add to it.

## When the new key is served

The weekly refresh cannot switch the keyring. `.github/package-refresh.sh` checks the newest
release's `SHA256SUMS.asc`, `Release.gpg` and `InRelease`, and the `InRelease` zigbox.org serves,
against the *current* subkey of `ZIGBOX_SIGNING_FPR` ("is not by a subkey of ZIGBOX_SIGNING_FPR",
"no valid signature"). The newest release carrying `zigbox-repos.tar.gz` is 0.5.x, signed by the old
subkey, so until a release is signed with the new key:

- the weekly `package-refresh` fails every Monday (the schedule stays on; its failure is expected,
  and nothing about it needs the owner);
- the served apt `Release` passes its `Valid-Until` (21 days after its last signing,
  `apt_valid_seconds` in `src/constants.zig`) and stays expired: every apt user, whatever keyring
  they hold, sees `Release file ... is expired` (apt refuses it, or warns, depending on the
  version) and cannot install or upgrade until 0.6.0;
- the keyring at `https://zigbox.org/zigbox-archive-keyring.gpg` and `.asc` stays the old one.

So the served keyring changes only with 0.6.0, the first release signed by the new key. Before
announcing, the owner fetches both URLs and checks that `gpg --show-keys` prints
`1207 CB86 00CE 25FF DD3C  C87E CCBE C141 C334 8787`, and that the served `InRelease` verifies against it.

## What existing users do (from 0.6.0 on)

Do not run these before 0.6.0 is out: the served keyring is the old one until then, and the
fingerprint check below will fail. Packages and repository metadata signed from then on are by the
new key. A machine that holds only the old keyring refuses them: apt fails `apt update` with
`NO_PUBKEY C07B2441C39645B7` (the long id of the new signing subkey; it may also say `EXPKEYSIG` or
`BADSIG`), and dnf or rpm refuses the signature. Each step below downloads to a temporary file,
checks the fingerprint, and only then installs it. If the check does not show
`1207 CB86 00CE 25FF DD3C  C87E CCBE C141 C334 8787`, stop and delete the file.

apt (Debian, Ubuntu), replacing the file the install guide wrote:

```sh
curl -fsSLo /tmp/zigbox-new.gpg https://zigbox.org/zigbox-archive-keyring.gpg
```

```sh
gpg --show-keys --with-fingerprint /tmp/zigbox-new.gpg
```

```sh
sudo install -m 0644 /tmp/zigbox-new.gpg /usr/share/keyrings/zigbox.gpg
```

```sh
sudo apt update
```

dnf (Fedora, Rocky, RHEL):

```sh
curl -fsSLo /tmp/zigbox-new.asc https://zigbox.org/zigbox-archive-keyring.asc
```

```sh
gpg --show-keys --with-fingerprint /tmp/zigbox-new.asc
```

```sh
sudo rpm --import /tmp/zigbox-new.asc
```

```sh
sudo rpm -e gpg-pubkey-28b7dbb7
```

```sh
sudo dnf clean metadata && sudo dnf makecache
```

`rpm -qa 'gpg-pubkey*'` lists the old key's entry as `gpg-pubkey-28b7dbb7-*`; the `rpm -e` removes it
(use the full name that listing prints if rpm says the short one is ambiguous). Skipping it is
harmless, but the old key then stays trusted by rpm. Delete the temporary files afterwards.

The `zigbox-archive-keyring` package of
[2026-11-13-keyring-renewal-needs-refetch.md](2026-11-13-keyring-renewal-needs-refetch.md) would have
made this automatic; it is still a follow-up.

## Where the notice goes

There is no `docs/releases/0.6.0.md` yet. When it is written it carries these steps (the apt and dnf
commands above) under the "Renewing the keyring" notice, and the announcement does too. The install
guide (`docs/guide/try-linux.md`, "Renewing the keyring") already says the key was replaced and
points here.
