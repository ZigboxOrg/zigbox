#!/bin/bash
# The GitHub side of the CI box's accounts (ops/ci/README.md, "Owner steps"). Run on your own
# machine with `gh` logged in as an owner of the ZigboxOrg organisation (`gh auth login`), never on
# the box. Safe to run again; each run ends by reading back what it set.
#
#   BOT_LOGIN=zigbox-ci-bot OWNER_LOGINS=zvozin bash ops/ci/owner-github.sh admin   # to activate
#   BOT_LOGIN=zigbox-ci-bot OWNER_LOGINS=zvozin bash ops/ci/owner-github.sh write   # afterwards
#
# BOT_LOGIN: the GitHub account made for Woodpecker (the only one that ever logs in to it).
# OWNER_LOGINS: comma-separated logins that merge into main (the account the sessions' pull
# requests are authored from, and any other human who merges). ALLOW_APPS: optional, comma-
# separated slugs of GitHub Apps that must push to main (none today).
#
# It makes the bot a plain member of the organisation (role `member`, never an owner, in no team):
# Woodpecker logs in only members of the organisation (WOODPECKER_ORGS), and GitHub lets only a
# member make a fine-grained token on one of its repositories. A member inherits the organisation's
# base repository permission on every repository, so the script sets that to `none` and reads it
# back (this takes the base access away from every member, not only the bot: each keeps what a team
# or a direct grant gives). In the same call it takes away every member's right to create
# repositories (public or private) and Pages sites and to fork private repositories, so a stolen bot
# token cannot publish under the organisation's name (again every member's, not only the bot's; the
# organisation's owners keep these rights). It then checks that every OWNER_LOGINS account can
# still merge into zigbox. The bot then gets the given role on zigbox alone (`admin` only for the
# run that turns the repository on in Woodpecker, since GitHub lets only an admin do that). It sets
# main's protection so that only OWNER_LOGINS can push or merge: no approvals are required, so the
# supervisor's merges from the author's account still work.
#
# The protection PUT REPLACES the whole protection of main (status checks, review rules, restrictions,
# every flag); anything set by hand and not written below is gone after a run. The read-back then
# checks what matters: the restrictions are exactly OWNER_LOGINS and ALLOW_APPS, pull request reviews
# are required, admins are enforced, no force pushes or deletion.
set -euo pipefail

org=ZigboxOrg
repo=$org/zigbox
level="${1:-write}"
: "${BOT_LOGIN:?set BOT_LOGIN to the GitHub login of the Woodpecker account}"
: "${OWNER_LOGINS:?set OWNER_LOGINS to the logins that merge into main, comma separated}"
case "$level" in admin | write) ;; *) echo "owner-github: FAIL the role is admin or write" >&2; exit 1 ;; esac
fail() { echo "owner-github: FAIL $*" >&2; exit 1; }

owners=$(jq -Rc 'split(",") | map(select(. != ""))' <<<"$OWNER_LOGINS")
apps=$(jq -Rc 'split(",") | map(select(. != ""))' <<<"${ALLOW_APPS:-}")
jq -e --arg bot "$BOT_LOGIN" 'index($bot) == null and length > 0' <<<"$owners" >/dev/null ||
    fail "OWNER_LOGINS is empty or names the bot: the bot must not be able to merge into main"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# gh_or_404 PATH: the body on stdout, or nothing when GitHub answers 404; any other answer fails.
# `gh api` prints an error's JSON body on stdout too, so the status line (--include) decides, never
# whether stdout is empty.
gh_or_404() {
    local rc=0 status
    gh api --include "$1" >"$work/out" 2>"$work/err" || rc=$?
    status=$(head -n 1 "$work/out" | tr -d '\r' | awk '{print $2}')
    if [ "$rc" = 0 ] && [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
        awk 'body { print; next } /^\r?$/ { body = 1 }' "$work/out"
        return 0
    fi
    [ "$rc" = 0 ] || [ "$status" != 404 ] || return 0
    fail "cannot read $1 (status ${status:-none}, $(head -c 200 "$work/err" | tr '\n' ' '))"
}

echo "owner-github: the bot $BOT_LOGIN: a plain member of $org, with no base permission, $level on $repo only"
# The organisation's member settings first: from the moment the bot is a member, it holds whatever
# the base permission grants on every repository, and may create what members may create.
org_fields='{default_repository_permission, members_can_create_repositories,
    members_can_create_public_repositories, members_can_create_private_repositories,
    members_can_create_pages, members_can_fork_private_repositories}'
org_want='.default_repository_permission == "none" and .members_can_create_repositories == false
    and .members_can_create_public_repositories == false
    and .members_can_create_private_repositories == false
    and .members_can_create_pages == false and .members_can_fork_private_repositories == false'
settings=$(gh api "orgs/$org") ||
    fail "cannot read $org's member settings (gh must be logged in as an owner of $org)"
if ! jq -e "$org_want" >/dev/null <<<"$settings"; then
    echo "owner-github: $org's member settings are $(jq -c "$org_fields" <<<"$settings"); setting" \
        "the base permission to none and every member's create and fork rights off (members keep" \
        "what a team or a direct grant gives them)"
    gh api -X PATCH "orgs/$org" -f default_repository_permission=none \
        -F members_can_create_repositories=false -F members_can_create_public_repositories=false \
        -F members_can_create_private_repositories=false -F members_can_create_pages=false \
        -F members_can_fork_private_repositories=false >/dev/null ||
        fail "could not set $org's member settings"
    settings=$(gh api "orgs/$org") || fail "cannot read $org's member settings back"
