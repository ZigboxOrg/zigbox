#!/usr/bin/env bash
# Test of owner-github.sh against a stub `gh` that answers as GitHub and `gh` 2.89 do: an error's
# JSON body on stdout, `gh: ... (HTTP N)` on stderr, exit 1, and with --include the status line and
# headers first. Run from `zig build test` (src/owner_github_tests.zig) or by hand. It covers: the
# bot not a member (invited, nothing else changed), a team the bot is not in (404, passes), the bot
# in a team (refused), a 502 on the membership and on a team read (fails, never "not a member"),
# the bot an owner of the organisation (refused), member settings that do not stick or are missing
# (refused), a merging account left with read once the base permission is none (refused before the
# protection is written), and the good path. Skips with a reason, and exits 0, only when jq is
# missing.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
if ! command -v jq >/dev/null; then
    echo "owner-github-test: SKIP jq is not installed"
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# The stub. A response is a file $GH_STUB/<METHOD>/<path, / as _>: its first line is the HTTP
# status, the rest the body. A file of the same name with `.then` names, one per line, `DST SRC`
# pairs under $GH_STUB that are copied once the request is answered (a PATCH changing a later GET).
# Every call is logged to $GH_STUB/log as `METHOD PATH fields...`.
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = api ] || { echo "stub gh: only api is stubbed" >&2; exit 2; }
shift
method=GET include=false jqexpr="" path="" fields=()
while [ $# -gt 0 ]; do
    case "$1" in
        -X) method=$2; shift 2 ;;
        -i | --include) include=true; shift ;;
        --paginate) shift ;;
        --jq) jqexpr=$2; shift 2 ;;
        --input) cat >/dev/null; shift 2 ;;
        -f | -F) fields+=("$2"); shift 2 ;;
        -*) echo "stub gh: unknown flag $1" >&2; exit 2 ;;
        *) path=$1; shift ;;
    esac
done
echo "$method $path ${fields[*]}" >>"$GH_STUB/log"
file="$GH_STUB/$method/${path//\//_}"
if [ -f "$file" ]; then
    status=$(head -n 1 "$file")
    body=$(tail -n +2 "$file")
else
    status=404
    body='{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
fi
if [ -f "$file.then" ]; then
    while read -r dst src; do cp "$GH_STUB/$src" "$GH_STUB/$dst"; done <"$file.then"
fi
if [ "$include" = true ]; then
    printf 'HTTP/2.0 %s Stub\r\nContent-Type: application/json\r\n\r\n' "$status"
fi
case "$status" in
    2??)
        if [ -n "$jqexpr" ]; then jq -r "$jqexpr" <<<"$body"; else printf '%s\n' "$body"; fi ;;
    *)
        printf '%s\n' "$body"
        case "$status" in
            404) echo "gh: Not Found (HTTP 404)" >&2 ;;
            *) echo "gh: Server Error (HTTP $status)" >&2 ;;
        esac
        exit 1 ;;
esac
STUB
chmod +x "$work/bin/gh"

org_good='{"default_repository_permission":"none","members_can_create_repositories":false,
"members_can_create_public_repositories":false,"members_can_create_private_repositories":false,
"members_can_create_pages":false,"members_can_fork_private_repositories":false}'
org_open='{"default_repository_permission":"write","members_can_create_repositories":true,
"members_can_create_public_repositories":true,"members_can_create_private_repositories":true,
"members_can_create_pages":true,"members_can_fork_private_repositories":true}'
prot_good='{"enforce_admins":{"enabled":true},"restrictions":{"users":[{"login":"owner"}],
"teams":[],"apps":[]},"required_pull_request_reviews":{},"allow_force_pushes":{"enabled":false},
"allow_deletions":{"enabled":false}}'

