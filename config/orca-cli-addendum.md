## Orca CLI mode (opt-in, currently ON)

`.claude-dev/sandbox.json` has `{"orca": {"cli": true}}`, so this project's
sandbox can reach the Orca control socket and the `orca-cli` /
`orchestration` skills are installed. Two things follow.

**Claude is the coordinator.** Orca orchestration is a way to run a slice,
never a second planner. You still plan, decompose, review and decide; an
Orca worker is a worker seat like any other. Nothing about this mode
changes the lane rubric, the delegation rules, or who authors beads and
acceptance contracts.

**A tier's executor slice may become an Orca worker.** Where you would
spawn `executor`, you may instead run:

```
orca orchestration worker-start --task <id> --worktree current --agent <codex|claude|gemini>
```

`--worktree current` is load-bearing: a worker started in THIS worktree
opens its shell through the same `claude-orca-shell` hook every other
shell here goes through, so it lands inside the same sandbox. A worker
started anywhere else does not, and is an unsandboxed process on the
user's Mac. Workers report completion with `worker_done`; wait for that
rather than polling, and treat the report as a claim to check, exactly as
you would an `executor` summary.

Whatever Orca's own task list shows, beads remain the source of truth for
task state. An Orca task id is a handle for one running worker, not a
record of the work: file, claim, update and close the bead as usual, and
never let an Orca task list stand in for `bd ready`.

**Residual escape surface, unchanged by any of the above.** `orca terminal
create --command …` runs a command outside this sandbox unless the shell
it opens lands in one of this project's worktrees; `orca goto`/`orca exec`
drive an unsandboxed browser; automations and artifacts run outside too.
Use the CLI for coordination, and keep anything that touches the host to
what the user has explicitly asked for.
