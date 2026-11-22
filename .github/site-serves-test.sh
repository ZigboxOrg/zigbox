#!/usr/bin/env bash
# Tests .github/actions/site-serves/wait.sh against a local HTTP server (python3's http.server)
# that plays the site, the release downloads and the releases API: it passes when the site serves
# the archive's files, passes once a stale site catches up, follows a refreshed asset or a newer
# release during the wait, skips a prerelease and a release with a newer one, and otherwise fails
# with one line, prefixed with the caller, naming what was served instead.
# Usage: .github/site-serves-test.sh (from the repository root).
set -euo pipefail

wait_sh=$PWD/.github/actions/site-serves/wait.sh
work=$(mktemp -d)
server=""
cleanup() { [ -z "$server" ] || kill "$server" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "site-serves-test: $*" >&2; exit 1; }

# The files the wait compares, and one it does not.
compared=(
  apt/dists/stable/Release apt/dists/stable/Release.gpg apt/dists/stable/InRelease
  rpm/x86_64/repodata/repomd.xml rpm/x86_64/repodata/repomd.xml.asc
  rpm/aarch64/repodata/repomd.xml rpm/aarch64/repodata/repomd.xml.asc
  zigbox-archive-keyring.gpg zigbox-archive-keyring.asc
)

# make_tree DIR SIGNING DATE: a release's repositories, signed as SIGNING on DATE.
make_tree() {
  local dir=$1 signing=$2 date=$3 f
  for f in "${compared[@]}" apt/pool/x.deb; do
    mkdir -p "$dir/$(dirname "$f")"
    printf '%s %s\n' "$f" "$signing" > "$dir/$f"
  done
  printf 'Origin: Zigbox\nDate: %s\n' "$date" > "$dir/apt/dists/stable/Release"
}

# publish TAG DIR: the release's zigbox-repos.tar.gz and SHA256SUMS on the download server.
publish() {
  local tag=$1 dir=$2
  mkdir -p "$work/root/dl/$tag"
  tar -czf "$work/root/dl/$tag/zigbox-repos.tar.gz.part" -C "$dir" apt rpm \
    zigbox-archive-keyring.gpg zigbox-archive-keyring.asc
  mv "$work/root/dl/$tag/zigbox-repos.tar.gz.part" "$work/root/dl/$tag/zigbox-repos.tar.gz"
  (cd "$work/root/dl/$tag" && sha256sum zigbox-repos.tar.gz > SHA256SUMS)
}

# releases ENTRY...: the API's release list, each ENTRY TAG,CREATED,PRERELEASE,HAS_ARCHIVE.
releases() {
  local entry tag created pre has json="["
  for entry in "$@"; do
    IFS=, read -r tag created pre has <<< "$entry"
    [ "$json" = "[" ] || json+=","
    json+="{\"tag_name\":\"$tag\",\"created_at\":\"$created\",\"draft\":false,\"prerelease\":$pre,"
    if [ "$has" = true ]; then
      json+="\"assets\":[{\"name\":\"SHA256SUMS\"},{\"name\":\"zigbox-repos.tar.gz\"}]}"
    else
      json+="\"assets\":[{\"name\":\"SHA256SUMS\"}]}"
    fi
  done
  printf '%s]\n' "$json" > "$work/root/api/releases.part"
  mv "$work/root/api/releases.part" "$work/root/api/releases"
}

mkdir -p "$work/root/site" "$work/root/api"
make_tree "$work/old" old 'Wed, 18 Nov 2026 00:57:35 UTC'
make_tree "$work/new" new 'Sun, 22 Nov 2026 19:49:03 UTC'
make_tree "$work/refreshed" refreshed 'Mon, 23 Nov 2026 05:17:00 UTC'
make_tree "$work/next" next 'Tue, 24 Nov 2026 10:00:00 UTC'
publish v0.6.0 "$work/new"
releases v0.6.0,2026-11-22T19:49:00Z,false,true v0.5.0,2026-11-18T00:50:00Z,false,true

python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$work/root" > "$work/server.log" 2>&1 &
server=$!
port=""
for _ in $(seq 1 50); do
  port=$(sed -n 's/.* port \([0-9]*\) .*/\1/p' "$work/server.log" | head -n 1)
  [ -n "$port" ] && break
  sleep 0.1
done
[ -n "$port" ] || fail "the test server did not start: $(cat "$work/server.log")"
unset GH_TOKEN
export SITE_API=http://127.0.0.1:$port/api SITE_DOWNLOAD=http://127.0.0.1:$port/dl
base=http://127.0.0.1:$port/site

# Runs the wait for v0.6.0 (or $TAG); expects exit status $1 and, when $2 is not empty, that
# text on stderr's one line (exit 1, 2) or in stdout (exit 0).
expect() {
  local want=$1 text=$2 got=0
  shift 2
  env SITE_WHO=release "$@" "$wait_sh" "${TAG:-v0.6.0}" "$base" > "$work/out" 2> "$work/err" ||
    got=$?
  [ "$got" = "$want" ] || fail "exit $got, wanted $want: $(cat "$work/err")"
  [ -n "$text" ] || return 0
  if [ "$want" = 0 ]; then
    grep -qF -- "$text" "$work/out" || fail "wanted '$text', got: $(cat "$work/out")"
  else
    [ "$(wc -l < "$work/err")" = 1 ] || fail "wanted one line on stderr, got: $(cat "$work/err")"
    grep -qF -- "$text" "$work/err" || fail "wanted '$text', got: $(cat "$work/err")"
  fi
}
serve() { rm -rf "$work/root/site"; cp -R "$1/." "$work/root/site/"; }

