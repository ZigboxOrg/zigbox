#!/usr/bin/env bash
# Sets up this machine as Zigbox's CI: Docker, Woodpecker (server, one agent), Caddy for TLS, the
# step image zigbox-ci and the cache directories (ops/ci/README.md). Run it as root on the box
# itself, Ubuntu 24.04 on bare metal (the VM demos need /dev/kvm):
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/ZigboxOrg/zigbox/main/ops/ci/bootstrap.sh)
#
# It clones the repository into /opt/zigbox-ci/src (ZIGBOX_CI_REF picks the branch, default main)
# and runs the copy there; ZIGBOX_CI_IN_CHECKOUT=1 runs the file where it is instead. It asks for
# what it does not have yet: the DNS name, the admin's GitHub login, and the GitHub OAuth app's
# client ID and secret (the secret is read without echo and never put on a command line). Safe to
# run again: it asks only for what is missing, changes only what differs, and a second run after a
# good one ends in the same OK line. The last line is `ci-bootstrap: OK ...` or
# `ci-bootstrap: FAIL <why>`.
set -euo pipefail

repo_url=https://github.com/ZigboxOrg/zigbox
ref="${ZIGBOX_CI_REF:-main}"
etc=/etc/zigbox-ci
opt=/opt/zigbox-ci
src="$opt/src"
cache=/var/lib/zigbox-ci

fail() { echo "ci-bootstrap: FAIL $*"; exit 1; }
step() { echo "ci-bootstrap: $*"; }

# --- Preflight -----------------------------------------------------------------------------------
[ "$(id -u)" = 0 ] || fail "run as root"
. /etc/os-release
[ "${ID:-}" = ubuntu ] && [ "${VERSION_ID:-}" = 24.04 ] ||
    fail "this script is written for Ubuntu 24.04, found ${PRETTY_NAME:-unknown}"
modprobe kvm_amd 2>/dev/null || modprobe kvm_intel 2>/dev/null || true
if [ ! -c /dev/kvm ]; then
    virt=$(systemd-detect-virt 2>/dev/null || true)
    if [ -n "$virt" ] && [ "$virt" != none ]; then
        fail "this machine is a virtual machine ($virt) without nested virtualisation, so it has \
no /dev/kvm; the VM demos need a bare-metal server"
    fi
    fail "/dev/kvm is missing: the CPU's virtualisation (SVM or VT-x) is off in the BIOS"
fi

# --- Run from a checkout -------------------------------------------------------------------------
# Started from curl, this file has no repository beside it: clone one and run the copy in it.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [ -z "${ZIGBOX_CI_IN_CHECKOUT:-}" ]; then
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
    ZIGBOX_CI_IN_CHECKOUT=1 exec bash "$src/ops/ci/bootstrap.sh"
fi
[ -f "$here/compose.yaml" ] || fail "$here has no compose.yaml; run this file from ops/ci"

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
[ -f "$etc/ci.env" ] || install -m 0644 "$here/ci.env.example" "$etc/ci.env"
set -a; . "$etc/ci.env"; set +a
if [ "${CI_ADMINS:-your-github-login}" = your-github-login ]; then
    ask CI_HOST "DNS name of this box" "${CI_HOST:-ci.zigbox.org}"
    ask CI_ADMINS "Your GitHub login (Woodpecker admin)"
    [ -n "$CI_ADMINS" ] || fail "no GitHub login given"
    sed -i "s|^CI_HOST=.*|CI_HOST=$CI_HOST|; s|^CI_ADMINS=.*|CI_ADMINS=$CI_ADMINS|" "$etc/ci.env"
fi
for v in CI_HOST CI_ADMINS CI_GITHUB_ORG CI_MAX_WORKFLOWS CI_AGENT_NAME; do
    [ -n "${!v:-}" ] || fail "$v is not set in $etc/ci.env"
done
if [ ! -s "$etc/github-client-id" ] || [ ! -s "$etc/github-client-secret" ]; then
    echo "The GitHub OAuth app (github.com/organizations/$CI_GITHUB_ORG/settings/applications):"
    echo "  Homepage URL:               https://$CI_HOST"
    echo "  Authorization callback URL: https://$CI_HOST/authorize"
fi
if [ ! -s "$etc/github-client-id" ]; then
    ask client_id "OAuth app Client ID"
    [ -n "$client_id" ] || fail "no Client ID given"
    printf '%s' "$client_id" > "$etc/github-client-id"
fi
[ -s "$etc/github-client-secret" ] ||
    ask_secret "$etc/github-client-secret" "OAuth app client secret"
