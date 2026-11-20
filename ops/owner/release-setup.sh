#!/usr/bin/env bash
# Release plumbing for ZigboxOrg/zigbox and ZigboxOrg/zigcube, run by the owner on their Mac (or
# any machine with gh and gpg). Sections, in order:
#
#   repos  copy Zigbox/homebrew-tap and Zigbox/website into ZigboxOrg (the release writes to both)
#   envs   the environments: zigbox release, release-publish, package-refresh; zigcube release
#   key    a NEW Zigbox release key (the old secret key is lost): primary, signing subkey, offline
#          backup and revocation certificate, the subkey into both signing environments, the
#          public key as a gist for the supervisor
#   app    the release GitHub App's id and key (making the App is a browser step; it says which)
#   mac    the Developer ID certificate and the notary key
#   check  every secret and variable the workflows read is present
#
#   bash release-setup.sh                 all sections, asking before each
#   bash release-setup.sh --only key      one section
#
# Safe to run again: each section checks what exists and skips it. No secret is ever an argument
# or printed: gh and gpg prompt for them, or read them from a file you name. Bash 3.2 (macOS) is
# enough. The last line is `release-setup: OK ...` or `release-setup: FAIL <what to fix>`.
set -euo pipefail

org=ZigboxOrg
old_org=Zigbox
box="$org/zigbox"
cube="$org/zigcube"
uid="Zigbox releases <releases@zigbox.org>"

fail() { echo "release-setup: FAIL $*"; exit 1; }
say() { echo "release-setup: $*"; }
ask() { # ask VAR PROMPT [DEFAULT]
    local answer
    read -r -p "$2${3:+ [$3]}: " answer
    printf -v "$1" '%s' "${answer:-${3:-}}"
}
confirm() { # confirm SECTION TEXT: true to run it.
    [ -n "$only" ] && return 0
    local a
    read -r -p "== $1: $2. Run it? [Y/n] " a
    case "$a" in n | N | no) return 1 ;; *) return 0 ;; esac
}
has_secret() { # has_secret REPO ENV NAME
    gh secret list --repo "$1" --env "$2" --json name --jq '.[].name' 2>/dev/null | grep -qx "$3"
}
has_var() { # has_var REPO ENV NAME
    gh variable list --repo "$1" --env "$2" --json name --jq '.[].name' 2>/dev/null | grep -qx "$3"
}

only=""
case "${1:-}" in
    "") ;;
    --only) only="${2:?--only takes repos, envs, key, app, mac or check}" ;;
    *) fail "usage: release-setup.sh [--only repos|envs|key|app|mac|check]" ;;
esac
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }

command -v gh >/dev/null || fail "gh is missing: brew install gh"
command -v gpg >/dev/null || fail "gpg is missing: brew install gnupg"
command -v git >/dev/null || fail "git is missing: xcode-select --install"
# Ask GitHub, not `gh auth status`: that fails when any other account or host gh knows is bad.
gh_err=$(gh api user --jq .login 2>&1 >/dev/null) ||
  fail "gh cannot call GitHub as you ($(printf '%s' "$gh_err" | head -n 1)): gh auth login (scopes repo, workflow, gist, admin:org)"
gh api "orgs/$org" --jq .login >/dev/null 2>&1 || fail "gh cannot see the organisation $org"

# --- repos ---------------------------------------------------------------------------------------
if want repos && confirm repos "copy $old_org/homebrew-tap and $old_org/website into $org"; then
    for name in homebrew-tap website; do
        if gh repo view "$org/$name" >/dev/null 2>&1; then
            say "$org/$name exists"
            continue
        fi
        tmp=$(mktemp -d)
        git clone -q --mirror "https://github.com/$old_org/$name.git" "$tmp/$name.git" ||
            fail "cannot read $old_org/$name"
        gh repo create "$org/$name" --public --disable-wiki >/dev/null
        # Branches and tags only: GitHub refuses refs/pull/*.
        git -C "$tmp/$name.git" push -q "https://github.com/$org/$name.git" \
            'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*'
        rm -rf "$tmp"
        say "copied $old_org/$name to $org/$name"
    done
fi

