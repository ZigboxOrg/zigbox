#!/usr/bin/env bash
# Copies every branch and tag of the repositories in BACKUP_REPOS from GitHub to the Forgejo on this
# box, and never loses a commit doing it (ops/backup/README.md). A systemd timer runs it every five
# minutes as the user zigbox-backup; bootstrap.sh installs it as
# /usr/local/lib/zigbox-backup/sync.sh.
#
# - A new branch or tag is copied; a branch GitHub moved forward is moved forward.
# - A branch GitHub moved any other way (a force push) or a tag GitHub moved keeps its old tip on
#   Forgejo as archive/<UTC time>/<name> before it follows GitHub.
# - A branch or tag GitHub deleted stays on Forgejo. Branches starting with a BACKUP_SKIP prefix
#   (scratch branches, vm/ by default) are not copied.
#
# Each repository ends in one line, `backup: <owner/name> ...`; the last line is `backup: OK ...` or
# `backup: FAIL ...`, and the exit status is 1 on FAIL. `sync.sh credential FILE get` is the git
# credential helper the user's .gitconfig names: it answers with the token in FILE, so no token is
# ever on a command line or in the environment.
set -euo pipefail

if [ "${1:-}" = credential ]; then
    [ "${3:-}" = get ] || exit 0
    printf 'password=%s\n' "$(cat "$2")"
    exit 0
fi

etc=/etc/zigbox-backup
mirrors=/var/lib/zigbox-backup/mirrors
set -a; . "$etc/backup.env"; set +a
export GIT_TERMINAL_PROMPT=0

say() { echo "backup: $*"; }

skipped() { # skipped BRANCH: whether BRANCH starts with a BACKUP_SKIP prefix.
    local prefix
    for prefix in ${BACKUP_SKIP:-}; do
        case "$1" in "$prefix"*) return 0 ;; esac
    done
    return 1
}

# plan KIND: appends to `specs` the refspecs that bring Forgejo's KIND (heads or tags) up to
# GitHub's, counting what it does.
plan() {
    local kind=$1 ref sha name old
    while read -r ref sha; do
        name=${ref#refs/gh/$kind/}
        if [ "$kind" = heads ] && skipped "$name"; then continue; fi
        case "$name" in archive/*) continue ;; esac
        old=$(git rev-parse -q --verify "refs/fj/$kind/$name" || true)
        if [ -z "$old" ]; then
            specs+=("$sha:refs/$kind/$name"); new=$((new + 1))
        elif [ "$old" = "$sha" ]; then
            continue
        elif [ "$kind" = heads ] && git merge-base --is-ancestor "$old" "$sha"; then
            specs+=("$sha:refs/$kind/$name"); moved=$((moved + 1))
        else
            specs+=("$old:refs/$kind/archive/$stamp/$name" "+$sha:refs/$kind/$name")
            archived=$((archived + 1))
        fi
    done < <(git for-each-ref --format='%(refname) %(objectname)' "refs/gh/$kind/")
}

# sync_repo OWNER/NAME: one repository; prints its line and fails with the reason.
sync_repo() {
    local repo=$1 dir="$mirrors/$1.git" err
    [ -d "$dir" ] || git init -q --bare "$dir"
    cd "$dir"
    err=$(git fetch -q --prune --no-tags "https://github.com/$repo" \
        '+refs/heads/*:refs/gh/heads/*' '+refs/tags/*:refs/gh/tags/*' 2>&1) || {
        say "$repo: FAIL fetching from GitHub: $(head -1 <<<"$err")"; return 1; }
    err=$(git fetch -q --prune --no-tags "https://$BACKUP_HOST/$repo" \
        '+refs/heads/*:refs/fj/heads/*' '+refs/tags/*:refs/fj/tags/*' 2>&1) || {
        say "$repo: FAIL fetching from Forgejo: $(head -1 <<<"$err")"; return 1; }
    specs=() new=0 moved=0 archived=0
    plan heads
    plan tags
    if [ "${#specs[@]}" -eq 0 ]; then
        say "$repo: up to date"
        return 0
    fi
    err=$(git push -q --atomic "https://$BACKUP_HOST/$repo" "${specs[@]}" 2>&1) || {
        say "$repo: FAIL pushing to Forgejo: $(head -1 <<<"$err")"; return 1; }
    say "$repo: $new new, $moved moved forward, $archived force-moved (old tips under archive/)"
}

stamp=$(date -u +%Y%m%dT%H%M%SZ)
failed=()
for repo in $BACKUP_REPOS; do
    ( sync_repo "$repo" ) || failed+=("$repo")
done
if [ "${#failed[@]}" -gt 0 ]; then
    say "FAIL ${failed[*]} (the lines above say why)"
    exit 1
fi
date -u +%s > /var/lib/zigbox-backup/last-ok
say "OK $(wc -w <<<"$BACKUP_REPOS") repositories at $stamp"
