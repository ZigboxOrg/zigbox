#!/usr/bin/env bash
# Waits until a site serves the apt and dnf repositories of a release's zigbox-repos.tar.gz byte
# for byte. zigbox.org is deployed by Cloudflare from the newest release that carries the asset
# (docs/decisions/2026-11-22-site-deployed-by-cloudflare.md); the release only waits for it.
# Shell, not Zig: glue around `curl`, `jq` and `cmp` on a runner that has no Zig.
#
# Usage: wait.sh TAG BASE_URL
#   TAG       the published release, e.g. v0.6.0
#   BASE_URL  the site, e.g. https://zigbox.org (no trailing slash)
# Environment:
#   SITE_WHO           the caller, the prefix of every line (default site)
#   SITE_API           the repository's API, default https://api.github.com/repos/$GITHUB_REPOSITORY
#   SITE_DOWNLOAD      the release downloads, default
#                      https://github.com/$GITHUB_REPOSITORY/releases/download
#   GH_TOKEN           sent to SITE_API when set (the rate limit)
#   SITE_WAIT_SECONDS  default 3600; SITE_POLL_SECONDS, default 60
#
# The site serves only the newest release that is not a prerelease and carries the archive. So
# a prerelease, or a release with a newer such release, is not waited for: one line says why and
# the exit is 0. While waiting, each poll that finds a mismatch looks again for the newest
# release and fetches its SHA256SUMS, and takes its archive (checked against the sums) when the
# release or the archive's sum changed: a refresh that replaces the asset, or a newer release
# published mid-wait, moves the target instead of failing a healthy wait.
# Exit 0 once every file matches (or the wait is skipped); 1, with one line on stderr saying what
# was served instead, when the wait runs out; 2 on a usage, API or archive error.
set -euo pipefail

