#!/usr/bin/env bats
#
# card-control.bats -- scripts/card.sh (bin/card): on|off|toggle|status|
# autostart, anchored to the terminal it runs in (claude-orca-ao7.1, design
# claude-orca-ao7). FROZEN from this file's RED-AT commit onward per the
# bead's acceptance contract -- if a case here turns out wrong, stop and
# report; do not edit it.
#
# CLASS: unit. The `orca` CLI is stubbed as a script on PATH in setup(), so
# no Orca runtime is ever contacted: every assertion below reads either the
# stub's own invocation log ($STUB_LOG, one line per call: `terminal split
# --terminal ... --command ...`) or the state files card.sh itself writes
# (card.state, card.pane) under a throwaway $PROJECT_DIR.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CARD="$REPO_ROOT/scripts/card.sh"

# Builds { ok:true, result:{ terminals:[ ... ] } } from raw JSON object
# strings, e.g. write_terminals_fixture "$f" '{"handle":"a","leafId":"x"}'.
write_terminals_fixture() {
    local out="$1" terms="" sep=""
    shift
    for t in "$@"; do
        terms="${terms}${sep}${t}"
        sep=","
    done
    printf '{"ok":true,"result":{"terminals":[%s]}}' "$terms" > "$out"
}

# A working orca stub: logs every invocation to $CARD_STUB_DIR/log (one
# line, "terminal split --terminal ... --json" etc.) and answers `terminal
# list --json` from $CARD_STUB_DIR/terminals.json, `terminal split` by
# minting a new handle (term_card_new_<n>, one per call) and appending it
# to that same fixture so a later `terminal list` finds it live, and
# `terminal rename` / `terminal close` with a bare {"ok":true}.
write_working_orca_stub() {
    cat > "$1" <<'STUBEOF'
#!/usr/bin/env bash
set -u
LOG="$CARD_STUB_DIR/log"
TERMS="$CARD_STUB_DIR/terminals.json"
printf '%s\n' "$*" >> "$LOG"
case "${1:-} ${2:-}" in
    "terminal list")
        cat "$TERMS"
        ;;
    "terminal split")
        count_file="$CARD_STUB_DIR/split_count"
        n=0
        [ -f "$count_file" ] && n="$(cat "$count_file")"
        n=$((n + 1))
        printf '%s' "$n" > "$count_file"
        new_handle="term_card_new_${n}"
        jq --arg h "$new_handle" \
            '.result.terminals += [{"handle":$h,"leafId":"leaf-card","tabId":"tab-card","title":"CARD"}]' \
            "$TERMS" > "$TERMS.tmp" && mv "$TERMS.tmp" "$TERMS"
        printf '{"ok":true,"result":{"split":{"handle":"%s"}}}\n' "$new_handle"
        ;;
    "terminal rename")
        printf '{"ok":true}\n'
        ;;
    "terminal close")
        printf '{"ok":true}\n'
        ;;
    *)
        printf '{"ok":true,"result":{}}\n'
        ;;
esac
exit 0
STUBEOF
    chmod +x "$1"
}

# An orca CLI that stands in for an unreachable runtime: found on PATH, but
# every call fails with no stdout at all.
write_dead_orca_stub() {
    cat > "$1" <<'STUBEOF'
#!/usr/bin/env bash
exit 1
STUBEOF
    chmod +x "$1"
}

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    export PROJECT_DIR="$BATS_TEST_TMPDIR/project"
    mkdir -p "$PROJECT_DIR"
    RUN_DIR="$PROJECT_DIR/.claude-dev/run"
    STATE_FILE="$RUN_DIR/card.state"
    PANE_FILE="$RUN_DIR/card.pane"

    STUB_BIN="$BATS_TEST_TMPDIR/stubbin"
    mkdir -p "$STUB_BIN"
    export CARD_STUB_DIR="$BATS_TEST_TMPDIR/stub-data"
    mkdir -p "$CARD_STUB_DIR"
    STUB_LOG="$CARD_STUB_DIR/log"
    : > "$STUB_LOG"

    write_terminals_fixture "$CARD_STUB_DIR/terminals.json" \
        '{"handle":"term_other","leafId":"leaf-other","tabId":"tab-x"}' \
        '{"handle":"term_self","leafId":"leaf-self","tabId":"tab-x"}'

    write_working_orca_stub "$STUB_BIN/orca"
    export PATH="$STUB_BIN:$PATH"
    export ORCA_PANE_KEY="tab-x:leaf-self"
}

