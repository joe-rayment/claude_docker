#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# acceptance-contracts.bats — asserts clauses (a)-(g), (i), (k), (m)-(o) of
# beads_claude_docker-bmm/-ifd/-lhf's acceptance contracts: that verifier.md,
# bead-auditor.md, and executor.md carry the five contract checks (C1-C5,
# plus C2b) and the red-commit-first executor loop, still true of this
# repo's own config/agents/*.md.
#
# S7 port (claude-orca-3sk.7) drops four cases that named old-template
# documents/behaviour this repo doesn't have:
#   (h) a CLAUDE.md '## Acceptance Contracts' section -- this repo's own
#       CLAUDE.md is a beads-workflow doc with a different structure; S11
#       (docs) is where a rulebook-facing companion doc would land, if ever.
#   (j),(p) knowledge-base/ACCEPTANCE_CONTRACTS.md + README.md -- the
#       knowledge-base/ isn't ported yet (S11's job per the epic plan).
#   (l) tier-prime.sh's old --full flag/TIER_PRIME_LANE env var -- S4
#       (claude-orca-3sk.4) redesigned tier-prime.sh around tier.json
#       instead of agent frontmatter; it has no --full mode, and its own
#       current interface is covered by tests/tier-hooks.bats (FROZEN).
# (a)-(g), (i), (k), (m)-(o) are otherwise unmodified from the old suite.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VERIFIER="$REPO_ROOT/config/agents/verifier.md"
AUDITOR="$REPO_ROOT/config/agents/bead-auditor.md"
EXECUTOR="$REPO_ROOT/config/agents/executor.md"

# (a) verifier.md no longer contains the re-derivation-stance language.
@test "(a) verifier.md drops 'from scratch', 'not a boundary', 'one by one', 'Fix plan', 'Root cause'" {
    run grep -F "from scratch" "$VERIFIER"
    [ "$status" -ne 0 ]

    run grep -F "not a boundary" "$VERIFIER"
    [ "$status" -ne 0 ]

    run grep -F "one by one" "$VERIFIER"
    [ "$status" -ne 0 ]

    run grep -F "Fix plan" "$VERIFIER"
    [ "$status" -ne 0 ]

    run grep -F "Root cause" "$VERIFIER"
    [ "$status" -ne 0 ]
}

# (b) verifier.md frontmatter carries 'effort: low' AND 'model: inherit'.
@test "(b) verifier.md frontmatter has effort: low and model: inherit" {
    run grep -F "effort: low" "$VERIFIER"
    [ "$status" -eq 0 ]

    run grep -F "model: inherit" "$VERIFIER"
    [ "$status" -eq 0 ]
}

# (c) verifier.md names all five checks C1-C5 and the four verdicts.
@test "(c) verifier.md names checks C1-C5 and verdicts PASS/FAIL/TAMPERED/NO-CONTRACT" {
    for check in C1 C2 C3 C4 C5; do
        run grep -F "$check" "$VERIFIER"
        [ "$status" -eq 0 ]
    done

    for verdict in PASS FAIL TAMPERED NO-CONTRACT; do
        run grep -Fw "$verdict" "$VERIFIER"
        [ "$status" -eq 0 ]
    done
}

# (d) verifier.md still contains the git status --porcelain check.
@test "(d) verifier.md still contains 'git status --porcelain'" {
    run grep -F "git status --porcelain" "$VERIFIER"
    [ "$status" -eq 0 ]
}

# (e) bead-auditor.md references 'bd history' and no longer instructs
# re-running every verification itself.
@test "(e) bead-auditor.md references bd history and drops 'run the verification yourself'" {
    run grep -F "bd history" "$AUDITOR"
    [ "$status" -eq 0 ]

    run grep -Fi "run the verification yourself" "$AUDITOR"
    [ "$status" -ne 0 ]
}

# (f) executor.md documents the red-commit-first loop and the FROZEN
# prohibition.
@test "(f) executor.md documents RED-AT/GREEN-AT loop and FROZEN prohibition" {
    run grep -F "RED-AT" "$EXECUTOR"
    [ "$status" -eq 0 ]

    run grep -F "GREEN-AT" "$EXECUTOR"
    [ "$status" -eq 0 ]

    run grep -F "FROZEN" "$EXECUTOR"
    [ "$status" -eq 0 ]
}

# (g) every agent file still parses as YAML frontmatter + body: starts with
# a '---' line, has a closing '---' line, every non-blank frontmatter line
# looks like a key, a list item, or a folded-scalar continuation, and there
# is non-blank body content after the closing '---'. Deliberately a
# stdlib-only structural check (no pyyaml dependency) so this test doesn't
# require an environment change to run.
@test "(g) every agent file in config/agents/ still parses as YAML frontmatter + body" {
    run python3 - "$REPO_ROOT/config/agents" <<'PYEOF'
import glob
import re
import sys

KEY_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*:')
LIST_ITEM_RE = re.compile(r'^-\s')
CONTINUATION_RE = re.compile(r'^\s+\S')

bad = []
for path in sorted(glob.glob(sys.argv[1] + "/*.md")):
    with open(path) as fh:
        lines = fh.read().split("\n")

    if not lines or lines[0].strip() != "---":
        bad.append((path, "missing opening --- on line 1"))
        continue

    close_idx = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            close_idx = i
            break
    if close_idx is None:
        bad.append((path, "missing closing ---"))
        continue

    for line in lines[1:close_idx]:
        stripped = line.strip()
        if not stripped:
            continue
        if KEY_RE.match(line) or LIST_ITEM_RE.match(line) or CONTINUATION_RE.match(line):
            continue
        bad.append((path, f"frontmatter line does not parse: {line!r}"))
        break

    body = "\n".join(lines[close_idx + 1:]).strip()
    if not body:
        bad.append((path, "empty body after frontmatter"))

if bad:
    for path, reason in bad:
        print(f"{path}: {reason}", file=sys.stderr)
    sys.exit(1)
PYEOF
    [ "$status" -eq 0 ]
}

