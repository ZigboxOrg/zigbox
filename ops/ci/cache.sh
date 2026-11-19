#!/usr/bin/env bash
# The VM caches that GitHub's actions/cache kept (.github/workflows/vm.yml), on the box's disk:
# the same four entries, the same paths and the same keys (the hash of the file that pins them).
#
#   cache.sh restore   copy each entry's files into this workspace, if the box has that key
#   cache.sh save      store each entry the box lacks, from this workspace (as actions/cache: a key
#                      once stored is never overwritten)
#
# Several pipelines share the store, so saving holds a lock and an entry appears all at once
# (written under a temporary name, then renamed). Old keys are never read again; prune by hand
# (ops/ci/README.md, "Disk").
set -euo pipefail

store=${ZBX_CI_CACHE:-/cache}/vm-entries

key() { echo "$1-$(cat "$2" | sha256sum | cut -c1-16)"; }

# name, workspace directory, glob of its files (within that directory), key
entries() {
    printf '%s\n' \
        "image|.zig-cache/zbx-vm|ubuntu-24.04-server-cloudimg-amd64.img|$(key vm-image src/testing/vm/lib/image.zon)" \
        "guests|.zig-cache/zbx-vm-guests|debian-*.qcow2 Fedora-*.qcow2 Rocky-*.qcow2|$(key vm-guests src/testing/vm/lib/guests.zon)" \
        "alpine|.zig-cache/zbx-vm|alpine-*.tar.gz|$(key vm-alpine src/testing/vm/alpine.zon)" \
        "blobs|.zig-cache/zbx-vm|m4-blobs.img|$(key vm-m4-blobs src/testing/vm/zbx.lock)"
}

restore() {
    local name dir globs k n=0
    while IFS='|' read -r name dir globs k; do
        [ -d "$store/$k" ] || { echo "cache: $name: miss ($k)"; continue; }
        mkdir -p "$dir"
        # A copy, never a hard link: demo-m4 writes into m4-blobs.img, which must not change the store.
        cp -a --reflink=auto "$store/$k/." "$dir/"
        echo "cache: $name: hit ($k)"; n=$((n + 1))
    done < <(entries)
    chown -R 1001:1001 .zig-cache 2>/dev/null || true
}

save() {
    local name dir globs k g f tmp found
    mkdir -p "$store"
    exec 9>"$store/.lock"
    flock 9
    while IFS='|' read -r name dir globs k; do
        [ -d "$store/$k" ] && continue
        [ -d "$dir" ] || continue
        tmp="$store/.$k.tmp.$$"
        rm -rf "$tmp"; mkdir -p "$tmp"
        found=0
        for g in $globs; do
            for f in "$dir"/$g; do
                [ -f "$f" ] && [ -s "$f" ] || continue
                cp "$f" "$tmp/"; found=1
            done
        done
        if [ "$found" -eq 1 ]; then
            mv "$tmp" "$store/$k"; echo "cache: $name: saved ($k)"
        else
            rm -rf "$tmp"
        fi
    done < <(entries)
}

case "${1:-}" in
    restore) restore ;;
    save) save ;;
    *) echo "usage: cache.sh restore | save" >&2; exit 64 ;;
esac