if [ ! -s "$etc/agent-secret" ]; then
    step "making $etc/agent-secret"
    (umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$etc/agent-secret")
fi
# The containers run as their own users and read the secrets through bind mounts.
chmod 0644 "$etc/github-client-id" "$etc/ci.env"
chmod 0640 "$etc/github-client-secret" "$etc/agent-secret"

# --- DNS and disk --------------------------------------------------------------------------------
# Caddy's certificate and GitHub's webhooks need CI_HOST to point here.
resolved=$(getent ahostsv4 "$CI_HOST" | awk 'NR==1 {print $1}' || true)
[ -n "$resolved" ] || fail "$CI_HOST does not resolve; add an A record for this box"
addrs=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1)
grep -qx "$resolved" <<<"$addrs" ||
    fail "$CI_HOST points at $resolved, which is not this box ($(paste -sd' ' <<<"$addrs"))"
free_gb=$(df -BG --output=avail /var/lib | tail -1 | tr -dc 0-9)
[ "$free_gb" -ge 100 ] || fail "/var/lib has ${free_gb} GiB free; the VM images and caches need 100"

# --- Packages ------------------------------------------------------------------------------------
pkgs=(docker.io docker-compose-v2 ca-certificates curl git qemu-system-x86 qemu-utils)
missing=()
for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [ "${#missing[@]}" -gt 0 ]; then
    step "installing ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
fi
systemctl enable --now docker >/dev/null
# kvm_amd at boot, and a kvm group to own /dev/kvm (qemu-system-x86 makes both on Ubuntu).
echo kvm_amd > /etc/modules-load.d/zigbox-ci-kvm.conf
getent group kvm >/dev/null || fail "no kvm group after installing qemu-system-x86"
kvm_gid=$(getent group kvm | cut -d: -f3)
[ "$(stat -c %g /dev/kvm)" = "$kvm_gid" ] || fail "/dev/kvm is not owned by the kvm group"

# --- Files ---------------------------------------------------------------------------------------
install -d -m 0755 "$opt"
install -m 0644 "$here/compose.yaml" "$here/Caddyfile" "$opt/"
install -m 0644 "$etc/ci.env" "$opt/.env"

# Caches the pipelines mount at /cache (src/testing/vm/cache.zig). tester is uid 1001 in the image.
install -d -m 0755 -o 1001 -g 1001 "$cache" "$cache/zig" "$cache/vm-entries"

# --- The step image ------------------------------------------------------------------------------
zig_version=$(sed -n 's/^ *ARG ZIG_VERSION=//p' "$here/image/Dockerfile")
image="zigbox-ci:$zig_version"
step "building $image (kvm gid $kvm_gid)"
docker build -q --build-arg "KVM_GID=$kvm_gid" -t "$image" "$here/image" >/dev/null
docker run --rm "$image" zig version | grep -qx "$zig_version" ||
    fail "$image has no zig $zig_version"
docker run --rm --privileged "$image" \
    runuser -u tester -- sh -c 'test -r /dev/kvm && test -w /dev/kvm' ||
    fail "tester in $image cannot open /dev/kvm"

# --- Firewall ------------------------------------------------------------------------------------
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
fi

# --- Woodpecker ----------------------------------------------------------------------------------
step "starting Woodpecker and Caddy"
docker compose -f "$opt/compose.yaml" --env-file "$opt/.env" up -d --remove-orphans >/dev/null

# The server answers on the public name once Caddy has its certificate (a minute on the first run).
ok=""
for _ in $(seq 1 60); do
    if curl -fsS --max-time 5 "https://$CI_HOST/healthz" >/dev/null 2>&1; then ok=1; break; fi
    sleep 5
done
[ -n "$ok" ] || fail "https://$CI_HOST/healthz did not answer in 5 minutes; check that $CI_HOST \
points at this box and ports 80 and 443 are open (docker compose -f $opt/compose.yaml logs caddy)"
version=$(curl -fsS "https://$CI_HOST/version" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')

# The agent registers on first contact. It must still be running 30 s later, and its log must hold
# no refusal (a wrong secret) or unreachable server.
sleep 30
running=$(docker compose -f "$opt/compose.yaml" ps --status running --services)
grep -qx woodpecker-agent <<<"$running" || fail "the agent is not running \
(docker compose -f $opt/compose.yaml logs woodpecker-agent)"
if docker compose -f "$opt/compose.yaml" logs --since 30s woodpecker-agent 2>&1 |
    grep -qiE 'unauthenticated|permission denied|connection refused|no such host'; then
    fail "the agent cannot reach or log in to the server \
(docker compose -f $opt/compose.yaml logs woodpecker-agent)"
fi

echo "ci-bootstrap: OK https://$CI_HOST (woodpecker ${version:-?}, agent $CI_AGENT_NAME, \
$CI_MAX_WORKFLOWS workflows, image $image, kvm gid $kvm_gid)"
