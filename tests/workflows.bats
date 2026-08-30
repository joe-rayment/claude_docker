#!/usr/bin/env bats
# workflows.bats — .claude/workflows/{recon-fanout,verify-contracts}.js:
#   - node ES-module syntax validity
#   - export const meta literal shape (name/description/phases)
#   - every agent() call carries an explicit model:
#   - scripts/workflow-lint.sh allows the real script and denies a
#     model-stripped mutant of it (via a synthetic PreToolUse Workflow
#     payload — workflow-lint.sh itself is NOT modified by this suite)
#   - knowledge-base/TIERED_ORCHESTRATION.md references both workflows
#   - bead beads_claude_docker-ehq's notes record a completed live
#     recon-fanout run — ORCHESTRATOR-OWNED (see the last test below):
#     this executor's Agent grant is scout-only and does not include the
#     Workflow tool, so that one clause is expected to stay red across
#     this bead's own GREEN-AT commit, by advance deviation authorization
#     from the swarm brief. It must go green before the bead closes.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

WORKFLOWS_DIR="$REPO_ROOT/.claude/workflows"
RECON="$WORKFLOWS_DIR/recon-fanout.js"
VERIFY="$WORKFLOWS_DIR/verify-contracts.js"
LINT="$REPO_ROOT/scripts/workflow-lint.sh"
KB="$REPO_ROOT/knowledge-base/TIERED_ORCHESTRATION.md"
BEAD_ID="beads_claude_docker-ehq"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
}

# Node import-based introspection: this actually loads the module and
# inspects the real `meta` export's runtime shape, rather than grepping
# for tokens that could appear anywhere (comments, the schema literal,
# prose). Safe to import: `agent()` calls live only inside the default
# export function body, never at module top level, so importing never
# invokes an undefined `agent` global.
meta_shape_ok() {
    node -e '
import(process.argv[1]).then(m => {
  const meta = m.meta;
  if (!meta || typeof meta.name !== "string" || !meta.name) throw new Error("meta.name missing/invalid");
  if (typeof meta.description !== "string" || !meta.description) throw new Error("meta.description missing/invalid");
  if (!Array.isArray(meta.phases) || meta.phases.length === 0) throw new Error("meta.phases missing/invalid");
  console.log("meta ok: " + JSON.stringify(meta));
}).catch(e => { console.error(String(e)); process.exit(1); });
' "$1"
}

# ── recon-fanout.js ─────────────────────────────────────────────────────

@test "recon-fanout.js: valid ES module syntax" {
    [ -f "$RECON" ]
    run node --input-type=module --check < "$RECON"
    [ "$status" -eq 0 ]
}

@test "recon-fanout.js: export const meta is a literal with name, description, and phases" {
    run grep -qE '^export const meta' "$RECON"
    [ "$status" -eq 0 ]
    run meta_shape_ok "$RECON"
    [ "$status" -eq 0 ]
}

@test "recon-fanout.js: no Date.now, Math.random, or new Date (bead's plain-JS/determinism constraint)" {
    run grep -E 'Date\.now\(|Math\.random\(|new Date\(' "$RECON"
    [ "$status" -ne 0 ]
}

@test "recon-fanout.js: every agent( call carries a model: option (workflow-lint allows the real script)" {
    run bash -c "jq -Rs --arg tn Workflow '{tool_name:\$tn, tool_input:{script:.}}' < '$RECON' | sh '$LINT'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "recon-fanout.js: workflow-lint denies a model-stripped mutant of the real script" {
    mut="$BATS_TEST_TMPDIR/recon-fanout.mutant.js"
    sed '/model:/d' "$RECON" > "$mut"
    run grep -q "model:" "$mut"
    [ "$status" -ne 0 ]
    run bash -c "jq -Rs --arg tn Workflow '{tool_name:\$tn, tool_input:{script:.}}' < '$mut' | sh '$LINT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

# ── verify-contracts.js ─────────────────────────────────────────────────

@test "verify-contracts.js: valid ES module syntax" {
    [ -f "$VERIFY" ]
    run node --input-type=module --check < "$VERIFY"
    [ "$status" -eq 0 ]
}

@test "verify-contracts.js: export const meta is a literal with name, description, and phases" {
    run grep -qE '^export const meta' "$VERIFY"
    [ "$status" -eq 0 ]
    run meta_shape_ok "$VERIFY"
    [ "$status" -eq 0 ]
}

@test "verify-contracts.js: no Date.now, Math.random, or new Date (bead's plain-JS/determinism constraint)" {
    run grep -E 'Date\.now\(|Math\.random\(|new Date\(' "$VERIFY"
    [ "$status" -ne 0 ]
}

@test "verify-contracts.js: every agent( call carries a model: option (workflow-lint allows the real script)" {
    run bash -c "jq -Rs --arg tn Workflow '{tool_name:\$tn, tool_input:{script:.}}' < '$VERIFY' | sh '$LINT'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "verify-contracts.js: workflow-lint denies a model-stripped mutant of the real script" {
    mut="$BATS_TEST_TMPDIR/verify-contracts.mutant.js"
    sed '/model:/d' "$VERIFY" > "$mut"
    run grep -q "model:" "$mut"
    [ "$status" -ne 0 ]
    run bash -c "jq -Rs --arg tn Workflow '{tool_name:\$tn, tool_input:{script:.}}' < '$mut' | sh '$LINT'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

# ── knowledge-base cross-reference ──────────────────────────────────────

@test "TIERED_ORCHESTRATION.md references .claude/workflows/recon-fanout.js" {
    run grep -F ".claude/workflows/recon-fanout.js" "$KB"
    [ "$status" -eq 0 ]
}

@test "TIERED_ORCHESTRATION.md references .claude/workflows/verify-contracts.js" {
    run grep -F ".claude/workflows/verify-contracts.js" "$KB"
    [ "$status" -eq 0 ]
}

# ── bead notes: live recon-fanout run (ORCHESTRATOR-OWNED) ──────────────

@test "bead ehq notes record a completed live recon-fanout run (orchestrator-owned)" {
    run bash -c "bd show '$BEAD_ID' --json | jq -r '.[0].notes // empty'"
    [ "$status" -eq 0 ]
    notes="$output"
    # A completed run appends a line starting with this exact marker
    # (chosen so it cannot appear by accident in prose ABOUT the
    # requirement, only in a report OF an actual run), e.g.:
    #   RECON-FANOUT-RUN-RESULT: 2 questions, model=haiku, findings=N
    line=$(printf '%s\n' "$notes" | grep -F "RECON-FANOUT-RUN-RESULT:" | head -1)
    [ -n "$line" ]
    echo "$line" | grep -Eqi '2[^0-9]{0,4}question'
    echo "$line" | grep -qi "haiku"
}
