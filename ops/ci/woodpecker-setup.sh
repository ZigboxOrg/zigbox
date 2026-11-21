#!/bin/bash
# The repository's settings in Woodpecker, through its API (ops/ci/README.md, step 4). Run as root
# on the CI box after the bootstrap and one login in the browser; safe to run again, and it ends
# by reading every setting back:
#
#   bash /opt/zigbox-ci/src/ops/ci/woodpecker-setup.sh
#
# It turns ZigboxOrg/zigbox on (Woodpecker adds the webhook on GitHub), makes the token's own
# account (the bot) the repository's owner in Woodpecker (POST /api/repos/ID/chown) and checks that
# in Woodpecker's database, then sets: Trusted
# (security and volumes: the demo steps' /dev/kvm and the /var/lib/zigbox-ci mount), approval
# before any pipeline of a pull request from a fork (or, with ZBX_CI_APPROVAL=all_events and
# ZBX_CI_APPROVED_USERS, before every pipeline not from the listed logins; see the runbook),
# cancel-previous for pushes and pull requests, and the 180-minute timeout; and it creates or updates the `github_token` secret that
# deletes vmw/* branches. It asks for three tokens, none echoed or put on a command line: the
# Woodpecker token (User settings -> CLI & API) of a Woodpecker admin, the GitHub token for the
# secret (empty keeps the stored one), and a read-only GitHub token for its checks (below; it is
# not stored). Before it changes anything it refuses unless main's protection is as the runbook
# sets it and the token's own account cannot change main; it ends by refusing if another account
# Woodpecker holds a token for can change main (it names the one to delete, and by then the bot owns
# the repository, so deleting it is safe; this comes before the admin check, so an owner's account
# is named for deletion, never for demotion), or else if any of them is a repository admin.
#
# Why the owner matters: Woodpecker looks the repository's owner user up on every webhook, and
# deleting that user leaves the repository pointing at a row that is gone, so every push and pull
# request then answers 404 and no pipeline runs, with no error anywhere. The API does not show the
# owner (user_id is not in its JSON), so the check reads the database file on this host (sqlite3).
set -euo pipefail

repo_name="ZigboxOrg/zigbox"
etc=/etc/zigbox-ci

fail() { echo "ci-setup: FAIL $*"; exit 1; }
step() { echo "ci-setup: $*"; }

[ "$(id -u)" = 0 ] || fail "run it as root on the CI box"
command -v jq >/dev/null || fail "jq is missing; rerun the bootstrap (it installs jq)"
command -v gh >/dev/null || fail "gh is missing (the check of main's protection needs it)"
command -v sqlite3 >/dev/null || fail "sqlite3 is missing; rerun the bootstrap (it installs sqlite3)"
command -v docker >/dev/null || fail "docker is missing; run the bootstrap first"
[ -r "$etc/ci.env" ] || fail "$etc/ci.env is missing; run the bootstrap first"
CI_HOST=$(sed -n 's/^CI_HOST=//p' "$etc/ci.env")
[ -n "$CI_HOST" ] || fail "$etc/ci.env has no CI_HOST"
server="https://$CI_HOST"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 0700 "$work"

if [ -n "${WOODPECKER_TOKEN:-}" ]; then
    token="$WOODPECKER_TOKEN"
else
    read -rsp "Woodpecker token (User settings -> CLI & API at $server): " token </dev/tty
    echo
fi
[ -n "$token" ] || fail "no Woodpecker token"
printf 'Authorization: Bearer %s\n' "$token" > "$work/auth"
unset token

api() { # api METHOD PATH [curl args...]: the response body on stdout; fails on HTTP >= 400.
    local method="$1" path="$2"
    shift 2
    curl -fsS -X "$method" -H @"$work/auth" -H 'Content-Type: application/json' \
        "$server/api$path" "$@"
}

me=$(api GET /user) ||
    fail "$server refused the Woodpecker token (log in again and copy a new one)"
me_login=$(jq -r '.login // empty' <<<"$me")
[ -n "$me_login" ] || fail "Woodpecker did not say whose token that is"

