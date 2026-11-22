#!/usr/bin/env bash
# Tests .github/actions/site-serves/wait.sh against a local HTTP server (python3's http.server):
# it passes when the site serves the archive's files, passes once a stale site catches up, and
# otherwise fails with one line naming what was served instead.
# Usage: .github/site-serves-test.sh (from the repository root).
set -euo pipefail

wait_sh=$PWD/.github/actions/site-serves/wait.sh
work=$(mktemp -d)
server=""
cleanup() { [ -z "$server" ] || kill "$server" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "site-serves-test: $*" >&2; exit 1; }

# A release's archive with the files the wait compares (and one it does not).
mkdir -p "$work/tree/apt/dists/stable" "$work/tree/rpm/x86_64/repodata" \
  "$work/tree/rpm/aarch64/repodata" "$work/tree/apt/pool"
printf 'Origin: Zigbox\nDate: Sun, 22 Nov 2026 19:49:03 UTC\n' > "$work/tree/apt/dists/stable/Release"
printf 'signed new\n' > "$work/tree/apt/dists/stable/InRelease"
printf '<repomd x86_64/>\n' > "$work/tree/rpm/x86_64/repodata/repomd.xml"
printf '<repomd aarch64/>\n' > "$work/tree/rpm/aarch64/repodata/repomd.xml"
printf 'keyring\n' > "$work/tree/zigbox-archive-keyring.gpg"
printf 'pool\n' > "$work/tree/apt/pool/x.deb"
tar -czf "$work/zigbox-repos.tar.gz" -C "$work/tree" apt rpm zigbox-archive-keyring.gpg

mkdir "$work/site"
python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$work/site" > "$work/server.log" 2>&1 &
server=$!
port=""
for _ in $(seq 1 50); do
  port=$(sed -n 's/.* port \([0-9]*\) .*/\1/p' "$work/server.log" | head -n 1)
  [ -n "$port" ] && break
  sleep 0.1
done
[ -n "$port" ] || fail "the test server did not start: $(cat "$work/server.log")"
base=http://127.0.0.1:$port

# Runs the wait; expects exit status $1 and, when $2 is not empty, that text on stderr's one line.
expect() {
  local want=$1 text=$2 got=0
  shift 2
  env "$@" "$wait_sh" "$work/zigbox-repos.tar.gz" "$base" > "$work/out" 2> "$work/err" || got=$?
  [ "$got" = "$want" ] || fail "exit $got, wanted $want: $(cat "$work/err")"
  if [ -n "$text" ]; then
    [ "$(wc -l < "$work/err")" = 1 ] || fail "wanted one line on stderr, got: $(cat "$work/err")"
    grep -qF -- "$text" "$work/err" || fail "wanted '$text', got: $(cat "$work/err")"
  fi
}

# Nothing served yet: a 404.
expect 1 '/apt/dists/stable/Release answered 404' SITE_WAIT_SECONDS=0
# The previous release's Release: its Date is named.
cp -R "$work/tree/." "$work/site/"
printf 'Origin: Zigbox\nDate: Wed, 18 Nov 2026 00:57:35 UTC\n' > "$work/site/apt/dists/stable/Release"
expect 1 'has Date: Wed, 18 Nov 2026 00:57:35 UTC, the release'"'"'s has Date: Sun, 22 Nov 2026' \
  SITE_WAIT_SECONDS=0
# Release matches, a later file does not.
cp "$work/tree/apt/dists/stable/Release" "$work/site/apt/dists/stable/Release"
printf 'old keyring\n' > "$work/site/zigbox-archive-keyring.gpg"
expect 1 '/zigbox-archive-keyring.gpg differs' SITE_WAIT_SECONDS=0
# Everything matches.
cp "$work/tree/zigbox-archive-keyring.gpg" "$work/site/"
expect 0 '' SITE_WAIT_SECONDS=0
grep -q 'serves the release' "$work/out" || fail "no success line: $(cat "$work/out")"
# A stale site that catches up during the wait passes.
printf 'old\n' > "$work/site/rpm/aarch64/repodata/repomd.xml"
( sleep 2; cp "$work/tree/rpm/aarch64/repodata/repomd.xml" "$work/site/rpm/aarch64/repodata/" ) &
expect 0 '' SITE_WAIT_SECONDS=20 SITE_POLL_SECONDS=1
grep -q 'site: waiting, /rpm/aarch64/repodata/repomd.xml differs' "$work/out" ||
  fail "no waiting line: $(cat "$work/out")"
# An archive without the files is refused before anything is fetched.
tar -czf "$work/zigbox-repos.tar.gz" -C "$work/tree" apt
expect 2 'does not hold' SITE_WAIT_SECONDS=0
echo "site-serves-test: PASS"
