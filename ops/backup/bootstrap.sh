#!/usr/bin/env bash
# Sets up this machine as the backup of Zigbox's GitHub repositories: Forgejo (its own TLS through
# Let's Encrypt, SQLite, sign-in required, no SSH, no registration) and a timer that copies every
# branch and tag from GitHub to it every five minutes without ever losing a commit (sync.sh,
# ops/backup/README.md). Run it as root on the box itself, Ubuntu 24.04 or Debian 12 or 13:
#
#   bash <(curl -fsSL \
#       https://raw.githubusercontent.com/ZigboxOrg/zigbox/main/ops/backup/bootstrap.sh)
#
# It clones the repository into /opt/zigbox-backup/src (ZIGBOX_BACKUP_REF picks the branch, default
# main) and runs the copy there; ZIGBOX_BACKUP_IN_CHECKOUT=1 runs the file where it is instead. It
# asks for what it does not have yet: the DNS name, the Forgejo admin's name and e-mail, and a
# read-only GitHub token (read without echo, never put on a command line). Safe to run again: it
# asks only for what is missing and changes only what differs. A heartbeat URL, if the owner puts
# one in /etc/zigbox-backup/heartbeat-url (ops/backup/README.md, step 4), is kept readable by the
# sync. Any failure ends in one line, and the last line is
# `backup-bootstrap: OK ...` or `backup-bootstrap: FAIL <why>`.
set -Eeuo pipefail

# Forgejo's long-term-support line (supported until 2027-07-15), signed by Forgejo's release key
# (https://forgejo.org/download/).
forgejo_version=15.0.12
forgejo_key=EB114F5E6C0DC2BCDD183550A4B61A2DC5923710

repo_url=https://github.com/ZigboxOrg/zigbox
ref="${ZIGBOX_BACKUP_REF:-main}"
etc=/etc/zigbox-backup
opt=/opt/zigbox-backup
src="$opt/src"
lib=/usr/local/lib/zigbox-backup
home=/var/lib/zigbox-backup
fj_data=/var/lib/forgejo
fj_etc=/etc/forgejo

fail() { trap - ERR; echo "backup-bootstrap: FAIL $*"; exit 1; }
# Every step no `fail` covers still ends in one FAIL line (a failed download, a wrong
# ZIGBOX_BACKUP_REF, apt); the tool's own message is above it.
trap '[ "$BASHPID" != "$$" ] || fail "step failed at line $LINENO: $BASH_COMMAND"' ERR
cleanup=()
trap 'rm -rf "${cleanup[@]}"' EXIT
step() { echo "backup-bootstrap: $*"; }

# --- Preflight -----------------------------------------------------------------------------------
[ "$(id -u)" = 0 ] || fail "run as root"
. /etc/os-release
case "${ID:-}-${VERSION_ID:-}" in
    ubuntu-24.04 | debian-12 | debian-13) ;;
    *) fail "this script is written for Ubuntu 24.04 or Debian 12 or 13, found ${PRETTY_NAME:-?}" ;;
esac
[ "$(uname -m)" = x86_64 ] || fail "this script installs Forgejo for x86_64, found $(uname -m)"

# --- Run from a checkout -------------------------------------------------------------------------
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [ -z "${ZIGBOX_BACKUP_IN_CHECKOUT:-}" ]; then
    if ! command -v git >/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get update -q
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q git
    fi
    install -d -m 0755 "$opt"
    if [ -d "$src/.git" ]; then
        step "updating $src to $ref"
        git -C "$src" fetch -q --depth 1 origin "$ref"
        git -C "$src" checkout -q --force FETCH_HEAD
    else
        step "cloning $repo_url ($ref) into $src"
        git clone -q --depth 1 -b "$ref" "$repo_url" "$src"
    fi
    ZIGBOX_BACKUP_IN_CHECKOUT=1 exec bash "$src/ops/backup/bootstrap.sh"
fi
[ -f "$here/sync.sh" ] || fail "$here has no sync.sh; run this file from ops/backup"