stub="" out="" rc=0
# put METHOD PATH STATUS BODY: the stub answers METHOD PATH with STATUS and BODY.
put() {
    local file="$stub/$1/${2//\//_}"
    mkdir -p "$stub/$1"
    printf '%s\n%s\n' "$3" "$4" >"$file"
}
# A world where everything is as owner-github.sh wants it: the bot an active member in no team,
# write on the repository, the owner an admin, main protected; the organisation has the team core.
world() {
    stub=$(mktemp -d "$work/stub.XXXX")
    : >"$stub/log"
    put GET orgs/ZigboxOrg 200 "$org_good"
    put GET repos/ZigboxOrg/zigbox/collaborators/owner/permission 200 '{"permission":"admin"}'
    put GET repos/ZigboxOrg/zigbox/collaborators/bot/permission 200 '{"permission":"write"}'
    put GET orgs/ZigboxOrg/memberships/bot 200 '{"state":"active","role":"member"}'
    put GET orgs/ZigboxOrg/teams 200 '[{"slug":"core"}]'
    put PUT repos/ZigboxOrg/zigbox/collaborators/bot 204 ''
    put PUT repos/ZigboxOrg/zigbox/branches/main/protection 200 "$prot_good"
    put GET repos/ZigboxOrg/zigbox/branches/main/protection 200 "$prot_good"
}
run() {
    rc=0
    out=$(PATH="$work/bin:$PATH" GH_STUB=$stub BOT_LOGIN=bot OWNER_LOGINS=owner \
        bash "$here/owner-github.sh" write 2>&1) || rc=$?
}
die() {
    printf 'owner-github-test: FAIL %s\n--- the last run, status %s:\n%s\n--- gh calls:\n%s\n' \
        "$*" "$rc" "$out" "$(cat "$stub/log")"
    exit 1
}
# expect STATUS TEXT: the last run ended in STATUS and printed TEXT.
expect() {
    [ "$rc" = "$1" ] || die "expected status $1"
    grep -qF -- "$2" <<<"$out" || die "expected '$2'"
}
called() { grep -qF -- "$1" "$stub/log"; }
protected() { called "PUT repos/ZigboxOrg/zigbox/branches/main/protection"; }

# The good path: the base permission and member rights are open, the script closes them in one
# PATCH and reads them back; core answers 404 for the bot, which is "not in it", not a refusal.
world
put GET orgs/ZigboxOrg 200 "$org_open"
put GET orgs/ZigboxOrg.patched 200 "$org_good"
put PATCH orgs/ZigboxOrg 200 "$org_good"
echo "GET/orgs_ZigboxOrg GET/orgs_ZigboxOrg.patched" >"$stub/PATCH/orgs_ZigboxOrg.then"
run
expect 0 "owner-github: OK bot is a plain member of ZigboxOrg"
for field in default_repository_permission=none members_can_create_repositories=false \
    members_can_create_public_repositories=false members_can_create_private_repositories=false \
    members_can_create_pages=false members_can_fork_private_repositories=false; do
    grep -q "^PATCH orgs/ZigboxOrg .*$field" "$stub/log" || die "the PATCH did not set $field"
done
called "GET orgs/ZigboxOrg/teams/core/memberships/bot" || die "the team core was not checked"
protected || die "main's protection was not written"
echo "owner-github-test: ok the good path, a team the bot is not in"

# The bot is not a member: it is invited, and the run stops before the repository and main.
world
put GET orgs/ZigboxOrg/memberships/bot 404 '{"message":"Not Found","status":"404"}'
put PUT orgs/ZigboxOrg/memberships/bot 200 '{"state":"pending","role":"member"}'
run
expect 0 "owner-github: invited bot to ZigboxOrg as a member"
called "PUT orgs/ZigboxOrg/memberships/bot role=member" || die "the bot was not invited"
! called "PUT repos/ZigboxOrg/zigbox/collaborators/bot" || die "the bot got a role too early"
! protected || die "main's protection was written for a bot that is not a member"
echo "owner-github-test: ok not a member"

# The bot is in a team: refused, nothing written.
world
put GET orgs/ZigboxOrg/teams/core/memberships/bot 200 '{"state":"active","role":"member"}'
run
expect 1 "owner-github: FAIL bot is in ZigboxOrg's team core"
! protected || die "main's protection was written while the bot is in a team"
echo "owner-github-test: ok in a team"

