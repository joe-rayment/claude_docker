#!/usr/bin/env bats
#
# claude-orca-oxr -- FROZEN from RED-AT onward.
# Acceptance contract for removing the /card index-card panel: nothing
# under scripts/, bin/, config/ or tests/ still names it, the shipped
# settings.json no longer wires a card hook (and stays valid, non-empty),
# and the README no longer documents it.
# One deliberate edit since: case 2 now expects the off-ramp Stop check
# (claude-orca-ngq.1) beside export-logs -- a later feature, not a pass
# forced on the card removal.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SETTINGS="$REPO_ROOT/config/claude-settings.json"

# Word-ish match: "card" not immediately preceded/followed by a letter, so
# discard/wildcard/cardinal (and cardStatus) don't trip it. Prove it's not
# vacuous below.
CARD_PATTERN='(^|[^a-z])card([^a-z]|$)'

@test "the shipped settings.json is valid json and leaves no hook array empty" {
    run jq -e . "$SETTINGS"
    [ "$status" -eq 0 ]

    run jq -e '[.hooks[][].hooks | length] | any(. == 0)' "$SETTINGS"
    [ "$status" -eq 1 ]
    [ "$output" = "false" ]
}

@test "the Stop hook still runs export-logs, and Orca's own managed entries survive" {
    run jq -r '.hooks.Stop[].hooks[].command' "$SETTINGS"
    [ "$status" -eq 0 ]
    [[ "$output" == *'export-logs'* ]]
    [[ "$output" != *card* ]]

    # Orca's own managed entries (e.g. under ~/.orca/agent-hooks/) are
    # injected by config-sync into a synced project, not shipped in this
    # template file -- so the invariant here is simply that removing the
    # card entry didn't touch anything else in the array: what is left is
    # export-logs, then the off-ramp's Stop check (claude-orca-ngq.1).
    run jq -r '.hooks.Stop[0].hooks[].command' "$SETTINGS"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[0]}" == *'bin/export-logs'* ]]
    [[ "${lines[1]}" == *'bin/offramp" --stop'* ]]
}