fi
jq -e "$org_want" >/dev/null <<<"$settings" ||
    fail "$org's member settings are $(jq -c "$org_fields" <<<"$settings") after setting them"

# Only now, with no base permission, does a merging account's own permission show: one that had
# write only through the base permission has none any more.
for login in $(jq -r '.[]' <<<"$owners"); do
    perm=$(gh api "repos/$repo/collaborators/$login/permission" --jq .permission) ||
        fail "cannot read $login's permission on $repo"
    case "$perm" in
        admin | maintain | write) ;;
        *) fail "$login has $perm on $repo with no base permission, so it cannot merge; give it \
a direct role (gh api -X PUT repos/$repo/collaborators/$login -f permission=write), run this again" ;;
    esac
done

# A 404 is the one answer that means "not a member"; any other failure stops here (a command
# substitution's failure is checked by `||`, never left to a test, which would read it as empty).
membership=$(gh_or_404 "orgs/$org/memberships/$BOT_LOGIN") || exit 1
[ -n "$membership" ] || membership='{}'
state=$(jq -r '.state // "none"' <<<"$membership")
role=$(jq -r '.role // "none"' <<<"$membership")
case "$state/$role" in
    none/none)
        gh api -X PUT "orgs/$org/memberships/$BOT_LOGIN" -f role=member >/dev/null ||
            fail "could not invite $BOT_LOGIN to $org as a member"
        state=pending role=member ;;
    pending/member | active/member) ;;
    */admin) fail "$BOT_LOGIN is an owner of $org; make it a plain member (gh api -X PUT \
orgs/$org/memberships/$BOT_LOGIN -f role=member) and run this again" ;;
    *) fail "$BOT_LOGIN's membership of $org is '$state', role '$role', which this script does not know" ;;
esac
if [ "$state" = pending ]; then
    echo "owner-github: invited $BOT_LOGIN to $org as a member; log in as it and accept (gh api -X" \
        "PATCH user/memberships/orgs/$org -f state=active), then run this again"
    exit 0
fi
# A team can grant the bot more than its own role, on zigbox or on any other repository.
teams=$(gh api --paginate "orgs/$org/teams" --jq '.[].slug') || fail "cannot list $org's teams"
for slug in $teams; do
    team=$(gh_or_404 "orgs/$org/teams/$slug/memberships/$BOT_LOGIN") || exit 1
    [ -z "$team" ] ||
        fail "$BOT_LOGIN is in $org's team $slug; remove it (gh api -X DELETE \
orgs/$org/teams/$slug/memberships/$BOT_LOGIN) and run this again"
done
# A member is added directly (no invitation); an answer with an invitation means it is not one.
resp=$(gh api -X PUT "repos/$repo/collaborators/$BOT_LOGIN" -f permission="$level")
[ -n "$resp" ] || resp='{}'
inv=$(jq -r '.id // empty' <<<"$resp")
[ -z "$inv" ] || fail "GitHub invited $BOT_LOGIN to $repo (invitation $inv) instead of adding it: it is \
not an active member of $org; run this again"

echo "owner-github: main: pushes and merges only by $OWNER_LOGINS"
jq -n --argjson users "$owners" --argjson apps "$apps" '{
  required_status_checks: null,
  enforce_admins: true,
  required_pull_request_reviews: {
    required_approving_review_count: 0,
    bypass_pull_request_allowances: {users: [], teams: [], apps: []}
  },
  restrictions: {users: $users, teams: [], apps: $apps},
  allow_force_pushes: false,
  allow_deletions: false
}' | gh api -X PUT "repos/$repo/branches/main/protection" --input - >/dev/null

echo "owner-github: reading it back"
perm=$(gh api "repos/$repo/collaborators/$BOT_LOGIN/permission" --jq .permission)
[ "$perm" = "$level" ] || fail "$BOT_LOGIN has $perm on $repo, not $level"
role=$(gh api "orgs/$org/memberships/$BOT_LOGIN" --jq '"\(.state)/\(.role)"') ||
    fail "cannot read $BOT_LOGIN's membership of $org back"
[ "$role" = active/member ] || fail "$BOT_LOGIN's membership of $org is $role, not active/member"
settings=$(gh api "orgs/$org") || fail "cannot read $org's member settings back"
jq -e "$org_want" >/dev/null <<<"$settings" ||
    fail "$org's member settings are $(jq -c "$org_fields" <<<"$settings"), not as set"
prot=$(gh api "repos/$repo/branches/main/protection")
jq -e --arg bot "$BOT_LOGIN" --argjson users "$owners" --argjson apps "$apps" '
    .enforce_admins.enabled == true
    and ([.restrictions.users[].login | ascii_downcase] | sort) == ($users | map(ascii_downcase) | sort)
    and ([.restrictions.apps[].slug] | sort) == ($apps | sort)
    and (.restrictions.teams | length) == 0
    and ([.restrictions.users[].login] | index($bot)) == null
    and .required_pull_request_reviews != null
    and .allow_force_pushes.enabled == false and .allow_deletions.enabled == false' \
    >/dev/null <<<"$prot" || fail "main's protection is not as set: $(jq -c .restrictions <<<"$prot")"
who=$(jq -r '[.restrictions.users[].login] | join(",")' <<<"$prot")
echo "owner-github: OK $BOT_LOGIN is a plain member of $org (base permission none, members create" \
    "and fork nothing, no team) and" \
    "$level on $repo; only $who can push or merge into main"
