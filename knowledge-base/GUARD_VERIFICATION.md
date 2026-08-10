# Guard and Data-Safety Verification

When to use: you have a pattern-matching guard (like `bd-guard`) or a script
with a destructive recovery step (like an entrypoint's database rebuild) and
need to know whether it actually holds up, not just whether its test suite is
green. This is a method, not a one-off report — it transfers to the next
guard or destructive-path review, whatever script it lives in.

## The core loop: build, mutate, confirm red

A green suite is not evidence a pattern-matching guard or a destructive-path
gate works. `bd-guard` went through four independent adversarial verifier
rounds in one session; every round found a live, exploitable bypass while the
suite was 100% green, climbing from 39 to 161 tests as each round's bypass
shape was patched (see `bd memories verifying-a-pattern-matching-guard-a-green-test`).

The only thing that settles whether an assertion is load-bearing:

1. Copy the script to a scratch path (never edit the guarded script itself
   for this).
2. Revert the ONE mechanism the assertion claims to guard — nothing else.
3. Re-run the assertion against the mutated copy.
4. It must go **red**. If it stays green, the assertion is not testing what
   you think it is — fix or delete it before relying on it.

```bash
cp scripts/some-guard.sh /tmp/mutant.sh
# hand-edit /tmp/mutant.sh to remove/invert the one mechanism under test
bash -c 'source /tmp/mutant.sh; <drive the same input the real test drives>'
# expect: the check that was passing now fails
```

Do this for every assertion you're about to trust, not just the ones you
wrote. An assertion nobody has mutation-tested is an assertion nobody has
verified.

## Settling a shell or quoting question: never by argument

Shell-quoting and word-splitting intuitions have been wrong four times in
this codebase, in four different directions, and every one was caught only
by running the real thing (full detail: `bd memories
shell-quoting-intuitions-have-been-wrong-three-times` — **the key name is
stale, the content is current**: it now documents FOUR failures, not three,
including a zsh-vs-bash word-splitting difference found 2026-08-10).

The method that actually settles these questions:

1. Put a fake binary on `PATH` that only logs its own argv.
2. Drive the candidate string/heredoc/quoting through a **real shell**
   (`bash -c`, an actual heredoc) — not through reasoning about the text.
3. Read the log to see which inner commands really executed.

```bash
mkdir -p /tmp/fakebin
cat > /tmp/fakebin/bd <<'EOF'
#!/usr/bin/env bash
echo "FAKE-BD-CALLED: $*" >> "$BD_LOG"
EOF
chmod +x /tmp/fakebin/bd

export BD_LOG=/tmp/bd-via-bash.log; : > "$BD_LOG"
PATH="/tmp/fakebin:$PATH" bash <<'PAYLOAD'
bd status --json
PAYLOAD
cat "$BD_LOG"   # → FAKE-BD-CALLED: status --json
```

Verified in this container 2026-08-10: the quoted-delimiter heredoc piped
into `bash` invokes the fake binary; the identical body piped into `cat`
instead leaves the log empty. A quoted heredoc delimiter suppresses
expansion *inside* the body, but says nothing about whether the *consumer*
executes that body — `bash` does, `cat` does not. Same finding, independently
recorded: `bd memories verifying-bd-guard-never-prove-a-bypass-is`.

The interactive shell in this container is zsh, which does not word-split
unquoted parameter expansions the way bash does:

```bash
zsh  -c 'ids="1 2 3"; set -- $ids; echo $#'   # → 1
bash -c 'ids="1 2 3"; set -- $ids; echo $#'   # → 3
```

Verified in this container 2026-08-10. When feeding a captured list to a
command from an interactive zsh session, loop explicitly or use `${=ids}` —
do not assume splitting happens.

## Building a fixture that isn't self-healing

A fixture built using the tool's own "healthy" commands can be repaired by
those same commands while you're still constructing the corruption, so it
never reaches the state you meant to test. `bd`-built fixtures are the
concrete case: the `bd` commands used to build a corrupted database heal it
mid-construction.

Rule: construct the corrupted state with a lower-level primitive the tool
doesn't self-heal through — direct `dolt sql` statements against a **copy**
of the embedded database, never `bd` commands, and never the live tracker's
own `.beads/`:

```bash
cp -r /workspace/.beads/embeddeddolt /tmp/fixture-dolt   # work on the COPY only
cd /tmp/fixture-dolt/beads_claude_docker                 # dolt commands run from INSIDE the db dir
dolt sql -q "select count(*) from issues"                # read; the same shape mutates the copy directly
```

Verified against a real copy in this container 2026-08-10 — `command -v
dolt` → `/usr/local/bin/dolt`, `dolt version` → `dolt version 2.0.5`
(current here; check the same command rather than trusting this number as
pinned), and the query above returned a real row count (114) with `rc=0`.
The database lives one level down, inside a subdirectory named after the
project's issue prefix (`beads_claude_docker` here) — but dolt auto-discovers
a database up to one level below the current directory, so the same query
also succeeds run from `embeddeddolt/` itself, with `select database()`
there confirming it auto-selected `beads_claude_docker`; it errors `no
database selected` only from `.beads/` or any directory above it. Depth
probe, re-verified 2026-08-10 on a fresh copy never `cd`'d into:

```bash
( cd /tmp/fixture-dolt/beads_claude_docker && dolt sql -q "select count(*) from issues" >/dev/null 2>&1; echo "db dir: rc=$?" )
( cd /tmp/fixture-dolt                      && dolt sql -q "select count(*) from issues" >/dev/null 2>&1; echo "embeddeddolt/: rc=$?" )
( cd /tmp/fixture-dolt/..                   && dolt sql -q "select count(*) from issues" >/dev/null 2>&1; echo ".beads/-equivalent: rc=$?" )
```
→ `db dir: rc=0`, `embeddeddolt/: rc=0`, `.beads/-equivalent: rc=1` (`no
database selected`).

Source for the self-healing finding: `git log -1 --format=%B b7299b3`, grep
for `"direct dolt statements"`.

**Related trap:** don't backdate a fixture's export-state file to force a
"stale export" condition. `bd`'s own throttled auto-export can refresh the
export before your escalation path is reached, masking exactly the
staleness you meant to test — drive the real timing (or shim the exporting
command) instead of faking the clock. Source: `git log -1 --format=%B
aa641fd`, grep for `"methodology trap"`. Adjacent trap when repairing rather
than corrupting a fixture: `bd init --reinit-local` deletes the very jsonl
export you might need to rebuild from (`bd memories
bd-embedded-dolt-mode-bd-doctor-fix-yes`; full recovery recipe in
`BEADS_TROUBLESHOOTING.md`).

## The vacuity taxonomy: three ways a passing check proves nothing

Classify every green assertion on a guard or destructive path against these
three shapes before trusting it. All three are caught the same way — mutate
the mechanism and confirm red — but each fails that test for a different
reason, so it helps to know which one you're looking for.

**Setup-vacuous** — the test's own setup breaks before it reaches the code
under test. Example: a `PATH=/nonexistent` prefix meant to force a fail-open
path instead broke the `jq` call that built the test's *own input*, so the
test silently exercised an empty-stdin path rather than the fail-open
behavior it claimed to check. Full detail and two more instances of this
shape: `bd memories verifying-a-pattern-matching-guard-a-green-test`.

**Outcome-vacuous** — the fixture makes the guarded *failure physically
impossible*, so the check passes no matter whether the guard mechanism
works. Concrete case: testing a "both safety copies impossible" bail-out
with a fully read-only `.beads/` — `bd` could not have deleted the export
there even with the bail-out removed, so the pass proved nothing about the
bail-out itself. Fix: block only the specific copy tiers the bail-out
depends on (e.g. a read-only `TMPDIR` for tier one, a pre-existing
unwritable backup file for tier two) while leaving the directory the
destructive command would actually write to still writable, so the bad
outcome stays physically possible and the bail-out is genuinely what
prevents it. Recorded 2026-08-10: `bd show beads_claude_docker-bk0`, grep
for `"outcome-vacuous"`.
Test for this shape: with the guard mechanism reverted, does the bad outcome
actually happen? If reverting the guard still passes, the fixture proves
nothing about the guard.

**Shadowed** — an assertion looks unkillable only because an *earlier*
assertion in the same test body fails first, halting the test before it
ever reaches the one you're evaluating. To classify an assertion honestly,
temporarily neutralize every assertion that precedes it in the same test,
then re-run the mutation against the one you actually care about. (Design
rule from this session, 2026-08-10 — no independent command re-derives this
fact in this container; the fixtures involved no longer exist in this
shape. Treat it as a standing check, not a re-run-able figure.)

## Gating a destructive step on its protective captures

Invariant: a destructive step (`rm -rf`, a database rebuild) may run only
when every protective capture it depends on has **demonstrably succeeded** —
not merely been attempted. Source: `git log -1 --format=%B aa641fd`, grep
for `"The invariant:"`.

This exact invariant was violated five separate times in a single recovery
function before it was applied uniformly: an ungated capture with no success
check, an adoption copy wrapped in `|| true` that let destruction proceed
after a silent failure, and cleanup steps that deleted the last safety net
unconditionally instead of gating on the restore having actually landed.
Source: same commit, plus `git log -1 --format=%B 80add07`.

Two sharp edges that make this kind of gate easy to get wrong even when you
know the rule:

**`|| true` swallows more than the one failure you meant to tolerate.**
Attached to a compound command, it discards *every* `set -e` abort inside
that command, not just the specific failure path you had in mind:

```bash
bash -c 'set -e; ( false; echo "unreachable" ) || true; echo "reached anyway: exit=$?"'
# → unreachable
#   reached anyway: exit=0
```

Verified in this container 2026-08-10. If a destructive step is gated on a
capture command's exit status, and that capture is wrapped in `|| true`
anywhere upstream, the gate observes success even when the capture aborted
partway through. Rule: before trusting a clean ("no abort") run through any
such harness, run a **positive control** — inject a bare `false` at the
exact point you expect an abort and confirm the harness actually reports it.
A harness that can't fail loud can't be trusted to pass quiet.

**Instrumentation itself can be the leak.** A diagnostic call made purely to
*report* status can trigger the tool's real side effects. In this session, a
verifier's own read of an issue-prefix value ran real `bd`, whose throttled
auto-export deleted a fixture's `issues.jsonl` as a side effect — silently
invalidating the state under test before the code being verified was ever
reached, and producing a result that looked like a clean pass. (Design rule
from this session, 2026-08-10 — no independent command re-derives the
specific incident here. Standing check: before trusting a diagnostic or
logging call inside a test or verifier, confirm it cannot itself mutate the
fixture — especially anything touching the same throttled-export mechanism
the code under test also touches.)

## Measure protection structurally, not just by outcome

A concurrency guard — an `flock`-guarded lock file is the concrete case
here — can be structurally absent while every observed run still looks
protected, because the loss it prevents may itself be rare. Count the
mechanism directly — distinct lock paths taken, and observed contention
skips — rather than trusting a clean loss rate alone. `flock` only excludes
concurrent holders of the *same path*; the failure mode below is a lock
whose path is never the same twice.

```bash
for i in 1 2 3; do mktemp -u /tmp/lock.XXXXXX; done
# → three DIFFERENT paths: a mktemp-named lock can never contend with itself
for i in 1 2 3; do echo "/tmp/lock.$(echo -n fixed-input | md5sum | cut -c1-8)"; done
# → the SAME path three times: only a deterministic name can serialize contenders
```

Verified in this container 2026-08-10 (three distinct suffixes vs. one
stable hash each run). In the driven case that surfaced this, 30 iterations
of a 5-way concurrent invocation, the deterministic lock name produced 1
lock path and exactly 4 contention skips every single time; the
`mktemp`-named lock produced 5 lock paths and 0 skips — mutual exclusion
structurally absent despite outcomes that, on a smaller run, could easily
have looked fine. Recorded 2026-08-10: `bd show beads_claude_docker-8zo`,
grep for `"contention-skips"` — this is the record of what that session
measured, not something re-derived independently here.

A related placement rule surfaced in the same fixture: a guard's own
lock/lease file must live somewhere the guarded operation can *already*
write, or the guard breaks exactly the environment it exists to protect. A
lock placed in a directory the guarded repair does not itself need to write
made an otherwise-fine read-only environment skip a repair that would
otherwise have succeeded. Recorded 2026-08-10: `bd show
beads_claude_docker-8zo`, grep for `"REGRESSION CAUGHT IN VERIFICATION"`.
When the guard is an optimization (avoiding a race) rather than the point of
the operation, degrade gracefully — fall back to another writable location,
and if none exists, proceed unprotected and log it, rather than bailing out
and blocking work the environment would otherwise support.

## Drive the fixture before accepting any argument

A plausible-sounding argument about where a guard should sit, or whether a
path is reachable, is not evidence — build the fixture and drive it, even
when the argument comes from a stronger reviewer. Concrete case: a
suggestion to place a symlink guard at the destructive call site (reasoning:
the read-only/healthy path is a no-op, so checking later is safe) was
refuted by actually driving a symlinked target through a plain read-only
status call — that call alone misreported the record count and silently
created a stray new database at the symlink target's parent, so the
"safe no-op" premise was false and the guard had to move before the
*first* call touching the resource, not the destructive one. Recorded
2026-08-10: `bd show beads_claude_docker-8zo`, grep for `"Symlinked
embeddeddolt"`.

(That the same suggestion was raised and refuted more than once before it
stuck is a session-internal detail with no independent command to re-derive
here. The transferable rule is the one above, not the anecdote: one driven
fixture outranks any number of rounds of plausible argument.)

## What never to do

- **Never prove a bypass is live against the real tracker.** Doing so once
  created two real records assigned to a person, found and cleaned up later
  by an unrelated audit. Use the fake-binary-on-`PATH` method above instead
  — it settles the same shell question without touching production state.
  `bd memories verifying-bd-guard-never-prove-a-bypass-is`.
- **Never backdate export/timestamp state to force a "stale" condition** —
  see the auto-export throttle trap above. Drive the real timing or shim the
  tool; don't fake the clock.
- **Never trust a list-based sweep without an explicit limit.** A
  status-filtered `bd list --json` truncates silently under its default row
  cap (50) unless `--limit` is set explicitly, and only a stderr line says
  so — a caller that only looks at stdout JSON sees a clean, under-counted
  array. Re-verified in this container 2026-08-10, read-only against the
  live tracker (a moving count — re-run the commands, don't trust these
  numbers as pinned):
  ```bash
  bd list --status closed --json >/tmp/c.json 2>/tmp/c.err
  python3 -c 'import json;print(len(json.load(open("/tmp/c.json"))))'; cat /tmp/c.err
  # → 50, plus stderr: "Showing 50 issues; more results matched but were
  #   hidden by --limit. Use --limit 0 for all, or --limit N to raise the cap."
  bd list --status closed --limit 500 --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'  # → 112
  bd list --status closed --limit 0   --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'  # → 112
  ```
  Cross-check against ground truth from inside a **copy** of the database
  (see the `cd .../beads_claude_docker` pattern above), never the live one:
  `select count(*) from issues where status='closed'` → 112, matching.
  **Nuance, not a universal rule:** the same check with `--all --json` and
  no explicit `--limit` returned all 114 issues (112 closed + 2 in_progress)
  uncapped in this same run — `--all` was not subject to the cap that
  `--status closed` was. Verify the cap against your own exact invocation
  rather than assuming it does or doesn't apply. `bd memories
  bd-list-default-row-cap-truncates-sweeps`.

## Cross-references

- `bd memories verifying-a-pattern-matching-guard-a-green-test` — why a
  green suite is not evidence; the setup-vacuous pattern in full.
- `bd memories shell-quoting-intuitions-have-been-wrong-three-times` — stale
  key name, four failure directions now documented, including zsh splitting.
- `bd memories verifying-bd-guard-never-prove-a-bypass-is` — the
  fake-binary method and the incident behind the "never against the real
  tracker" rule.
- `bd memories bd-embedded-dolt-mode-bd-doctor-fix-yes` — `bd doctor --fix`
  unsupported in embedded mode; `bd init --reinit-local` deletes the jsonl
  export. Full recovery recipe: `BEADS_TROUBLESHOOTING.md`.
- `bd memories bd-list-default-row-cap-truncates-sweeps` — pass an explicit
  `--limit`; cross-check against `dolt sql` ground truth on a copy.
- `LIVE_TESTING.md` — the bats rules this playbook assumes when a mutation
  test is wired into a regression suite: one assertion per line (`A && B`
  defeats `set -e`), and never `mktemp` your own scratch dir in a bats test.
- `HOOK_AUTHORING.md` — the sibling trap for hook fixtures: validate against
  real captured traffic, not an assumed schema, for the same
  vacuous-by-construction reason a self-healing fixture is vacuous here.