# --- envs ----------------------------------------------------------------------------------------
env_main_only() { # env_main_only REPO ENV REVIEWED(yes|no)
    local me body
    me=$(gh api user --jq .id)
    if [ "$3" = yes ]; then
        body="{\"reviewers\":[{\"type\":\"User\",\"id\":$me}],\"prevent_self_review\":false,"
    else
        body="{\"reviewers\":[],"
    fi
    body="$body\"wait_timer\":0,\"can_admins_bypass\":false,\"deployment_branch_policy\":"
    body="$body{\"protected_branches\":false,\"custom_branch_policies\":true}}"
    printf '%s' "$body" | gh api -X PUT "repos/$1/environments/$2" --input - >/dev/null
    if ! gh api "repos/$1/environments/$2/deployment-branch-policies" \
        --jq '.branch_policies[].name' | grep -qx main; then
        gh api -X POST "repos/$1/environments/$2/deployment-branch-policies" \
            -f name=main -f type=branch >/dev/null
    fi
    say "$1 environment $2: from main only$( [ "$3" = yes ] && echo ', your approval')"
}
if want envs && confirm envs "make the release environments of both repositories"; then
    env_main_only "$box" release yes
    env_main_only "$box" release-publish no
    env_main_only "$box" package-refresh no
    env_main_only "$cube" release yes
fi

# --- key -----------------------------------------------------------------------------------------
if want key && confirm key "make a NEW Zigbox release key and give it to the release"; then
    if has_secret "$box" release ZIGBOX_SIGNING_KEY; then
        say "$box already has ZIGBOX_SIGNING_KEY in release; skipped (delete it to start again)"
    else
        key=$(gpg --list-secret-keys --with-colons "$uid" 2>/dev/null |
            awk -F: '$1 == "fpr" { print $10; exit }' || true)
        if [ -z "$key" ]; then
            echo "gpg now asks for a passphrase (pinentry). Keep it in your password manager:"
            echo "the release needs it, as ZIGBOX_SIGNING_PASSPHRASE."
            gpg --quick-generate-key "$uid" rsa4096 cert never
            key=$(gpg --list-secret-keys --with-colons "$uid" |
                awk -F: '$1 == "fpr" { print $10; exit }')
            gpg --quick-add-key "$key" rsa4096 sign 1y
        fi
        sub=$(gpg --list-secret-keys --with-colons "$key" |
            awk -F: '$1 == "ssb" { s = 1; next } $1 == "fpr" && s { print $10; exit }')
        [ -n "$sub" ] || fail "the key $key has no signing subkey"
        echo "The offline backup and the revocation certificate go straight to removable media,"
        echo "never this disk. Plug in a USB stick (later: a second copy, kept elsewhere)."
        ask media "Directory on that media (e.g. /Volumes/OFFLINE)"
        [ -d "$media" ] && [ -w "$media" ] || fail "$media is not a writable directory"
        if [ ! -s "$media/zigbox-primary-backup.asc" ]; then
            gpg --armor --export-secret-keys "$key" > "$media/zigbox-primary-backup.asc"
        fi
        if [ ! -s "$media/zigbox-revoke.asc" ]; then
            gpg --output "$media/zigbox-revoke.asc" --gen-revoke "$key"
        fi
        gpg --armor --export "$key" > "$media/zigbox-release-key.asc"
        for env in release package-refresh; do
            gpg --armor --export-secret-subkeys "$sub!" |
                gh secret set ZIGBOX_SIGNING_KEY --repo "$box" --env "$env"
            echo "Type the key's passphrase for the $env environment (gh hides it):"
            gh secret set ZIGBOX_SIGNING_PASSPHRASE --repo "$box" --env "$env"
        done
        url=$(gh gist create --public -d "Zigbox release key $key" "$media/zigbox-release-key.asc")
        say "new release key $key (subkey $sub, expires in a year)"
        say "send the supervisor this line: release key $key $url"
    fi
fi

# --- app -----------------------------------------------------------------------------------------
if want app && confirm app "store the release GitHub App's id and private key"; then
    if has_secret "$box" release-publish RELEASE_APP_PRIVATE_KEY &&
        has_secret "$box" package-refresh RELEASE_APP_PRIVATE_KEY; then
        say "the App's key is set; skipped"
    else
        cat <<EOF
