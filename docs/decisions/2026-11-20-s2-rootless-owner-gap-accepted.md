# S2: the rootless owner gap is accepted for 0.6.0, and `lazy_down_fail_ms` stays 2 s

*Decided 2026-11-20, by the owner (in writing to the supervisor, on the review of PR 8).*

**1. The gap is accepted for 0.6.0 as a recorded cut.** Review of S2 slice 6 (MUST 2, `src/store/object.zig` `apply_owner`): the lazy resolver's slots are threads, so they run outside the store's namespace (`store/owners.zig`, Z9). Rootless, a file's owner can only be changed to the user's own ids there, and `fchown` to any other id, or a `security.capability` xattr, is `EPERM`. Scenario: rootless `zbx run -d --lazy alpine:3.20`. `/etc/shadow` is 0:42, so the put of its last chunk fails; every chunk stays held and verified in `partial/`, the object is never assembled, the run's record stays `partial`, and the fill retries that object on every pass. Each read of its chunks waits `lazy_down_fail_ms` for a round and is then served from `partial/`.

What users see: the run works and every read returns the right bytes, but files owned by any id but container root (and files with `security.capability`) are read about 2 s late the first time each chunk is asked for, `zbx ps` never shows the image 100 % local, and the fill keeps retrying. Running as root, or in a root-owned namespace with `CAP_CHOWN`, is not affected; neither is a run without `--lazy`.

`src/lazy/resolver_test.zig` ("rootless, an object owned by a container id is never made whole, yet reads succeed") pins exactly this with the simulated file system, and `src/store/chunks_tests.zig` pins that the held chunks finish inside the namespace with nothing fetched again. The `security.capability` case has no gate in `SimFs` and is not tested.

**Follow-up (0.6.x).** Complete the object inside the user namespace, as [2026-11-18-s2-lazy-owner-outside.md](2026-11-18-s2-lazy-owner-outside.md) proposes (its option 1: a finishing pass in a fresh single-threaded `zbx` process that runs `chunks.finish` for every object whose chunks are all held), with a rootless VM test whose fixture has a 0:42 file and a `security.capability` file. Until then the cut is recorded in `docs/demos/s2.md`, "Cuts and deviations".

**Release text.** `docs/releases/0.6.0.md` does not exist on this branch, so it is not edited here. The 0.6.0 RC1 release notes must carry a "Known limits" line: "Rootless `--lazy`: files owned by an id other than root, and files with file capabilities, are read about 2 s late on first access, the image stays partial and the fill keeps retrying; fixed in 0.6.x."

**2. `lazy_down_fail_ms` stays 2000 ms.** No change to the constant.
