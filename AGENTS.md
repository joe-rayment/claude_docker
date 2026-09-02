# Agent Instructions

Instructions for any coding agent — Codex, Aider, Cursor, plain Claude, etc. — working in this repo, including ones that never load Claude Code's own project config.

**[config/claude-user-memory.md](config/claude-user-memory.md) is the canonical rulebook**: sandbox vs. external systems, push/deploy, ownership, finishing a message, beads, lanes, delegation. Claude Code loads it as `~/.claude/CLAUDE.md`; other agents should read it directly at that repo path. **[CLAUDE.md](CLAUDE.md)** adds this repo's own facts (tools, config sync, tests, cleanup) on top of it. Either file wins on any conflict with something else.

## Binding rules

- Use `bd` (beads) for **all** task tracking — `bd ready`, `bd show <id>`, `bd update <id> --claim`, `bd close <id>`. Never TodoWrite, TaskCreate, or markdown TODO lists.
- Work the branch already checked out, including `main` — never create or switch branches on your own initiative.

See `config/claude-user-memory.md` for everything else, including push/commit policy and the no-human-assignment rule for beads.
