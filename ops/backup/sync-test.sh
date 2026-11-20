#!/usr/bin/env bash
# Test of sync.sh and of the README's restore, with local bare repositories standing in for GitHub
# and Forgejo (sync.sh's ZIGBOX_BACKUP_* overrides point it at them). Run from `zig build test`
# (src/backup_sync_tests.zig) or by hand. It covers: a first copy, a fast-forward, a force-pushed
# branch and a moved tag (old tips archived), a rerun, a branch deleted upstream (kept), a name
# clash both ways, a ref Forgejo refuses (named, the others still land), GitHub and Forgejo
# unreachable, the lock timeout, the heartbeat, and a restore from a mirror clone that
# reproduces every ref. Skips with a reason, and exits 0, only when git is missing.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
if ! command -v git >/dev/null; then
    echo "sync-test: SKIP git is not installed"
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh=$work/gh fj=$work/fj wc=$work/wc state=$work/state etc=$work/etc
mkdir -p "$state" "$etc"
export HOME=$work GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$work/gitconfig
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.org GIT_COMMITTER_NAME=t
export GIT_COMMITTER_EMAIL=t@example.org
git config --global init.defaultBranch main
printf 'BACKUP_HOST=forgejo.test\nBACKUP_REPOS="o/r"\nBACKUP_SKIP="vm/"\n' > "$etc/backup.env"
export ZIGBOX_BACKUP_ETC=$etc ZIGBOX_BACKUP_HOME=$state
export ZIGBOX_BACKUP_GITHUB_URL=$gh ZIGBOX_BACKUP_FORGEJO_URL=$fj

git init -q --bare "$gh/o/r"
git init -q --bare "$fj/o/r"
git init -q "$wc"
git -C "$wc" remote add gh "$gh/o/r"

out="" rc=0
die() {
    printf 'sync-test: FAIL %s\n--- the last sync, status %s:\n%s\n' "$*" "$rc" "$out"
    exit 1
}
sync() { rc=0; out=$(bash "$here/sync.sh" 2>&1) || rc=$?; }
expect() { # expect STATUS TEXT: the last sync ended in STATUS and printed TEXT.
    [ "$rc" = "$1" ] || die "wanted status $1"
    grep -qF -- "$2" <<<"$out" || die "wanted the text: $2"
}
commit() { echo "$1" >> "$wc/f"; git -C "$wc" add f; git -C "$wc" commit -q -m "$1"; }
push() { git -C "$wc" push -q gh "$@"; }
tip() { git -C "$1/o/r" rev-parse -q --verify "$2" || echo none; } # tip DIR REF
same() { [ "$(tip "$gh" "$1")" = "$(tip "$fj" "$1")" ] || die "$1 differs on Forgejo"; }
archived() { git -C "$fj/o/r" for-each-ref --format='%(refname)' "$1" | head -1; } # archive/*/NAME

# 1. First copy: three new refs; the vm/ scratch branch is not copied.
commit one
git -C "$wc" tag v1
git -C "$wc" branch feature
git -C "$wc" branch vm/scratch
git -C "$wc" branch deep/a/b
push main feature vm/scratch deep/a/b v1
sync
expect 0 "4 new"
expect 0 "backup: OK"
same refs/heads/main; same refs/heads/feature; same refs/tags/v1
[ "$(tip "$fj" refs/heads/vm/scratch)" = none ] || die "vm/scratch was copied"
[ -s "$state/last-ok" ] || die "no last-ok"
grep -q ' OK$' "$state/status" || die "status is not OK"

# 2. A rerun changes nothing.
sync
expect 0 "up to date"

# 3. A fast-forward moves the tip, and archives nothing.
commit two
push main
old_main=$(tip "$gh" refs/heads/main)
sync
expect 0 "1 moved forward"
same refs/heads/main
[ -z "$(archived 'refs/heads/archive/*')" ] || die "a fast-forward was archived"

# 4. A force push and a moved tag: the old tips are kept, the new ones followed.
git -C "$wc" reset -q --hard HEAD~1
commit rewritten
git -C "$wc" tag -f v1 >/dev/null
old_tag=$(tip "$fj" refs/tags/v1)
push -f main v1
sync
expect 0 "2 force-moved"
same refs/heads/main; same refs/tags/v1
a=$(archived 'refs/heads/archive/*/main')
[ -n "$a" ] && [ "$(tip "$fj" "$a")" = "$old_main" ] || die "main's old tip is not archived"
a=$(archived 'refs/tags/archive/*/v1')
[ -n "$a" ] && [ "$(tip "$fj" "$a")" = "$old_tag" ] || die "v1's old tip is not archived"
sync
expect 0 "up to date"

# 5. A branch deleted on GitHub stays on Forgejo.
old_feature=$(tip "$gh" refs/heads/feature)
push --delete feature
sync
expect 0 "up to date"
[ "$(tip "$fj" refs/heads/feature)" = "$old_feature" ] || die "feature was not kept"

