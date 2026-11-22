# The release waits for zigbox.org; Cloudflare deploys it

*Decided 2026-11-22, by the owner.*

The owner, 2026-11-22: "Cloudflare will deploy." zigbox.org is deployed by Cloudflare, not by a
GitHub workflow in `ZigboxOrg/website`, so neither `release.yml` nor `package-refresh.yml`
dispatches or waits on that repository's `deploy.yml` (0.6.0's `site` job failed doing so: the
website repository has no Cloudflare secrets, and `verify` was skipped).

What a release must still prove is that zigbox.org serves it. The `site` job, now named
`zigbox.org serves the release`, downloads the published release's `zigbox-repos.tar.gz` from
the public release URL, checks it against the release's `SHA256SUMS`, and polls every 60 s, for
up to an hour, until `https://zigbox.org` serves the archive's `apt/dists/stable/Release`,
`Release.gpg` and `InRelease`, both `rpm/*/repodata/repomd.xml` and `repomd.xml.asc`, and both
keyrings byte for byte (`.github/actions/site-serves/`). On timeout it fails with one line,
prefixed with the caller (`release` or `package-refresh`), naming what was served instead (for
`Release`, its `Date:`). It holds no secret and no environment, so it works the same on a re-run
for an already published release. `verify` still needs it. The refresh waits the same way after
replacing the asset.

The site serves only the newest release that is not a prerelease and carries the archive, so the
wait reads the releases API first: for a prerelease, or for a release finished after a newer one
carrying the archive, it prints one line saying why and passes without waiting, and `verify`
runs. This is decided inside the job rather than in an `if:`, so a release run and a dispatch
re-run of a published release take the same path. A poll that finds a mismatch reads the releases
and the target's `SHA256SUMS` again and, when the asset was replaced (the weekly refresh) or a
newer release is out, compares against that archive (checked against its sums) from then on: a
refresh or a release during the other's wait does not fail a healthy run. A shared concurrency
group between `release.yml` and `package-refresh.yml` was not chosen: the race is between one
workflow's upload and the other's wait, which are different jobs, and GitHub cancels all but one
pending run in a group.

So the release App no longer needs the `website` repository or Actions read; `preflight` (now
`the tap is reachable`) and `prepare` mint its token for `homebrew-tap` alone. Supersedes the
dispatch described in `docs/releases/packaging.md` and `docs/releases/automation.md` before this
change; the earlier decisions stay as they were merged.
