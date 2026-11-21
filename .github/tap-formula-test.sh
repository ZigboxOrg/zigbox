#!/usr/bin/env bash
# Checks .github/actions/tap-formula/check-url.sh: the honest formula passes; a url on another
# host, another tag or a second url line is refused with a one-line `release: ...` reason.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
check=$here/actions/tap-formula/check-url.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
want=https://github.com/zigbox/zigbox/releases/download/v1.2.3/zbx-1.2.3-macos-universal.zip
die() { echo "tap-formula-test: $*" >&2; exit 1; }
make() { printf 'class Zigbox < Formula\n%s\n  version "1.2.3"\nend\n' "$1" > "$work/f.rb"; }
refuse() { # refuse NAME PATTERN
  if "$check" "$work/f.rb" "$want" 2> "$work/log"; then die "accepted: $1"; fi
  if ! grep -q '^release: ' "$work/log" || ! grep -q -- "$2" "$work/log"; then
    cat "$work/log" >&2; die "wrong reason: $1"
  fi
  echo "ok: refused: $1"
}
make "  url \"$want\""
"$check" "$work/f.rb" "$want" || die "refused the honest formula"
echo "ok: accepted: the honest formula"
make '  url "https://evil.example/zbx-1.2.3-macos-universal.zip"'
refuse "another host" "is not"
make "  url \"${want/v1.2.3/v1.2.2}\""
refuse "another tag" "is not"
make "  url \"$want\"
  url \"https://evil.example/x.zip\""
refuse "a second url" "exactly one"
make '  homepage "x"'
refuse "no url" "exactly one"
echo "tap-formula-test: all cases passed"
