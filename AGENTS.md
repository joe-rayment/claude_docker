# Agent Instructions

Instructions for any coding agent — Codex, Aider, Cursor, plain Claude, etc. — working in this repo, including ones that never load Claude Code's own project config.

**[CLAUDE.md](CLAUDE.md) is the canonical rulebook** for this repo: full environment contract, verification rules, the model-tiering/delegation protocol, and detailed bd usage. It wins on any conflict with this file.

## Binding rules

- Use `bd` (beads) for **all** task tracking — `bd ready` for unblocked work, `bd show <id>` for details, `bd update <id> --claim` to claim, `bd close <id>` to complete. Never use TodoWrite, TaskCreate, or markdown TODO lists.
- **Never assign a bead to a human, directly or indirectly** — no human assignee, no "review this"/"decide X"/"run Y" bead text, no blocked-on-a-person dependency or gate/label. If a human decision is genuinely needed, ask in chat instead, only after exhausting your own options.
- Use `bd remember` for persistent knowledge, not MEMORY.md files.
- Work the branch already checked out, including `main` — never create or switch branches on your own initiative.
- Commit locally at the end of every session; that local commit is mandatory. Push (`git push`, `bd dolt push`) is opt-in only — run it only when explicitly asked, in that moment.
- Run `bd prime` for the full command reference and session-close protocol.

See CLAUDE.md for everything else this file omits.
