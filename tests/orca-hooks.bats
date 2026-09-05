#!/usr/bin/env bats
#
# S6 acceptance contract (claude-orca-3sk.18) -- FROZEN from RED-AT onward.
# Orca writes its managed hook entries into the REAL ~/.claude/settings.json;
# the sandboxed Claude runs with its own CLAUDE_CONFIG_DIR and never reads
# that file, so the wrapper (host side, every launch) merges Orca's managed
# entries -- identified by the ~/.orca/agent-hooks/claude-hook.sh command --
# into <config dir>/settings.json, chains Orca's statusline before ours,
# leaves ORCA_* env alone, and (only when the project opts in) symlinks
# ~/.claude/projects/<slug> at the sandboxed transcripts dir.
# See .claude/plans/orca-port.md S3.5.
#
# tests/fixtures/orca/claude-settings-with-orca.json is a faithful copy of
# what Orca's own installer writes: the 12 CLAUDE_EVENTS of
# src/main/claude/hook-settings.ts, each carrying the command built by
# src/main/agent-hooks/runtime-home-hook-command.ts (POSIX + encoded
# PowerShell branches, timeout 10), plus the claude-statusline entry and two
# user-owned host-side hooks that must never be imported.

load helpers/setup

NEEDLE="/.orca/agent-hooks/"

ORCA_EVENTS=(SessionStart UserPromptSubmit Stop StopFailure SubagentStart \
    SubagentStop TeammateIdle PreToolUse PostToolUse PostToolUseFailure \
    PermissionRequest PostCompact)

MERGE() {
    "$ORCA_HOST/template/bin/orca-hooks-merge" "$@"
}

# Populates $primary/.claude-dev/home/.claude/settings.json the way the
# wrapper does, and drops Orca's fixture settings into $real_home/.claude.
prepare() {
    primary="$(abspath "$PROJECT_DIR")"
    real_home="$(abspath "$(make_real_home)")"
    config_dir="$primary/.claude-dev/home/.claude"
    "$ORCA_HOST/template/scripts/config-sync.sh" \
        --project "$primary" --host "$ORCA_HOST" >/dev/null
    baseline="$BATS_TEST_TMPDIR/baseline.json"
    cp "$config_dir/settings.json" "$baseline"
    mkdir -p "$real_home/.claude"
    cp "$BATS_TEST_DIRNAME/fixtures/orca/claude-settings-with-orca.json" \
        "$real_home/.claude/settings.json"
}

# Number of Orca-managed hook definitions under event $2 of file $1.
managed_count() {
    jq --arg e "$2" --arg n "$NEEDLE" \
        '[ .hooks[$e][]? | select(any(.hooks[]?.command; contains($n))) ] | length' "$1"
}

total_managed() {
    jq --arg n "$NEEDLE" \
        '[ .hooks[]?[]? | select(any(.hooks[]?.command; contains($n))) ] | length' "$1"
}

# The file with every managed entry (and the statusLine slot) removed, so
# two states can be compared for "our own config is byte-identical".
without_managed() {
    jq -S --arg n "$NEEDLE" \
        'del(.statusLine)
         | .hooks |= (with_entries(.value |= map(select(any(.hooks[]?.command; contains($n)) | not)))
                      | with_entries(select(.value | length > 0)))' "$1"
}

@test "managed entries for the 12 Orca events from a fixture ~/.claude/settings.json are merged into the project settings.json" {
    make_project "$PROJECT_DIR"
    prepare

    run MERGE --real-home "$real_home" --config-dir "$config_dir"
    [ "$status" -eq 0 ]

    for ev in "${ORCA_EVENTS[@]}"; do
        [ "$(managed_count "$config_dir/settings.json" "$ev")" -eq 1 ]
    done

    # The command is carried over verbatim, matcher and timeout included.
    src="$real_home/.claude/settings.json"
    for ev in PreToolUse PostToolUse PostToolUseFailure PermissionRequest; do
        got="$(jq -r --arg e "$ev" --arg n "$NEEDLE" \
            '[.hooks[$e][] | select(any(.hooks[]?.command; contains($n)))][0] | .matcher' \
            "$config_dir/settings.json")"
        [ "$got" = "*" ]
    done
    want="$(jq -r --arg n "$NEEDLE" '[.hooks.Stop[] | select(any(.hooks[]?.command; contains($n)))][0].hooks[0]' "$src")"
    got="$(jq -r --arg n "$NEEDLE" '[.hooks.Stop[] | select(any(.hooks[]?.command; contains($n)))][0].hooks[0]' "$config_dir/settings.json")"
    [ "$want" = "$got" ]
    [[ "$want" == *"claude-hook.sh"* ]]

    # Host-side, user-owned hooks are never imported.
    ! grep -q 'host-only-session-start' "$config_dir/settings.json"
    ! grep -q 'host-only-notification' "$config_dir/settings.json"
    [ "$(jq '.hooks.Notification | length' "$config_dir/settings.json")" = "0" ]
}

