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
# It makes the bot an organisation member with the given role on the repository (`admin` only for
# the run that turns the repository on in Woodpecker, since GitHub lets only an admin do that), and
# sets main's protection so that only OWNER_LOGINS can push or merge: no approvals are required, so
# the supervisor's merges from the author's account still work.
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

for login in $(jq -r '.[]' <<<"$owners"); do
    perm=$(gh api "repos/$repo/collaborators/$login/permission" --jq .permission)
    case "$perm" in admin | maintain | write) ;; *) fail "$login has $perm on $repo; it cannot merge" ;; esac
done

echo "owner-github: the bot $BOT_LOGIN in $org, and $level on $repo"
state=$(gh api "orgs/$org/memberships/$BOT_LOGIN" --jq .state 2>/dev/null || echo none)
if [ "$state" = none ]; then
    gh api -X PUT "orgs/$org/memberships/$BOT_LOGIN" -f role=member --jq .state
    echo "owner-github: invited $BOT_LOGIN; log in as it and accept (gh api -X PATCH" \
        "user/memberships/orgs/$org -f state=active), then run this again"
    exit 0
fi
[ "$state" = active ] ||
    fail "$BOT_LOGIN has not accepted the invitation to $org (state $state): log in as it and accept"
gh api -X PUT "repos/$repo/collaborators/$BOT_LOGIN" -f permission="$level" >/dev/null

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
prot=$(gh api "repos/$repo/branches/main/protection")
jq -e --arg bot "$BOT_LOGIN" '.enforce_admins.enabled == true
    and ([.restrictions.users[].login] | index($bot)) == null
    and (.restrictions.teams | length) == 0
    and .allow_force_pushes.enabled == false and .allow_deletions.enabled == false' \
    >/dev/null <<<"$prot" || fail "main's protection is not as set: $(jq -c .restrictions <<<"$prot")"
who=$(jq -r '[.restrictions.users[].login] | join(",")' <<<"$prot")
echo "owner-github: OK $BOT_LOGIN is $level; only $who can push or merge into main"
