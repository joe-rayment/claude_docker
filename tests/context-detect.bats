#!/usr/bin/env bats

# context-detect — SessionStart hook that injects project-type-specific
# instructions when workspace markers (or a manifest) match.
# Tests run the repo script directly (not the baked /usr/local/bin copy).

DETECT=${CONTEXT_DETECT_BIN:-/workspace/scripts/context-detect.sh}

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    WS="$BATS_TEST_TMPDIR/ws"
    CTX="$BATS_TEST_TMPDIR/ctx"
    mkdir -p "$WS" "$CTX"
    printf '# Project Context: Snowflake\nNEVER-QUERY-SNOWFLAKE-RULE\n' > "$CTX/snowflake.md"
}

run_detect() {
    run env WORKSPACE="$WS" CONTEXTS_DIR="$CTX" "$DETECT"
}

@test "context-detect: no markers -> empty output, exit 0" {
    run_detect
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "context-detect: missing contexts dir -> empty output, exit 0" {
    run env WORKSPACE="$WS" CONTEXTS_DIR="$BATS_TEST_TMPDIR/nope" "$DETECT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "context-detect: snowflake.yml marker injects the rules" {
    touch "$WS/snowflake.yml"
    run_detect
    [ "$status" -eq 0 ]
    [[ "$output" == *"NEVER-QUERY-SNOWFLAKE-RULE"* ]]
}

@test "context-detect: snowpark dep in requirements.txt injects the rules" {
    echo 'snowflake-snowpark-python==1.20.0' > "$WS/requirements.txt"
    run_detect
    [ "$status" -eq 0 ]
    [[ "$output" == *"NEVER-QUERY-SNOWFLAKE-RULE"* ]]
}

@test "context-detect: snowflake dep in pyproject.toml injects the rules" {
    printf '[project]\ndependencies = ["Snowflake-connector-python"]\n' > "$WS/pyproject.toml"
    run_detect
    [ "$status" -eq 0 ]
    [[ "$output" == *"NEVER-QUERY-SNOWFLAKE-RULE"* ]]
}

@test "context-detect: unrelated deps do not inject" {
    echo 'requests==2.31.0' > "$WS/requirements.txt"
    run_detect
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "context-detect: manifest forces a context with no marker" {
    mkdir -p "$WS/.claude-dev"
    printf '# forced for this project\nsnowflake\n' > "$WS/.claude-dev/contexts"
    run_detect
    [ "$status" -eq 0 ]
    [[ "$output" == *"NEVER-QUERY-SNOWFLAKE-RULE"* ]]
}

@test "context-detect: manifest !name suppresses a matching marker" {
    touch "$WS/snowflake.yml"
    mkdir -p "$WS/.claude-dev"
    echo '!snowflake' > "$WS/.claude-dev/contexts"
    run_detect
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "context-detect: manifest-only context (no detector) injects via manifest" {
    printf 'DBT-CONTEXT-RULE\n' > "$CTX/dbt.md"
    mkdir -p "$WS/.claude-dev"
    echo 'dbt' > "$WS/.claude-dev/contexts"
    run_detect
    [ "$status" -eq 0 ]
    [[ "$output" == *"DBT-CONTEXT-RULE"* ]]
    [[ "$output" != *"NEVER-QUERY-SNOWFLAKE-RULE"* ]]
}

@test "context-detect: two matched contexts both inject, stdout only has rules" {
    touch "$WS/snowflake.yml"
    printf 'DBT-CONTEXT-RULE\n' > "$CTX/dbt.md"
    mkdir -p "$WS/.claude-dev"
    echo 'dbt' > "$WS/.claude-dev/contexts"
    run env WORKSPACE="$WS" CONTEXTS_DIR="$CTX" sh -c "\"$DETECT\" 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NEVER-QUERY-SNOWFLAKE-RULE"* ]]
    [[ "$output" == *"DBT-CONTEXT-RULE"* ]]
}

@test "context-detect: manifest entry without rules file warns on stderr, not stdout" {
    mkdir -p "$WS/.claude-dev"
    echo 'ghost' > "$WS/.claude-dev/contexts"
    run env WORKSPACE="$WS" CONTEXTS_DIR="$CTX" sh -c "\"$DETECT\" 2>$BATS_TEST_TMPDIR/err"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    grep -q "no rules file for manifest entry 'ghost'" "$BATS_TEST_TMPDIR/err"
}

@test "context-detect: staged snowflake.md ships real rules (repo copy)" {
    run env WORKSPACE="$WS" CONTEXTS_DIR=/workspace/config/contexts sh -c "touch \"$WS/snowflake.yml\"; WORKSPACE=\"$WS\" CONTEXTS_DIR=/workspace/config/contexts \"$DETECT\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"no direct access"* ]]
}

# beads_claude_docker-jqmd — Snowflake surfaces: config/contexts/snowflake.md
# and the snowpark-deploy skill no longer wait on a human reply. Four
# banned phrases from the old "ask the user ... paste ... blocked on
# their reply" pattern must not survive in either shipped file, the
# context file has a hard word budget, and knowledge-base/SNOWFLAKE_DEPLOY.md
# carries a banner stating Claude prepares files/commands and never runs
# `snow` itself. The regenerated plugin copy is checked byte-identical too.

SNOWFLAKE_BANNED_PHRASES=(
    'blocked on their reply'
    'paste the deploy'
    'paste the output'
    'ask the user'
)

@test "context-detect: banned phrases absent from config/contexts/snowflake.md" {
    for phrase in "${SNOWFLAKE_BANNED_PHRASES[@]}"; do
        run grep -F -- "$phrase" /workspace/config/contexts/snowflake.md
        [ "$status" -ne 0 ]
    done
}

@test "context-detect: banned phrases absent from config/skills/snowpark-deploy/SKILL.md" {
    for phrase in "${SNOWFLAKE_BANNED_PHRASES[@]}"; do
        run grep -F -- "$phrase" /workspace/config/skills/snowpark-deploy/SKILL.md
        [ "$status" -ne 0 ]
    done
}

@test "context-detect: config/contexts/snowflake.md is at most 90 words" {
    local words
    words=$(wc -w < /workspace/config/contexts/snowflake.md)
    [ "$words" -le 90 ]
}

@test "context-detect: SNOWFLAKE_DEPLOY.md banner in first 5 lines states Claude never runs snow" {
    run head -5 /workspace/knowledge-base/SNOWFLAKE_DEPLOY.md
    [ "$status" -eq 0 ]
    [[ "$output" == *'never runs `snow`'* ]]
}

@test "context-detect: plugin snowpark-deploy skill copy is byte-identical to config source" {
    diff -q /workspace/plugin/skills/snowpark-deploy/SKILL.md /workspace/config/skills/snowpark-deploy/SKILL.md
}
