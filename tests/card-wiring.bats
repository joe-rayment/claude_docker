#!/usr/bin/env bats
#
# S3 acceptance contract (claude-orca-ao7.3) -- FROZEN from RED-AT onward.
# The card panel's WIRING: the two hook entries, the /card slash command and
# the sync that carries it into a folder. The scripts themselves are pinned
# by tests/card-control.bats and tests/card-render.bats.

load helpers/setup

SETTINGS="$BATS_TEST_DIRNAME/../config/claude-settings.json"
COMMAND_MD="$BATS_TEST_DIRNAME/../config/claude-commands/card.md"

# Every command string registered for one hook event, one per line.
hook_commands() {
    jq -r --arg e "$1" '.hooks[$e][].hooks[].command' "$SETTINGS"
}

@test "SessionStart runs card autostart in the background so it cannot delay a session" {
    run hook_commands SessionStart
    [ "$status" -eq 0 ]

    line="$(printf '%s\n' "$output" | grep -F '/bin/card" autostart' || true)"
    [ -n "$line" ]
    # The disk-cleanup idiom: subshell, output discarded, ampersand -- the
    # session never waits on Orca answering.
    [[ "$line" == *'>/dev/null 2>&1 &)'* ]]
    # ... and never the blocking form.
    [[ "$line" != *'exec '* ]]
}

@test "Stop runs card update in the background so it cannot delay a turn" {
    run hook_commands Stop
    [ "$status" -eq 0 ]
    [[ "$output" == *'/bin/card-hook'* ]]

    # card-hook is what makes it background: it reads the payload in the
    # foreground (instant) and detaches the model call, which is the slow
    # part. Assert it never runs card-update.sh inline.
    hook="$BATS_TEST_DIRNAME/../scripts/card-hook.sh"
    [ -x "$hook" ]
    grep -q 'card-update.sh' "$hook"
    run grep -cE '(setsid|\) *>/dev/null 2>&1 *&|&$)' "$hook"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
    # No line invokes the updater without detaching it.
    ! grep -qE '^[[:space:]]*"?\$UPDATE"?[[:space:]]*<' "$hook"
}

@test "every card hook entry is guarded, so a folder whose template lacks the script still starts" {
    seen=0
    for event in SessionStart Stop; do
        while IFS= read -r line; do
            case "$line" in
                *"/bin/card"*)
                    seen=$((seen + 1))
                    [[ "$line" == '[ -x '* ]]
                    [[ "$line" == *'exit 0'* ]]
                    ;;
            esac
        done < <(hook_commands "$event")
    done
    # Never vacuous: both entries have to be there to be checked at all.
    [ "$seen" -ge 2 ]
}

@test "the /card slash command is a trivial passthrough to card and documents on, off and toggle" {
    [ -f "$COMMAND_MD" ]
    grep -q '^allowed-tools: Bash(card:\*)$' "$COMMAND_MD"
    grep -q '^!`card \$ARGUMENTS`$' "$COMMAND_MD"
    grep -qi 'verbatim' "$COMMAND_MD"
    grep -qi 'toggle' "$COMMAND_MD"
    grep -q 'on | off | status' "$COMMAND_MD"
}

@test "config-sync mirrors the card command into the project's .claude/commands" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    rm -f "$PROJECT_DIR/.claude-dev/run/config-hash"

    run "$ORCA_HOST/template/scripts/config-sync.sh" --project "$primary" --host "$ORCA_HOST"
    [ "$status" -eq 0 ]

    dest="$primary/.claude-dev/home/.claude/commands/card.md"
    [ -f "$dest" ]
    diff "$ORCA_HOST/template/config/claude-commands/card.md" "$dest"
}