# --- Who Woodpecker holds a token for, and main's protection -------------------------------------
# Woodpecker keeps the GitHub OAuth token (scope `repo`) of every account that ever logged in, in
# its database on this host, and any writer can run a privileged step here and read it
# (ops/ci/README.md, "What a writer can reach"). A token can do what its account can. So the
# control is on the accounts: none of them may be a repository admin (admins edit main's
# protection and merge freely), and main may be pushed to, and merged into, only by the owner's
# accounts, which Woodpecker has never seen. `gh` reads that with a token that is asked for here,
# kept in this process only (a fine-grained token on this repository, Administration: read and
# Metadata: read), so no admin credential stays on the box.
if [ -n "${ZBX_CI_CHECK_TOKEN:-}" ]; then
    check_token="$ZBX_CI_CHECK_TOKEN"
else
    read -rsp "GitHub token that may read this repository's protection and collaborators (not stored): " \
        check_token </dev/tty
    echo
fi
[ -n "$check_token" ] || fail "no GitHub token for the checks of main's protection"
gh_read() { GH_TOKEN="$check_token" gh api "$@"; }

step "listing the accounts Woodpecker holds a token for"
logins=$(api GET /users | jq -r '.[].login') ||
    fail "cannot list Woodpecker's users: the token must be a Woodpecker admin's (CI_ADMINS)"
[ -n "$logins" ] || fail "Woodpecker lists no users"
step "accounts with a stored token: $(paste -sd' ' <<<"$logins")"

step "checking who can change main on $repo_name"
prot=$(gh_read "repos/$repo_name/branches/main/protection" 2>"$work/gh.err") ||
    fail "cannot read main's protection ($(head -c 200 "$work/gh.err" | tr '\n' ' ')): it is not \
set, or the token cannot read it; ops/ci/README.md, 'Owner steps', has the command that sets it"
jq -e '.enforce_admins.enabled == true' >/dev/null <<<"$prot" ||
    fail "main's protection lets admins bypass it: set enforce_admins (ops/ci/README.md)"
jq -e '.restrictions != null' >/dev/null <<<"$prot" ||
    fail "main's protection does not restrict who can push or merge: set restrictions to the \
owner's accounts (ops/ci/README.md); without it a writer's token merges its own pull request"
jq -e '(.restrictions.teams | length) == 0' >/dev/null <<<"$prot" ||
    fail "main's push restrictions name a team: list users only, so that this check can see who it is"
jq -e '(.allow_force_pushes.enabled // false) == false and (.allow_deletions.enabled // false) == false' \
    >/dev/null <<<"$prot" ||
    fail "main's protection allows force pushes or deletion: turn both off (ops/ci/README.md)"
