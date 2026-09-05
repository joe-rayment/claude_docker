#!/usr/bin/env bats
#
# V4 acceptance contract (claude-orca-qt9.4) -- FROZEN from RED-AT onward.
# With HOME redirected into the folder (.claude/plans/orca-port.md S9.1),
# Orca writes its managed hook entries and its statusline straight into
# <project>/.claude-dev/home/.claude/settings.json -- the very file
# config-sync regenerates from the template. So config-sync must PRESERVE
# Orca's entries and an existing Orca statusLine chain instead of wiping
# them; orca-hooks-merge, whose whole job was carrying them across the
# real-home/sandbox-home boundary, becomes a no-op once source and target
# are the same file; and the transcript symlink that worked around that
# same split is retired.

load helpers/setup

NEEDLE="/.orca/agent-hooks/"

ORCA_EVENTS=(SessionStart UserPromptSubmit Stop StopFailure SubagentStart \
    SubagentStop TeammateIdle PreToolUse PostToolUse PostToolUseFailure \
    PermissionRequest PostCompact)

CONFIG_SYNC() {
    "$CLAUDE_ORCA_HOME/template/scripts/config-sync.sh" "$@"
}

MERGE() {
    "$CLAUDE_ORCA_HOME/template/bin/orca-hooks-merge" "$@"
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

# Stands in for Orca-with-HOME-redirected: its installer dropping the 12
# managed hook entries and its statusline into the sandbox home's
# settings.json. Driven through orca-hooks-merge from a fixture "real
# home" so the bytes are exactly Orca's own (tests/fixtures/orca/), chain
# and .orca-statusline-base included. Uses $real_home and $config_dir.
install_orca_into_config_dir() {
    mkdir -p "$real_home/.claude"
    cp "$BATS_TEST_DIRNAME/fixtures/orca/claude-settings-with-orca.json" \
        "$real_home/.claude/settings.json"
    MERGE --real-home "$real_home" --config-dir "$config_dir"
}

@test "config-sync preserves Orca-managed hook entries and the Orca statusLine chain across two syncs and a template change" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    real_home="$(abspath "$(make_real_home)")"
    config_dir="$primary/.claude-dev/home/.claude"
    settings="$config_dir/settings.json"
    base_file="$config_dir/.orca-statusline-base"
    template_settings="$CLAUDE_ORCA_HOME/template/config/claude-settings.json"

    run CONFIG_SYNC --project "$primary" --host "$CLAUDE_ORCA_HOME"
    [ "$status" -eq 0 ]
    install_orca_into_config_dir
    [ "$(total_managed "$settings")" -eq 12 ]
    chained="$(jq -r '.statusLine.command' "$settings")"
    ours_v1="$(cat "$base_file")"
    [[ "$chained" == *"$ours_v1"* ]]

    # Sync #2, template untouched: the checksum gate skips the rewrite and
    # Orca's entries simply stay put.
    run CONFIG_SYNC --project "$primary" --host "$CLAUDE_ORCA_HOME"
    [ "$status" -eq 0 ]
    [ "$(total_managed "$settings")" -eq 12 ]
    [ "$(jq -r '.statusLine.command' "$settings")" = "$chained" ]

    # Sync #3, template CHANGED: a real rewrite -- which has to merge
    # Orca's entries back in and refresh only OUR half of the chain.
    jq '.statusLine.command = "__HOST__/template/bin/v4-statusline"' \
        "$template_settings" > "$BATS_TEST_TMPDIR/tpl.json"
    mv "$BATS_TEST_TMPDIR/tpl.json" "$template_settings"
    run CONFIG_SYNC --project "$primary" --host "$CLAUDE_ORCA_HOME"
    [ "$status" -eq 0 ]

    for ev in "${ORCA_EVENTS[@]}"; do
        [ "$(managed_count "$settings" "$ev")" -eq 1 ]
    done
    [ "$(total_managed "$settings")" -eq 12 ]
    grep -q 'template/bin/tier-prime' "$settings"
    grep -q 'template/bin/tier-gate' "$settings"

    ours_v2="$CLAUDE_ORCA_HOME/template/bin/v4-statusline"
    new_chain="$(jq -r '.statusLine.command' "$settings")"
    [[ "$new_chain" == *"claude-statusline.sh"* ]]
    [[ "$new_chain" == *"$ours_v2"* ]]
    [[ "$new_chain" != *"$ours_v1"* ]]
    orca_at="${new_chain%%claude-statusline.sh*}"
    ours_at="${new_chain%%$ours_v2*}"
    [ "${#orca_at}" -lt "${#ours_at}" ]
    run bash -n -c "$new_chain"
    [ "$status" -eq 0 ]
    [ "$(cat "$base_file")" = "$ours_v2" ]

    # And the rewrite lands on exactly the fixed point orca-hooks-merge
    # would: a following merge is a change of nothing.
    cp "$settings" "$BATS_TEST_TMPDIR/after-sync.json"
    run MERGE --real-home "$real_home" --config-dir "$config_dir"
    [ "$status" -eq 0 ]
    diff <(jq -S . "$BATS_TEST_TMPDIR/after-sync.json") <(jq -S . "$settings")
}

