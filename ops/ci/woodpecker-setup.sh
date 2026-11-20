#!/bin/bash
# The repository's settings in Woodpecker, through its API (ops/ci/README.md, step 4). Run as root
# on the CI box after the bootstrap and one login in the browser; safe to run again, and it ends
# by reading every setting back:
#
#   bash /opt/zigbox-ci/src/ops/ci/woodpecker-setup.sh
#
# It turns ZigboxOrg/zigbox on (Woodpecker adds the webhook on GitHub), then sets: Trusted
# (security and volumes: the demo steps' /dev/kvm and the /var/lib/zigbox-ci mount), approval
# before any pipeline of a pull request from a fork (or, with ZBX_CI_APPROVAL=all_events and
# ZBX_CI_APPROVED_USERS, before every pipeline not from the listed logins; see the runbook),
# cancel-previous for pushes and pull requests, and the 180-minute timeout; and it creates or updates the `github_token` secret that
# deletes vmw/* branches. It asks for three tokens, none echoed or put on a command line: the
# Woodpecker token (User settings -> CLI & API) of a Woodpecker admin, the GitHub token for the
# secret (empty keeps the stored one), and a read-only GitHub token for its checks (below; it is
# not stored). Before it changes anything it refuses unless main cannot be changed by any account
# Woodpecker holds a token for, and at the end it refuses if one of them is a repository admin.
set -euo pipefail

repo_name="ZigboxOrg/zigbox"
etc=/etc/zigbox-ci

fail() { echo "ci-setup: FAIL $*"; exit 1; }
step() { echo "ci-setup: $*"; }

[ "$(id -u)" = 0 ] || fail "run it as root on the CI box"
command -v jq >/dev/null || fail "jq is missing; rerun the bootstrap (it installs jq)"
command -v gh >/dev/null || fail "gh is missing (the check of main's protection needs it)"
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

api GET /user >/dev/null ||
    fail "$server refused the Woodpecker token (log in again and copy a new one)"

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
for login in $logins; do
    if grep -qix "$login" <<<"$allowed"; then
        fail "$login holds a token in Woodpecker and may push, merge or bypass on main: remove it from \
main's restrictions (ops/ci/README.md); Woodpecker may only know accounts that cannot change main"
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
# An admin can edit main's protection with the token Woodpecker stores. The repository can only be
# turned on by an admin, so the run that turns it on may meet one: it warns and says what to do; every
# other run refuses.
admins=""
for login in $logins; do
    perm=$(gh_read "repos/$repo_name/collaborators/$login/permission" --jq .permission 2>/dev/null ||
        echo unknown)
    [ "$perm" = admin ] && admins="$admins $login"
done
if [ -n "$admins" ]; then
    msg="Woodpecker holds the token of an admin of $repo_name:$admins. Make it write: gh api -X PUT \
repos/$repo_name/collaborators/LOGIN -f permission=write (ops/ci/README.md, 'Owner steps', step 5)"
    [ "$active" != true ] || fail "$msg"
    echo "ci-setup: WARNING $msg; this run turned the repository on, which needs an admin. Do it \
now and run this script again: it refuses to finish while an admin is known here."
fi
has_secret=no
api GET "/repos/$repo_id/secrets/github_token" >/dev/null 2>&1 && has_secret=yes
echo "ci-setup: OK $repo_name (id $repo_id): $(jq -c '{trusted, require_approval, approval_allowed_users, timeout,
    cancel_previous_pipeline_events}' <<<"$settings"), github_token secret: $has_secret"
