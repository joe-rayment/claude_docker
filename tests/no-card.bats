#!/usr/bin/env bats
#
# claude-orca-oxr -- FROZEN from RED-AT onward.
# Acceptance contract for removing the /card index-card panel: nothing
# under scripts/, bin/, config/ or tests/ still names it, the shipped
# settings.json no longer wires a card hook (and stays valid, non-empty),
# and the README no longer documents it.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SETTINGS="$REPO_ROOT/config/claude-settings.json"

# Word-ish match: "card" not immediately preceded/followed by a letter, so
# discard/wildcard/cardinal (and cardStatus) don't trip it. Prove it's not
# vacuous below.
CARD_PATTERN='(^|[^a-z])card([^a-z]|$)'

@test "no card scripts, bin links, command or tests remain" {
    [ ! -e "$REPO_ROOT/bin/card" ]
    [ ! -e "$REPO_ROOT/bin/card-hook" ]
    [ ! -e "$REPO_ROOT/scripts/card.sh" ]
    [ ! -e "$REPO_ROOT/scripts/card-hook.sh" ]
    [ ! -e "$REPO_ROOT/scripts/card-update.sh" ]
    [ ! -e "$REPO_ROOT/scripts/card-view.sh" ]
    [ ! -e "$REPO_ROOT/config/claude-commands/card.md" ]
    [ ! -e "$REPO_ROOT/tests/card-control.bats" ]
    [ ! -e "$REPO_ROOT/tests/card-render.bats" ]
    [ ! -e "$REPO_ROOT/tests/card-wiring.bats" ]

    # Prove the pattern actually catches the word before trusting its
    # absence below.
    tmp="$BATS_TEST_TMPDIR/canary.txt"
    echo "this file mentions card in it" > "$tmp"
    run grep -iE "$CARD_PATTERN" "$tmp"
    [ "$status" -eq 0 ]

    run grep -rniE "$CARD_PATTERN" \
        --exclude-dir=.git \
        --exclude=no-card.bats \
        --exclude-dir=orca-skills \
        "$REPO_ROOT/scripts" "$REPO_ROOT/bin" "$REPO_ROOT/config" "$REPO_ROOT/tests"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "no hook entry in the shipped settings.json runs a card binary" {
    run grep -iE "$CARD_PATTERN" "$SETTINGS"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "the shipped settings.json is valid json and leaves no hook array empty" {
    run jq -e . "$SETTINGS"
    [ "$status" -eq 0 ]

    run jq -e '.hooks | to_entries[] | .value[] | .hooks | length == 0' "$SETTINGS"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "the Stop hook still runs export-logs, and Orca's own managed entries survive" {
    run jq -r '.hooks.Stop[].hooks[].command' "$SETTINGS"
    [ "$status" -eq 0 ]
    [[ "$output" == *'export-logs'* ]]
    [[ "$output" != *card* ]]

    # Orca's own managed entries (e.g. under ~/.orca/agent-hooks/) are
    # injected by config-sync into a synced project, not shipped in this
    # template file -- so the invariant here is simply that removing the
    # card entry didn't touch anything else in the array.
    run jq -e '.hooks.Stop[0].hooks | length' "$SETTINGS"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "the README no longer documents the index card" {
    run grep -iE "$CARD_PATTERN" "$REPO_ROOT/README.md"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}
