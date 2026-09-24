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

# ── beads_claude_docker-lhf: C2b, .beads carve-outs, VERIFIED prohibition ──
#
# Cases (m)-(o) are ADDED by beads_claude_docker-lhf. (p) from the same
# bead is dropped -- see header (knowledge-base/ not ported yet).
