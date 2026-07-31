# Hook Authoring: Traps in PreToolUse/SessionStart Hooks

When to use: you're writing or debugging a Claude Code hook (`.claude/settings.json`
`hooks` entries — `PreToolUse`, `SessionStart`, etc.) in this container and want
to avoid two traps that already cost real debugging time here.

## jq's object-construction shorthand null-fills absent keys

`jq`'s `{a, b, c}` shorthand (equivalent to `{a: .a, b: .b, c: .c}`) writes
`null` for a key that is **absent** from the input — indistinguishable in the
output from a key that is **present with value null**. If your hook logic
(or your debugging session) inspects a jq-shorthand summary instead of the
raw payload, "absent" and "present-but-null" collapse into the same thing.

```bash
echo '{"tool_name":"Bash"}' | jq '{tool_name, agent_id}'   # → {"tool_name":"Bash","agent_id":null}
```

That single line is the whole bug class: `agent_id` was never in the input,
but the summary makes it look like it was there and null. This turned "agent_id
is absent on main-loop hook payloads" into a false "present-but-null"
conclusion (delegation-gate, 2026-07-29) — and the synthetic test fixtures
built from that wrong conclusion then encoded the wrong payload shape.
**Incident record, not a re-checkable figure** (the fixtures have since
been fixed, so this can't be re-derived today): at the time, 12 of 12 tests
were green on a gate that never fired on real traffic.

**Rule:** when absence vs. null matters — and for hook payload schemas it
almost always does — check with `has("key")` or dump the raw JSON, never a
jq shorthand summary:

```bash
echo '{"tool_name":"Bash"}' | jq 'has("agent_id")'         # → false, unambiguous
```

**Rule:** validate hook fixtures against a payload actually captured from
real traffic (e.g. logged via `jq . >> /tmp/hook-capture.jsonl` inside the
hook during a live session), not one written from an assumed schema. A
green test suite built on an assumed fixture proves the hook matches its
own assumption, not that it fires on real input.

## Hook matcher scope and `updatedInput` contention

Multiple `PreToolUse` hooks can be registered against overlapping tool
matchers, and more than one can return `hookSpecificOutput.updatedInput`
for the same call. **Absence-of-documentation claim, not a measured one:**
Claude Code's own docs do not state a merge order across hooks for this
case — there is no command that verifies an undocumented behavior, so
don't expect one here. Before widening any hook's matcher, check what else
is already registered against tools it would now overlap with.

Concretely in this repo: `bd-guard`'s matcher is `Bash` only (verified
2026-07-31, `grep -n -A6 '"matcher": "Bash"' config/claude-settings.json`
shows the `bd-guard` command four lines after the matcher line), which is why it never
contends with the tier hooks (`tier-gate`, `workflow-lint`, ...) that are
matched against `Agent`/`Workflow` — those two hook groups never fire on
the same tool call, so `updatedInput` contention is moot today. (What
`bd-guard` itself enforces is documented in `CLAUDE.md`, not repeated
here — this entry is only the matcher-scope caveat.) If a future change
ever widens `bd-guard`'s matcher to include `Agent` or `Workflow`, re-check
for `updatedInput` contention with the tier hooks before shipping it.
