#!/bin/bash
# The repository's settings in Woodpecker, through its API (ops/ci/README.md, step 4). Run as root
# on the CI box after the bootstrap and one login in the browser; safe to run again, and it ends
# by reading every setting back:
#
#   bash /opt/zigbox-ci/src/ops/ci/woodpecker-setup.sh
#
# It turns ZigboxOrg/zigbox on (Woodpecker adds the webhook on GitHub), then sets: Trusted
# (security and volumes: the demo steps' /dev/kvm and the /var/lib/zigbox-ci mount), approval
# before any pipeline of a pull request from a fork, cancel-previous for pushes and pull requests,
# and the 180-minute timeout; and it creates or updates the `github_token` secret that
# deletes vm/* branches. It asks for the Woodpecker token (User settings -> CLI & API) and the
# GitHub token without echo; an empty GitHub token keeps the stored secret. Neither goes on a
# command line: the header is a 0600 file and the secret's JSON comes from stdin.
set -euo pipefail

repo_name="ZigboxOrg/zigbox"
etc=/etc/zigbox-ci

fail() { echo "ci-setup: FAIL $*"; exit 1; }
step() { echo "ci-setup: $*"; }

[ "$(id -u)" = 0 ] || fail "run it as root on the CI box"
command -v jq >/dev/null || fail "jq is missing; rerun the bootstrap (it installs jq)"
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

step "setting Trusted, fork approval, cancel-previous and the timeout on $repo_name"
api PATCH "/repos/$repo_id" -d @- >/dev/null <<'JSON'
{
  "trusted": {"network": false, "security": true, "volumes": true},
  "require_approval": "forks",
  "cancel_previous_pipeline_events": ["push", "pull_request", "pull_request_metadata"],
  "timeout": 180
}
JSON

# --- The secret ----------------------------------------------------------------------------------
read -rsp "GitHub token for vm/* branch deletion (Enter keeps the stored one): " gh_pat </dev/tty
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
    and .require_approval == "forks" and .timeout == 180'
jq -e "$want" >/dev/null <<<"$settings" ||
    fail "the settings did not stick: $(jq -c '{active, trusted, require_approval, timeout,
        cancel_previous_pipeline_events}' <<<"$settings")"
has_secret=no
api GET "/repos/$repo_id/secrets/github_token" >/dev/null 2>&1 && has_secret=yes
echo "ci-setup: OK $repo_name (id $repo_id): $(jq -c '{trusted, require_approval, timeout,
    cancel_previous_pipeline_events}' <<<"$settings"), github_token secret: $has_secret"
