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