# --- Settings and secrets ------------------------------------------------------------------------
ask() { # ask VAR PROMPT [DEFAULT]: reads from the terminal, never from a pipe.
    [ -r /dev/tty ] || fail "$2 is needed and there is no terminal to ask on"
    local answer
    read -r -p "$2${3:+ [$3]}: " answer </dev/tty
    printf -v "$1" '%s' "${answer:-${3:-}}"
}
ask_secret() { # ask_secret FILE PROMPT: writes the answer to FILE (0600), never echoes it.
    [ -r /dev/tty ] || fail "$2 is needed and there is no terminal to ask on"
    local answer
    read -r -s -p "$2 (hidden): " answer </dev/tty
    echo
    [ -n "$answer" ] || fail "$2 was empty"
    (umask 077; printf '%s' "$answer" > "$1")
}

install -d -m 0711 "$etc"
[ -f "$etc/backup.env" ] || install -m 0644 "$here/backup.env.example" "$etc/backup.env"
set -a; . "$etc/backup.env"; set +a
if [ -z "${BACKUP_ADMIN:-}" ] || [ -z "${BACKUP_EMAIL:-}" ]; then
    ask BACKUP_HOST "DNS name of this box" "${BACKUP_HOST:-git.zigbox.org}"
    ask BACKUP_ADMIN "Forgejo admin user name (not 'admin', which Forgejo reserves)"
    ask BACKUP_EMAIL "Admin e-mail (Let's Encrypt writes here about the certificate)"
    [ -n "$BACKUP_ADMIN" ] && [ -n "$BACKUP_EMAIL" ] || fail "the admin name and e-mail are needed"
    sed -i -e "s|^BACKUP_HOST=.*|BACKUP_HOST=$BACKUP_HOST|" \
        -e "s|^BACKUP_ADMIN=.*|BACKUP_ADMIN=$BACKUP_ADMIN|" \
        -e "s|^BACKUP_EMAIL=.*|BACKUP_EMAIL=$BACKUP_EMAIL|" "$etc/backup.env"
fi
for v in BACKUP_HOST BACKUP_ADMIN BACKUP_EMAIL BACKUP_REPOS; do
    [ -n "${!v:-}" ] || fail "$v is not set in $etc/backup.env"
done
if [ ! -s "$etc/github-token" ]; then
    echo "A fine-grained GitHub token, read-only: github.com/settings/personal-access-tokens/new,"
    echo "  owner ZigboxOrg, repositories: $BACKUP_REPOS, permission Contents: Read-only."
    ask_secret "$etc/github-token" "GitHub token"
fi

# --- DNS and disk --------------------------------------------------------------------------------
resolved=$(getent ahostsv4 "$BACKUP_HOST" | awk 'NR==1 {print $1}' || true)
[ -n "$resolved" ] || fail "$BACKUP_HOST does not resolve; add an A record for this box"
addrs=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1)
grep -qx "$resolved" <<<"$addrs" ||
    fail "$BACKUP_HOST points at $resolved, which is not this box ($(paste -sd' ' <<<"$addrs"))"
free_gb=$(df -BG --output=avail /var/lib | tail -1 | tr -dc 0-9)
[ "$free_gb" -ge 5 ] || fail "/var/lib has ${free_gb} GiB free; Forgejo and the mirrors need 5"

# --- Packages ------------------------------------------------------------------------------------
pkgs=(ca-certificates curl git gnupg jq)
missing=()
for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [ "${#missing[@]}" -gt 0 ]; then
    step "installing ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
fi

