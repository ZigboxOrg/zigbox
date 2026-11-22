# The release waits for zigbox.org; Cloudflare deploys it

*Decided 2026-11-22, by the owner.*

The owner, 2026-11-22: "Cloudflare will deploy." zigbox.org is deployed by Cloudflare, not by a
GitHub workflow in `ZigboxOrg/website`, so neither `release.yml` nor `package-refresh.yml`
dispatches or waits on that repository's `deploy.yml` (0.6.0's `site` job failed doing so: the
website repository has no Cloudflare secrets, and `verify` was skipped).

What a release must still prove is that zigbox.org serves it. The `site` job, now named
`zigbox.org serves the release`, downloads the published release's `zigbox-repos.tar.gz` from
the public release URL, checks it against the release's `SHA256SUMS`, and polls every 60 s, for
up to an hour, until `https://zigbox.org` serves the archive's `apt/dists/stable/Release` and
`InRelease`, both `rpm/*/repodata/repomd.xml` and `zigbox-archive-keyring.gpg` byte for byte
(`.github/actions/site-serves/`). On timeout it fails with one line naming what was served
instead (for `Release`, its `Date:`). It holds no secret and no environment, so it works the same
on a re-run for an already published release. `verify` still needs it. The refresh waits the same
way after replacing the asset.

So the release App no longer needs the `website` repository or Actions read; `preflight` (now
`the tap is reachable`) and `prepare` mint its token for `homebrew-tap` alone. Supersedes the
dispatch described in `docs/releases/packaging.md` and `docs/releases/automation.md` before this
change; the earlier decisions stay as they were merged.