# 6. A name that nests with a kept one, both ways, next to an unrelated new branch: the kept refs
# move under archive/, the new ones land, and the other branch is not held back.
push --delete deep/a/b
git -C "$wc" branch -q -D feature deep/a/b
git -C "$wc" branch feature/sub
git -C "$wc" branch deep/a
git -C "$wc" branch other
push feature/sub deep/a other
sync
expect 0 "moved aside"
for ref in feature/sub deep/a other; do same "refs/heads/$ref"; done
[ "$(tip "$fj" refs/heads/feature/sub)" != none ] || die "feature/sub was not copied"
a=$(archived 'refs/heads/archive/*/feature')
[ -n "$a" ] && [ "$(tip "$fj" "$a")" = "$old_feature" ] || die "feature's tip was lost"
[ -n "$(archived 'refs/heads/archive/*/deep/a/b')" ] || die "deep/a/b's tip was lost"
sync
expect 0 "up to date"

# 7. A ref Forgejo refuses is named in its own FAIL line, the others land, the run fails, and
# the next run (the refusal gone) copies it.
printf '#!/bin/sh\nwhile read -r old new ref; do\n  [ "$ref" = refs/heads/refuse-me ] && {\n' \
    > "$fj/o/r/hooks/pre-receive"
printf '    echo refused by the test hook >&2; exit 1; }\ndone\nexit 0\n' \
    >> "$fj/o/r/hooks/pre-receive"
chmod +x "$fj/o/r/hooks/pre-receive"
git -C "$wc" branch refuse-me
git -C "$wc" branch fine
push refuse-me fine
sync
expect 1 "o/r: FAIL pushing refs/heads/refuse-me"
expect 1 "backup: FAIL o/r"
[ "$(tail -1 <<<"$out" | cut -c1-12)" = "backup: FAIL" ] || die "the last line is not FAIL"
same refs/heads/fine
grep -q ' FAIL o/r$' "$state/status" || die "status is not FAIL"
rm "$fj/o/r/hooks/pre-receive"
sync
expect 0 "1 new"
same refs/heads/refuse-me

# 8. Unreachable peers: one FAIL line each, and the run's last line names the repository.
ZIGBOX_BACKUP_GITHUB_URL=$work/nowhere sync
expect 1 "o/r: FAIL fetching from GitHub"
expect 1 "backup: FAIL o/r"
ZIGBOX_BACKUP_FORGEJO_URL=$work/nowhere sync
expect 1 "o/r: FAIL fetching from Forgejo"
expect 1 "backup: FAIL o/r"

# 9. Another sync holding the lock: FAIL after the wait, nothing copied.
if command -v flock >/dev/null; then
    (flock 9; sleep 20) 9>"$state/sync.lock" &
    holder=$!
    until ! flock -n "$state/sync.lock" true; do sleep 0.1; done
    ZIGBOX_BACKUP_LOCK_WAIT=1 sync
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    expect 1 "FAIL another sync has held the lock"
else
    echo "sync-test: flock is missing, the lock case was not run"
fi

# 10. The heartbeat: pinged on OK, and a failed ping is said but does not change the result.
if command -v curl >/dev/null; then
    : > "$work/ping"
    echo "file://$work/ping" > "$etc/heartbeat-url"
    sync
    expect 0 "backup: OK"
    grep -q 'heartbeat' <<<"$out" && die "a good ping was reported failed"
    ZIGBOX_BACKUP_GITHUB_URL=$work/nowhere sync # pings .../ping/fail, which does not exist
    expect 1 "the heartbeat ping failed"
    rm "$etc/heartbeat-url"
else
    echo "sync-test: curl is missing, the heartbeat case was not run"
fi

# 11. Restore, with the README's commands: a mirror clone of the copy, archive refs dropped, then
# explicit pushes. Every branch and tag GitHub has comes back at its tip, and nothing else.
git init -q --bare "$work/new"
git clone -q --mirror "$fj/o/r" "$work/restore.git"
(
    cd "$work/restore.git"
    git for-each-ref --format='delete %(refname)' refs/heads/archive refs/tags/archive |
        git update-ref --stdin
    git push -q --all "$work/new"
    git push -q --tags "$work/new"
)
want=$(git -C "$gh/o/r" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags |
    grep -v ' vm/scratch' || true)
got=$(git -C "$work/new" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags)
want=$(grep -v 'refs/heads/vm/scratch' <<<"$want")
[ "$want" = "$got" ] || die "the restore differs from GitHub: want
$want
got
$got"
# One branch back from its archive ref (the README's one-branch recovery).
a=$(archived 'refs/heads/archive/*/main')
git -C "$fj/o/r" push -q "$work/new" "$a:refs/heads/recovered"
back=$(git -C "$work/new" rev-parse -q --verify refs/heads/recovered)
[ "$back" = "$old_main" ] || die "main's old tip did not come back"

echo "sync-test: OK"
