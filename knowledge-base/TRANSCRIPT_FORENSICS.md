# Transcript Forensics: Reading Claude Code's Own Session Data

When to use: you need to verify which model an agent actually ran on,
attribute spend to a role (orchestrator/executor/scout/verifier), or write
anything that totals tokens or dollars from Claude Code transcripts (e.g.
extending `cost-mirror.py`/`tier-cost`).

## Safety rule — read this first

**Never `Read`/`cat`/`head` a transcript `.jsonl` file.** They reach 2.4 MB+
and will blow out the context of whoever opens one. Always go through
`jq`/`grep` aggregates that print a summary, not the raw rows. The
`.meta.json` sidecars are small (under 1 KB) and safe to `Read` directly.

## Layout

```
~/.claude/projects/<proj>/<session-id>.jsonl                                    # main-loop records only
~/.claude/projects/<proj>/<session-id>/subagents/agent-<ID>.jsonl               # one subagent transcript
~/.claude/projects/<proj>/<session-id>/subagents/agent-<ID>.meta.json           # that subagent's role sidecar
~/.claude/projects/<proj>/<session-id>/subagents/workflows/<wf_id>/agent-*.jsonl  # workflow-spawned agents — ONE LEVEL DEEPER
```

The workflows nesting is easy to miss: a glob like `subagents/agent-*.jsonl`
silently omits every workflow-spawned agent (this was a real defect in
`cost-mirror.py`). The invariant, not a fixed count: the two-level glob's
count minus the single-level glob's count always equals the number of
workflow-spawned agent transcripts exactly — never zero once a workflow
has run, and it grows every time this session spawns another one (so
re-running this same check five minutes apart gives different absolute
numbers on purpose). Verified in this sandbox 2026-07-31, current
session (`5ed92c0b-412c-4e90-a03f-341226559e01`):

Resolve `<session-id>` first — inside a running session it's the
`CLAUDE_CODE_SESSION_ID` env var; from a plain shell (or for a past
session), the most recently modified transcript is a good default:

```bash
echo "$CLAUDE_CODE_SESSION_ID"                                        # inside a running session
ls -t ~/.claude/projects/-workspace/*.jsonl | head -1                 # fallback: most recent transcript
```

```bash
DIR=~/.claude/projects/-workspace/<session-id>
single=$(ls "$DIR/subagents"/agent-*.jsonl 2>/dev/null | wc -l)                        # WRONG: misses workflow agents
correct=$({ ls "$DIR/subagents"/agent-*.jsonl 2>/dev/null; ls "$DIR/subagents/workflows"/*/agent-*.jsonl 2>/dev/null; } | wc -l)  # correct
wf=$(ls "$DIR/subagents/workflows"/*/agent-*.jsonl 2>/dev/null | wc -l)
echo "single=$single correct=$correct diff=$((correct-single)) workflow-only=$wf"      # diff must equal workflow-only
```

Main transcripts carry zero subagent rows — spend for subagents lives only
under `subagents/`. This is a hard zero, not a count that drifts: however
long the main transcript has grown by the time you check, verified
2026-07-31 on the same session, still zero:

```bash
grep -c '"isSidechain":true' ~/.claude/projects/-workspace/<session-id>.jsonl   # → 0, regardless of `wc -l` on the same file
```

## Verifying which model an agent actually ran on

