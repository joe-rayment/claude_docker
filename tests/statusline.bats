#!/usr/bin/env bats

# statusline.bats — config/statusline.sh gains three new segments (prompt-cache
# hit ratio, context-window remaining, session cost) fed by JSON fields Claude
# Code >=2.1.251 emits, degrading byte-identically to today's output when those
# fields are absent (the container is 2.1.247, so absence is the live case
# until the next image rebuild). See beads_claude_docker-1jw.

STATUSLINE=${STATUSLINE_BIN:-"$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/config/statusline.sh"}
FIXTURES="${BATS_TEST_DIRNAME}/fixtures"
CACHE_FILE="/tmp/claude-usage-cache.json"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    # statusline.sh reads a live usage-limits cache at a hardcoded absolute
    # path (not parameterized by TMPDIR/HOME), refreshing it from a real API
    # call once it's stale. Freeze it to a known-fresh, known-value file so
    # the pre-existing session/weekly segments are deterministic and no
    # network fetch can race the assertions below.
    if [ -f "$CACHE_FILE" ]; then
        cp "$CACHE_FILE" "$BATS_TEST_TMPDIR/cache.orig"
    fi
    printf '{"five_hour":{"utilization":17.0},"seven_day":{"utilization":54.0}}\n' > "$CACHE_FILE"
}

teardown() {
    if [ -f "$BATS_TEST_TMPDIR/cache.orig" ]; then
        cp "$BATS_TEST_TMPDIR/cache.orig" "$CACHE_FILE"
    else
        rm -f "$CACHE_FILE"
    fi
}

@test "statusline: full fixture renders the prompt-cache hit-ratio percent" {
    run bash "$STATUSLINE" < "$FIXTURES/statusline-full.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cache 87%"* ]]
}

@test "statusline: full fixture renders the context-window remaining percent" {
    run bash "$STATUSLINE" < "$FIXTURES/statusline-full.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ctx 62%"* ]]
}

@test "statusline: full fixture renders the session cost in USD" {
    run bash "$STATUSLINE" < "$FIXTURES/statusline-full.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'$3.42'* ]]
}

@test "statusline: legacy fixture output is byte-identical to the pre-change script (regression guard)" {
    # Golden captured from the pre-change script against this exact fixture,
    # with the usage cache seeded as above (see setup()). At RED (script not
    # yet touched) this case is expected to pass trivially — it only starts
    # proving the no-op-on-absence guarantee once the new segments exist.
    golden=$'\033[32mSonnet\033[0m | \033[33m\xe2\x97\x8f\xe2\x97\x8f\xe2\x97\x8f\xe2\x97\x8f\xe2\x97\x8b\xe2\x97\x8b\xe2\x97\x8b\xe2\x97\x8b\xe2\x97\x8b\xe2\x97\x8b 45%\033[0m | \033[36mmain\033[0m | session: \033[32m17%\033[0m | weekly: \033[32m54%\033[0m'
    run bash "$STATUSLINE" < "$FIXTURES/statusline-legacy.json"
    [ "$status" -eq 0 ]
    [ "$output" = "$golden" ]
}
