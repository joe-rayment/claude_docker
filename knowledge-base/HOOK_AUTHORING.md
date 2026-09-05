# Hook Authoring: Traps in PreToolUse/SessionStart Hooks

When to use: you're writing or debugging a Claude Code hook (`.claude/settings.json`
`hooks` entries — `PreToolUse`, `SessionStart`, etc.) in this sandbox and want
to avoid four traps that already cost real debugging time here.

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

## A literal single quote breaks an awk program embedded in single-quoted shell

`workflow-lint.sh` shells out to `awk '...'`, quoting the whole program with
single quotes. Its masking lexer needs to compare a character against
JavaScript's single-quote string delimiter — write that comparison as a
literal `'` anywhere inside the awk block and the *shell* closes its
quoting right there, not awk: everything after that point is reinterpreted
as shell syntax instead of text handed to awk. The fix is awk's octal
escape `"\047"` (see the `sq` state in `scripts/workflow-lint.sh`, where the
quote delimiter is compared against `"\047"`, never against a literal `'`).

This is not hypothetical: during this change an executor added an ordinary
code comment inside that same awk block containing the word "doesn't" — the
apostrophe alone was enough. Result: `Syntax error: "{" unexpected` at
`awk`-invocation time, and 27 failing `tests/tier-hooks.bats` cases.

**Rule:** inside an awk program embedded in a single-quoted shell string, no
apostrophe may appear *anywhere* — not just in string/regex literals meant
to represent `'`, but in ordinary awk comments and prose too. The shell's
lexer runs before awk ever sees the text, and it does not know or care that
the quote was "just a comment". Use `\047` for any single-quote character
the awk program itself needs, and avoid apostrophes in comments within the
block entirely (write "does not", not "doesn't").

## Char-by-char string accumulation in awk is quadratic under mawk

`workflow-lint.sh`'s masking lexer builds each masked output line one
character at a time in a loop: `out = out c`. Under mawk (this sandbox's
`awk`), repeated string concatenation like this is O(n^2) in the length of
a *single* line — measured here at ~118s for a ~3MB one-line script.
Ordinary hand-written scripts never hit this: the pathology needs one
enormous line, and multi-line scripts of any total size are unaffected
because each line stays short.

**Rule:** a scanner that rewrites or masks text char-by-char in awk needs
an input-size cap that bails out *before* the lexer runs — a line-count
bound does not help, because the pathology lives inside a single line, not
across many of them. `workflow-lint.sh`'s `WORKFLOW_LINT_MAX_BYTES`
(default 500000) is the worked example: above that many bytes the script
skips the lexer entirely and passes the input through unscanned (fail
open) rather than risk a multi-minute `PreToolUse` hook stall.
