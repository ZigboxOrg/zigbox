# Woodpecker approval stays on forks; a stale VM cache entry is replaced

*Decided 2026-11-20, by the owner.* Both follow the round-3 review of PR 5. They amend, and do not
replace, [2026-11-19-ci-on-woodpecker.md](2026-11-19-ci-on-woodpecker.md).

## 1. Approval stays `require_approval: "forks"`; `all_events` stays off

Woodpecker's approval setting is `forks`, and `all_events` is not turned on. The consequence is
stated in `ops/ci/README.md` and is the owner's to carry: anyone with write access to
`ZigboxOrg/zigbox`, or holding a writer's credentials, can run privileged steps on the box without
approval (a push to `vmw/*`, or a pull request from a branch of this repository), because the
pipeline YAML comes from the pushed branch and the repository is Trusted. A privileged step is root
on the host, which holds Woodpecker's database (the activating admin's GitHub OAuth token), the
Docker socket, the fleet's token and `/etc/zigbox-ci/*`. The sentence that a leaked token "can
delete or push scratch branches and nothing more" was wrong, and is gone: it holds for the
`github_token` secret alone, not for a writer's token.

Why it is accepted:

- The writers are the owner and the owner's sessions. Nobody else has write access.
- Pull requests from forks, the only route open to others, are held until a maintainer approves.
- `all_events` would hold the owner's own `vmw/*` pushes unless the owner's login is allowed, and the
  sessions push as the owner, so it would add clicks and stop only a second writer, who does not
  exist.
- `main`'s protection, which nobody can bypass (checked by `woodpecker-setup.sh`), keeps the
  activating admin's OAuth token from changing `main`.

If write access ever widens (a collaborator, a team, a bot, an app with `contents: write`), this
decision no longer holds. Before the new writer gets access, switch to
`ZBX_CI_APPROVAL=all_events ZBX_CI_APPROVED_USERS=<owner logins>` and rerun `woodpecker-setup.sh`,
or run the Woodpecker server on a different host from the agent (not built). Until then, write
access is root on the box.

## 2. The 60 s bound of demo-m4 stays; its VM cache entry is replaceable

demo-m4's 60 s bound for its pulls does not move. The cause of the misses was the cache: a key, once
stored, was never overwritten, so a cold `m4-blobs.img` saved by a first run (before the demo had
pulled anything), or any copy that restore found unusable and a later save could not replace, kept
the demo pulling the two Python images on every run.

`src/testing/vm/cache.zig` now replaces a stored entry, atomically and under the store's existing
lock, when it is no use:

- its hash list is missing or unreadable (any entry, whether or not the run passed);
- for an entry the demo writes into (`grows`, only the m4 blob image), when a run whose steps all
  passed leaves files that differ by SHA-256 from the stored ones. A failed run does not replace
  it, since it may leave a half-written image;
- a copy that fails its hash on restore was already deleted and is stored again by the next save.

The replacement writes the new entry under a temporary name, renames the old key aside, renames the
new one to the key and deletes the old one, all while holding the store's lock, so concurrent saves
and the prune of the key count take turns. Restore takes no lock and checks every copy against its
own list, so it meets the old entry, the new one, or a miss for the instant between the renames.
The next save also removes scratch directories a killed save left. The hourly `zigbox-ci-prune`
works on the Zig caches under `.prune-lock` and never on `vm-entries`.

The runbook gives the disk to expect (estimates, with the `du` command for the real figures) and
how to clear one entry by hand.

Not changed: a pin that moves is a new key and so a cold first run; warm each scope once, as the
runbook says. The review's remark that `m4-blobs.img` was not hash-verified on restore was out of
date: restore verified it against the stored list since the earlier round; what was missing was
replacement.