# --- Forgejo -------------------------------------------------------------------------------------
fj=/usr/local/bin/forgejo
fj_changed=""
installed=$("$fj" --version 2>/dev/null || true)
if ! grep -qE "version $forgejo_version([+ ]|$)" <<<"$installed"; then
    step "installing Forgejo $forgejo_version (signature checked against $forgejo_key)"
    tmp=$(mktemp -d)
    cleanup+=("$tmp")
    base="https://codeberg.org/forgejo/forgejo/releases/download/v$forgejo_version"
    bin="forgejo-$forgejo_version-linux-amd64"
    curl -fsSL --retry 3 -o "$tmp/$bin" "$base/$bin"
    curl -fsSL --retry 3 -o "$tmp/$bin.asc" "$base/$bin.asc"
    install -d -m 0700 "$tmp/gnupg"
    gpg --homedir "$tmp/gnupg" -q --keyserver hkps://keys.openpgp.org --recv-keys "$forgejo_key" \
        2>/dev/null || fail "could not fetch Forgejo's key $forgejo_key from keys.openpgp.org"
    # VALIDSIG's last field is the primary key's fingerprint, whichever subkey signed.
    signer=$(gpg --homedir "$tmp/gnupg" --status-fd 1 --verify "$tmp/$bin.asc" "$tmp/$bin" \
        2>/dev/null | awk '$2 == "VALIDSIG" {print $NF}')
    [ "$signer" = "$forgejo_key" ] ||
        fail "$bin is not signed by Forgejo's release key (signer: ${signer:-none})"
    install -m 0755 "$tmp/$bin" "$fj"
    fj_changed=1
fi

if ! id git >/dev/null 2>&1; then
    adduser --system --shell /bin/bash --gecos 'Git Version Control' --group \
        --disabled-password --home /home/git git >/dev/null
fi
install -d -m 0750 -o git -g git "$fj_data"
install -d -m 0750 -o root -g git "$fj_etc"

# Forgejo's own secrets, made once and kept, so app.ini can be written afresh on every run.
if [ ! -s "$etc/forgejo-secrets.env" ]; then
    (umask 077; {
        echo "SECRET_KEY=$("$fj" generate secret SECRET_KEY)"
        echo "INTERNAL_TOKEN=$("$fj" generate secret INTERNAL_TOKEN)"
        echo "JWT_SECRET=$("$fj" generate secret JWT_SECRET)"
    } > "$etc/forgejo-secrets.env")
fi
. "$etc/forgejo-secrets.env"
ini=$(mktemp)
cat > "$ini" <<EOF
; Written by ops/backup/bootstrap.sh on every run; edit that, not this.
APP_NAME = Zigbox backup
RUN_USER = git
RUN_MODE = prod
WORK_PATH = $fj_data

[server]
PROTOCOL = https
DOMAIN = $BACKUP_HOST
ROOT_URL = https://$BACKUP_HOST/
HTTP_PORT = 443
REDIRECT_OTHER_PORT = true
PORT_TO_REDIRECT = 80
ENABLE_ACME = true
ACME_ACCEPTTOS = true
ACME_DIRECTORY = $fj_data/acme
ACME_EMAIL = $BACKUP_EMAIL
DISABLE_SSH = true
OFFLINE_MODE = true
LFS_START_SERVER = false
APP_DATA_PATH = $fj_data/data

[database]
DB_TYPE = sqlite3
PATH = $fj_data/data/forgejo.db

[repository]
ROOT = $fj_data/repositories
DEFAULT_PRIVATE = private

[security]
INSTALL_LOCK = true
SECRET_KEY = $SECRET_KEY
INTERNAL_TOKEN = $INTERNAL_TOKEN

[oauth2]
JWT_SECRET = $JWT_SECRET