@test "config-sync still drops nothing of ours and settings.local.json still wins" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    real_home="$(abspath "$(make_real_home)")"
    config_dir="$primary/.claude-dev/home/.claude"
    settings="$config_dir/settings.json"

    mkdir -p "$config_dir"
    cat > "$config_dir/settings.local.json" <<'JSON'
{"model":"local-test-model","permissions":{"allow":["Bash(local-thing)"]}}
JSON
    local_before="$(cat "$config_dir/settings.local.json")"

    run CONFIG_SYNC --project "$primary" --host "$CLAUDE_ORCA_HOME"
    [ "$status" -eq 0 ]
    install_orca_into_config_dir

    # A template change forces the rewrite that has to keep everything.
    echo "# changed" >> "$CLAUDE_ORCA_HOME/template/config/claude-user-memory.md"
    run CONFIG_SYNC --project "$primary" --host "$CLAUDE_ORCA_HOME"
    [ "$status" -eq 0 ]

    [ "$(jq -r '.model' "$settings")" = "local-test-model" ]
    run jq -e '.permissions.allow | index("Bash(local-thing)") != null' "$settings"
    [ "$status" -eq 0 ]
    run jq -e '.permissions.allow | index("Bash(*)") != null' "$settings"
    [ "$status" -eq 0 ]
    [ "$(cat "$config_dir/settings.local.json")" = "$local_before" ]

    # Nothing of OURS differs from a pristine sync of the same template and
    # the same overlay into a project Orca never touched.
    pristine="$BATS_TEST_TMPDIR/pristine"
    mkdir -p "$pristine/.claude-dev/home/.claude"
    cp "$config_dir/settings.local.json" \
        "$pristine/.claude-dev/home/.claude/settings.local.json"
    run CONFIG_SYNC --project "$pristine" --host "$CLAUDE_ORCA_HOME"
    [ "$status" -eq 0 ]
    diff <(without_managed "$pristine/.claude-dev/home/.claude/settings.json") \
         <(without_managed "$settings")

    # The rest of the config dir is still fully repopulated, not just
    # settings.json.
    diff "$CLAUDE_ORCA_HOME/template/config/claude-user-memory.md" "$config_dir/CLAUDE.md"
    [ -x "$config_dir/statusline.sh" ]
    for f in "$CLAUDE_ORCA_HOME/template/config"/agents/*.md; do
        [ -f "$config_dir/agents/$(basename "$f")" ]
    done
}

@test "orca-hooks-merge is a no-op when the real home equals the sandbox home" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    real_home="$(abspath "$(make_real_home)")"
    config_dir="$primary/.claude-dev/home/.claude"
    settings="$config_dir/settings.json"
    sandbox_home="$primary/.claude-dev/home"

    run CONFIG_SYNC --project "$primary" --host "$CLAUDE_ORCA_HOME"
    [ "$status" -eq 0 ]
    cp "$settings" "$BATS_TEST_TMPDIR/pristine.json"
    install_orca_into_config_dir

    # HOME redirected into the folder: <real home>/.claude/settings.json IS
    # <config dir>/settings.json, so there is nothing to carry over and
    # re-merging would only nest the statusline chain into itself.
    before="$(cat "$settings")"
    before_base="$(cat "$config_dir/.orca-statusline-base")"
    run MERGE --real-home "$sandbox_home" --config-dir "$config_dir"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$settings")" = "$before" ]
    [ "$(cat "$config_dir/.orca-statusline-base")" = "$before_base" ]

    # Same file reached by a non-canonical path: still a no-op.
    run MERGE --real-home "$sandbox_home/." --config-dir "$config_dir"
    [ "$status" -eq 0 ]
    [ "$(cat "$settings")" = "$before" ]
    [ "$(total_managed "$settings")" -eq 12 ]

    # Not a blanket no-op: a genuinely separate real home still merges.
    cp "$BATS_TEST_TMPDIR/pristine.json" "$settings"
    rm -f "$config_dir/.orca-statusline-base"
    run MERGE --real-home "$real_home" --config-dir "$config_dir"
    [ "$status" -eq 0 ]
    [ "$(total_managed "$settings")" -eq 12 ]
    [[ "$(jq -r '.statusLine.command' "$settings")" == *"claude-statusline.sh"* ]]
}

@test "orca.transcriptSymlink is accepted, warns once and creates nothing" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    real_home="$(abspath "$(make_real_home)")"
    slug="$(printf '%s' "$primary" | tr '/.' '-')"
    link="$real_home/.claude/projects/$slug"
    sandbox_json="$primary/.claude-dev/sandbox.json"

    export CLAUDE_ORCA_REAL_HOME="$real_home"
    export STUB_SRT_NOEXEC=1

    # Absent (the default sandbox.json): not a word about it.
    run "$CLAUDE_ORCA_HOME/bin/claude-orca-shell" --root "$primary" --cwd "$primary" -- zsh
    [ "$status" -eq 0 ]
    [[ "$output" != *"transcriptSymlink"* ]]

    jq '.orca.transcriptSymlink = true' "$sandbox_json" > "$BATS_TEST_TMPDIR/sandbox.json"
    mv "$BATS_TEST_TMPDIR/sandbox.json" "$sandbox_json"

    run "$CLAUDE_ORCA_HOME/bin/claude-orca-shell" --root "$primary" --cwd "$primary" -- zsh
    unset STUB_SRT_NOEXEC CLAUDE_ORCA_REAL_HOME
    # Accepted: a retired key never fails a launch.
    [ "$status" -eq 0 ]
    # Warned, once, and said it is retired.
    [ "$(printf '%s\n' "$output" | grep -c 'orca\.transcriptSymlink')" -eq 1 ]
    [[ "$output" == *"retired"* ]]
    # And created nothing, on either side of the old boundary.
    [ ! -e "$link" ]
    [ ! -e "$real_home/.claude/projects" ]
    [ ! -e "$primary/.claude-dev/home/.claude/projects" ]
}
