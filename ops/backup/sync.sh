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
# - A branch or tag name that nests with a kept one (claude/x kept, GitHub now has claude/x/y)
#   cannot coexist with it on Forgejo: the kept ref moves to archive/<UTC time>/<name> first.
#
# Each repository ends in one line, `backup: <owner/name> ...`; a ref Forgejo refuses is named in
# its own FAIL line and does not stop the others. The last line is `backup: OK ...` or
# `backup: FAIL ...`, and the exit status is 1 on FAIL. `status` in the state directory holds the
# last run's result, and the URL in `heartbeat-url` (if the file exists) is pinged on OK, and
# at URL/fail on FAIL, so a dead or failing sync is noticed by whatever watches that URL.
#
# `sync.sh credential FILE get` is the git
# credential helper the user's .gitconfig names: it answers with the token in FILE, so no token is
# ever on a command line or in the environment.
set -euo pipefail

if [ "${1:-}" = credential ]; then
    [ "${3:-}" = get ] || exit 0
    printf 'password=%s\n' "$(cat "$2")"
    exit 0
fi

# The paths and URLs can be overridden for the test (sync-test.sh); the defaults are the box's.
etc=${ZIGBOX_BACKUP_ETC:-/etc/zigbox-backup}
home=${ZIGBOX_BACKUP_HOME:-/var/lib/zigbox-backup}
mirrors=$home/mirrors
set -a; . "$etc/backup.env"; set +a
export GIT_TERMINAL_PROMPT=0
github_url=${ZIGBOX_BACKUP_GITHUB_URL:-https://github.com}
forgejo_url=${ZIGBOX_BACKUP_FORGEJO_URL:-https://$BACKUP_HOST}
refused=75 # sync_repo's status for a failure it has already said why of.

say() { echo "backup: $*"; }
first_line() { sed -n '/./{p;q;}' <<<"$1"; }

# ping SUFFIX: tells the heartbeat URL, if there is one. The URL is a secret, so curl reads it from
# a config on stdin, not from its command line.
ping() {
    [ -s "$etc/heartbeat-url" ] || return 0
    printf 'url = "%s%s"\n' "$(cat "$etc/heartbeat-url")" "$1" |
        curl -fsS -m 10 -o /dev/null -K - 2>/dev/null || say "the heartbeat ping failed"
}

# One run at a time: the timer and a bootstrap's first sync can start together, and two runs
# that both see a ref as new collide on Forgejo ("reference already exists").
exec 9>"$home/sync.lock"
flock -w "${ZIGBOX_BACKUP_LOCK_WAIT:-900}" 9 || {
    say "FAIL another sync has held the lock for ${ZIGBOX_BACKUP_LOCK_WAIT:-900} seconds"
    exit 1
}

skipped() { # skipped BRANCH: whether BRANCH starts with a BACKUP_SKIP prefix.
    local prefix
    for prefix in ${BACKUP_SKIP:-}; do
        case "$1" in "$prefix"*) return 0 ;; esac
    done
    return 1
}

nests() { # nests A B: whether A is B or lies under B/.
    case "$1/" in "$2"/*) return 0 ;; esac
    return 1
}

# clear_clashes KIND NAME: Forgejo cannot hold refs/KIND/NAME next to a ref that nests with it. A
# ref GitHub no longer has (so only Forgejo does) is moved under archive/ first, in a push of its
# own (a push cannot delete a ref and create one that nests with it): `clears` gets one group
# for it, once per kept ref.
clear_clashes() {
    local kind=$1 name=$2 ref sha held
    while read -r ref sha; do
        held=${ref#"refs/fj/$kind/"}
        case "$held" in archive/*) continue ;; esac
        [ "$held" != "$name" ] || continue
        if nests "$name" "$held" || nests "$held" "$name"; then
            [ -z "${cleared[$held]:-}" ] || continue
            cleared[$held]=1
            clears+=("$sha:refs/$kind/archive/$stamp/$held :refs/$kind/$held")
            kept_clashes=$((kept_clashes + 1))
        fi
    done < <(git for-each-ref --format='%(refname) %(objectname)' "refs/fj/$kind/")
}

# plan KIND: appends to `groups` what brings Forgejo's KIND (heads or tags) up to GitHub's, one
# string of refspecs per ref (a force move's archive ref and its new tip go together), counting
# what it does.
plan() {
    local kind=$1 ref sha name old
    while read -r ref sha; do
        name=${ref#"refs/gh/$kind/"}
        if [ "$kind" = heads ] && skipped "$name"; then continue; fi
        case "$name" in archive | archive/*)
            say "$repo: not copying $kind $name: archive/ is where the old tips are kept"
            continue ;;
        esac
        old=$(git rev-parse -q --verify "refs/fj/$kind/$name" || true)
        if [ -z "$old" ]; then
            clear_clashes "$kind" "$name"
            groups+=("$sha:refs/$kind/$name"); new=$((new + 1))
        elif [ "$old" = "$sha" ]; then
            continue
        elif [ "$kind" = heads ] && git merge-base --is-ancestor "$old" "$sha"; then
            groups+=("$sha:refs/$kind/$name"); moved=$((moved + 1))
        else
            groups+=("$old:refs/$kind/archive/$stamp/$name +$sha:refs/$kind/$name")
            archived=$((archived + 1))
        fi
    done < <(git for-each-ref --format='%(refname) %(objectname)' "refs/gh/$kind/")
}

# push_groups GROUP...: all of them in one atomic push; if Forgejo refuses it, each group alone
# (still atomic, so an archive ref and the force move that needs it stand or fall together), so
# one refused ref does not hold back the rest. Each refused ref gets its own FAIL line.
push_groups() {
    local all=() group parts err refs_refused=0
    for group in "$@"; do
        read -ra parts <<<"$group"
        all+=("${parts[@]}")
    done
    git push -q --atomic "$forgejo_url/$repo" "${all[@]}" >/dev/null 2>&1 && return 0
    for group in "$@"; do
        read -ra parts <<<"$group"
        err=$(git push -q --atomic "$forgejo_url/$repo" "${parts[@]}" 2>&1) && continue
        say "$repo: FAIL pushing ${parts[-1]#*:}: $(first_line "$err")"
        refs_refused=1
    done
    [ "$refs_refused" = 1 ] || say "$repo: FAIL pushing to Forgejo: no ref refused alone"
    return "$refused"
}

# sync_repo OWNER/NAME: one repository; prints its line, and fails with `refused` after saying
# why. It runs as a background job, where `set -e` holds, so a step it does not check stops it.
sync_repo() {
    local repo=$1 dir="$mirrors/$1.git" err
    local -A cleared=()
    local groups=() new=0 moved=0 archived=0 kept_clashes=0 clears=()
    { [ -d "$dir" ] || git init -q --bare "$dir"; } 2>/dev/null || {
        say "$repo: FAIL cannot make the mirror $dir"; return "$refused"; }
    cd "$dir"
    err=$(git fetch -q --prune --no-tags "$github_url/$repo" \
        '+refs/heads/*:refs/gh/heads/*' '+refs/tags/*:refs/gh/tags/*' 2>&1) || {
        say "$repo: FAIL fetching from GitHub: $(first_line "$err")"; return "$refused"; }
    err=$(git fetch -q --prune --no-tags "$forgejo_url/$repo" \
        '+refs/heads/*:refs/fj/heads/*' '+refs/tags/*:refs/fj/tags/*' 2>&1) || {
        say "$repo: FAIL fetching from Forgejo: $(first_line "$err")"; return "$refused"; }
    plan heads
    plan tags
    if [ "${#groups[@]}" -eq 0 ]; then
        say "$repo: up to date"
        return 0
    fi
    local pushed=0
    [ "${#clears[@]}" -eq 0 ] || push_groups "${clears[@]}" || pushed=1
    push_groups "${groups[@]}" || pushed=1
    [ "$pushed" = 0 ] || return "$refused"
    say "$repo: $new new, $moved moved forward, $archived force-moved, $kept_clashes moved aside" \
        "for a clashing name (old tips under archive/)"
}

stamp=$(date -u +%Y%m%dT%H%M%SZ)
failed=()
for repo in $BACKUP_REPOS; do
    status=0
    sync_repo "$repo" & wait "$!" || status=$?
    [ "$status" = 0 ] && continue
    [ "$status" = "$refused" ] ||
        say "$repo: FAIL stopped unexpectedly (status $status; the command's own message is above)"
    failed+=("$repo")
done
if [ "${#failed[@]}" -gt 0 ]; then
    say "FAIL ${failed[*]} (the lines above say which ref and why)"
    echo "$(date -u +%s) FAIL ${failed[*]}" > "$home/status"
    ping /fail
    exit 1
fi
date -u +%s > "$home/last-ok"
echo "$(date -u +%s) OK" > "$home/status"
ping ""
say "OK $(wc -w <<<"$BACKUP_REPOS") repositories at $stamp"
