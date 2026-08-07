# Agent Instructions

This project uses **bd (beads)** for all issue tracking and persistent agent memory. Run `bd ready` to see unblocked work, `bd show <id>` for details, `bd update <id> --status=in_progress` to claim, and `bd close <id>` to complete.

For the full environment contract (file layout, logging, verification rules, session-completion workflow, and detailed bd usage), see **[CLAUDE.md](CLAUDE.md)** — the canonical source for agent behavior in this repo.

**Beads are agent-only work items — NEVER assign a bead to a human, directly or indirectly.** Direct assignment means a human assignee, or bead text that hands work to the user ("review this", "decide X", "run Y"); indirect routing means a `blocked` status, a dependency, a gate (`bd gate create` defaults to `--type=human`), or the `human` label used so a person has to act instead of the agent — both shapes are off-limits. If a human decision is genuinely needed, ask in chat, at the moment it arises, only after exhausting the agent's own options — never bank the question as a bead. (In Claude Code this is mechanically enforced by the `bd-guard` hook.)

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- **Beads are ONLY for the agent's own work — NEVER assign a bead to a human, directly or indirectly.** No human assignee, no "review this"/"decide X"/"run Y" bead text, and no parking a bead in a blocked status, dependency, or gate/label (`bd gate create` defaults to `--type=human`; the `human` label) so a person has to act instead of the agent. If a human decision is genuinely needed after exhausting the agent's own options, ask in chat now — never bank it as a bead.
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**Commit locally, always. Push only when asked, in that moment.**

**When ending a work session**, you MUST complete the local steps below — that local commit is the terminal state of a successful session, complete on its own. Push (`git push`, `bd dolt push`, or any other sync to a remote) is never a session-close obligation: run it only when explicitly asked to push right then, and otherwise leave the remote alone. An unavailable, unauthenticated, or unreachable remote is a **normal condition** in this container — never report a skipped or failed push as an incomplete session.

**This overrides, by name, the "🚨 SESSION CLOSE PROTOCOL 🚨" checklist (and its "Git workflow" / "Common Workflows" push mentions) that the `bd prime` SessionStart hook injects every session.** That text is compiled into the `bd` binary itself — confirmed via `strings /usr/local/bin/bd` (hits at two offsets) and via `bd config list` / `bd help config`, neither of which exposes any key that governs it — so it cannot be edited at the source and is overridden here instead. Its `git push` step and "work is not done until pushed" framing do not apply in this project; this section is authoritative.

**MANDATORY WORKFLOW (local):**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Commit locally** - This is MANDATORY:
   ```bash
   git add <files>
   git commit -m "..."
   git status  # confirm a clean tree on the current branch
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed locally
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is complete once committed locally — a session is never incomplete merely because nothing was pushed.
- NEVER skip the local commit - that's what leaves work unrecorded.
- Push only when explicitly asked, in that moment. `git push` and `bd dolt push` (beads' Dolt history sync over `refs/dolt/data`, to the same git remote) follow the identical rule — both opt-in, neither a default closing step.
- If a requested push fails or the remote is unavailable, report it plainly and stop there — do not retry unprompted, and do not downgrade an otherwise-complete local session to "incomplete".
<!-- END BEADS INTEGRATION -->