# Nothing served yet: a 404, prefixed with the caller.
expect 1 'release: http://127.0.0.1' SITE_WAIT_SECONDS=0
expect 1 '/apt/dists/stable/Release answered 404' SITE_WAIT_SECONDS=0
expect 1 'package-refresh: http://127.0.0.1' SITE_WAIT_SECONDS=0 SITE_WHO=package-refresh
# The previous release's Release: its Date is named.
serve "$work/old"
expect 1 'has Date: Wed, 18 Nov 2026 00:57:35 UTC, v0.6.0'"'"'s has Date: Sun, 22 Nov 2026' \
  SITE_WAIT_SECONDS=0
# Release matches, a later file does not: each signature and keyring is compared.
serve "$work/new"
for f in apt/dists/stable/Release.gpg rpm/aarch64/repodata/repomd.xml.asc \
  zigbox-archive-keyring.asc zigbox-archive-keyring.gpg; do
  cp "$work/old/$f" "$work/root/site/$f"
  expect 1 "/$f differs from v0.6.0's" SITE_WAIT_SECONDS=0
  cp "$work/new/$f" "$work/root/site/$f"
done
# Everything matches.
expect 0 "release: $base serves v0.6.0's repositories" SITE_WAIT_SECONDS=0
# A stale site that catches up during the wait passes.
cp "$work/old/rpm/aarch64/repodata/repomd.xml" "$work/root/site/rpm/aarch64/repodata/"
(
  sleep 2
  cp "$work/new/rpm/aarch64/repodata/repomd.xml" "$work/root/site/rpm/aarch64/repodata/"
) &
helper=$!
expect 0 'release: waiting, /rpm/aarch64/repodata/repomd.xml differs' \
  SITE_WAIT_SECONDS=20 SITE_POLL_SECONDS=1
wait "$helper"
# The refresh replaces the asset during the wait and the site serves the refreshed one: the wait
# takes the new archive (checked against the new SHA256SUMS) and passes.
serve "$work/refreshed"
( sleep 2; publish v0.6.0 "$work/refreshed" ) &
helper=$!
expect 0 "now comparing with v0.6.0's zigbox-repos.tar.gz (Release Date: Mon, 23 Nov 2026" \
  SITE_WAIT_SECONDS=20 SITE_POLL_SECONDS=1
wait "$helper"
grep -qF "serves v0.6.0's repositories (Release Date: Mon, 23 Nov 2026" "$work/out" ||
  fail "no success line for the refreshed archive: $(cat "$work/out")"
# A newer release is published during the wait and the site serves it: the wait passes on it.
serve "$work/next"
(
  sleep 2
  publish v0.7.0 "$work/next"
  releases v0.7.0,2026-11-24T09:00:00Z,false,true v0.6.0,2026-11-22T19:49:00Z,false,true
) &
helper=$!
expect 0 "serves v0.7.0's repositories, newer than v0.6.0" SITE_WAIT_SECONDS=20 SITE_POLL_SECONDS=1
wait "$helper"
# A release finished after a newer one with the archive is not waited for; one without the archive
# does not count.
expect 0 'v0.6.0 is not the newest release with zigbox-repos.tar.gz (v0.7.0 is)' SITE_WAIT_SECONDS=0
releases v0.7.0,2026-11-24T09:00:00Z,false,false v0.6.0,2026-11-22T19:49:00Z,false,true
publish v0.6.0 "$work/new"
expect 1 "v0.6.0's has Date: Sun, 22 Nov 2026" SITE_WAIT_SECONDS=0
# A prerelease is not waited for, and nothing is downloaded for it.
releases v0.7.0-rc.1,2026-11-24T09:00:00Z,true,true v0.6.0,2026-11-22T19:49:00Z,false,true
TAG=v0.7.0-rc.1 expect 0 'release: v0.7.0-rc.1 is a prerelease' SITE_WAIT_SECONDS=0
# A refresh's upload in progress (the new SHA256SUMS beside the old archive) during the wait is
# not fatal: the poll says why and a later one takes the new archive.
serve "$work/refreshed"
releases v0.6.0,2026-11-22T19:49:00Z,false,true
publish v0.6.0 "$work/new"
publish staged "$work/refreshed"
(
  sleep 1
  cp "$work/root/dl/staged/SHA256SUMS" "$work/root/dl/v0.6.0/SHA256SUMS"
  sleep 2
  cp "$work/root/dl/staged/zigbox-repos.tar.gz" "$work/root/dl/v0.6.0/zigbox-repos.tar.gz"
) &
helper=$!
expect 0 "v0.6.0's zigbox-repos.tar.gz does not match its SHA256SUMS" \
  SITE_WAIT_SECONDS=20 SITE_POLL_SECONDS=1
wait "$helper"
grep -qF "now comparing with v0.6.0's" "$work/out" || fail "no retarget line: $(cat "$work/out")"
# An archive that does not match its SHA256SUMS, or lacks the files, is refused before the site
# is fetched.
echo "0000000000000000000000000000000000000000000000000000000000000000  zigbox-repos.tar.gz" \
  > "$work/root/dl/v0.6.0/SHA256SUMS"
expect 2 'release: v0.6.0'"'"'s zigbox-repos.tar.gz does not match its SHA256SUMS' \
  SITE_WAIT_SECONDS=0
tar -czf "$work/root/dl/v0.6.0/zigbox-repos.tar.gz" -C "$work/new" apt
(cd "$work/root/dl/v0.6.0" && sha256sum zigbox-repos.tar.gz > SHA256SUMS)
expect 2 'does not hold' SITE_WAIT_SECONDS=0
# A releases API that does not answer is refused.
expect 2 "release: http://127.0.0.1:$port/none/releases did not answer" SITE_WAIT_SECONDS=0 \
  SITE_API="http://127.0.0.1:$port/none"
echo "site-serves-test: PASS"
