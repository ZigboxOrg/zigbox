#!/usr/bin/env bash
# What each Woodpecker step runs (.woodpecker/*.yaml, ops/ci/README.md). The YAML stays thin so the
# logic lives here, where `ops/ci/step-test.sh` exercises it without Woodpecker.
#
#   step.sh changes            write .ci/changes (name=true|false, from .github/ci-changes.sh)
#   step.sh gate NAME          run one of ci.yml's code jobs as tester, if `code` is true
#   step.sh demo ID            run one VM demo as tester, if its demo_<ID> is true
#   step.sh vm                 run the demos a vm/<demo>-<x> branch names, then delete the branch
#
# Steps run as root in zigbox-ci (ops/ci/image); the work runs as tester, as on GitHub's runners.
# /cache is the box's /var/lib/zigbox-ci, shared by every pipeline (ops/ci/cache.sh).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cd "$root"

say() { echo "ci: $*"; }

as_tester() {
    chown -R tester:tester "$root"
    runuser -u tester -- env HOME=/home/tester ZIG_GLOBAL_CACHE_DIR=/cache/zig \
        PATH="$PATH" "$@"
}

# The changed paths, one per line. Woodpecker gives them as a JSON array in CI_PIPELINE_FILES for
# pushes and pull requests; with none (a manual run, or a list it could not fill), every rule
# runs, as ci-changes.sh does for an empty list.
changed_paths() {
    if [ -n "${CI_PIPELINE_FILES:-}" ] && [ "${CI_PIPELINE_FILES}" != "[]" ]; then
        jq -r '.[]' <<<"$CI_PIPELINE_FILES"
    fi
}

cmd_changes() {
    mkdir -p .ci
    local labels
    labels=$(tr ',' ' ' <<<"${CI_COMMIT_PULL_REQUEST_LABELS:-}")
    changed_paths |
        EVENT="${CI_PIPELINE_EVENT:-push}" HEAD_REF="${CI_COMMIT_SOURCE_BRANCH:-}" LABELS="$labels" \
            GITHUB_OUTPUT=.ci/changes.tmp bash .github/ci-changes.sh
    mv .ci/changes.tmp .ci/changes
    cat .ci/changes
}

# Each pipeline workflow computes its own copy (workflows do not share a workspace).
wanted() {
    [ -f .ci/changes ] || cmd_changes >/dev/null
    grep -qx "$1=true" .ci/changes
}

cmd_gate() {
    if ! wanted code; then say "$1: not affected by this change (code=false)"; return 0; fi
    case "$1" in
        build)
            as_tester zig build
            as_tester zig build release
            as_tester zig build trust-wasm
            as_tester zig build fuzz-macos ;;
        tidy) as_tester zig build tidy ;;
        test) as_tester zig build test --summary all ;;
        errors-site) as_tester zig build errors-site-check ;;
        fuzz) as_tester zig build fuzz -- all-but provenance 10000 ;;
        fuzz-provenance)
            as_tester zig build fuzz -- provenance "$(od -An -N8 -tu8 /dev/urandom | tr -d ' ')" 10000 ;;
        dbus-live) as_tester dbus-run-session -- zig build dbus-live ;;
        *) say "no gate $1"; return 1 ;;
    esac
}

# demo id (ci-changes.sh's names) -> zig build steps
demo_steps() {
    case "$1" in
        m0|m1|m2|m2b|m3|m4|m5|m6|m6b|m7|m8|m8b|m9|m10|c4|z7) echo "demo-$1" ;;
        s2_lazy|s2lazy) echo "demo-s2-lazy" ;;
        s2) echo "demo-s2-probe" ;;
        m2bprobe) echo "demo-m2b-probe" ;;
        m8_packages) echo "demo-m8-packages" ;;
        m6d) echo "" ;;
        *) return 1 ;;
    esac
}

run_demos() {
    local s status=0
    bash "$here/cache.sh" restore
    for s in "$@"; do
        say "== $s"
        if ! as_tester env ZBX_REGISTRY_MIRRORS=mirror.gcr.io zig build "$s" -Daccel=kvm; then
            say "$s: FAILED"; status=1
        fi
    done
    bash "$here/cache.sh" save || true
    return "$status"
}

cmd_demo() {
    local id="$1" steps
    if ! wanted "demo_$id"; then say "demo $id: not affected by this change"; return 0; fi
    steps=$(demo_steps "$id") || { say "no demo $id"; return 1; }
    if [ -z "$steps" ]; then
        say "demo $id: NOT RUN (needs the owner's Google setup, which this CI does not have yet)"
        return 0
    fi
    [ -w /dev/kvm ] || { say "demo $id: /dev/kvm is not writable (is the repository Trusted?)"; return 1; }
    # shellcheck disable=SC2086
    run_demos $steps
}

delete_branch() {
    local branch="$1"
    if [ -z "${GITHUB_TOKEN:-}" ]; then
        say "not deleting $branch: the github_token secret is not set"; return 0
    fi
    curl -fsS -o /dev/null -X DELETE \
        -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${CI_REPO_OWNER}/${CI_REPO_NAME}/git/refs/heads/$branch" &&
        say "deleted the scratch branch $branch" ||
        say "could not delete $branch (the token needs contents: write)"
}

cmd_vm() {
    local branch="${CI_COMMIT_BRANCH:?}" name demo steps status=0
    name="${branch#vm/}"
    demo="${name%%-*}"
    if [ "$demo" = all ]; then
        steps="demo-m0 demo-m1 demo-m2 demo-m2b demo-m3 demo-m4 demo-m5 demo-m6 demo-m6b demo-m7"
        steps="$steps demo-m8 demo-m8b demo-m9 demo-m10 demo-c4 demo-s2-probe demo-s2-lazy demo-z7"
    elif [ "$demo" = m8 ]; then
        steps="demo-m8 demo-m8-packages"
    elif ! steps=$(demo_steps "$demo"); then
        say "branch $branch names no demo (vm/<demo>-<x>, <demo> as in .github/workflows/vm.yml)"
        delete_branch "$branch"; return 1
    fi
    if [ "$name" = m8-push-ghcr ]; then
        say "vm/m8-push-ghcr: NOT RUN (the GHCR push needs GitHub's own token; not ported)"
        steps=""
    fi
    if [ -z "$steps" ]; then
        say "$branch: nothing to run"
    else
        # shellcheck disable=SC2086
        run_demos $steps || status=1
    fi
    delete_branch "$branch"
    return "$status"
}

case "${1:-}" in
    changes) cmd_changes ;;
    gate) cmd_gate "${2:?gate name}" ;;
    demo) cmd_demo "${2:?demo id}" ;;
    vm) cmd_vm ;;
    *) echo "usage: step.sh changes | gate NAME | demo ID | vm" >&2; exit 64 ;;
esac