# ── resolving this terminal's own handle ─────────────────────────────────────

@test "card resolves its own terminal handle from the leaf id in ORCA_PANE_KEY" {
    run bash "$CARD" on
    [ "$status" -eq 0 ]
    split_line="$(grep '^terminal split' "$STUB_LOG")"
    [[ "$split_line" == *"--terminal term_self"* ]]
    [[ "$split_line" != *"--terminal term_other"* ]]
}

# ── on ────────────────────────────────────────────────────────────────────

@test "card on splits that terminal, renames the pane CARD, and records the handle and the on state" {
    run bash "$CARD" on
    [ "$status" -eq 0 ]
    split_line="$(grep '^terminal split' "$STUB_LOG")"
    [[ "$split_line" == *"--terminal term_self"* ]]
    [[ "$split_line" == *"card-view.sh"* ]]
    rename_line="$(grep '^terminal rename' "$STUB_LOG")"
    [[ "$rename_line" == *"--title CARD"* ]]
    [[ "$rename_line" == *"term_card_new_1"* ]]
    [ "$(cat "$PANE_FILE")" = "term_card_new_1" ]
    [ "$(cat "$STATE_FILE")" = "on" ]
}

@test "card on is idempotent: a second call while the recorded pane is live splits nothing" {
    run bash "$CARD" on
    [ "$status" -eq 0 ]
    run bash "$CARD" on
    [ "$status" -eq 0 ]
    splits="$(grep -c '^terminal split' "$STUB_LOG" || true)"
    [ "$splits" -eq 1 ]
    [ "$(cat "$PANE_FILE")" = "term_card_new_1" ]
    [ "$(cat "$STATE_FILE")" = "on" ]
}

# ── off ───────────────────────────────────────────────────────────────────

@test "card off closes the recorded pane and records the off state" {
    run bash "$CARD" on
    [ "$status" -eq 0 ]
    pane="$(cat "$PANE_FILE")"
    run bash "$CARD" off
    [ "$status" -eq 0 ]
    close_line="$(grep '^terminal close' "$STUB_LOG")"
    [[ "$close_line" == *"--terminal $pane"* ]]
    [ "$(cat "$STATE_FILE")" = "off" ]
}

# ── toggle ────────────────────────────────────────────────────────────────

@test "card toggle flips on to off and off to on" {
    [ ! -f "$STATE_FILE" ]
    run bash "$CARD" toggle
    [ "$status" -eq 0 ]
    [ "$(cat "$STATE_FILE")" = "off" ]
    splits="$(grep -c '^terminal split' "$STUB_LOG" || true)"
    [ "$splits" -eq 0 ]

    run bash "$CARD" toggle
    [ "$status" -eq 0 ]
    [ "$(cat "$STATE_FILE")" = "on" ]
    splits="$(grep -c '^terminal split' "$STUB_LOG" || true)"
    [ "$splits" -eq 1 ]
}

# ── autostart ─────────────────────────────────────────────────────────────

@test "card autostart opens a pane when the state is on or unset and stays quiet when it is off" {
    [ ! -f "$STATE_FILE" ]
    run bash "$CARD" autostart
    [ "$status" -eq 0 ]
    splits="$(grep -c '^terminal split' "$STUB_LOG" || true)"
    [ "$splits" -eq 1 ]
    [ -f "$PANE_FILE" ]

    mkdir -p "$RUN_DIR"
    printf 'off' > "$STATE_FILE"
    run bash "$CARD" autostart
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    splits="$(grep -c '^terminal split' "$STUB_LOG" || true)"
    [ "$splits" -eq 1 ]
}

# ── fails open ────────────────────────────────────────────────────────────

@test "card exits 0 with one explanatory line when there is no ORCA_PANE_KEY, no orca CLI, or an unreachable runtime" {
    run env -u ORCA_PANE_KEY bash "$CARD" on
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]

    run env PATH="/usr/bin:/bin" ORCA_PANE_KEY="tab-x:leaf-self" bash "$CARD" on
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]

    dead_dir="$BATS_TEST_TMPDIR/deadbin"
    mkdir -p "$dead_dir"
    write_dead_orca_stub "$dead_dir/orca"
    run env PATH="$dead_dir:/usr/bin:/bin" ORCA_PANE_KEY="tab-x:leaf-self" bash "$CARD" on
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}