@test "our hooks are kept and not duplicated across two merges" {
    make_project "$PROJECT_DIR"
    prepare

    run MERGE --real-home "$real_home" --config-dir "$config_dir"
    [ "$status" -eq 0 ]
    cp "$config_dir/settings.json" "$BATS_TEST_TMPDIR/after-one.json"

    run MERGE --real-home "$real_home" --config-dir "$config_dir"
    [ "$status" -eq 0 ]

    # Idempotent: the second merge changes nothing at all.
    diff "$BATS_TEST_TMPDIR/after-one.json" "$config_dir/settings.json"

    for ev in "${ORCA_EVENTS[@]}"; do
        [ "$(managed_count "$config_dir/settings.json" "$ev")" -eq 1 ]
    done

    # Our own hooks (SessionStart and PreToolUse overlap with Orca's events)
    # survive both merges unchanged.
    diff <(without_managed "$baseline") <(without_managed "$config_dir/settings.json")
    grep -q 'template/bin/tier-prime' "$config_dir/settings.json"
    grep -q 'template/bin/tier-gate' "$config_dir/settings.json"
}

@test "entries disappear from the project settings when removed from the fixture" {
    make_project "$PROJECT_DIR"
    prepare

    run MERGE --real-home "$real_home" --config-dir "$config_dir"
    [ "$status" -eq 0 ]
    [ "$(total_managed "$config_dir/settings.json")" -eq 12 ]

    # Orca uninstalled / hooks toggled off: its managed entries and its
    # statusline are gone from the real ~/.claude/settings.json.
    jq --arg n "$NEEDLE" \
        'del(.statusLine)
         | .hooks |= with_entries(.value |= map(select(any(.hooks[]?.command; contains($n)) | not)))' \
        "$real_home/.claude/settings.json" > "$BATS_TEST_TMPDIR/src.json"
    mv "$BATS_TEST_TMPDIR/src.json" "$real_home/.claude/settings.json"

    run MERGE --real-home "$real_home" --config-dir "$config_dir"
    [ "$status" -eq 0 ]
    [ "$(total_managed "$config_dir/settings.json")" -eq 0 ]
    ! grep -q "$NEEDLE" "$config_dir/settings.json"

    # Back to exactly what config-sync wrote, statusLine included.
    diff <(jq -S . "$baseline") <(jq -S . "$config_dir/settings.json")
}