[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = true

[log]
MODE = console
LEVEL = Info

[cron.update_checker]
ENABLED = false
EOF
if ! cmp -s "$ini" "$fj_etc/app.ini"; then
    install -m 0640 -o root -g git "$ini" "$fj_etc/app.ini"
    fj_changed=1
fi
rm -f "$ini"

unit=/etc/systemd/system/forgejo.service
cat > "$unit.new" <<EOF
[Unit]
Description=Forgejo (the Zigbox backup, ops/backup/README.md)
After=network-online.target
Wants=network-online.target

[Service]
User=git
Group=git
WorkingDirectory=$fj_data
Environment=USER=git HOME=/home/git FORGEJO_WORK_DIR=$fj_data
ExecStart=$fj web --config $fj_etc/app.ini
# Ports 80 and 443 without root.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
if ! cmp -s "$unit.new" "$unit"; then mv "$unit.new" "$unit"; fj_changed=1; else rm "$unit.new"; fi
systemctl daemon-reload
systemctl enable -q forgejo
if [ -n "$fj_changed" ]; then
    step "starting Forgejo"
    systemctl restart forgejo
fi

if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
fi

# Forgejo answers on its public name once Let's Encrypt has issued the certificate.
ok=""
for _ in $(seq 1 60); do
    if curl -fsS --max-time 5 "https://$BACKUP_HOST/api/healthz" >/dev/null 2>&1; then
        ok=1; break
    fi
    sleep 5
done
[ -n "$ok" ] || fail "https://$BACKUP_HOST/api/healthz did not answer in 5 minutes; check that \
$BACKUP_HOST points at this box and ports 80 and 443 are open (journalctl -u forgejo)"

# --- The admin, the organisation and the repositories --------------------------------------------
fja() { # fja ARGS: forgejo admin ARGS, as the user git.
    runuser -u git -- env HOME=/home/git "$fj" --config "$fj_etc/app.ini" --work-path "$fj_data" \
        admin "$@"
}
# The admin's first password is kept in admin-password (root only, 0400), and the last lines name
# the file. The admin must never be made to change the password: the backup's API token is the
# admin's, and Forgejo answers 403 to every API call of a user who must change it, so `user create`
# says --must-change-password=false whatever is already in the database. ZIGBOX_BACKUP_RESET_ADMIN=1
# on a rerun sets a new password there (Forgejo's change-password takes it in argv: a moment, on a
# box with no users).
admin_pw="$etc/admin-password"
if ! fja user list --admin | awk 'NR > 1 {print $2}' | grep -qx "$BACKUP_ADMIN"; then
    step "creating the Forgejo admin $BACKUP_ADMIN"
    created=$(fja user create --username "$BACKUP_ADMIN" --email "$BACKUP_EMAIL" --admin \
        --random-password --must-change-password=false 2>&1) ||
        fail "Forgejo refused the admin: $(tail -1 <<<"$created" | sed "s/'[^']*'/(masked)/g")"
    pw=$(sed -n "s/.*generated random password is '\(.*\)'.*/\1/p" <<<"$created")
    [ -n "$pw" ] || fail "Forgejo created $BACKUP_ADMIN but its output has no password line to read"
    (umask 077; printf '%s\n' "$pw" > "$admin_pw"); chmod 0400 "$admin_pw"
elif [ "${ZIGBOX_BACKUP_RESET_ADMIN:-}" = 1 ]; then
    step "setting a new password for $BACKUP_ADMIN"
    pw=$(head -c 18 /dev/urandom | base64)
    fja user change-password --username "$BACKUP_ADMIN" --password "$pw" \
        --must-change-password=false >/dev/null || fail "Forgejo refused the new password"
    rm -f "$admin_pw"; (umask 077; printf '%s\n' "$pw" > "$admin_pw"); chmod 0400 "$admin_pw"
fi
if ! id zigbox-backup >/dev/null 2>&1; then
    adduser --system --group --home "$home" --shell /usr/sbin/nologin zigbox-backup >/dev/null
fi
install -d -m 0750 -o zigbox-backup -g zigbox-backup "$home" "$home/mirrors"
if [ ! -s "$etc/forgejo-token" ]; then
    step "making the sync's Forgejo token"
    token=$(fja user generate-access-token --username "$BACKUP_ADMIN" --raw \
        --token-name "zigbox-backup-sync-$(date -u +%s)" \
        --scopes write:repository,write:organization)
    [ -n "$token" ] || fail "Forgejo made no access token for $BACKUP_ADMIN"
    (umask 077; printf '%s' "$token" > "$etc/forgejo-token")