Browser step (GitHub has no API that creates a GitHub App):
  https://github.com/organizations/$org/settings/apps/new
  Name: Zigbox Release. Homepage: https://github.com/$box. Webhook: untick Active.
  Repository permissions: Contents Read and write, Actions Read (Metadata Read comes with it).
  Where can it be installed: Only on this account. Create GitHub App.
  Note the App ID; "Generate a private key" downloads a .pem.
  Install App -> $org -> Only select repositories: homebrew-tap and website (not zigbox).
EOF
        ask app_id "App ID"
        case "$app_id" in '' | *[!0-9]*) fail "the App ID is a number" ;; esac
        ask pem "Path to the downloaded .pem" "$(ls -t ~/Downloads/*.private-key.pem 2>/dev/null |
            head -1)"
        [ -s "$pem" ] || fail "$pem is not a file"
        for env in release-publish package-refresh; do
            gh variable set RELEASE_APP_ID --repo "$box" --env "$env" --body "$app_id"
            gh secret set RELEASE_APP_PRIVATE_KEY --repo "$box" --env "$env" < "$pem"
        done
        rm -i "$pem" || true
        say "App $app_id stored in release-publish and package-refresh"
    fi
fi

# --- mac -----------------------------------------------------------------------------------------
if want mac && confirm mac "store the Developer ID certificate and the notary key"; then
    if has_secret "$box" release MAC_CERT_P12 && has_secret "$box" release MAC_NOTARY_KEY; then
        say "the Mac secrets are set; skipped"
    else
        cat <<EOF
The Developer ID Application certificate as a .p12: Keychain Access -> login -> My Certificates
-> "Developer ID Application: ..." -> right-click -> Export (an export password; keep it). The
notary key is the App Store Connect API key (.p8, role Developer) with its Key ID and Issuer ID.
EOF
        ask p12 "Path to the .p12"
        [ -s "$p12" ] || fail "$p12 is not a file"
        base64 < "$p12" | tr -d '\n' | gh secret set MAC_CERT_P12 --repo "$box" --env release
        echo "Type the .p12's export password (gh hides it):"
        gh secret set MAC_CERT_PASSWORD --repo "$box" --env release
        ask p8 "Path to AuthKey_<KEYID>.p8"
        [ -s "$p8" ] || fail "$p8 is not a file"
        gh secret set MAC_NOTARY_KEY --repo "$box" --env release < "$p8"
        kid_default=$(basename "$p8" .p8); kid_default=${kid_default#AuthKey_}
        ask kid "Key ID" "$kid_default"
        ask iss "Issuer ID (a UUID, App Store Connect -> Integrations)"
        gh variable set MAC_NOTARY_KEY_ID --repo "$box" --env release --body "$kid"
        gh variable set MAC_NOTARY_ISSUER_ID --repo "$box" --env release --body "$iss"
        say "Mac secrets stored in release"
    fi
fi

# --- check ---------------------------------------------------------------------------------------
missing=""
need() { # need secret|var REPO ENV NAME
    if [ "$1" = secret ]; then has_secret "$2" "$3" "$4" || missing="$missing $2:$3:$4"
    else has_var "$2" "$3" "$4" || missing="$missing $2:$3:$4"; fi
}
if want check || [ -z "$only" ]; then
    for n in ZIGBOX_SIGNING_KEY ZIGBOX_SIGNING_PASSPHRASE MAC_CERT_P12 MAC_CERT_PASSWORD \
        MAC_NOTARY_KEY; do need secret "$box" release "$n"; done
    need var "$box" release MAC_NOTARY_KEY_ID
    need var "$box" release MAC_NOTARY_ISSUER_ID
    need secret "$box" release-publish RELEASE_APP_PRIVATE_KEY
    need var "$box" release-publish RELEASE_APP_ID
    for n in ZIGBOX_SIGNING_KEY ZIGBOX_SIGNING_PASSPHRASE RELEASE_APP_PRIVATE_KEY; do
        need secret "$box" package-refresh "$n"; done
    need var "$box" package-refresh RELEASE_APP_ID
    gh api "repos/$cube/environments/release" >/dev/null 2>&1 ||
        missing="$missing $cube:release(environment)"
    for name in homebrew-tap website; do
        gh repo view "$org/$name" >/dev/null 2>&1 || missing="$missing $org/$name(repository)"
    done
    [ -z "$missing" ] || fail "missing:$missing (rerun the section that makes it)"
    echo "release-setup: OK $box (release, release-publish, package-refresh) and $cube (release)"
else
    echo "release-setup: OK section $only"
fi
