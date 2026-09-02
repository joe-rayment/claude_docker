#!/usr/bin/env bats

# prime-hook.bats — bd's compiled-in workflow boilerplate (a session-close
# checklist ending "git push … NEVER skip this. Work is not done until
# pushed", "Create beads issue BEFORE writing code", a "Write tests for X"
# separate-bead example, "use parallel subagents" to file issues) is only
# ever contradicted by this repo's own CLAUDE.md, which never ships to a
# user project — config/claude-user-memory.md does. `bd prime
# --memories-only` drops all of that and prints just the memories.
# scripts/prime-memories.sh wires that flag into both hooks and adds a
# byte budget on the memories themselves (Claude-written, unbounded).
#
# Covers: the SessionStart/PreCompact hook wiring (config/claude-
# settings.json), the wrapper script's own budgeting/fail-open behavior,
# `bd init --skip-agents` (scripts/entrypoint.sh), the idempotent
# settings.json rewrite function for existing projects, the Dockerfile/
# plugin staging, and the two now-deletable "argue with bd's injected
# text" paragraphs in CLAUDE.md / config/claude-user-memory.md.
#
# NOTE on test (1): the bead's own PASS-IF says every hook command
# mentioning 'prime' "is exactly 'prime-memories'". A literal bare
# "prime-memories" command would fail hook-staging-check.py's GUARD
# invariant (scripts/prime-memories.sh is an optional COPY'd project
# script, not a hard dependency like bd — SAFE_FIRST_TOKENS documents
# exactly that distinction) and is also unsatisfiable as literally worded:
# the existing tier-prime hook commands also contain the substring
# "prime" and are not "prime-memories". This test instead checks the
# clause's intent: no bare 'bd prime' remains, and prime-memories is wired
# into both events — see the executor's report for this deviation.

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SETTINGS="$REPO_DIR/config/claude-settings.json"
ENTRYPOINT_SRC="$REPO_DIR/scripts/entrypoint.sh"
PRIME_MEMORIES="$REPO_DIR/scripts/prime-memories.sh"
DOCKERFILE="$REPO_DIR/Dockerfile"
CLAUDE_MD="$REPO_DIR/CLAUDE.md"
USER_MEMORY="$REPO_DIR/config/claude-user-memory.md"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    command -v bd  >/dev/null 2>&1 || skip "bd not installed"
    command -v jq  >/dev/null 2>&1 || skip "jq not installed"
    command -v git >/dev/null 2>&1 || skip "git not installed"
}

# make_bd_repo <dir> — throwaway git + bd repo, memories channel only (no
# AGENTS.md/settings.json noise from bd's own agent-file generation).
make_bd_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name "Test"
    (cd "$dir" && bd init --prefix px --quiet --non-interactive --skip-agents >/dev/null 2>&1)
}

@test "prime-hook: scripts/prime-memories.sh exists and is executable" {
    [ -f "$PRIME_MEMORIES" ]
    [ -x "$PRIME_MEMORIES" ]
}

# ── (1) SessionStart/PreCompact hooks: prime-memories in, bare bd prime out ─

@test "prime-hook: config/claude-settings.json's SessionStart and PreCompact hooks invoke prime-memories, and no bare 'bd prime' command remains anywhere in the file" {
    run jq -r '[.hooks.SessionStart[]?.hooks[]?.command, .hooks.PreCompact[]?.hooks[]?.command] | map(select(. == "bd prime")) | length' "$SETTINGS"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]

    run jq -r '[.hooks.SessionStart[]?.hooks[]?.command] | map(select(contains("prime-memories"))) | length' "$SETTINGS"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]

    run jq -r '[.hooks.PreCompact[]?.hooks[]?.command] | map(select(contains("prime-memories"))) | length' "$SETTINGS"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]

    run grep -F '"bd prime"' "$SETTINGS"
    [ "$status" -eq 1 ]
}

# ── (2) memories only: the probe survives, none of bd's injected boilerplate does ─

@test "prime-hook: prime-memories prints a remembered probe and none of bd prime's injected workflow boilerplate" {
    local dir="$BATS_TEST_TMPDIR/probe-repo"
    make_bd_repo "$dir"
    (cd "$dir" && bd remember --key probe-marker "unique-probe-marker-9f3e: a fact, not a rule" >/dev/null 2>&1)

    run bash -c "cd '$dir' && bash '$PRIME_MEMORIES'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"unique-probe-marker-9f3e"* ]]
    [[ "$output" != *"git push"* ]]
    [[ "$output" != *"BEFORE writing code"* ]]
    [[ "$output" != *"Write tests for"* ]]
    [[ "$output" != *"parallel subagents"* ]]
    [[ "$output" != *"SESSION CLOSE"* ]]
}

# ── (3) byte budget: whole memories in bd's order, omitted keys named, never truncated ─