fi
for f in github-token forgejo-token heartbeat-url; do
    [ ! -e "$etc/$f" ] || { chown zigbox-backup:zigbox-backup "$etc/$f"; chmod 0400 "$etc/$f"; }
done

api_header=$(mktemp)
cleanup+=("$api_header")
(umask 077; printf 'Authorization: token %s\n' "$(cat "$etc/forgejo-token")" > "$api_header")
api() { # api METHOD PATH [JSON]: prints the HTTP status.
    curl -sS -o /dev/null -w '%{http_code}' -X "$1" -H @"$api_header" \
        -H 'Content-Type: application/json' ${3:+--data "$3"} "https://$BACKUP_HOST/api/v1$2"
}
for repo in $BACKUP_REPOS; do
    owner=${repo%/*} name=${repo#*/}
    status=$(api GET "/orgs/$owner")
    [ "$status" = 200 ] || [ "$status" = 404 ] ||
        fail "Forgejo answered $status reading the organisation $owner (is $BACKUP_ADMIN locked?)"
    if [ "$status" = 404 ]; then
        step "creating the organisation $owner"
        status=$(api POST /orgs "{\"username\":\"$owner\",\"visibility\":\"private\"}")
        [ "$status" = 201 ] || fail "Forgejo answered $status creating the organisation $owner"
    fi
    if [ "$(api GET "/repos/$repo")" != 200 ]; then
        step "creating the repository $repo"
        status=$(api POST "/orgs/$owner/repos" \
            "{\"name\":\"$name\",\"private\":true,\"default_branch\":\"main\"}")
        [ "$status" = 201 ] || fail "Forgejo answered $status creating the repository $repo"
    fi
done

# --- The sync ------------------------------------------------------------------------------------
install -d -m 0755 "$lib"
install -m 0755 "$here/sync.sh" "$lib/sync.sh"
# Written through a temp file and `install`, which replaces a symlink the zigbox-backup user may
# have put at .gitconfig instead of writing through it (root runs this, the user runs git).
gitconfig=$(mktemp)
cleanup+=("$gitconfig")
cat > "$gitconfig" <<EOF
[credential "https://github.com"]
	username = x-access-token
	helper = $lib/sync.sh credential $etc/github-token
[credential "https://$BACKUP_HOST"]
	username = $BACKUP_ADMIN
	helper = $lib/sync.sh credential $etc/forgejo-token
EOF
rm -f "$home/.gitconfig"
install -m 0644 -o zigbox-backup -g zigbox-backup "$gitconfig" "$home/.gitconfig"

cat > /etc/systemd/system/zigbox-backup-sync.service <<EOF
[Unit]
Description=Copy the Zigbox repositories from GitHub to Forgejo (ops/backup/README.md)
After=forgejo.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=zigbox-backup
Group=zigbox-backup
ExecStart=$lib/sync.sh
TimeoutStartSec=15min
EOF
cat > /etc/systemd/system/zigbox-backup-sync.timer <<EOF
[Unit]
Description=Copy the Zigbox repositories from GitHub to Forgejo every five minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload

# The first sync runs before the timer starts: a timer started after OnBootSec has passed fires
# at once. sync.sh also holds a lock, for a rerun while the timer is already active.
step "running the first sync"
out=$(runuser -u zigbox-backup -- env HOME="$home" "$lib/sync.sh" 2>&1) || {
    echo "$out"; fail "the first sync failed (its lines are above)"; }
echo "$out"
systemctl enable -q --now zigbox-backup-sync.timer
if [ -s "$admin_pw" ]; then
    echo "Log in at https://$BACKUP_HOST as $BACKUP_ADMIN with the password in $admin_pw"
    echo "(cat it as root). The file is kept: the README's later steps read it."
fi
echo "backup-bootstrap: OK https://$BACKUP_HOST (Forgejo $forgejo_version, $BACKUP_REPOS, \
every 5 minutes)"
