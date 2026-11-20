#!/usr/bin/env bash
# The owner's one-time (and re-runnable) setup of everything Zigbox and Zigcube need in the GitHub
# organisation ZigboxOrg. Run it on your own machine, not in CI and not as root:
#
#   ops/owner/zigboxorg-setup.sh [--only tags|jepsen|wif|fleet]... [--dry-run] [--yes]
#                                [--help]
#
# Sections, in this order (the default runs all of them and asks before each):
#   tags     push the old repositories' tags (Zigbox/zigbox, Zigbox/zigcube) to ZigboxOrg
#   jepsen   create ZigboxOrg/zigcube-jepsen and push the old harness's branches to it
#   wif      Google workload identity federation: Zigcube's Jepsen (condition moved to the new
#            repository and owner ids) and Zigbox's demo-m6d (created if missing)
#   fleet    the simulation fleet's tracker issue, and a check of the new token
#
# Safe to run again: each step checks before it creates and says "already". Nothing secret is
# printed, put on a command line or written outside a mode-600 file in a private temporary
# directory that is removed on exit. Values come from prompts (secrets without echo) or from the
# named files. --dry-run prints what would change and changes nothing (it still reads). --yes
# answers the per-section questions; it never answers for you where a value is wanted.
# The release plumbing (environments, App, signing key, Mac secrets, homebrew-tap and website) is
# NOT here: it is release-setup.sh, which the supervisor gave the owner.
# The last line is `owner-setup: OK ...` or `owner-setup: FAIL <what to fix>`.
# Written for bash 3.2 (macOS) and later. ops/owner/README.md is the full guide.
set -euo pipefail
umask 077

ORG=ZigboxOrg
OLD_ORG=Zigbox
# The old WIF condition of Jepsen was pinned to these (docs/supervisor-handoff.md, Zigcube).
OLD_JEPSEN_REPO_ID=1455702118
OLD_OWNER_ID=347124131
JEPSEN_PROJECT=${JEPSEN_GCP_PROJECT:-zigcube-jepsen}
JEPSEN_POOL=${JEPSEN_GCP_POOL:-github}
JEPSEN_PROVIDER=${JEPSEN_GCP_PROVIDER:-zigcube-jepsen}
M6D_POOL=${ZBX_GCP_POOL:-github}
M6D_PROVIDER=${ZBX_GCP_PROVIDER:-zigbox}
SIM_TRACKER_TITLE="Simulation fleet: seeds per day"

DRY=0 YES=0 ONLY=""
PROBLEMS="" TODOS="" RAN=""
TMP=""

say() { echo "owner-setup: $*"; }
die() { echo "owner-setup: FAIL $*"; exit 1; }
problem() { say "PROBLEM: $*"; PROBLEMS="$PROBLEMS$*"$'\n'; }
todo() { say "TODO (yours): $*"; TODOS="$TODOS$*"$'\n'; }
dry() { [ "$DRY" = 1 ]; }
would() { say "would: $*"; }

cleanup() { if [ -n "$TMP" ]; then rm -rf "$TMP"; fi; }
on_err() { echo "owner-setup: FAIL a command failed at line $1; read the message above it, fix that, run again"; }
trap cleanup EXIT
trap 'on_err $LINENO' ERR
TMP=$(mktemp -d)

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# --- Asking ---------------------------------------------------------------------------------------
tty_ok() { [ -r /dev/tty ] && [ -w /dev/tty ]; }

confirm() { # question; default no. --yes and --dry-run say yes.
    if [ "$YES" = 1 ] || dry; then return 0; fi
    tty_ok || die "no terminal to ask '$1' on; run this in a terminal, or pass --yes"
    local ans
    read -r -p "owner-setup: $1 [y/N] " ans </dev/tty
    case "$ans" in y | Y | yes) return 0 ;; *) return 1 ;; esac
}

# prompt VAR "text": VAR keeps a value already in the environment; else asks (echoing). Empty = 1.
prompt() {
    local var=$1 text=$2 cur
    eval "cur=\${$var:-}"
    if [ -n "$cur" ]; then return 0; fi
    if dry; then eval "$var='<$var>'"; return 0; fi
    tty_ok || die "$var is not set and there is no terminal to ask on"
    read -r -p "owner-setup: $text: " cur </dev/tty
    if [ -z "$cur" ]; then return 1; fi
    eval "$var=\$cur"
}