@test "prime-hook: PRIME_MEMORY_BUDGET caps the memory section, names every omitted key in one footer line, and never truncates a printed memory" {
    local dir="$BATS_TEST_TMPDIR/budget-repo"
    make_bd_repo "$dir"
    (cd "$dir" && bd remember --key aaa-first "aaa: this is the first memory, alphabetically first key too" >/dev/null 2>&1)
    (cd "$dir" && bd remember --key mmm-second "mmm: a second, unrelated project fact of similar length here" >/dev/null 2>&1)
    (cd "$dir" && bd remember --key zzz-third "zzz: a third fact that will not fit under the tiny test budget" >/dev/null 2>&1)

    run bash -c "cd '$dir' && PRIME_MEMORY_BUDGET=80 bash '$PRIME_MEMORIES'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"### aaa-first"* ]]
    [[ "$output" == *"aaa: this is the first memory, alphabetically first key too"* ]]
    [[ "$output" != *"### mmm-second"* ]]
    [[ "$output" != *"### zzz-third"* ]]
    [[ "$output" == *"mmm-second"* ]]
    [[ "$output" == *"zzz-third"* ]]
    [[ "$output" == *"bd memories <keyword>"* ]]
    local footer_lines
    footer_lines=$(printf '%s\n' "$output" | grep -c 'omitted')
    [ "$footer_lines" -eq 1 ]
}

# ── (4) fail-open: bd absent ────────────────────────────────────────────────

@test "prime-hook: prime-memories exits 0 with empty output when bd is absent from PATH" {
    local emptydir="$BATS_TEST_TMPDIR/emptybin"
    mkdir -p "$emptydir"
    local realbd realbddir filtered
    realbd=$(command -v bd)
    realbddir=$(dirname "$realbd")
    filtered=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vF "$realbddir" | paste -sd: -)

    run env PATH="$emptydir:$filtered" bash "$PRIME_MEMORIES"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── (5) bd init --skip-agents ───────────────────────────────────────────────

@test "prime-hook: every 'bd init --prefix' invocation in scripts/entrypoint.sh carries --skip-agents" {
    run grep -n 'bd init --prefix' "$ENTRYPOINT_SRC"
    [ "$status" -eq 0 ]
    local total with_flag
    total=$(printf '%s\n' "$output" | grep -c 'bd init --prefix')
    with_flag=$(printf '%s\n' "$output" | grep -c -- '--skip-agents')
    [ "$total" -ge 1 ]
    [ "$total" -eq "$with_flag" ]
}

# ── (6) idempotent settings.json rewrite for existing projects ─────────────

@test "prime-hook: entrypoint's settings.json rewrite function turns 'bd prime' hooks into prime-memories and is idempotent" {
    local start end
    start=$(grep -n '^normalize_bd_prime_hooks() {' "$ENTRYPOINT_SRC" | head -1 | cut -d: -f1)
    end=$(grep -n '^normalize_bd_prime_hooks$' "$ENTRYPOINT_SRC" | head -1 | cut -d: -f1)
    [ -n "$start" ]
    [ -n "$end" ]
    sed -n "${start},$((end - 1))p" "$ENTRYPOINT_SRC" > "$BATS_TEST_TMPDIR/normalize-fn.sh"

    local fixture="$BATS_TEST_TMPDIR/fixture-settings.json"
    cat > "$fixture" <<'JSON'
{
  "hooks": {
    "PreCompact": [
      { "hooks": [ { "command": "bd prime", "type": "command" } ], "matcher": "" }
    ],
    "SessionStart": [
      { "hooks": [ { "command": "bd prime", "type": "command" } ], "matcher": "" }
    ]
  }
}
JSON

    run bash -c "source '$BATS_TEST_TMPDIR/normalize-fn.sh' && normalize_bd_prime_hooks '$fixture'"
    [ "$status" -eq 0 ]
    run grep -c '"bd prime"' "$fixture"
    [ "$status" -eq 1 ]
    run grep -c 'prime-memories' "$fixture"
    [ "$status" -eq 0 ]
    [ "$output" -eq 2 ]

    cp "$fixture" "$BATS_TEST_TMPDIR/fixture-after-1.json"
    run bash -c "source '$BATS_TEST_TMPDIR/normalize-fn.sh' && normalize_bd_prime_hooks '$fixture'"
    [ "$status" -eq 0 ]
    run diff "$BATS_TEST_TMPDIR/fixture-after-1.json" "$fixture"
    [ "$status" -eq 0 ]
}

# ── (7) the two override-by-name paragraphs are gone ────────────────────────

@test "prime-hook: CLAUDE.md no longer contains the 'overrides, by name' or 'SESSION CLOSE PROTOCOL' phrases" {
    run grep -F 'overrides, by name' "$CLAUDE_MD"
    [ "$status" -eq 1 ]
    run grep -F 'SESSION CLOSE PROTOCOL' "$CLAUDE_MD"
    [ "$status" -eq 1 ]
}

@test "prime-hook: config/claude-user-memory.md contains neither the 'overrides, by name' nor 'SESSION CLOSE PROTOCOL' phrases" {
    run grep -F 'overrides, by name' "$USER_MEMORY"
    [ "$status" -eq 1 ]
    run grep -F 'SESSION CLOSE PROTOCOL' "$USER_MEMORY"
    [ "$status" -eq 1 ]
}

# ── (8) Dockerfile + plugin staging ─────────────────────────────────────────

@test "prime-hook: Dockerfile stages scripts/prime-memories.sh and plugin/bin/prime-memories is byte-identical to it" {
    run grep -F 'scripts/prime-memories.sh' "$DOCKERFILE"
    [ "$status" -eq 0 ]
    [ -f "$REPO_DIR/plugin/bin/prime-memories" ]
    run diff "$PRIME_MEMORIES" "$REPO_DIR/plugin/bin/prime-memories"
    [ "$status" -eq 0 ]
}