allowed=$(jq -r '[.restrictions.users[].login] + [(.required_pull_request_reviews
    .bypass_pull_request_allowances.users // [])[].login] | .[]' <<<"$prot")
# The token's own account becomes the repository's owner below, so it must never be one that can
# change main. Any other stored account that can is refused at the end, once the bot owns the
# repository and deleting that account cannot orphan it.
stale=""
for login in $logins; do
    if grep -qix "$login" <<<"$allowed"; then
        [ "$login" != "$me_login" ] ||
            fail "this Woodpecker token is $login's, and $login may push, merge or bypass on main: log \
in to Woodpecker as the bot (ops/ci/README.md, step 3a) and use its token"
        stale="$stale $login"
    fi
done

# --- The repository ------------------------------------------------------------------------------
repo_id=$(api GET "/repos/lookup/$repo_name" 2>/dev/null | jq -r '.id // empty' || true)
active=""
if [ -n "$repo_id" ]; then
    active=$(api GET "/repos/$repo_id" | jq -r '.active')
fi
if [ "$active" != true ]; then
    remote_id=$(api GET "/user/repos?all=true" |
        jq -r --arg n "$repo_name" '.[] | select(.full_name == $n) | .forge_remote_id')
    [ -n "$remote_id" ] ||
        fail "Woodpecker cannot see $repo_name on GitHub (grant the OAuth app access to ZigboxOrg)"
    step "turning on $repo_name"
    repo_id=$(api POST "/repos?forge_remote_id=$remote_id" | jq -r '.id')
fi
[ -n "$repo_id" ] || fail "could not turn on $repo_name"
[[ "$repo_id" =~ ^[0-9]+$ ]] || fail "Woodpecker gave a repository id that is not a number: $repo_id"

# --- The repository's owner ----------------------------------------------------------------------
# chown makes the token's account the owner (Woodpecker 3.20.1, server/api/repo.go ChownRepo). The
# owner is whoever turned the repository on, unless this is changed, and Woodpecker uses that
# account's stored GitHub token for the clone, statuses and webhook.
step "making $me_login the owner of $repo_name in Woodpecker"
api POST "/repos/$repo_id/chown" >/dev/null || fail "Woodpecker refused to change the owner of \
$repo_name to $me_login (the token must be a Woodpecker admin's: CI_ADMINS in $etc/ci.env)"
volume=zigbox-ci_woodpecker-data
db_dir=$(docker volume inspect "$volume" --format '{{.Mountpoint}}' 2>/dev/null) ||
    fail "cannot find Docker's volume $volume; run the bootstrap first"
db="$db_dir/woodpecker.sqlite"
[ -r "$db" ] || fail "Woodpecker's database $db is not readable"
sql() { sqlite3 -readonly -batch "$db" "$1"; }
owner_login=$(sql "select u.login from repos r join users u on u.id = r.user_id where r.id = $repo_id") ||
    fail "cannot read the owner of $repo_name from $db"
[ -n "$owner_login" ] ||
    fail "$repo_name has no owner user in Woodpecker's database: every webhook would answer 404 and \
no pipeline would run; this script's chown should have set it, so report it"
[ "$owner_login" = "$me_login" ] ||
    fail "$repo_name is owned by $owner_login in Woodpecker, not by $me_login"
# Only an active repository receives webhooks; a deactivated one whose owner is gone harms nothing.
# A value of `active` this does not know counts as active (fail closed).
orphans=$(sql "select r.full_name from repos r left join users u on u.id = r.user_id \
    where u.id is null and coalesce(r.active, 1) not in (0, '0', 'false')") ||
    fail "cannot read Woodpecker's repositories from $db"
[ -z "$orphans" ] ||
    fail "Woodpecker holds a repository whose owner user is gone, so its webhooks answer 404: \
$(paste -sd' ' <<<"$orphans"); run this script as the bot to take it over, or deactivate it"

# Approval (Woodpecker 3.20.1, server/pipeline/gated.go): "forks" (the default) holds only pull
# requests from forks; "all_events" holds every pipeline except cron and manual, unless its author
# is in approval_allowed_users. all_events needs the allowed logins, so it is opt-in:
#   ZBX_CI_APPROVAL=all_events ZBX_CI_APPROVED_USERS=login1,login2 bash woodpecker-setup.sh
approval="${ZBX_CI_APPROVAL:-forks}"
approved_users="${ZBX_CI_APPROVED_USERS:-}"
case "$approval" in
    forks) approved_json='[]' ;;
    all_events)
        [ -n "$approved_users" ] ||
            fail "ZBX_CI_APPROVAL=all_events needs ZBX_CI_APPROVED_USERS=login,login (the people whose pushes run without approval)"
        approved_json=$(jq -Rc 'split(",") | map(select(. != ""))' <<<"$approved_users") ;;
    *) fail "ZBX_CI_APPROVAL is forks or all_events, not $approval" ;;
esac

step "setting Trusted, approval ($approval), cancel-previous and the timeout on $repo_name"
jq -n --arg a "$approval" --argjson u "$approved_json" '{
  trusted: {network: false, security: true, volumes: true},
  require_approval: $a,
  approval_allowed_users: $u,
  cancel_previous_pipeline_events: ["push", "pull_request", "pull_request_metadata"],
  timeout: 180
}' | api PATCH "/repos/$repo_id" -d @- >/dev/null