# read_secret VAR "text": always asks, without echo, never from the environment. Empty = 1.
read_secret() {
    local var=$1 text=$2 cur
    if dry; then eval "$var='<secret>'"; return 0; fi
    tty_ok || die "no terminal to ask for $var on"
    read -rs -p "owner-setup: $text (not shown): " cur </dev/tty
    echo >/dev/tty
    if [ -z "$cur" ]; then return 1; fi
    eval "$var=\$cur"
}

# --- GitHub helpers -------------------------------------------------------------------------------
GIT_AUTH=(-c credential.helper= -c 'credential.helper=!gh auth git-credential')
export GIT_TERMINAL_PROMPT=0

secret_has() { # repo env|- name
    if [ "$2" = - ]; then
        gh secret list --repo "$1" --json name --jq '.[].name' 2>/dev/null | grep -qx "$3"
    else
        gh secret list --env "$2" --repo "$1" --json name --jq '.[].name' 2>/dev/null | grep -qx "$3"
    fi
}
var_has() { # repo env|- name
    if [ "$2" = - ]; then
        gh variable list --repo "$1" --json name --jq '.[].name' 2>/dev/null | grep -qx "$3"
    else
        gh variable list --env "$2" --repo "$1" --json name --jq '.[].name' 2>/dev/null | grep -qx "$3"
    fi
}
# set_var repo env|- name value
set_var() {
    if dry; then would "set variable $3 on $1 ($2)"; return 0; fi
    if [ "$2" = - ]; then gh variable set "$3" --repo "$1" --body "$4" >/dev/null
    else gh variable set "$3" --env "$2" --repo "$1" --body "$4" >/dev/null; fi
    say "variable $3 set on $1 ($2)"
}

# --- Section: tags --------------------------------------------------------------------------------
tags_one() { # repo
    local repo=$1 work old new sha ref name have commit pushed=0 present=0 bad=0
    work="$TMP/tags-$repo"
    old="https://github.com/$OLD_ORG/$repo"
    new="https://github.com/$ORG/$repo"
    git init -q --bare "$work"
    say "tags: $repo: reading the branches of $new (the tags' commits must be there)"
    git -C "$work" "${GIT_AUTH[@]}" fetch -q --no-tags "$new" '+refs/heads/*:refs/remotes/new/*' ||
        die "cannot read $new: does it exist, and is gh signed in with access to it?"
    git "${GIT_AUTH[@]}" ls-remote --tags "$new" >"$work/new-tags"
    git "${GIT_AUTH[@]}" ls-remote --tags "$old" >"$work/old-tags" ||
        die "cannot read $old (the old repository)"
    while read -r sha ref; do
        case "$ref" in *'^{}') continue ;; esac
        name=${ref#refs/tags/}
        case "$name" in untagged-*) say "tags: $repo: $name is a draft release's placeholder: skipped"; continue ;; esac
        have=$(awk -v r="$ref" '$2 == r { print $1 }' "$work/new-tags")
        if [ "$have" = "$sha" ]; then present=$((present + 1)); continue; fi
        if [ -n "$have" ]; then
            problem "tag $name of $repo exists in $ORG at $have, but the old one is at $sha: not touched"
            bad=$((bad + 1)); continue
        fi
        if ! git -C "$work" "${GIT_AUTH[@]}" fetch -q --no-tags "$old" "+$ref:$ref"; then
            problem "cannot fetch tag $name of $old"; bad=$((bad + 1)); continue
        fi
        if [ "$(git -C "$work" rev-parse "$ref")" != "$sha" ]; then
            problem "tag $name of $repo changed while fetching; run again"; bad=$((bad + 1)); continue
        fi
        commit=$(git -C "$work" rev-parse "$ref^{commit}" 2>/dev/null) || {
            problem "tag $name of $repo does not point at a commit"; bad=$((bad + 1)); continue; }
        if [ -z "$(git -C "$work" for-each-ref --contains "$commit" refs/remotes/new | head -n 1)" ]; then
            problem "tag $name of $repo points at $commit, which is on no branch of $ORG/$repo (the old/* branches are missing it): not pushed, so no history is invented"
            bad=$((bad + 1)); continue
        fi
        if dry; then would "push tag $name ($sha, commit $commit) to $ORG/$repo"; continue; fi
        if git -C "$work" "${GIT_AUTH[@]}" push -q "$new" "$ref:$ref"; then
            say "tags: $repo: pushed $name"; pushed=$((pushed + 1))
        else
            problem "pushing tag $name to $ORG/$repo was refused (a tag ruleset on v* blocks it: lift it, run again, set it afterwards)"
            bad=$((bad + 1))
        fi
    done <"$work/old-tags"
    # The check: every old tag is in the new repository at the same object.
    git "${GIT_AUTH[@]}" ls-remote --tags "$new" >"$work/new-tags"
    say "tags: $repo: $present already there, $pushed pushed, $bad refused"
}

