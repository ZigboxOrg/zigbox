#!/usr/bin/env bash
# Waits until a site serves the apt and dnf repositories of a release's zigbox-repos.tar.gz byte
# for byte. zigbox.org is deployed by Cloudflare from the newest release that carries the asset
# (docs/decisions/2026-11-22-site-deployed-by-cloudflare.md); the release only waits for it.
# Shell, not Zig: glue around `curl` and `cmp` on a runner that has no Zig.
#
# Usage: wait.sh ARCHIVE BASE_URL
#   ARCHIVE   the release's zigbox-repos.tar.gz, its hash already checked against SHA256SUMS
#   BASE_URL  the site, e.g. https://zigbox.org (no trailing slash)
# Environment: SITE_WAIT_SECONDS (default 3600), SITE_POLL_SECONDS (default 60).
# Exit 0 once every file matches; 1, with one line on stderr saying what was served instead,
# when the wait runs out; 2 on a usage or archive error.
set -euo pipefail

fail() { echo "site: $*" >&2; exit 2; }
[ $# = 2 ] || fail "usage: wait.sh ARCHIVE BASE_URL"
archive=$1
base=${2%/}
wait_seconds=${SITE_WAIT_SECONDS:-3600}
poll_seconds=${SITE_POLL_SECONDS:-60}
[ -f "$archive" ] || fail "$archive does not exist"

# The files whose bytes change with every signing: the apt Release (and its inline-signed
# InRelease), both rpm repomd.xml, and the keyring.
files=(
  apt/dists/stable/Release
  apt/dists/stable/InRelease
  rpm/x86_64/repodata/repomd.xml
  rpm/aarch64/repodata/repomd.xml
  zigbox-archive-keyring.gpg
)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/want"
tar -xzf "$archive" -C "$work/want" --no-same-owner --no-same-permissions -- "${files[@]}" \
  2> "$work/tar.err" ||
  fail "$archive does not hold ${files[*]}"
for f in "${files[@]}"; do
  [ -f "$work/want/$f" ] && [ ! -L "$work/want/$f" ] || fail "$f in $archive is not a regular file"
done

date_of() { sed -n 's/^Date: //p' "$1" | head -n 1; }
want_date=$(date_of "$work/want/apt/dists/stable/Release")

# One pass over the files. Sets `mismatch` to a description of the first file that differs, or
# leaves it empty. No redirect is followed and nothing is decoded: a 3xx, a rewrite or an added
# Content-Encoding is a mismatch.
check() {
  mismatch=""
  local f code got_date
  for f in "${files[@]}"; do
    code=$(curl -sS --max-time 30 -o "$work/got" -w '%{http_code}' "$base/$f" 2>/dev/null) || code=000
    if [ "$code" != 200 ]; then
      mismatch="/$f answered $code"
      return
    fi
    if ! cmp -s "$work/got" "$work/want/$f"; then
      if [ "$f" = apt/dists/stable/Release ]; then
        got_date=$(date_of "$work/got")
        mismatch="/$f has Date: ${got_date:-none}, the release's has Date: $want_date"
      else
        mismatch="/$f differs from the release's ($(wc -c < "$work/got") bytes served)"
      fi
      return
    fi
  done
}

deadline=$(( $(date +%s) + wait_seconds ))
while :; do
  check
  if [ -z "$mismatch" ]; then
    echo "site: $base serves the release's repositories (Release Date: $want_date)"
    exit 0
  fi
  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    echo "release: $base did not serve this release's repositories within $wait_seconds s: $mismatch" >&2
    exit 1
  fi
  echo "site: waiting, $mismatch"
  sleep "$(( poll_seconds < deadline - now ? poll_seconds : deadline - now ))"
done
