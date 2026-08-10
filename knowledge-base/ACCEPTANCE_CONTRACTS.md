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

## The five checks (verifier side)

Given a bead id plus its `RED-AT`/`GREEN-AT` SHAs:

| # | Check | Command |
|---|-------|---------|
| C1 | Goalposts unmoved | `bd history <id> --json \| jq -r '[.. \| objects \| select(has("acceptance_criteria")) \| .acceptance_criteria] \| unique \| length'` — must print `1` |
| C2 | Test not weakened | `git diff <RED-AT> HEAD -- <FROZEN paths>` — must be empty; `git show --stat <RED-AT>` must contain only the frozen test, no implementation |
| C3 | Actually green | Run `CHECK` verbatim; compare output to `PASS-IF`; `git status --porcelain` clean |
| C4 | Honest (the one judgment step) | Read `git diff <RED-AT> HEAD` **excluding** the `FROZEN` paths — hunt hardcoded expected values, test-env detection, added skips/xfails, assertions weakened in *other* test files |
| C5 | Not lazily closed | Read the bead's close reason/notes/status for a punt: human hand-off, "couldn't verify here" where a small env fix existed, a `blocked` status or human-type gate, silently narrowed scope |

C1+C2 give the discrimination guarantee for free: the test failed at
`RED-AT` and C2 proves it is byte-identical at HEAD, so a green result now
can only be the implementation — no mutation testing, no revert-and-rerun
needed.

## The four verdicts

`PASS` — none of C1-C5 tripped. `FAIL` — C3, C4, or C5 tripped (bad
implementation, dishonest diff, or a lazy close). `TAMPERED` — C1 or C2
tripped (the goalposts or the test itself moved after RED-AT). `NO-CONTRACT`
— the bead has no acceptance field, or `CLASS: no-contract`; the verifier
stops immediately with no further checks, rather than falling back to an
open-ended review.

Anything short of `PASS` blocks "done". The verdict record itself
(`VERIFIED: PASS ...`) is written to the bead's notes by the **orchestrator**
on receiving the verifier's report — the verifier stays read-only and never
writes to the bead.

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
  the bead has no acceptance contract or no recorded `VERIFIED: PASS`
  note. Silent when both are present.
- `enforce` — same check, but denies the close (via
  `hookSpecificOutput.permissionDecision == "deny"`) instead of warning.

Set via `CONTRACT_GATE_MODE` env var or `~/.claude/contract-gate.mode`; an
unrecognized value falls back to `warn`, never to `off`. A bead whose
contract carries `CLASS: no-contract` is exempt in any mode. The hook
fails open on every error path (missing `bd`, unparseable JSON, timeout) —
a broken gate can never block a real close.
