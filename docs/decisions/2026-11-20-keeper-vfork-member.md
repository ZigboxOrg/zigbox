# The scope's keeper puts a vfork child in the scope

*Decided 2026-11-20, by the slice (fix for demo-m2's flaky OOM reason, before 0.6.0).*

demo-m2's `--memory 32m` hog was sometimes reported as a plain SIGKILL (reason `signal`, 137)
instead of `oom` (run 44671710258). The kernel log of a diagnostic run (run 44680042212) showed
the cause: after the OOM killer killed `sh`, another process of the command (`head` or `tr`) was
still charging the cgroup, a second memcg OOM picked the keeper (`Killed process ... (zbx)`), the
scope was empty, and systemd removed it with `memory.events` before zbx read it.

The keeper is now two processes. zbx forks the keeper (the pid it signals and reaps), and the
keeper clones its member with `CLONE_VM | CLONE_VFORK | CLONE_FILES`. Only the member goes in the
scope's `PIDs`. The kernel's `oom_badness` returns `LONG_MIN` for a task in a vfork
(`in_vfork`, mm/oom_kill.c), so the member is never an OOM victim; `/proc/<member>/oom_score`
reads 0, which a real-kernel test checks. The keeper itself stays outside the scope, so it is not
in the cgroup the OOM killer chooses from.

Rejected:

- Raising the container's `oom_score_adj` so the keeper is never preferred: it changes what the
  user's processes see (a user-visible default), and it only ranks victims; it does not exclude
  the keeper once the container's processes are gone.
- Lowering the keeper's `oom_score_adj`: an unprivileged process cannot.
- Retrying the read of `memory.events` after the scope is gone: the counters go with the cgroup.

`TasksMax` is unchanged (`--pids` plus one): the scope still has one extra process.
