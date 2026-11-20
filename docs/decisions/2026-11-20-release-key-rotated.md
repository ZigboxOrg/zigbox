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

## What existing users do

Packages and repository metadata signed from now on are by the new key. A machine that holds only the
old keyring refuses them: apt fails `apt update` with `NO_PUBKEY 4A1D7E3AD844177A496A072EC07B2441C39645B7`
(or `EXPKEYSIG` / `BADSIG`), and dnf or rpm refuses the signature. Check the fingerprint printed below
against the one in this file before trusting it.

apt (Debian, Ubuntu), replacing the file the install guide wrote:

```sh
curl -fsSL https://zigbox.org/zigbox-archive-keyring.gpg | sudo tee /usr/share/keyrings/zigbox.gpg >/dev/null
gpg --show-keys --with-fingerprint /usr/share/keyrings/zigbox.gpg   # must show 1207 CB86 00CE 25FF DD3C  C87E CCBE C141 C334 8787
sudo apt update
```

dnf (Fedora, Rocky, RHEL):

```sh
sudo rpm --import https://zigbox.org/zigbox-archive-keyring.asc
sudo dnf clean metadata && sudo dnf makecache
```

The old key's `gpg-pubkey` entry stays in rpm's database; it is harmless, and
`rpm -qa gpg-pubkey*` lists it (`gpg-pubkey-28b7dbb7-*`) if the user wants to `sudo rpm -e` it.

Because the repository trees are replaced by the weekly refresh and the next release, the keyring
served at `https://zigbox.org/zigbox-archive-keyring.gpg` carries the new key only after the first
refresh or release signed with it; the owner checks that URL's fingerprint before announcing. The
`zigbox-archive-keyring` package of
[2026-11-13-keyring-renewal-needs-refetch.md](2026-11-13-keyring-renewal-needs-refetch.md) would have
made this automatic; it is still a follow-up.

## Where the notice goes

There is no `docs/releases/0.6.0.md` yet. When it is written it carries these steps (the apt and dnf
commands above) under the "Renewing the keyring" notice, and the announcement does too. The install
guide (`docs/guide/try-linux.md`, "Renewing the keyring") already says the key was replaced and
points here.
