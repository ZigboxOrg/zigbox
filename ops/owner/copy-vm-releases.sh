#!/usr/bin/env bash
# Copy the VM build inputs' GitHub releases from Zigbox/zigbox to ZigboxOrg/zigbox.
# Safe to re-run: a release that exists is reused, and assets are re-uploaded with --clobber.
# Needs: gh (logged in with write access to ZigboxOrg/zigbox: `gh auth login`), git.
# Ends in one line: `copy-vm-releases: OK` or `copy-vm-releases: FAIL <what>`.
set -euo pipefail

src=Zigbox/zigbox
dst=ZigboxOrg/zigbox
tags=(vm-kernel-6.18.59 vm-deps-alpine-3.20)

fail() { echo "copy-vm-releases: FAIL $*"; exit 1; }
command -v gh >/dev/null || fail "gh is not installed (brew install gh)"
# Ask GitHub, not `gh auth status`: that fails when any other account or host gh knows is bad.
gh_err=$(gh api user --jq .login 2>&1 >/dev/null) ||
  fail "gh cannot call GitHub as you ($(printf '%s' "$gh_err" | head -n 1)): gh auth login"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for tag in "${tags[@]}"; do
  echo "== $tag"
  gh release view "$tag" --repo "$src" >/dev/null 2>&1 || fail "$tag: no release at $src"
  mkdir -p "$work/$tag"
  gh release download "$tag" --repo "$src" --dir "$work/$tag" --clobber
  gh release view "$tag" --repo "$src" --json body --jq .body > "$work/$tag.notes"
  title=$(gh release view "$tag" --repo "$src" --json name --jq .name)
  if ! gh release view "$tag" --repo "$dst" >/dev/null 2>&1; then
    commit=$(gh api "repos/$src/commits/$tag" --jq .sha)
    # The tag's commit must be in ZigboxOrg/zigbox (zigboxorg-setup.sh --only tags pushes it);
    # otherwise the release is made on main's head and says so in its notes.
    if gh api "repos/$dst/commits/$commit" >/dev/null 2>&1; then
      target=$commit
    else
      target=main
      printf '\n\n(Copied from %s; the original tag points at %s.)\n' "$src" "$commit" >> "$work/$tag.notes"
    fi
    gh release create "$tag" --repo "$dst" --target "$target" --title "${title:-$tag}" \
      --notes-file "$work/$tag.notes" --prerelease
  fi
  gh release upload "$tag" --repo "$dst" --clobber "$work/$tag"/*
  # Check: every asset at $dst has the same size as at $src.
  diff <(gh release view "$tag" --repo "$src" --json assets --jq '.assets[]|"\(.name) \(.size)"' | sort) \
       <(gh release view "$tag" --repo "$dst" --json assets --jq '.assets[]|"\(.name) \(.size)"' | sort) \
    || fail "$tag: assets differ between $src and $dst"
done

curl -fsSIL -o /dev/null "https://github.com/$dst/releases/download/vm-kernel-6.18.59/Image" \
  || fail "the kernel Image is not downloadable from $dst"
echo "copy-vm-releases: OK"
