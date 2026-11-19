#!/usr/bin/env bash
# Sets up the fleet box as Zigbox's CI: Docker, Woodpecker (server, one agent), Caddy for TLS, the
# step image zigbox-ci and the cache directories (ops/ci/README.md). Run as root on Ubuntu 24.04,
# from a copy of ops/ci. Safe to run again: it changes only what differs, and a second run after a
# good one ends in the same OK line.
#
#   sudo ./bootstrap.sh
#
# It needs /etc/zigbox-ci/ci.env (from ci.env.example), /etc/zigbox-ci/github-client-id and
# /etc/zigbox-ci/github-client-secret. It makes /etc/zigbox-ci/agent-secret if missing.
# The last line is `ci-bootstrap: OK ...` or `ci-bootstrap: FAIL <why>`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
etc=/etc/zigbox-ci
opt=/opt/zigbox-ci
cache=/var/lib/zigbox-ci

fail() { echo "ci-bootstrap: FAIL $*"; exit 1; }
step() { echo "ci-bootstrap: $*"; }

# --- Preflight -----------------------------------------------------------------------------------
[ "$(id -u)" = 0 ] || fail "run as root (sudo ./bootstrap.sh)"
. /etc/os-release
[ "${ID:-}" = ubuntu ] && [ "${VERSION_ID:-}" = 24.04 ] ||
    fail "this script is written for Ubuntu 24.04, found ${PRETTY_NAME:-unknown}"
grep -qw svm /proc/cpuinfo || grep -qw vmx /proc/cpuinfo ||
    fail "the CPU reports no virtualisation (svm/vmx); enable SVM in the BIOS"
modprobe kvm_amd 2>/dev/null || modprobe kvm_intel 2>/dev/null || true
[ -c /dev/kvm ] || fail "/dev/kvm is missing after loading kvm_amd; enable SVM in the BIOS"
for f in ci.env github-client-id github-client-secret; do
    [ -s "$etc/$f" ] || fail "$etc/$f is missing or empty (ops/ci/README.md, step 3)"
done
set -a; . "$etc/ci.env"; set +a
for v in CI_HOST CI_ADMINS CI_GITHUB_ORG CI_MAX_WORKFLOWS CI_AGENT_NAME; do
    [ -n "${!v:-}" ] || fail "$v is not set in $etc/ci.env"
done
[ "$CI_ADMINS" != your-github-login ] || fail "set CI_ADMINS in $etc/ci.env to your GitHub login"
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

# --- Secrets and files ---------------------------------------------------------------------------
chmod 0700 "$etc"
chmod 0600 "$etc/github-client-id" "$etc/github-client-secret"
if [ ! -s "$etc/agent-secret" ]; then
    step "making $etc/agent-secret"
    (umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$etc/agent-secret")
fi
# The containers run as their own users and read the secrets through bind mounts.
chmod 0644 "$etc/github-client-id"
chmod 0640 "$etc/github-client-secret" "$etc/agent-secret"
chmod 0711 "$etc"
install -d -m 0755 "$opt"
install -m 0644 "$here/compose.yaml" "$here/Caddyfile" "$opt/"
install -m 0644 "$etc/ci.env" "$opt/.env"

# Caches the pipelines mount at /cache (ops/ci/cache.sh). tester is uid 1001 in the image.
install -d -m 0755 -o 1001 -g 1001 "$cache" "$cache/zig" "$cache/vm-entries"

# --- The step image ------------------------------------------------------------------------------
zig_version=$(sed -n 's/^ *ARG ZIG_VERSION=//p' "$here/image/Dockerfile")
image="zigbox-ci:$zig_version"
step "building $image (kvm gid $kvm_gid)"
docker build -q --build-arg "KVM_GID=$kvm_gid" -t "$image" "$here/image" >/dev/null
docker run --rm "$image" zig version | grep -qx "$zig_version" || fail "$image has no zig $zig_version"
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
