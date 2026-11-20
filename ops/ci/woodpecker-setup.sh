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
# deletes vmw/* branches. It asks for the Woodpecker token (User settings -> CLI & API) and the
# GitHub token without echo; an empty GitHub token keeps the stored secret. Neither goes on a
# command line: the header is a 0600 file and the secret's JSON comes from stdin.
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

# --- main's protection ---------------------------------------------------------------------------
# Any writer can run a privileged pipeline here (a push to vmw/* or a same-repo pull request needs
# no approval), and the host holds the Woodpecker database with the activating admin's GitHub
# token. The one control is that nobody, an admin included, can get past main's protection
# (ops/ci/README.md, "What a writer can reach"). Needs `gh` logged in as someone who can read it.
step "checking that nobody can bypass main's protection on $repo_name"
prot=$(gh api "repos/$repo_name/branches/main/protection" 2>"$work/gh.err") ||
    fail "cannot read main's protection ($(head -c 200 "$work/gh.err" | tr '\n' ' ')); log in with \
'gh auth login' as an admin of $repo_name, and set the protection first (ops/ci/README.md)"
jq -e '.enforce_admins.enabled == true' >/dev/null <<<"$prot" ||
    fail "main's protection lets admins bypass it: set enforce_admins (ops/ci/README.md, \
'What a writer can reach' has the gh api command)"
jq -e '.required_pull_request_reviews != null' >/dev/null <<<"$prot" ||
    fail "main's protection does not require pull requests: set it (ops/ci/README.md)"
jq -e '(.required_pull_request_reviews.bypass_pull_request_allowances // {}
        | [.users, .teams, .apps] | map(. // []) | add | length) == 0' >/dev/null <<<"$prot" ||
    fail "main's protection has bypass_pull_request_allowances: remove every user, team and app \
from it (ops/ci/README.md)"
jq -e '(.allow_force_pushes.enabled // false) == false and (.allow_deletions.enabled // false) == false' \
    >/dev/null <<<"$prot" ||
    fail "main's protection allows force pushes or deletion: turn both off (ops/ci/README.md)"

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
has_secret=no
api GET "/repos/$repo_id/secrets/github_token" >/dev/null 2>&1 && has_secret=yes
echo "ci-setup: OK $repo_name (id $repo_id): $(jq -c '{trusted, require_approval, approval_allowed_users, timeout,
    cancel_previous_pipeline_events}' <<<"$settings"), github_token secret: $has_secret"
