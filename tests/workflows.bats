#!/usr/bin/env bats
# workflows.bats — config/workflows/{recon-fanout,verify-contracts}.js:
#   - node ES-module syntax validity
#   - export const meta literal shape (name/description/phases)
#   - every agent() call carries an explicit model:
#   - scripts/workflow-lint.sh allows the real script and denies a
#     model-stripped mutant of it (via a synthetic PreToolUse Workflow
#     payload — workflow-lint.sh itself is NOT modified by this suite)
#
# S7 port (claude-orca-3sk.7): workflows live in config/workflows/ (synced
# by config-sync.sh into a project's .claude/workflows/, see scripts/
# config-sync.sh), not this repo's own .claude/workflows/ (which is this
# session's live config dir, not the template source). Drops the
# knowledge-base/TIERED_ORCHESTRATION.md cross-reference cases
# (knowledge-base/ is S11, not ported yet) and the bead-notes case (names
# a bead id from the old template's own beads DB, not this repo's).

load helpers/setup

WORKFLOWS_DIR="$REPO_ROOT/config/workflows"
RECON="$WORKFLOWS_DIR/recon-fanout.js"
VERIFY="$WORKFLOWS_DIR/verify-contracts.js"
LINT="$REPO_ROOT/scripts/workflow-lint.sh"

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

@test "config-sync mirrors config/workflows/*.js into the project's .claude/workflows/" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run "$ORCA_HOST/template/scripts/config-sync.sh" --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]
    dest="$primary/.claude-dev/home/.claude/workflows"
    diff "$WORKFLOWS_DIR/recon-fanout.js" "$dest/recon-fanout.js"
    diff "$WORKFLOWS_DIR/verify-contracts.js" "$dest/verify-contracts.js"
}