@test "statusLine chains Orca's claude-statusline.sh then ours" {
    make_project "$PROJECT_DIR"
    prepare

    ours="$(jq -r '.statusLine.command' "$baseline")"
    run MERGE --real-home "$real_home" --config-dir "$config_dir"
    [ "$status" -eq 0 ]

    chained="$(jq -r '.statusLine.command' "$config_dir/settings.json")"
    [[ "$chained" == *"claude-statusline.sh"* ]]
    [[ "$chained" == *"$ours"* ]]
    orca_at="${chained%%claude-statusline.sh*}"
    ours_at="${chained%%$ours*}"
    [ "${#orca_at}" -lt "${#ours_at}" ]
    run bash -n -c "$chained"
    [ "$status" -eq 0 ]

    # A second merge must not chain it twice.
    run MERGE --real-home "$real_home" --config-dir "$config_dir"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.statusLine.command' "$config_dir/settings.json")" = "$chained" ]

    # And it really runs both, Orca's first: a stub Orca statusline script
    # plus a trivial "ours" in a scratch config dir.
    cat > "$real_home/.orca/agent-hooks/claude-statusline.sh" <<'STUB'
#!/bin/sh
cat >/dev/null
echo "ORCA-USAGE"
STUB
    chmod +x "$real_home/.orca/agent-hooks/claude-statusline.sh"
    scratch="$BATS_TEST_TMPDIR/scratch-config"
    mkdir -p "$scratch"
    echo '{"statusLine":{"type":"command","command":"cat >/dev/null; echo MINE"}}' > "$scratch/settings.json"

    run MERGE --real-home "$real_home" --config-dir "$scratch"
    [ "$status" -eq 0 ]
    cmd="$(jq -r '.statusLine.command' "$scratch/settings.json")"
    run env HOME="$real_home" sh -c "printf '{}' | { $cmd ; }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ORCA-USAGE"* ]]
    [[ "$output" == *"MINE"* ]]
    before_orca="${output%%ORCA-USAGE*}"
    before_mine="${output%%MINE*}"
    [ "${#before_orca}" -lt "${#before_mine}" ]
}

@test "ORCA_* variables pass through the wrapper env untouched" {
    make_project "$PROJECT_DIR"
    real_home="$(abspath "$(make_real_home)")"
    primary="$(abspath "$PROJECT_DIR")"

    export CLAUDE_ORCA_REAL_HOME="$real_home"
    export STUB_SRT_NOEXEC=1
    export ORCA_AGENT_HOOK_PORT=54321
    export ORCA_SESSION_ID="sess-abc"
    export ORCA_TERMINAL_ID="term-xyz"
    run "$ORCA_HOST/bin/claude-orca-shell" --root "$primary" --cwd "$primary" -- zsh
    unset STUB_SRT_NOEXEC CLAUDE_ORCA_REAL_HOME ORCA_AGENT_HOOK_PORT ORCA_SESSION_ID ORCA_TERMINAL_ID
    [ "$status" -eq 0 ]

    grep -qxF 'ORCA_AGENT_HOOK_PORT=54321' "$STUB_ENV"
    grep -qxF 'ORCA_SESSION_ID=sess-abc' "$STUB_ENV"
    grep -qxF 'ORCA_TERMINAL_ID=term-xyz' "$STUB_ENV"
}

@test "transcript symlink is written only when the flag file says Orca cannot see the config dir" {
    make_project "$PROJECT_DIR"
    real_home="$(abspath "$(make_real_home)")"
    primary="$(abspath "$PROJECT_DIR")"
    slug="$(printf '%s' "$primary" | tr '/.' '-')"
    link="$real_home/.claude/projects/$slug"
    target="$primary/.claude-dev/home/.claude/projects/$slug"

    export CLAUDE_ORCA_REAL_HOME="$real_home"
    export STUB_SRT_NOEXEC=1

    # Default sandbox.json (no orca.transcriptSymlink): no symlink.
    run "$ORCA_HOST/bin/claude-orca-shell" --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -eq 0 ]
    [ ! -e "$link" ]

    jq '.orca.transcriptSymlink = true' "$primary/.claude-dev/sandbox.json" \
        > "$BATS_TEST_TMPDIR/sandbox.json"
    mv "$BATS_TEST_TMPDIR/sandbox.json" "$primary/.claude-dev/sandbox.json"

    run "$ORCA_HOST/bin/claude-orca-shell" --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -eq 0 ]
    [ -L "$link" ]
    [ "$(readlink "$link")" = "$target" ]

    # Idempotent, and a real directory in the slot is never replaced.
    run "$ORCA_HOST/bin/claude-orca-shell" --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -eq 0 ]
    [ -L "$link" ]

    rm -f "$link"
    mkdir -p "$link"
    echo keep > "$link/real-transcript.jsonl"
    run "$ORCA_HOST/bin/claude-orca-shell" --root "$primary" --cwd "$primary" -- zsh
    unset STUB_SRT_NOEXEC CLAUDE_ORCA_REAL_HOME
    [ "$status" -eq 0 ]
    [ ! -L "$link" ]
    [ -d "$link" ]
    [ "$(cat "$link/real-transcript.jsonl")" = "keep" ]
}