section_tags() {
    local repo
    for repo in zigbox zigcube; do tags_one "$repo"; done
    say "tags: GitHub Releases (notes, assets) of the old organisation are not copied, only tags"
}

# --- Section: jepsen ------------------------------------------------------------------------------
section_jepsen() {
    local repo="$ORG/zigcube-jepsen" work="$TMP/jepsen" priv=true vis ref name sha have refname n=0
    if gh repo view "$repo" --json name >/dev/null 2>&1; then say "jepsen: $repo exists"
    else
        vis=$(gh api "repos/$OLD_ORG/zigcube-jepsen" --jq '.private' 2>/dev/null || true)
        if [ "$vis" = false ]; then priv=false; fi
        say "jepsen: creating $repo (private=$priv; the old one's visibility, or private when it cannot be read)"
        if dry; then would "gh repo create $repo"; else
            if [ "$priv" = true ]; then
                gh repo create "$repo" --private --description "Jepsen battery for Zigcube" >/dev/null
            else gh repo create "$repo" --public --description "Jepsen battery for Zigcube" >/dev/null; fi
        fi
    fi
    git init -q --bare "$work"
    git -C "$work" "${GIT_AUTH[@]}" fetch -q --no-tags "https://github.com/$ORG/zigcube" \
        '+refs/heads/old/jepsen/*:refs/remotes/src/*' || die "cannot read $ORG/zigcube"
    if [ -z "$(git -C "$work" for-each-ref refs/remotes/src)" ]; then
        die "$ORG/zigcube has no old/jepsen/* branches to push"
    fi
    if ! dry; then
        git -C "$work" "${GIT_AUTH[@]}" fetch -q --no-tags "https://github.com/$repo" '+refs/heads/*:refs/remotes/dest/*' 2>/dev/null || true
    fi
    # main first, so that it is the repository's default branch.
    for refname in main $(git -C "$work" for-each-ref --format='%(refname:strip=3)' refs/remotes/src | grep -vx main); do
        sha=$(git -C "$work" rev-parse -q --verify "refs/remotes/src/$refname" || true)
        if [ -z "$sha" ]; then continue; fi
        have=$(git -C "$work" rev-parse -q --verify "refs/remotes/dest/$refname" || true)
        if [ "$have" = "$sha" ]; then say "jepsen: $refname: already at $sha"; continue; fi
        if [ -n "$have" ] && ! git -C "$work" merge-base --is-ancestor "$have" "$sha"; then
            problem "jepsen: $refname in $repo has commits the old harness lacks: not overwritten"; continue
        fi
        if dry; then would "push $refname ($sha) to $repo"; continue; fi
        git -C "$work" "${GIT_AUTH[@]}" push -q "https://github.com/$repo" "$sha:refs/heads/$refname"
        say "jepsen: pushed $refname"; n=$((n + 1))
    done
    if ! dry; then gh repo edit "$repo" --default-branch main >/dev/null; fi
    jepsen_refs "$repo" "$work"
    say "jepsen: $n branch(es) pushed; check: gh api repos/$repo/branches --jq '.[].name'"
}

