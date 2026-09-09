#!/usr/bin/env bats
# card-render.bats -- S2 acceptance contract (claude-orca-ao7.2), FROZEN from
# RED-AT onward. Covers scripts/card-update.sh (the Stop hook's worker: a
# transcript tail -> a small model -> .claude-dev/run/card.md) and
# scripts/card-view.sh (the pane: clear + repaint one boxed card, never
# scroll). CLASS: unit -- `claude` is stubbed on PATH and returns a canned
# card; no model is ever called.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CARD_UPDATE="$REPO_ROOT/scripts/card-update.sh"
CARD_VIEW="$REPO_ROOT/scripts/card-view.sh"

setup() {
    export STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    export PATH="$STUB_BIN:$PATH"
    unset CLAUDE_STUB_OUTPUT CLAUDE_STUB_EMPTY CLAUDE_STUB_LOG

    cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
# Canned model: never a real call, per CLASS. Logs its stdin (the material
# sent for a card) when CLAUDE_STUB_LOG is set, then answers from
# CLAUDE_STUB_OUTPUT, or prints nothing when CLAUDE_STUB_EMPTY is set, or
# else a fixed, valid card.
input="$(cat)"
if [ -n "${CLAUDE_STUB_LOG:-}" ]; then
    printf '%s' "$input" > "$CLAUDE_STUB_LOG"
fi
[ -n "${CLAUDE_STUB_EMPTY:-}" ] && exit 0
if [ -n "${CLAUDE_STUB_OUTPUT:-}" ]; then
    printf '%s' "$CLAUDE_STUB_OUTPUT"
else
    cat <<'CARD'
NOW: stub now line
WHY: stub why line
DONE: stub done thing one
NEXT: stub next line
SNAG: -
CARD
fi
STUB
    chmod +x "$STUB_BIN/claude"

    export CARD_FILE="$BATS_TEST_TMPDIR/card.md"
    export CARD_MODEL="stub-model"
}

# Writes a minimal but valid transcript at $1 -- one user turn, one
# assistant turn, both isSidechain:false.
write_basic_transcript() {
    local path="$1"
    {
        jq -nc '{type:"user", isSidechain:false, message:{role:"user", content:"please fix the flaky test"}}'
        jq -nc '{type:"assistant", isSidechain:false, message:{role:"assistant", content:[{type:"text", text:"looked at tests/foo.bats"},{type:"tool_use", name:"Bash", input:{command:"bats tests/foo.bats"}}]}}'
    } > "$path"
}

# ── card-update ──────────────────────────────────────────────────────────

@test "card-update takes transcript_path from the hook payload on stdin and writes the card file" {
    transcript="$BATS_TEST_TMPDIR/transcript.jsonl"
    write_basic_transcript "$transcript"

    payload="$(jq -nc --arg t "$transcript" '{transcript_path:$t, hook_event_name:"Stop"}')"
    run bash -c "printf '%s' \"\$1\" | \"\$2\"" _ "$payload" "$CARD_UPDATE"
    [ "$status" -eq 0 ]
    [ -f "$CARD_FILE" ]
    grep -q '^NOW: stub now line$' "$CARD_FILE"
    grep -q '^WHY: stub why line$' "$CARD_FILE"
    grep -q '^SNAG: -$' "$CARD_FILE"
}

@test "card-update replaces the card atomically, so a reader never sees a partial card" {
    # Static: the only way CARD_FILE is ever touched is a rename off a
    # sibling temp path -- never a direct redirection into it.
    grep -qE '\$CARD_FILE\.[A-Za-z]*tmp' "$CARD_UPDATE"
    grep -qE 'mv .*"\$CARD_FILE"' "$CARD_UPDATE"
    ! grep -qE '(^|[^"])>[[:space:]]*"\$CARD_FILE"([^.]|$)' "$CARD_UPDATE"

    # Behavioural: an old card survives untouched right up until the new one
    # is completely ready, and no temp file is left behind afterward.
    printf 'OLD CARD CONTENT\n' > "$CARD_FILE"
    transcript="$BATS_TEST_TMPDIR/transcript.jsonl"
    write_basic_transcript "$transcript"
    run "$CARD_UPDATE" "$transcript"
    [ "$status" -eq 0 ]
    grep -q '^NOW: stub now line$' "$CARD_FILE"
    ! grep -q 'OLD CARD CONTENT' "$CARD_FILE"
    shopt -s nullglob
    leftovers=("$BATS_TEST_TMPDIR"/card.md.*tmp*)
    [ "${#leftovers[@]}" -eq 0 ]
}

@test "card-update sends the model no thinking blocks and stays inside its byte budget" {
    transcript="$BATS_TEST_TMPDIR/transcript.jsonl"
    big_user="HEADMARK$(python3 -c "print('U' * 20000)")TAILMARK"
    big_think="THINKMARK$(python3 -c "print('T' * 20000)")"
    {
        jq -nc --arg t "$big_user" '{type:"user", isSidechain:false, message:{role:"user", content:[{type:"text", text:$t}]}}'
        jq -nc --arg t "$big_think" '{type:"assistant", isSidechain:false, message:{role:"assistant", content:[{type:"thinking", thinking:$t},{type:"text", text:"replied briefly"}]}}'
    } > "$transcript"

    export CLAUDE_STUB_LOG="$BATS_TEST_TMPDIR/sent.txt"
    run "$CARD_UPDATE" "$transcript"
    [ "$status" -eq 0 ]
    [ -f "$CLAUDE_STUB_LOG" ]

    ! grep -q 'THINKMARK' "$CLAUDE_STUB_LOG"
    ! grep -q 'TAILMARK' "$CLAUDE_STUB_LOG"
    grep -q 'HEADMARK' "$CLAUDE_STUB_LOG"

    sent_bytes="$(wc -c < "$CLAUDE_STUB_LOG")"
    [ "$sent_bytes" -lt 9000 ]
}