# ── beads_claude_docker-ifd: land the protocol in docs/dispatch/KB ─────────
#
# These cases (i), (k) are ADDED by beads_claude_docker-ifd, not edits to
# the seven above. (h), (j) from the same bead are dropped -- see header.

USER_MEMORY="$REPO_ROOT/config/claude-user-memory.md"

# (i) config/claude-user-memory.md's verifier dispatch row no longer
# promises a verifier-authored Repro/Root-cause/Fix-plan, and no longer
# uses the old CONFIRMED/PARTIAL/REFUTED verdict vocabulary anywhere.
@test "(i) config/claude-user-memory.md drops Repro/Root-cause/Fix-plan and CONFIRMED/PARTIAL/REFUTED" {
    run grep -F "Repro, Root cause and Fix plan" "$USER_MEMORY"
    [ "$status" -ne 0 ]

    for verdict in CONFIRMED PARTIAL REFUTED; do
        run grep -Fw "$verdict" "$USER_MEMORY"
        [ "$status" -ne 0 ]
    done

    for verdict in PASS FAIL TAMPERED NO-CONTRACT; do
        run grep -Fw "$verdict" "$USER_MEMORY"
        [ "$status" -eq 0 ]
    done
}

# (k) verifier.md's description frontmatter drops the old
# per-claim-bundle/per-worker-output trigger, and no worked example
# hardcodes a real bead id from another slice.
@test "(k) verifier.md description drops the old trigger wording; no literal beads_claude_docker- id" {
    run grep -F "folded into the final answer" "$VERIFIER"
    [ "$status" -ne 0 ]

    run grep -F "beads_claude_docker-" "$VERIFIER"
    [ "$status" -ne 0 ]
}

# ── beads_claude_docker-lhf: C2b, .beads carve-outs, VERIFIED prohibition ──
#
# Cases (m)-(o) are ADDED by beads_claude_docker-lhf. (p) from the same
# bead is dropped -- see header (knowledge-base/ not ported yet).

# (m) verifier.md defines C2b — materialize RED-AT in a temporary git
# worktree, run the contract's CHECK there, expect it to FAIL — and the
# 'no revert-and-rerun' boast, which C2b contradicts, is gone.
@test "(m) verifier.md defines C2b (worktree at RED-AT, CHECK must fail) and drops 'no revert-and-rerun'" {
    run grep -F "C2b" "$VERIFIER"
    [ "$status" -eq 0 ]

    run grep -F "git worktree add" "$VERIFIER"
    [ "$status" -eq 0 ]

    run grep -F "git worktree remove" "$VERIFIER"
    [ "$status" -eq 0 ]

    # the C2b section itself must tie the worktree to RED-AT, to running the
    # contract's CHECK, to a failing result, and to the TAMPERED verdict.
    sed -n '/\*\*C2b —/,/\*\*C3 —/p' "$VERIFIER" > "$BATS_TEST_TMPDIR/c2b.md"
    [ -s "$BATS_TEST_TMPDIR/c2b.md" ]

    for token in "RED-AT" "CHECK" "TAMPERED"; do
        run grep -F "$token" "$BATS_TEST_TMPDIR/c2b.md"
        [ "$status" -eq 0 ]
    done

    run grep -Fi "fail" "$BATS_TEST_TMPDIR/c2b.md"
    [ "$status" -eq 0 ]

    run grep -F "no revert-and-rerun" "$VERIFIER"
    [ "$status" -ne 0 ]

    run grep -F "revert-and-rerun" "$VERIFIER"
    [ "$status" -ne 0 ]
}

# (n) verifier.md carves .beads/ export churn out of C2's RED-AT-contents
# rule and C3's clean-tree rule — the pre-commit bd export rides every
# commit, and must not read as TAMPERED or FAIL.
@test "(n) verifier.md carves .beads/ out of C2 (RED-AT contents) and C3 (clean tree)" {
    sed -n '/\*\*C2 —/,/\*\*C2b —/p' "$VERIFIER" > "$BATS_TEST_TMPDIR/c2.md"
    [ -s "$BATS_TEST_TMPDIR/c2.md" ]
    run grep -F ".beads/" "$BATS_TEST_TMPDIR/c2.md"
    [ "$status" -eq 0 ]

    sed -n '/\*\*C3 —/,/\*\*C4 —/p' "$VERIFIER" > "$BATS_TEST_TMPDIR/c3.md"
    [ -s "$BATS_TEST_TMPDIR/c3.md" ]
    run grep -F ".beads/" "$BATS_TEST_TMPDIR/c3.md"
    [ "$status" -eq 0 ]
}

# (o) executor.md's Never list prohibits the executor writing a VERIFIED:
# line to a bead — that record belongs to the orchestrator, after a real
# verifier report.
@test "(o) executor.md's Never list prohibits writing VERIFIED: lines to a bead" {
    sed -n '/^## Never$/,$p' "$EXECUTOR" > "$BATS_TEST_TMPDIR/never.md"
    [ -s "$BATS_TEST_TMPDIR/never.md" ]

    run grep -F "VERIFIED:" "$BATS_TEST_TMPDIR/never.md"
    [ "$status" -eq 0 ]

    run grep -Fi "bead" "$BATS_TEST_TMPDIR/never.md"
    [ "$status" -eq 0 ]
}