# What the harness's workflows read: the names are found in the pushed main, never guessed.
jepsen_refs() { # repo workdir
    local repo=$1 work=$2 sha name kind
    sha=$(git -C "$work" rev-parse -q --verify refs/remotes/src/main) || return 0
    git -C "$work" grep -hoE '(vars|secrets)\.[A-Z][A-Z0-9_]+' "$sha" -- .github 2>/dev/null |
        sort -u | grep -v GITHUB_TOKEN >"$work/refs" || true
    while read -r name; do
        if [ -z "$name" ]; then continue; fi
        kind=${name%%.*}; name=${name#*.}
        if dry; then say "jepsen: its workflows read $kind $name"; continue; fi
        if [ "$kind" = vars ] && var_has "$repo" - "$name"; then continue; fi
        if [ "$kind" = secrets ] && secret_has "$repo" - "$name" 2>/dev/null; then continue; fi
        todo "$repo: the workflows read $kind $name; it is not set on the repository (repository level; if it belongs to an environment, set it there): gh ${kind%s} set $name --repo $repo"
    done <"$work/refs"
}

# --- Section: wif ---------------------------------------------------------------------------------
need_gcloud() {
    command -v gcloud >/dev/null 2>&1 || die "gcloud is not installed (https://cloud.google.com/sdk/docs/install)"
    command -v jq >/dev/null 2>&1 || die "jq is not installed"
    [ -n "$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)" ] ||
        die "gcloud is not signed in: gcloud auth login"
}

# new_name STRING: the old organisation's name in a condition or member becomes ZigboxOrg's.
new_name() {
    sed -E "s#(^|[^A-Za-z0-9])[Zz]igbox/#\\1$ORG/#g; s#'[Zz]igbox'#'$ORG'#g"
}

# rebind kind(sa|project) target project: grants the new repository's principal what the old had.
rebind() {
    local kind=$1 target=$2 project=$3 role member new
    local policy
    if [ "$kind" = sa ]; then
        policy=$(gcloud iam service-accounts get-iam-policy "$target" --project "$project" --format=json)
    else policy=$(gcloud projects get-iam-policy "$project" --format=json); fi
    while read -r role member; do
        if [ -z "$role" ]; then continue; fi
        new=$(printf '%s' "$member" | new_name)
        if printf '%s' "$policy" | jq -e --arg r "$role" --arg m "$new" '.bindings[]? | select(.role == $r) | .members[]? | select(. == $m)' >/dev/null 2>&1; then
            say "wif: $target already grants $role to $new"; continue
        fi
        if dry; then would "grant $role on $target to $new"; continue; fi
        if [ "$kind" = sa ]; then
            gcloud iam service-accounts add-iam-policy-binding "$target" --project "$project" --member "$new" --role "$role" --condition=None >/dev/null
        else
            gcloud projects add-iam-policy-binding "$project" --member "$new" --role "$role" --condition=None >/dev/null
        fi
        say "wif: granted $role on $target to $new (the old member is left; remove it when the old org is gone)"
    done < <(printf '%s' "$policy" | jq -r '.bindings[]? | .role as $r | .members[]? | select(test("[/:][Zz]igbox/")) | "\($r) \(.)"')
}

wif_jepsen() {
    local repo="$ORG/zigcube-jepsen" rid oid cur new sa
    say "wif: Jepsen: project $JEPSEN_PROJECT, pool $JEPSEN_POOL, provider $JEPSEN_PROVIDER"
    rid=$(gh api "repos/$repo" --jq .id 2>/dev/null) || { problem "wif: $repo does not exist yet: run the jepsen section first, then this"; return 0; }
    oid=$(gh api "orgs/$ORG" --jq .id)
    say "wif: $repo has id $rid, $ORG has id $oid (old: $OLD_JEPSEN_REPO_ID and $OLD_OWNER_ID)"
    cur=$(gcloud iam workload-identity-pools providers describe "$JEPSEN_PROVIDER" --project "$JEPSEN_PROJECT" \
        --location=global --workload-identity-pool="$JEPSEN_POOL" --format='value(attributeCondition)') ||
        die "cannot read the provider (is gcloud signed in as someone allowed on project $JEPSEN_PROJECT?)"
    new=$(printf '%s' "$cur" | sed "s/$OLD_JEPSEN_REPO_ID/$rid/g; s/$OLD_OWNER_ID/$oid/g" | new_name)
    if [ "$cur" = "$new" ]; then
        say "wif: the provider's condition needs no change"
    elif ! printf '%s' "$cur" | grep -q "$OLD_JEPSEN_REPO_ID\|$OLD_OWNER_ID\|[Zz]igbox/"; then
        problem "wif: the provider's condition names none of the old ids or names, so I do not know how to change it; it is: $cur"
    else
        say "wif: condition now:  $cur"
        say "wif: condition next: $new"
        if dry; then would "update the provider's attribute condition"
        elif confirm "change the Jepsen provider's condition to the new one?"; then
            gcloud iam workload-identity-pools providers update-oidc "$JEPSEN_PROVIDER" --project "$JEPSEN_PROJECT" \
                --location=global --workload-identity-pool="$JEPSEN_POOL" --attribute-condition="$new" >/dev/null
            say "wif: Jepsen condition updated"
        else todo "wif: the Jepsen condition is unchanged"; fi
    fi
    while read -r sa; do
        if [ -n "$sa" ]; then rebind sa "$sa" "$JEPSEN_PROJECT"; fi
    done < <(gcloud iam service-accounts list --project "$JEPSEN_PROJECT" --format='value(email)')
    rebind project x "$JEPSEN_PROJECT"
}

m6d_condition() { # repo_id owner_id
    printf "assertion.repository == '%s/zigbox' && assertion.repository_id == '%s' && assertion.repository_owner_id == '%s' && (assertion.ref == 'refs/heads/main' || assertion.ref.startsWith('refs/pull/') || assertion.ref.startsWith('refs/heads/vm/'))" "$ORG" "$1" "$2"
}

wif_m6d() {
    local ZBX_GCP_PROJECT="${ZBX_GCP_PROJECT:-}" ZBX_GCP_REGION="${ZBX_GCP_REGION:-}" zr="$ORG/zigbox"
    local rid oid cond num sa principal cur
    if ! prompt ZBX_GCP_PROJECT "Google project id for demo-m6d (empty to skip demo-m6d)"; then
        todo "demo-m6d: choose a Google project, run again: --only wif (docs/demos/m6d.md)"; return 0
    fi
    prompt ZBX_GCP_REGION "Artifact Registry region, e.g. us-central1 (empty to skip)" || { todo "demo-m6d: region missing"; return 0; }
    rid=$(gh api "repos/$zr" --jq .id); oid=$(gh api "orgs/$ORG" --jq .id)
    cond=$(m6d_condition "$rid" "$oid")
    num=$(gcloud projects describe "$ZBX_GCP_PROJECT" --format='value(projectNumber)') || die "cannot read project $ZBX_GCP_PROJECT"
    sa="zbx-pull@$ZBX_GCP_PROJECT.iam.gserviceaccount.com"
    principal="principalSet://iam.googleapis.com/projects/$num/locations/global/workloadIdentityPools/$M6D_POOL/attribute.repository/$ORG/zigbox"
    if dry; then
        would "enable APIs; pool $M6D_POOL; provider $M6D_PROVIDER with the condition: $cond"
        would "repositories zbx-demo, zbx-denied in $ZBX_GCP_REGION and gcr.io in us; service account $sa; readers; workloadIdentityUser for $principal; repository variables"
        return 0
    fi
    gcloud services enable artifactregistry.googleapis.com iamcredentials.googleapis.com sts.googleapis.com --project "$ZBX_GCP_PROJECT"
    if gcloud iam workload-identity-pools describe "$M6D_POOL" --project "$ZBX_GCP_PROJECT" --location=global >/dev/null 2>&1; then
        say "wif: pool $M6D_POOL exists"
    else
        gcloud iam workload-identity-pools create "$M6D_POOL" --project "$ZBX_GCP_PROJECT" --location=global --display-name="GitHub Actions" >/dev/null
        say "wif: pool $M6D_POOL created"
    fi
    local mapping='google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref,attribute.repository_id=assertion.repository_id'
    if cur=$(gcloud iam workload-identity-pools providers describe "$M6D_PROVIDER" --project "$ZBX_GCP_PROJECT" \
        --location=global --workload-identity-pool="$M6D_POOL" --format='value(attributeCondition)' 2>/dev/null); then
        if [ "$cur" = "$cond" ]; then say "wif: provider $M6D_PROVIDER exists with the right condition"
        else
            say "wif: provider $M6D_PROVIDER has condition: $cur"
            say "wif: it becomes: $cond"
            if confirm "replace the demo-m6d provider's condition?"; then
                gcloud iam workload-identity-pools providers update-oidc "$M6D_PROVIDER" --project "$ZBX_GCP_PROJECT" \
                    --location=global --workload-identity-pool="$M6D_POOL" --attribute-mapping="$mapping" --attribute-condition="$cond" >/dev/null
            else todo "wif: demo-m6d's condition is unchanged"; fi
        fi
    else
        gcloud iam workload-identity-pools providers create-oidc "$M6D_PROVIDER" --project "$ZBX_GCP_PROJECT" \
            --location=global --workload-identity-pool="$M6D_POOL" --issuer-uri=https://token.actions.githubusercontent.com \
            --attribute-mapping="$mapping" --attribute-condition="$cond" >/dev/null
        say "wif: provider $M6D_PROVIDER created"
    fi
    wif_m6d_registry "$ZBX_GCP_PROJECT" "$ZBX_GCP_REGION" "$sa" "$principal"
    set_var "$zr" - ZBX_GAR_PROVIDER "projects/$num/locations/global/workloadIdentityPools/$M6D_POOL/providers/$M6D_PROVIDER"
    set_var "$zr" - ZBX_GAR_SERVICE_ACCOUNT "$sa"
    set_var "$zr" - ZBX_GAR_REGISTRY "$ZBX_GCP_REGION-docker.pkg.dev/$ZBX_GCP_PROJECT"
    set_var "$zr" - ZBX_GCR_REGISTRY "gcr.io/$ZBX_GCP_PROJECT"
    todo "demo-m6d: push the test image (needs docker): see ops/owner/README.md, 'demo-m6d image'; consider the org policy iam.disableServiceAccountKeyCreation (docs/demos/m6d.md)"
}

wif_m6d_registry() { # project region sa principal
    local p=$1 r=$2 sa=$3 principal=$4 repo loc
    for repo in zbx-demo:"$r" zbx-denied:"$r" gcr.io:us; do
        loc=${repo#*:}; repo=${repo%%:*}
        if gcloud artifacts repositories describe "$repo" --project "$p" --location "$loc" >/dev/null 2>&1; then
            say "wif: repository $repo ($loc) exists"
        else
            gcloud artifacts repositories create "$repo" --project "$p" --location "$loc" --repository-format=docker >/dev/null
            say "wif: repository $repo ($loc) created"
        fi
    done
    if gcloud iam service-accounts describe "$sa" --project "$p" >/dev/null 2>&1; then say "wif: service account $sa exists"
    else gcloud iam service-accounts create zbx-pull --project "$p" --display-name "zbx demo pull" >/dev/null; say "wif: $sa created"; fi
    # Reader on zbx-demo and gcr.io only; nothing on zbx-denied (docs/demos/m6d.md, step 4).
    gcloud artifacts repositories add-iam-policy-binding zbx-demo --project "$p" --location "$r" --member "serviceAccount:$sa" --role roles/artifactregistry.reader >/dev/null
    gcloud artifacts repositories add-iam-policy-binding gcr.io --project "$p" --location us --member "serviceAccount:$sa" --role roles/artifactregistry.reader >/dev/null
    gcloud iam service-accounts add-iam-policy-binding "$sa" --project "$p" --member "$principal" --role roles/iam.workloadIdentityUser >/dev/null
    say "wif: $sa reads zbx-demo and gcr.io, and may be impersonated by $ORG/zigbox"
}

section_wif() {
    need_gcloud
    wif_jepsen
    wif_m6d
}

# --- Section: fleet -------------------------------------------------------------------------------
fleet_token_check() { # tokenfile tracker
    local f=$1 tracker=$2 hdr="$TMP/fleet-hdr" code expiry
    f=${f/#\~/$HOME}
    [ -r "$f" ] || { problem "fleet: cannot read the token file $f"; return 0; }
    printf 'Authorization: Bearer %s\n' "$(tr -d '\n' <"$f")" >"$hdr"
    code=$(curl -sS -o /dev/null -D "$TMP/fleet-h" -w '%{http_code}' -H "@$hdr" -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$ORG/zigcube")
    [ "$code" = 200 ] || { problem "fleet: the token cannot read $ORG/zigcube (HTTP $code): resource owner $ORG, repository zigcube"; rm -f "$hdr"; return 0; }
    expiry=$(grep -i '^github-authentication-token-expiration' "$TMP/fleet-h" | cut -d: -f2- | tr -d '\r' | sed 's/^ //')
    say "fleet: the token reads $ORG/zigcube; it expires: ${expiry:-never or not reported} (put the date in your calendar)"
    code=$(curl -sS -o /dev/null -w '%{http_code}' -H "@$hdr" "https://api.github.com/repos/$ORG/zigcube/issues/$tracker")
    [ "$code" = 200 ] || problem "fleet: the token cannot read issue #$tracker (HTTP $code): it needs Issues permission"
    code=$(curl -sS -o /dev/null -w '%{http_code}' -H "@$hdr" "https://api.github.com/repos/$ORG/zigbox")
    if [ "$code" = 200 ]; then problem "fleet: the token also reads $ORG/zigbox: it must be limited to zigcube alone"
    else say "fleet: and it cannot read $ORG/zigbox (HTTP $code), as it should not"; fi
    rm -f "$hdr"
}

section_fleet() {
    local repo="$ORG/zigcube" n FLEET_TOKEN_FILE="${FLEET_TOKEN_FILE:-}"
    if gh label list --repo "$repo" --json name --jq '.[].name' | grep -qx sim-fleet; then say "fleet: label sim-fleet exists"
    elif dry; then would "create label sim-fleet in $repo"
    else gh label create sim-fleet --repo "$repo" --color 5319e7 --description "filed by the simulation fleet" >/dev/null; say "fleet: label sim-fleet created"; fi
    n=$(gh issue list --repo "$repo" --state all --limit 100 --search "\"$SIM_TRACKER_TITLE\" in:title" --json number,title \
        --jq "[.[] | select(.title == \"$SIM_TRACKER_TITLE\")] | sort_by(.number) | .[0].number // empty")
    if [ -n "$n" ]; then say "fleet: the tracking issue is #$n"
    elif dry; then would "create the tracking issue '$SIM_TRACKER_TITLE'"; n='<N>'
    else
        n=$(gh issue create --repo "$repo" --title "$SIM_TRACKER_TITLE" --label sim-fleet \
            --body "The simulation fleet posts its seeds per day here (ops/sim-fleet/README.md). No comment for a day means the fleet did not run that day." | sed 's#.*/##')
        say "fleet: created the tracking issue #$n"
        gh issue pin "$n" --repo "$repo" >/dev/null 2>&1 || todo "fleet: pin issue #$n (gh issue pin $n --repo $repo, or the browser)"
    fi
    cat <<EOF
owner-setup: the fleet's token cannot be made from here: GitHub has no API for fine-grained personal
owner-setup: access tokens, only the page. In the browser: https://github.com/settings/personal-access-tokens/new
owner-setup:   Resource owner: $ORG (if it is not offered: the organisation must allow fine-grained
owner-setup:   tokens, Settings > Personal access tokens, and may need to approve yours)
owner-setup:   Repository access: Only select repositories: $repo
owner-setup:   Permissions: Issues: Read and write (nothing else); Expiration: as long as allowed.
owner-setup: Save the token into a file with mode 600 on your machine (not the clipboard history).
EOF
    if prompt FLEET_TOKEN_FILE "path of the token file, to check it (empty to skip)"; then
        if dry; then would "check the token in $FLEET_TOKEN_FILE against the API"; else fleet_token_check "$FLEET_TOKEN_FILE" "$n"; fi
    else todo "fleet: make the token and check it: run again with --only fleet"; fi
    cat <<EOF
owner-setup: the fleet host needs these (ops/sim-fleet is not changed here; slice C2 does that):
owner-setup:   /etc/sim-fleet/token                  the token file (root, mode 600), via setup.sh --token-file
owner-setup:   /etc/sim-fleet/fleet.env              SIM_FLEET_TRACKER=$n
owner-setup:                                         SIM_FLEET_GH_REPO=$repo   (run.sh still defaults to $OLD_ORG/zigcube)
owner-setup:                                         SIM_FLEET_REMOTE=https://github.com/$repo
owner-setup:   unchanged: the heartbeat URL (/etc/sim-fleet/heartbeat-url)
owner-setup: then on the host, as root: git -C /root/zigcube pull; sh /root/zigcube/ops/sim-fleet/setup.sh --token-file TOKENFILE;
owner-setup:   systemctl restart sim-fleet; journalctl -u sim-fleet -f   (README "Deploy" and "What the owner provides")
EOF
}

# --- Driver ---------------------------------------------------------------------------------------
preflight() {
    local tool login role
    for tool in git gh curl jq; do command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed (see ops/owner/README.md)"; done
    gh auth status >/dev/null 2>&1 || die "gh is not signed in: gh auth login (scopes repo, workflow, read:org)"
    login=$(gh api user --jq .login)
    role=$(gh api "user/memberships/orgs/$ORG" --jq .role 2>/dev/null || true)
    [ "$role" = admin ] || die "$login is not an owner of $ORG (role: ${role:-none}); sign in as an owner: gh auth login"
    say "signed in as $login, owner of $ORG$(dry && echo ' (dry run: nothing will change)')"
    for tool in zigbox zigcube; do
        gh repo view "$ORG/$tool" --json name >/dev/null 2>&1 || die "$ORG/$tool does not exist"
    done
}

run_section() {
    local name=$1 text=$2
    case ",$ONLY," in ",,") ;; *",$name,"*) ;; *) return 0 ;; esac
    say "---- $name: $text"
    if ! confirm "run the $name section?"; then say "$name: skipped"; return 0; fi
    "section_$name"
    RAN="$RAN$name "
}

main() {
    local arg
    while [ $# -gt 0 ]; do
        arg=$1; shift
        case "$arg" in
            --only) [ $# -gt 0 ] || die "--only needs a section"; ONLY="$ONLY,$1"; shift ;;
            --dry-run) DRY=1 ;;
            --yes) YES=1 ;;
            --help | -h) usage; exit 0 ;;
            *) die "unknown argument $arg (--help)" ;;
        esac
    done
    local s
    for s in $(echo "$ONLY" | tr ',' ' '); do
        case "$s" in tags | jepsen | wif | fleet) ;; *) die "no section '$s': tags jepsen wif fleet" ;; esac
    done
    preflight
    run_section tags "the old repositories' tags, pushed to $ORG"
    run_section jepsen "$ORG/zigcube-jepsen, from the old harness's branches"
    run_section wif "Google workload identity: Jepsen's condition, demo-m6d's pool"
    run_section fleet "the fleet's tracking issue and token"
    if [ -n "$PROBLEMS" ]; then
        local first count
        first=$(printf '%s' "$PROBLEMS" | head -n 1); count=$(printf '%s' "$PROBLEMS" | grep -c .)
        die "$first ($count problem(s) in all, listed above; fix them and run again)"
    fi
    if [ -n "$TODOS" ]; then
        say "still yours to do:"
        printf '%s' "$TODOS" | sed 's/^/owner-setup:   - /'
    fi
    if dry; then say "OK (dry run: sections ${RAN:-none}; nothing was changed)"
    else say "OK sections: ${RAN:-none}; $(printf '%s' "$TODOS" | grep -c . || true) step(s) still yours"; fi
}

main "$@"