@test "card-update exits 0 and leaves the previous card in place when there is no transcript or the model returns nothing" {
    printf 'PRE-EXISTING CARD\n' > "$CARD_FILE"

    # No transcript at all: the payload names none.
    run bash -c "printf '%s' '{}' | \"\$1\"" _ "$CARD_UPDATE"
    [ "$status" -eq 0 ]
    grep -q 'PRE-EXISTING CARD' "$CARD_FILE"

    # A transcript path that does not exist.
    run "$CARD_UPDATE" "$BATS_TEST_TMPDIR/does-not-exist.jsonl"
    [ "$status" -eq 0 ]
    grep -q 'PRE-EXISTING CARD' "$CARD_FILE"

    # A real transcript, but the model returns nothing.
    transcript="$BATS_TEST_TMPDIR/transcript.jsonl"
    write_basic_transcript "$transcript"
    export CLAUDE_STUB_EMPTY=1
    run "$CARD_UPDATE" "$transcript"
    [ "$status" -eq 0 ]
    grep -q 'PRE-EXISTING CARD' "$CARD_FILE"
    ! grep -q 'stub now line' "$CARD_FILE"
}

# ── card-view ────────────────────────────────────────────────────────────

strip_ansi() {
    sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g'
}

@test "card-view draws one boxed card clipped to the pane and repeats no line of it" {
    command -v script >/dev/null 2>&1 || skip "script is not installed"

    {
        printf 'NOW: %s\n' "$(python3 -c "print('X' * 60)")"
        for i in 1 2 3 4 5 6 7 8 9; do
            printf 'LINE-%s some filler text for this row\n' "$i"
        done
    } > "$CARD_FILE"

    run script -qec "env COLUMNS=30 LINES=8 CARD_FILE='$CARD_FILE' timeout 0.3 bash '$CARD_VIEW'" /dev/null
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]

    plain="$(printf '%s' "$output" | strip_ansi)"

    # Exactly one box: opened once, closed once -- never appended into a
    # second frame during this one short draw window.
    [ "$(printf '%s\n' "$plain" | grep -c '┌')" -eq 1 ]
    [ "$(printf '%s\n' "$plain" | grep -c '└')" -eq 1 ]

    # Every visible line clipped to the pane width. The trailing carriage
    # return comes off first: the pty translates each \n to \r\n, so it is
    # in every captured line and it is not a column. (card-view.sh used to
    # set `stty -onlcr`, which is why this once measured clean -- and why
    # the panel drew as a staircase, since without the CR every line began
    # where the last one ended.)
    while IFS= read -r line; do
        line="${line%$'\r'}"
        len="${#line}"
        [ "$len" -le 30 ]
    done <<< "$plain"

    # Clipped to the pane height: 9 fixture lines plus the two borders can
    # never all fit in 8 rows, so at least one fixture line is missing.
    total_lines="$(printf '%s\n' "$plain" | grep -c .)"
    [ "$total_lines" -le 8 ]
    missing=0
    for i in 1 2 3 4 5 6 7 8 9; do
        printf '%s\n' "$plain" | grep -q "LINE-$i " || missing=1
    done
    [ "$missing" -eq 1 ]

    # No content line repeated within the frame (the pane never scrolls a
    # duplicate copy of anything already shown).
    dupes="$(printf '%s\n' "$plain" | grep '^LINE-' | sort | uniq -d)"
    [ -z "$dupes" ]
}

@test "card-view repaints when the card file changes and not otherwise" {
    command -v script >/dev/null 2>&1 || skip "script is not installed"

    printf 'NOW: alpha state AAAA\nWHY: first\nDONE: -\nNEXT: -\nSNAG: -\n' > "$CARD_FILE"

    driver="$BATS_TEST_TMPDIR/drive.sh"
    cat > "$driver" <<DRV
#!/usr/bin/env bash
env COLUMNS=30 LINES=8 CARD_FILE='$CARD_FILE' bash '$CARD_VIEW' &
pid=\$!
sleep 1.0
printf 'NOW: bravo state BBBB\nWHY: second\nDONE: -\nNEXT: -\nSNAG: -\n' > '$CARD_FILE'
sleep 1.0
kill \$pid 2>/dev/null
wait \$pid 2>/dev/null
DRV
    chmod +x "$driver"

    run script -qec "$driver" /dev/null
    plain="$(printf '%s' "$output" | strip_ansi)"

    # Redrawn exactly twice: once for the initial content, once after the
    # file changed -- never once per idle loop tick in between.
    frames="$(printf '%s\n' "$plain" | grep -c '┌')"
    [ "$frames" -eq 2 ]
    printf '%s\n' "$plain" | grep -q 'AAAA'
    printf '%s\n' "$plain" | grep -q 'BBBB'

    # The BBBB frame is the last thing drawn, i.e. the change came after
    # the idle period, not before.
    last_frame="$(printf '%s\n' "$plain" | awk '/┌/{buf=""} {buf=buf"\n"$0} END{print buf}')"
    [[ "$last_frame" == *"BBBB"* ]]
    [[ "$last_frame" != *"AAAA"* ]]
}