# A 502 is never "not a member" or "not in the team": the run fails and names the status.
world
put GET orgs/ZigboxOrg/memberships/bot 502 '{"message":"Server Error"}'
run
expect 1 "owner-github: FAIL cannot read orgs/ZigboxOrg/memberships/bot (status 502"
! called "PUT orgs/ZigboxOrg/memberships/bot" || die "a 502 was taken for not a member"
world
put GET orgs/ZigboxOrg/teams/core/memberships/bot 502 '{"message":"Server Error"}'
run
expect 1 "owner-github: FAIL cannot read orgs/ZigboxOrg/teams/core/memberships/bot (status 502"
! protected || die "main's protection was written after a 502 on a team"
echo "owner-github-test: ok 502"

# The bot is an owner of the organisation: refused.
world
put GET orgs/ZigboxOrg/memberships/bot 200 '{"state":"active","role":"admin"}'
run
expect 1 "owner-github: FAIL bot is an owner of ZigboxOrg"
! protected || die "main's protection was written while the bot is an owner"
echo "owner-github-test: ok owner role"

# Member settings that do not stick, or that GitHub does not report: refused before the bot is
# touched, naming each field with the value seen and its fix, and only those fields.
world
put GET orgs/ZigboxOrg 200 "$(jq -c '.members_can_create_pages = true
    | .default_repository_permission = "read"' <<<"$org_good")"
put PATCH orgs/ZigboxOrg 200 '{}'
run
expect 1 "after setting them: default_repository_permission is \"read\" (gh api -X PATCH \
orgs/ZigboxOrg -f default_repository_permission=none); members_can_create_pages is true (gh api -X \
PATCH orgs/ZigboxOrg -F members_can_create_pages=false)"
[ "$(grep -c 'FAIL' <<<"$out")" = 1 ] || die "more than one FAIL line"
! grep -q 'FAIL.*members_can_create_repositories' <<<"$out" || die "a field that holds was named"
called "PATCH orgs/ZigboxOrg" || die "the settings were not set"
! called "orgs/ZigboxOrg/memberships/bot" || die "the bot was read before the settings held"
world
put GET orgs/ZigboxOrg 200 "$(jq -c 'del(.members_can_fork_private_repositories)
    | .members_can_create_pages = null' <<<"$org_good")"
put PATCH orgs/ZigboxOrg 200 '{}'
run
expect 1 "after setting them: members_can_create_pages is null (this plan does not offer \
members_can_create_pages; tell the supervisor); members_can_fork_private_repositories is missing \
(this plan does not offer members_can_fork_private_repositories; tell the supervisor)"
! protected || die "main's protection was written with a setting missing"
echo "owner-github-test: ok member settings"

# A merging account whose write came from the base permission: it has write while the base
# permission is open and read once the PATCH sets it to none. Refused (the check runs after the
# drop), with the command that gives it a direct role, before main's protection is written.
world
put GET orgs/ZigboxOrg 200 "$org_open"
put GET orgs/ZigboxOrg.patched 200 "$org_good"
put PATCH orgs/ZigboxOrg 200 "$org_good"
put GET repos/ZigboxOrg/zigbox/collaborators/owner/permission 200 '{"permission":"write"}'
put GET repos/ZigboxOrg/zigbox/collaborators/owner/permission.patched 200 '{"permission":"read"}'
owner_perm=GET/repos_ZigboxOrg_zigbox_collaborators_owner_permission
printf '%s\n' "GET/orgs_ZigboxOrg GET/orgs_ZigboxOrg.patched" "$owner_perm $owner_perm.patched" \
    >"$stub/PATCH/orgs_ZigboxOrg.then"
run
called "PATCH orgs/ZigboxOrg" || die "the base permission was not dropped"
expect 1 "owner has read on ZigboxOrg/zigbox with no base permission, so it cannot merge"
grep -qF "gh api -X PUT repos/ZigboxOrg/zigbox/collaborators/owner -f permission=write" <<<"$out" ||
    die "the refusal does not say how to give the account a role"
! protected || die "main's protection was written naming an account that cannot push"
echo "owner-github-test: ok owner without a role"

echo "owner-github-test: OK"
