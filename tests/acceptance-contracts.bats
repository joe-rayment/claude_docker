#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# acceptance-contracts.bats — asserts the seven clauses (a)-(g) of
# beads_claude_docker-bmm's acceptance contract: that verifier.md,
# bead-auditor.md, and executor.md were rewritten to replace open-ended
# re-derivation with the five contract checks (C1-C5) and the
# red-commit-first executor loop.
#
# FROZEN per beads_claude_docker-bmm's acceptance contract: this file must
# not be edited after its RED commit. If a test here turns out to be wrong,
# stop and report — do not edit it. (Slice 3 may later ADD cases to this
# file; that does not authorize editing existing ones.)

VERIFIER=/workspace/config/agents/verifier.md
AUDITOR=/workspace/config/agents/bead-auditor.md
EXECUTOR=/workspace/config/agents/executor.md

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
    run python3 - <<'PYEOF'
import glob
import re
import sys

KEY_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*:')
LIST_ITEM_RE = re.compile(r'^-\s')
CONTINUATION_RE = re.compile(r'^\s+\S')

bad = []
for path in sorted(glob.glob("/workspace/config/agents/*.md")):
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
# These cases (h)-(l) are ADDED by beads_claude_docker-ifd, not edits to the
# seven above — legitimate per this file's own freeze-window rule: -bmm's
# freeze window ran RED-AT -> its verification, which is complete and
# closed, so this file's frozen status reset and -ifd opened its own
# freeze window at ITS OWN RED-AT. (a)-(g) above are untouched.

CLAUDE_MD=/workspace/CLAUDE.md
USER_MEMORY=/workspace/config/claude-user-memory.md
KB_ACCEPTANCE=/workspace/knowledge-base/ACCEPTANCE_CONTRACTS.md
KB_README=/workspace/knowledge-base/README.md
TIER_PRIME=/workspace/scripts/tier-prime.sh

# (h) CLAUDE.md's Verification section documents the acceptance contract
# (CHECK/PASS-IF/FROZEN) and names all five checks C1-C5.
@test "(h) CLAUDE.md Verification section documents the acceptance contract and C1-C5" {
    sed -n '/^## Verification$/,/^## /p' "$CLAUDE_MD" > "$BATS_TEST_TMPDIR/verif-section.md"
    [ -s "$BATS_TEST_TMPDIR/verif-section.md" ]
    for token in CHECK PASS-IF FROZEN C1 C2 C3 C4 C5; do
        run grep -F "$token" "$BATS_TEST_TMPDIR/verif-section.md"
        [ "$status" -eq 0 ]
    done
}

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

# (j) knowledge-base/ACCEPTANCE_CONTRACTS.md exists, explicitly documents
# the freeze window as bounded (not forever) via RED-AT, and is indexed
# in knowledge-base/README.md.
@test "(j) knowledge-base/ACCEPTANCE_CONTRACTS.md exists, documents the bounded freeze window, and is indexed" {
    [ -f "$KB_ACCEPTANCE" ]

    run grep -Fi "freeze" "$KB_ACCEPTANCE"
    [ "$status" -eq 0 ]

    run grep -F "RED-AT" "$KB_ACCEPTANCE"
    [ "$status" -eq 0 ]

    run grep -F "not forever" "$KB_ACCEPTANCE"
    [ "$status" -eq 0 ]

    run grep -F "ACCEPTANCE_CONTRACTS.md" "$KB_README"
    [ "$status" -eq 0 ]
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

# (l) scripts/tier-prime.sh --full emits contract-shaped dispatch wording
# and drops the old 'non-trivial claim->verifier' phrasing entirely.
@test "(l) tier-prime.sh --full emits contract-shaped dispatch wording, drops 'non-trivial claim->verifier'" {
    run "$TIER_PRIME" --full
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/prime-full.txt"

    run grep -F "non-trivial claim→verifier" "$BATS_TEST_TMPDIR/prime-full.txt"
    [ "$status" -ne 0 ]

    for token in "acceptance contract" "CHECK" "PASS-IF" "red"; do
        run grep -F "$token" "$BATS_TEST_TMPDIR/prime-full.txt"
        [ "$status" -eq 0 ]
    done

    # the standing-authorization and invariants lines must survive untouched
    run grep -F "standing authorization" "$BATS_TEST_TMPDIR/prime-full.txt"
    [ "$status" -eq 0 ]
    run grep -F "expensive tiers never take the worker seat" "$BATS_TEST_TMPDIR/prime-full.txt"
    [ "$status" -eq 0 ]
}

# ── beads_claude_docker-lhf: C2b, .beads carve-outs, VERIFIED prohibition ──
#
# Cases (m)-(p) are ADDED by beads_claude_docker-lhf under its OWN RED-AT,
# per this file's bounded-freeze-window rule: -ifd's window ran from its
# RED-AT to its verification and is closed, so the file unfroze and -lhf
# opened a new window on it. Cases (a)-(l) above are untouched.

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

# (p) the KB doc documents C2b as a row of the checks table, drops the
# revert-and-rerun claim while keeping the no-mutation-testing one, and
# agrees with verifier.md on the "five checks plus C2b" naming.
@test "(p) ACCEPTANCE_CONTRACTS.md documents C2b in the checks table and drops the revert-and-rerun claim" {
    run grep -F "revert-and-rerun" "$KB_ACCEPTANCE"
    [ "$status" -ne 0 ]

    run grep -F "no mutation testing" "$KB_ACCEPTANCE"
    [ "$status" -eq 0 ]

    run grep -E '^\| C2b \|' "$KB_ACCEPTANCE"
    [ "$status" -eq 0 ]

    run grep -F "git worktree" "$KB_ACCEPTANCE"
    [ "$status" -eq 0 ]

    # both files name the check set the same way
    run grep -F "five checks plus C2b" "$KB_ACCEPTANCE"
    [ "$status" -eq 0 ]

    run grep -F "five checks plus C2b" "$VERIFIER"
    [ "$status" -eq 0 ]
}