Frontmatter (`model:` in an agent's `.md`) and settings are only *intent* —
a spawn can fail over to a different model, or a hook can rewrite it before
spawn. `.message.model` inside the subagent's own transcript is ground
truth:

```bash
jq -r '.message.model // empty' "$DIR/subagents/agent-<ID>.jsonl" | sort -u
```

Verified 2026-07-31: an executor-role transcript in this session reports
`claude-sonnet-5` on every row, matching its frontmatter binding.

## Role attribution — read the sidecar, use the right field

For a **named** spawn (`Agent({ name: "foo", subagent_type: "executor" })`),
the `.meta.json` sidecar puts the spawn's *name* in `agentType` and the
true role in `customAgentType`. Real example from this session's sidecars:

```json
{"agentType":"contract-edits","customAgentType":"executor", ...}
```

Reading `agentType` alone yields the name (`contract-edits`), not the role
— junk for any role-based rollup. The correct read is
`(.customAgentType // .agentType)` — falls back to `agentType` when
`customAgentType` is absent, which is the normal case for an **unnamed**
spawn (there `agentType` already holds the true role, e.g. `scout`, and no
`customAgentType` key exists at all). Missing sidecar entirely → fall back
to a neutral label, never guess the role from the transcript filename.

```bash
for f in "$DIR/subagents"/agent-*.meta.json; do
  jq -r '"\(.agentType // "MISSING")\t\(.customAgentType // "-")"' "$f"
done
```

Verified 2026-07-31 against this session's sidecars — unnamed spawns show
`scout` / `-` (no `customAgentType` key), named spawns show the name in
column 1 and the real role (`executor`) in column 2.

The undercount is a live, reproducible, dated fact, not just a war story
— but, like the group counts above, the total sidecar count moves every
session (127 when first measured 2026-07-31, already 128 an hour later).
Verified 2026-07-31 across every sidecar on this machine:

```bash
find ~/.claude/projects -path '*subagents*agent-*.meta.json' -exec jq -r '.agentType // "MISSING"' {} + | sort | uniq -c | sort -rn
find ~/.claude/projects -path '*subagents*agent-*.meta.json' -exec jq -r '.customAgentType // .agentType // "MISSING"' {} + | sort | uniq -c | sort -rn
```

`agentType` alone: `verifier` 13, `executor` 16, `scout` 37, plus 34
named-spawn/built-in singletons (`contract-edits`, `kb-bake`, `benchbase`,
`general-purpose`, ...) each counted once under their own name instead of
a role.
`(.customAgentType // .agentType)`: `verifier` 26, `executor` 31, `scout`
39 — every named spawn folds into its real role. `workflow-subagent`
stays at 25 either way (those sidecars have no `customAgentType`, so
`agentType` is already the true role). Re-run the two commands above to
get the current split; it moves every session.

## Counting tokens — the part that must be exactly right

One API response is written to the transcript as **several assistant rows
sharing one `.message.id`** — one row per content block (thinking / text /
tool_use). The correct reduction is **not** "take one row"; it differs per
field:

- `input_tokens`, `cache_read_input_tokens`, and both `cache_creation`
  members (`ephemeral_5m_input_tokens`, `ephemeral_1h_input_tokens`) are
  **identical on every row of the group — take one value.** The invariant
  (not the group count, which grows every session): **zero mismatches**
  on `input_tokens` or `cache_read_input_tokens` within any group, always.
  Verified 2026-07-31 across every subagent transcript on this machine —
  the command below reproduces this; re-run it for today's group counts,
  they move every session and were already different an hour apart while
  writing this doc.
- `output_tokens` is **cumulative across the group — take the maximum**
  (equivalently, the last row). The invariants, verified 2026-07-31 and
  stable across re-runs even though the underlying group counts aren't:
  the last row's value always equals the group max, there is never a
  decreasing step within a group, and roughly 86% of multi-row groups
  have *varying* `output_tokens` across their rows — meaning "take the
  first row" is wrong on the majority of groups, not an edge case. A real
  9-row group observed 2026-07-31 reads `5,5,5,5,5,5,5,5,743`.
- Group *row count* (max observed on this machine: 11) doesn't drive ring
  capacity — `_dedup_note` stores one running-max entry per distinct
  `message.id`, updated in place, not one entry per row, so a single slot
  covers a group of any size. `DEDUP_RING = 8` in `scripts/cost-mirror.py`
  (grep `_dedup_note`) instead caps how many *recent distinct groups*
  stay remembered before the oldest is evicted, giving slack for a scan
  boundary landing near more than one just-finished group. Don't read
  "8 < 11" as under-provisioned — the two numbers aren't measuring the
  same thing. What actually matters: this per-group state **must persist
  across incremental-scan boundaries**, or a group that straddles a
  resume point gets double-counted.

Reproduce the whole measurement — scoped to every subagent transcript on
this machine (all project dirs under `~/.claude/projects`, matching "on
this machine" above, not just the current project) — with:

```bash
for f in $(find ~/.claude/projects -path '*subagents*agent-*.jsonl'); do
  jq -r 'select(.message.id and .message.usage) |
    [.message.id, (.message.usage.output_tokens // 0),
     (.message.usage.input_tokens // 0), (.message.usage.cache_read_input_tokens // 0)] | @tsv' "$f"
done > /tmp/groups.tsv
awk -F'\t' '
{ id=$1; out=$2+0; in_=$3+0; cr=$4+0; n[id]++;
  if (n[id]==1) { inf[id]=in_; crf[id]=cr; mx[id]=out }
  else { if (in_!=inf[id]) inmm[id]=1; if (cr!=crf[id]) crmm[id]=1; if (out>mx[id]) mx[id]=out;
         if (out<prev[id]) dec[id]=1 }
  prev[id]=out; last[id]=out }
END { for (id in n) { total++; if (n[id]>1) { multi++;
        if (last[id]!=mx[id]) lastmm++; if (id in dec) decc++;
        if (id in inmm) inm++; if (id in crmm) crm++ } }
      print "total groups:", total, " multi-row:", multi;
      print "input/cache mismatches within a group:", inm+0, "/", crm+0, " (want 0/0)";
      print "last != max:", lastmm+0, " decreasing steps:", decc+0, " (want 0/0)" }
' /tmp/groups.tsv
```

**Both failure directions are live traps.** Summing every row overstates
`input`/`cache` by the row count — verified 2026-07-31, same scope, that
inflates raw `input_tokens` ~2.3x and `cache_read_input_tokens` ~2.0x
machine-wide (cache tokens dominate the bill, so this is close to the
dollar-inflation factor too). Like the group counts above, the exact
multiplier drifts as the transcript corpus rotates — re-run the command
above with `in_`/`cr` summed per-group vs. taken-once (`inf`/`crf` in the
script) to get today's ratio; the *direction and rough order of
magnitude* (roughly double, not roughly equal) is the stable fact. Taking
only the *first* row of a group instead understates `output_tokens`
badly — 5 instead of 743 in the example above. `scripts/cost-mirror.py`
(grep `_dedup_note`) is the worked, currently correct implementation.

## Model-selection mechanics

Three distinct surfaces exist; conflating them is the trap.

- **The `Agent` tool's `model` parameter accepts family aliases only** —
  `sonnet` / `opus` / `haiku` / `fable`. A concrete id (e.g.
  `claude-sonnet-5`) fails the tool's input validation. This is why
  `tier-gate.sh` maps a worker id to its alias before injecting it (grep
  `Map the worker id to its alias` in `scripts/tier-gate.sh`).
- **Agent frontmatter accepts concrete ids.** Verified 2026-07-31:
  `~/.claude/agents/executor.md` carries `model: claude-sonnet-5` and
  `~/.claude/agents/scout.md` carries `model: claude-haiku-4-5-20251001`
  (`grep '^model:' ~/.claude/agents/{executor,scout}.md`), and both agents
  run successfully under those bindings.
- **Workflow spawn options accept concrete ids too.** Verified 2026-07-31
  over this session's *workflow*-spawned sidecars specifically (not the
  top-level `subagents/` ones — those are separate, named `Agent` spawns):
  `subagents/workflows/*/agent-*.meta.json`, 18 sidecars, 9 carrying
  `claude-opus-5` and 9 carrying `claude-sonnet-5`.

  ```bash
  find "$DIR/subagents/workflows" -name 'agent-*.meta.json' -exec jq -r '.model // "MISSING"' {} + | sort | uniq -c
  ```

Separately: `PreToolUse` fires on `tool_name == "Agent"` — including calls
made from inside a subagent — and its `updatedInput` can deterministically
set a spawn's model before it starts (this is exactly what `tier-gate.sh`
does: the hook is registered against matcher `"Agent"` in
`grep -n '"matcher": "Agent"' config/claude-settings.json`, and the
`updatedInput` rewrite itself is in `grep -n updatedInput
scripts/tier-gate.sh`). **Not independently testable from inside this
sandbox** (there's no way to enumerate Claude Code's hook event set from
a session, only to observe the ones already wired into this repo's
`config/claude-settings.json`): `SubagentStart` is believed to fire too
late to set a model, and there is believed to be no `PreAgentSpawn` hook
event. Treat both as unverified until checked against Claude Code's own
hook documentation or changelog, not as measured facts of this repo.