who=${SITE_WHO:-site}
fail() { echo "$who: $*" >&2; exit 2; }
[ $# = 2 ] || fail "usage: wait.sh TAG BASE_URL"
tag=$1
base=${2%/}
api=${SITE_API:-https://api.github.com/repos/${GITHUB_REPOSITORY:-}}
download=${SITE_DOWNLOAD:-https://github.com/${GITHUB_REPOSITORY:-}/releases/download}
wait_seconds=${SITE_WAIT_SECONDS:-3600}
poll_seconds=${SITE_POLL_SECONDS:-60}
[[ "$tag" =~ ^v[0-9A-Za-z.+-]+$ ]] || fail "'$tag' is not a release tag"

# What apt and dnf fetch whose bytes change with every signing: the apt Release, its detached
# and inline signatures, both rpm repomd.xml and their signatures, and the two keyrings.
files=(
  apt/dists/stable/Release
  apt/dists/stable/Release.gpg
  apt/dists/stable/InRelease
  rpm/x86_64/repodata/repomd.xml
  rpm/x86_64/repodata/repomd.xml.asc
  rpm/aarch64/repodata/repomd.xml
  rpm/aarch64/repodata/repomd.xml.asc
  zigbox-archive-keyring.gpg
  zigbox-archive-keyring.asc
)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

auth=()
[ -z "${GH_TOKEN:-}" ] || auth=(-H "Authorization: Bearer $GH_TOKEN")
# Reads the releases. Sets `self_prerelease` for this tag, and `newer` to the
# newest release created after it that is neither a draft nor a prerelease and carries the
# archive (empty if none, or if this tag is not listed yet). Only a release newer than this one
# counts: while a refresh replaces this release's asset it briefly carries none, and an older
# release must not be taken for the newest then. Returns 1 if the API does not answer.
releases() {
  curl -fsS --max-time 30 "${auth[@]}" -H 'Accept: application/vnd.github+json' \
    -o "$work/releases.json" "$api/releases?per_page=100" 2>/dev/null || return 1
  jq -r --arg t "$tag" '
    (map(select(.tag_name == $t)) | .[0]) as $self
    | ($self.prerelease // false),
      (if $self == null then "" else
        [.[] | select((.draft | not) and (.prerelease | not))
          | select(.created_at > $self.created_at)
          | select(any(.assets[]?; .name == "zigbox-repos.tar.gz"))]
        | sort_by(.created_at) | reverse | .[0].tag_name // "" end)' \
    "$work/releases.json" > "$work/releases.txt" 2>/dev/null || return 1
  { read -r self_prerelease; read -r newer || newer=""; } < "$work/releases.txt"
}

# Fetches TAG's SHA256SUMS line for the archive into $work/sum.new; returns 1 on any failure.
fetch_sum() {
  curl -fsSL --max-time 60 -o "$work/SHA256SUMS" "$download/$1/SHA256SUMS" 2>/dev/null &&
    grep ' zigbox-repos\.tar\.gz$' "$work/SHA256SUMS" > "$work/sum.new"
}

# Makes TAG's archive (its sum already in $work/sum.new) the one compared against: downloads it,
# checks it against the sum and extracts the files, then sets `target` and `want_date`. Prints why
# on failure and returns 1; the previous target stays as it was. Not run in a subshell.
take() {
  rm -rf "$work/next"
  mkdir "$work/next"
  if ! curl -fsSL --max-time 300 -o "$work/next/zigbox-repos.tar.gz" \
    "$download/$1/zigbox-repos.tar.gz" 2>/dev/null; then
    echo "$1's zigbox-repos.tar.gz did not download"
    return 1
  fi
  cp "$work/sum.new" "$work/next/sum"
  if ! (cd "$work/next" && sha256sum --quiet -c sum > /dev/null 2>&1); then
    echo "$1's zigbox-repos.tar.gz does not match its SHA256SUMS"
    return 1
  fi
  mkdir "$work/next/want"
  if ! tar -xzf "$work/next/zigbox-repos.tar.gz" -C "$work/next/want" --no-same-owner \
    --no-same-permissions -- "${files[@]}" 2> /dev/null; then
    echo "$1's zigbox-repos.tar.gz does not hold ${files[*]}"
    return 1
  fi
  local f
  for f in "${files[@]}"; do
    if [ ! -f "$work/next/want/$f" ] || [ -L "$work/next/want/$f" ]; then
      echo "$f in $1's zigbox-repos.tar.gz is not a regular file"
      return 1
    fi
  done
  rm -rf "$work/want"
  mv "$work/next/want" "$work/want"
  mv "$work/next/sum" "$work/sum"
  rm -rf "$work/next"
  target=$1
  want_date=$(date_of "$work/want/apt/dists/stable/Release")
}

date_of() { sed -n 's/^Date: //p' "$1" | head -n 1; }

# One pass over the files. Sets `mismatch` to a description of the first file that differs, or
# leaves it empty. No redirect is followed and nothing is decoded: a 3xx, a rewrite or an added
# Content-Encoding is a mismatch.
check() {
  mismatch=""
  local f code got_date
  for f in "${files[@]}"; do
    code=$(curl -sS --max-time 30 -o "$work/got" -w '%{http_code}' "$base/$f" 2>/dev/null) ||
      code=000
    if [ "$code" != 200 ]; then
      mismatch="/$f answered $code"
      return
    fi
    if ! cmp -s "$work/got" "$work/want/$f"; then
      if [ "$f" = apt/dists/stable/Release ]; then
        got_date=$(date_of "$work/got")
        mismatch="/$f has Date: ${got_date:-none}, $target's has Date: $want_date"
      else
        mismatch="/$f differs from $target's ($(wc -c < "$work/got") bytes served)"
      fi
      return
    fi
  done
}

# After a mismatch: the newest release may have moved (a newer release published) or its archive
# been replaced (a refresh). Takes the new archive and prints a line saying so (returns 0), or
# sets `note` to why the look failed, or does nothing when nothing changed (both return 1).
retarget() {
  note=""
  local next=$target
  if releases && [ -n "$newer" ]; then
    next=$newer
  fi
  fetch_sum "$next" || { note=" ($next's SHA256SUMS did not download)"; return 1; }
  if [ "$next" = "$target" ] && cmp -s "$work/sum.new" "$work/sum"; then
    return 1
  fi
  if take "$next" > "$work/why"; then
    echo "$who: now comparing with $next's zigbox-repos.tar.gz (Release Date: $want_date)"
    return 0
  fi
  note=" ($(cat "$work/why"))"
  return 1
}

releases || fail "$api/releases did not answer"
if [ "$self_prerelease" = true ]; then
  echo "$who: $tag is a prerelease, which zigbox.org never serves; not waiting for it"
  exit 0
fi
if [ -n "$newer" ]; then
  echo "$who: $tag is not the newest release with zigbox-repos.tar.gz ($newer is), which" \
    "zigbox.org serves instead; not waiting for it"
  exit 0
fi
fetch_sum "$tag" || fail "$tag's SHA256SUMS did not download or does not list zigbox-repos.tar.gz"
target=$tag
take "$tag" > "$work/why" || fail "$(cat "$work/why")"

deadline=$(( $(date +%s) + wait_seconds ))
while :; do
  check
  note=""
  if [ -n "$mismatch" ] && retarget; then
    check
  fi
  if [ -z "$mismatch" ]; then
    if [ "$target" = "$tag" ]; then
      echo "$who: $base serves $tag's repositories (Release Date: $want_date)"
    else
      echo "$who: $base serves $target's repositories, newer than $tag (Release Date: $want_date)"
    fi
    exit 0
  fi
  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    echo "$who: $base did not serve $target's repositories within $wait_seconds s:" \
      "$mismatch$note" >&2
    exit 1
  fi
  echo "$who: waiting, $mismatch$note"
  sleep "$(( poll_seconds < deadline - now ? poll_seconds : deadline - now ))"
done