# --- The secret ----------------------------------------------------------------------------------
read -rsp "GitHub token for vmw/* branch deletion (Enter keeps the stored one): " gh_pat </dev/tty
echo
if [ -n "$gh_pat" ]; then
    printf '%s' "$gh_pat" |
        jq -Rs '{name: "github_token", value: ., events: ["push"]}' > "$work/secret.json"
    unset gh_pat
    if api GET "/repos/$repo_id/secrets/github_token" >/dev/null 2>&1; then
        api PATCH "/repos/$repo_id/secrets/github_token" -d @"$work/secret.json" >/dev/null
        step "secret github_token: updated"
    else
        api POST "/repos/$repo_id/secrets" -d @"$work/secret.json" >/dev/null
        step "secret github_token: stored"
    fi
else
    unset gh_pat
fi

# --- Read it back --------------------------------------------------------------------------------
settings=$(api GET "/repos/$repo_id")
want='.active == true and .trusted.security == true and .trusted.volumes == true
    and .require_approval == $a and .timeout == 180'
jq -e --arg a "$approval" "$want" >/dev/null <<<"$settings" ||
    fail "the settings did not stick: $(jq -c '{active, trusted, require_approval, approval_allowed_users, timeout,
        cancel_previous_pipeline_events}' <<<"$settings")"
# Accounts that may push, merge or bypass on main are refused first, with the one instruction that
# fixes them: delete the account from Woodpecker. By now the bot owns the repository, so that is
# safe. They are refused before the admin check because an owner's account is usually also an
# admin, and telling the owner to demote their own account (an organisation owner cannot even be
# demoted) would be the wrong fix: the account must go from Woodpecker, whatever its role.
if [ -n "$stale" ]; then
    fail "Woodpecker still holds a token for$stale, which may push, merge or bypass on main. $repo_name \
is owned by $me_login now, so deleting it is safe: for each login, curl -fsS -X DELETE -H @AUTH_FILE \
$server/api/users/LOGIN (ops/ci/README.md, step 3a), and revoke its grant on GitHub, then run this again"
fi
# An admin can edit main's protection with the token Woodpecker stores. The repository can only be
# turned on by an admin, so the run that turns it on may meet one: it warns and says what to do; every
# other run refuses. A permission that cannot be read is a failure, never "not an admin".
admins=""
for login in $logins; do
    perm=$(gh_read "repos/$repo_name/collaborators/$login/permission" --jq .permission 2>"$work/gh.err") ||
        fail "cannot read $login's permission on $repo_name ($(head -c 200 "$work/gh.err" | tr '\n' ' ')): \
the check token needs Administration: read, and $login must still exist on GitHub"
    case "$perm" in
        admin) admins="$admins $login" ;;
        none | read | triage | write | maintain) ;;
        *) fail "GitHub gave '$perm' as $login's permission on $repo_name, which this script does not know" ;;
    esac
done
# The bot is made write by owner-github.sh. Any other admin is deleted from Woodpecker, never
# demoted on GitHub: an organisation owner reads as admin whatever its role on the repository.
others=""
for login in $admins; do
    [ "$login" = "$me_login" ] || others="$others $login"
done
if [ -n "$others" ]; then
    fail "Woodpecker holds the token of an admin of $repo_name:$others. Delete each from Woodpecker \
(curl -fsS -X DELETE -H @AUTH_FILE $server/api/users/LOGIN, ops/ci/README.md, step 3a.8) and revoke its \
grant on GitHub, then run this again; demoting it on GitHub is not the fix (an organisation owner \
stays admin)"
fi
if [ -n "$admins" ]; then
    msg="Woodpecker holds the token of $me_login, an admin of $repo_name. Make it write: \
BOT_LOGIN=$me_login OWNER_LOGINS=... bash ops/ci/owner-github.sh write (ops/ci/README.md, step 3a.7)"
    [ "$active" != true ] || fail "$msg"
    echo "ci-setup: WARNING $msg; this run turned the repository on, which needs an admin. Do it \
now and run this script again: it refuses to finish while an admin is known here."
fi
has_secret=no
api GET "/repos/$repo_id/secrets/github_token" >/dev/null 2>&1 && has_secret=yes
echo "ci-setup: OK $repo_name (id $repo_id): $(jq -c '{trusted, require_approval, approval_allowed_users, timeout,
    cancel_previous_pipeline_events}' <<<"$settings"), github_token secret: $has_secret"
