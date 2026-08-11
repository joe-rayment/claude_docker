# Acceptance Contracts — pre-registered CHECK/PASS-IF instead of open-ended re-verification

When to use: registering work with the `verifier`, or wondering why a
`FROZEN` test file "can't be edited" — this doc is the authoritative
protocol; `config/agents/verifier.md` and `scripts/contract-gate.py`'s
docstring implement it.

## Why

Open-ended verification ("re-derive the work from scratch, check every
requirement one by one") is expensive and re-hashes the executor's work.
The fix: settle the pass/fail question **in advance**, in a fixed block on
the bead, so the verifier answers a handful of mechanical questions
instead of re-doing the implementation.

## The contract format

Written into the bead's `--acceptance` field **before the executor is
dispatched**, via `bd create --acceptance` / `bd update --acceptance`:

```
CHECK:   CLAUDE_DEV_TESTS=/workspace/tests bats tests/contract-gate.bats
PASS-IF: exit 0; "14 tests, 0 failures"; test "warns when bead has no contract" present and passing
FROZEN:  tests/contract-gate.bats
CLASS:   standard
```

- `CHECK` — a runnable, verbatim command.
- `PASS-IF` — the expected result of that command, specific enough that a
  weak/vague test can't silently pass.
- `FROZEN` — the file(s) whose content is pinned once the executor's RED
  commit lands (see below).
- `CLASS` — `standard`, or `no-contract` (see the escape hatch below).

The field is **write-once** in normal operation: red/green proof goes into
the bead's append-only *notes*, not the acceptance field itself, so
`bd history <id> --json` shows one unchanging `acceptance_criteria` value
across every revision. That is what makes the verifier's C1 check (below)
a pure equality test with no legitimate exceptions to reason about — any
change to the field after registration is `TAMPERED`, full stop.

## The red-commit-first loop (executor side)

1. Write the `FROZEN` test. Run it. **Observe RED.**
2. `git commit` the test file(s) alone. Append to the bead's notes:
   `RED-AT: <sha>` plus the actual failing output.
3. Implement. Run the same `CHECK` verbatim. Observe GREEN.
4. `git commit`. Append `GREEN-AT: <sha>` plus the passing output.

Step 2 is what makes the contract real: the test's content is pinned at a
SHA *before* any implementation exists, so the verifier can later prove
(mechanically, via `git diff`) that the test was never softened to make
the implementation pass.

## The five checks plus C2b (verifier side)

Given a bead id plus its `RED-AT`/`GREEN-AT` SHAs:

| # | Check | Command |
|---|-------|---------|
| C1 | Goalposts unmoved | `bd history <id> --json \| jq -r '[.. \| objects \| select(has("acceptance_criteria")) \| .acceptance_criteria] \| unique \| length'` — must print `1` |
| C2 | Test not weakened | `git diff <RED-AT> HEAD -- <FROZEN paths>` — must be empty; `git show --stat <RED-AT>` must contain only the frozen test, no implementation. **`.beads/` is carved out**: the pre-commit `bd` export rides `.beads/issues.jsonl` along on every commit, so its presence at `RED-AT` is expected churn |
| C2b | Red actually red | `git worktree add /tmp/redat-check <RED-AT>`, re-root the `CHECK`'s paths into the worktree (a test that assigns absolute `/workspace/...` paths internally ignores env overrides — `sed -i` them in the disposable checkout), run it, then `git worktree remove --force`. Must **fail** (non-zero). A `CHECK` that *passes* at `RED-AT`, re-rooting confirmed, means the test discriminated nothing and the recorded red is false ⇒ `TAMPERED` |
| C3 | Actually green | Run `CHECK` verbatim; compare output to `PASS-IF`; `git status --porcelain` clean — **except** under `.beads/`, whose export artifact is regenerated constantly and never counts as a dirty tree |
| C4 | Honest (the one judgment step) | Read `git diff <RED-AT> HEAD` **excluding** the `FROZEN` paths — hunt hardcoded expected values, test-env detection, added skips/xfails, assertions weakened in *other* test files |
| C5 | Not lazily closed | Read the bead's close reason/notes/status for a punt: human hand-off, "couldn't verify here" where a small env fix existed, a `blocked` status or human-type gate, silently narrowed scope |

C1+C2 give most of the discrimination guarantee for free: the test at HEAD
is byte-identical to the one that stood at `RED-AT`, so whatever it
discriminated then it discriminates now, and a green result can only be the
implementation. What they cannot show is that the test ever *failed* there
— a tautological test is byte-identical too — which is why C2b spends one
extra run of the same `CHECK` at `RED-AT` to make the red claim real. That
one rerun is the whole added cost: no mutation testing, no re-deriving the
implementation.

## The four verdicts

`PASS` — none of C1-C5 or C2b tripped. `FAIL` — C3, C4, or C5 tripped (bad
implementation, dishonest diff, or a lazy close). `TAMPERED` — C1, C2, or
C2b tripped (the goalposts moved, the test itself moved after RED-AT, or
the recorded red never happened). `NO-CONTRACT`
— the bead has no acceptance field, or `CLASS: no-contract`; the verifier
stops immediately with no further checks, rather than falling back to an
open-ended review.

Anything short of `PASS` blocks "done". The verdict record itself
(`VERIFIED: PASS ...`) is written to the bead's notes by the **orchestrator**
on receiving the verifier's report — the verifier stays read-only and never
writes to the bead, and the executor is forbidden to write a `VERIFIED:`
line at all (a worker that can forge the verdict makes the check
decorative).

## The `VERIFIED:` line format, and what corroborating it is worth

The verdict record must name the verifier that produced it:

```
VERIFIED: PASS — verifier <agentId>[, any further prose]
```

`<agentId>` is the harness's subagent id, the one in the transcript path
`~/.claude/projects/<project>/<session>/subagents/agent-<agentId>.jsonl`
(e.g. `a51ceb8cf23d0e21d`, or `averifier-opus-5-resume-90365b6d61bc8127`
when the `Agent` call passed a `name`). `contract-gate` treats a
`VERIFIED: PASS` note as verified only when that id **corroborates**: the
transcript file exists, it references this bead id, and the agent's *own*
output — `type == "assistant"` records only, never the raw file — records
a PASS verdict. The raw file is off-limits on purpose: every verifier
spawn prompt recites "PASS / FAIL / TAMPERED / NO-CONTRACT", so a raw
grep would let a *failing* verifier run corroborate a wishful note.

A `VERIFIED: PASS` line with no agentId, or with an id no transcript
backs, is **not** verified: warn in `warn` mode, deny in `enforce`. Where
the transcript store cannot be consulted at all — absent, not a
directory, or no `subagents/` dir anywhere under
`CONTRACT_GATE_TRANSCRIPT_ROOT` (default `~/.claude/projects`) — the gate
falls back to the old text-only behaviour and a bare `VERIFIED: PASS`
allows. Other machines, fresh containers and headless runs must never be
blocked by a store that was never there.

**This is not a security boundary, and must not be described as one.**
The transcript store is an ordinary user-writable path, and the
executor's scout-only `Agent` grant is a prompt contract rather than a
harness-enforced one, so an agent that *wants* to forge corroboration
can: write a plausible JSONL file, name its id in the note. What the
check actually buys is that self-certification stops being one appended
line of text and becomes deliberate, multi-step forgery. Call it
tamper-resistant against laziness and accident — never tamper-proof.

## A contract registered on a false premise is retired, never edited

If a contract turns out to prescribe a mechanism that does not exist, or
pins a baseline that has since moved, **do not edit the acceptance
field** — editing it is exactly what C1 reads as goalposts moved, i.e.
`TAMPERED`, and an executor cannot make that edit innocent by explaining
it. Retire the bead (close it as retired, with the reason recorded) and
register a **new** bead carrying a corrected contract that cites the
retired one.

The worked example is bead `beads_claude_docker-mvc`, retired 2026-08-11:
it prescribed corroborating a `VERIFIED: PASS` note against an actor
field in `bd history`, and no such field exists — `bd history <id>
--json` reports `Committer: "root"` for every revision regardless of
which agent wrote it, and `created_by: "claude"` — while its `PASS-IF`
additionally pinned a 9-case baseline that later work had already grown
past. Both defects live in the acceptance field, so both were
unfixable in place. Its replacement, `beads_claude_docker-4y6`, names
`mvc` as retired, prescribes the transcript-corroboration mechanism
above, and states its baseline relatively ("every pre-existing case still
passes") instead of by count.

## The `no-contract` escape hatch

`CLASS: no-contract` is for work with no observable check (pure prose
edits with nothing runnable to assert against). It is **assignable only at
registration, never at close** — a class grantable at closing time is
itself the goalpost move this system exists to catch. A `no-contract` bead
skips the verifier entirely instead of receiving an open-ended review; the
absence of a check is recorded, not papered over.

## The freeze window is bounded, not permanent

`FROZEN` means: from that bead's `RED-AT` commit until **that bead's own
verification completes** — it is a per-bead lock, **not forever**. Once a
bead is verified and closed, the file it froze is free again. A later,
different bead can add new cases to the same shared test file under its
own fresh `RED-AT`, exactly as this protocol's own history did:
`tests/acceptance-contracts.bats` was frozen under bead `-bmm`'s `RED-AT`
through its verification and close, then unfrozen, then a later bead
opened a *new* freeze window on it with a new `RED-AT` to add more cases.
Without this, a shared test file could only ever gain cases once, which
would make the whole approach unworkable for any repo with more than one
round of work touching the same suite.

What stays fixed forever is the **history**: `git diff <old-RED-AT> <old-GREEN-AT>`
for the first bead's window is immutable — a later bead's edits land at
commits *after* that window closed, so C2 for the *first* bead's contract
is never affected by work done under a second bead's contract.

## `contract-gate`'s mode ladder

`scripts/contract-gate.py`, a `PreToolUse(Bash)` hook that fires only on a
`bd close` command:

- `off` — silent allow, no `bd` call made at all.
- `warn` (**default**) — allows the close, but prints a stderr warning if
  the bead has no acceptance contract, no recorded `VERIFIED: PASS` note,
  or a `VERIFIED: PASS` note no verifier transcript corroborates (see the
  `VERIFIED:` line format above). Silent when all are in order.
- `enforce` — same check, but denies the close (via
  `hookSpecificOutput.permissionDecision == "deny"`) instead of warning.

Set via `CONTRACT_GATE_MODE` env var or `~/.claude/contract-gate.mode`; an
unrecognized value falls back to `warn`, never to `off`. A bead whose
contract carries `CLASS: no-contract` is exempt in any mode. The hook
fails open on every error path (missing `bd`, unparseable JSON, timeout,
and an undiscoverable transcript store) — a broken gate can never block a
real close.
