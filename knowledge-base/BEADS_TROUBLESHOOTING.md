# Beads Troubleshooting

Beads (`bd`) runs in **embedded Dolt mode** — no SQL server. The live database is `/workspace/.beads/embeddeddolt/` (gitignored); `/workspace/.beads/issues.jsonl` is a passive, git-tracked export used to rebuild the database. Always modify issues via `bd` commands, never by editing the JSONL.

## Self-healing

`bd doctor --fix --yes` runs automatically at container entrypoint and on the welcome screen. Run it manually any time the database misbehaves:

```bash
cd /workspace && bd doctor --fix --yes
```

## Common issues

| Symptom | Fix |
|---------|-----|
| `bd` hangs an agent session | You ran `bd edit` — it opens `$EDITOR` and blocks. Use `bd update <id> --title/--description/--notes` instead |
| Database corrupt / weird errors | `bd doctor --fix --yes` — rebuilds from `issues.jsonl` if needed |
| Issues missing after teardown/resume | The embedded DB rebuilds from the restored `issues.jsonl` on first container start; run `bd list --status=open` to confirm |
| Priority rejected | Use `0-4` or `P0-P4`, not `high`/`medium`/`low` |
| Sync conflicts with remote | Sync uses `refs/dolt/data` on the git remote — see <https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md> |

## Rules worth remembering

- Beads track Claude Code's own work only — never assign a bead to a human (`--assignee` is off-limits for humans; the only valid claim is Claude's own `--claim`).
- Include issue IDs in commit messages: `Fix auth bug (bd-a3f2)`.
- `bd remember "insight"` stores persistent project knowledge; search with `bd memories <keyword>`.
