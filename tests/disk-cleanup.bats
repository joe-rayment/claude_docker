#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# disk-cleanup.bats — beads claude-orca-3fp's acceptance contract (FROZEN
# from its RED commit onward: never edit to make an implementation pass).
#
# Covers the 3fp sweeps: dated graphify-out/<YYYY-MM-DD>/ dirs, aged session
# transcripts under the config dir's projects/, aged npm _cacache content,
# the --report mode, and idempotence. ms-playwright is reported, never swept.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CLEANUP="$REPO_ROOT/scripts/disk-cleanup.sh"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    export HOME="$BATS_TEST_TMPDIR/home"
    export TMP_SCAN_DIR="$BATS_TEST_TMPDIR/scan"
    export WORKSPACE="$BATS_TEST_TMPDIR/ws"
    mkdir -p "$HOME" "$TMP_SCAN_DIR" "$WORKSPACE"
}

# an old file, or a fresh one, by mtime
aged() { touch -d "$1" "$2"; }

# the dated-snapshot fixture: two dated dirs, the canonical root set
graphify_fixture() {
    mkdir -p "$WORKSPACE/graphify-out/2026-09-05" "$WORKSPACE/graphify-out/2026-09-08" \
        "$WORKSPACE/graphify-out/cache"
    printf '{}' > "$WORKSPACE/graphify-out/2026-09-05/graph.json"
    printf '{}' > "$WORKSPACE/graphify-out/2026-09-08/manifest.json"
    printf '{}' > "$WORKSPACE/graphify-out/graph.json"
    printf 'report' > "$WORKSPACE/graphify-out/GRAPH_REPORT.md"
    printf '{}' > "$WORKSPACE/graphify-out/manifest.json"
    printf '{}' > "$WORKSPACE/graphify-out/cache/e.json"
}

@test "sweep: dated graphify dirs go and the root graph set stays" {
    graphify_fixture

    run bash "$CLEANUP"
    [ "$status" -eq 0 ]
    [ ! -d "$WORKSPACE/graphify-out/2026-09-05" ]
    [ ! -d "$WORKSPACE/graphify-out/2026-09-08" ]
    [ -f "$WORKSPACE/graphify-out/graph.json" ]
    [ -f "$WORKSPACE/graphify-out/GRAPH_REPORT.md" ]
    [ -f "$WORKSPACE/graphify-out/manifest.json" ]
    [ -f "$WORKSPACE/graphify-out/cache/e.json" ]
}

@test "sweep: a 31-day-old transcript goes and a 1-day-old stays" {
    proj="$HOME/.claude/projects/proj-a"
    mkdir -p "$proj"
    printf 'old\n' > "$proj/session-old.jsonl"
    aged '31 days ago' "$proj/session-old.jsonl"
    printf 'new\n' > "$proj/session-new.jsonl"
    aged '1 day ago' "$proj/session-new.jsonl"

    run bash "$CLEANUP"
    [ "$status" -eq 0 ]
    [ ! -f "$proj/session-old.jsonl" ]
    [ -f "$proj/session-new.jsonl" ]
}

@test "sweep: npm cache files older than 14 days go and empty dirs are pruned" {
    old="$HOME/.npm/_cacache/content-v2/sha512/dead"
    fresh="$HOME/.npm/_cacache/content-v2/sha512/live"
    lone="$HOME/.npm/_cacache/index-v5/only"
    mkdir -p "$old" "$fresh" "$lone"
    printf 'blob' > "$old/old.bin"; aged '20 days ago' "$old/old.bin"
    printf 'blob' > "$fresh/new.bin"; aged '1 day ago' "$fresh/new.bin"
    printf 'idx' > "$lone/old.idx"; aged '20 days ago' "$lone/old.idx"

    run bash "$CLEANUP"
    [ "$status" -eq 0 ]
    [ ! -f "$old/old.bin" ]
    [ -f "$fresh/new.bin" ]
    [ ! -e "$lone/old.idx" ]
    [ ! -d "$lone" ]
    [ -d "$fresh" ]
}

@test "sweep: transcript and npm thresholds are overridable" {
    proj="$HOME/.claude/projects/proj-b"
    mkdir -p "$proj" "$HOME/.npm/_cacache"
    printf 'mid\n' > "$proj/session-mid.jsonl"
    aged '5 days ago' "$proj/session-mid.jsonl"
    printf 'blob' > "$HOME/.npm/_cacache/mid.bin"
    aged '5 days ago' "$HOME/.npm/_cacache/mid.bin"

    CLAUDE_ORCA_CLEANUP_TRANSCRIPT_DAYS=3 CLAUDE_ORCA_CLEANUP_NPM_DAYS=3 \
        run bash "$CLEANUP"
    [ "$status" -eq 0 ]
    [ ! -f "$proj/session-mid.jsonl" ]
    [ ! -f "$HOME/.npm/_cacache/mid.bin" ]
}

@test "sweep: ms-playwright is left alone" {
    pw="$HOME/.cache/ms-playwright/chromium-1"
    mkdir -p "$pw"
    printf 'browser' > "$pw/chrome"; aged '90 days ago' "$pw/chrome"

    run bash "$CLEANUP"
    [ "$status" -eq 0 ]
    [ -f "$pw/chrome" ]
}

@test "--report lists the top consumers and deletes nothing" {
    graphify_fixture
    proj="$HOME/.claude/projects/proj-c"
    mkdir -p "$proj" "$HOME/.cache/ms-playwright" "$HOME/big"
    printf 'old\n' > "$proj/session-old.jsonl"
    aged '31 days ago' "$proj/session-old.jsonl"
    dd if=/dev/zero of="$HOME/big/blob.bin" bs=1024 count=256 2>/dev/null

    run bash "$CLEANUP" --report
    [ "$status" -eq 0 ]
    [[ "$output" == *"big"* ]]
    [[ "$output" == *"graphify-out"* ]]
    [ -f "$proj/session-old.jsonl" ]
    [ -d "$WORKSPACE/graphify-out/2026-09-05" ]
    [ -f "$HOME/big/blob.bin" ]
}

@test "a second run changes nothing" {
    graphify_fixture
    proj="$HOME/.claude/projects/proj-d"
    mkdir -p "$proj" "$HOME/.npm/_cacache"
    printf 'old\n' > "$proj/session-old.jsonl"
    aged '31 days ago' "$proj/session-old.jsonl"
    printf 'new\n' > "$proj/session-new.jsonl"
    aged '1 day ago' "$proj/session-new.jsonl"
    printf 'blob' > "$HOME/.npm/_cacache/fresh.bin"
    aged '1 day ago' "$HOME/.npm/_cacache/fresh.bin"

    run bash "$CLEANUP"
    [ "$status" -eq 0 ]
    before="$(cd "$WORKSPACE" && find graphify-out | sort; cd "$HOME" && find .claude .npm | sort)"

    run bash "$CLEANUP"
    [ "$status" -eq 0 ]
    after="$(cd "$WORKSPACE" && find graphify-out | sort; cd "$HOME" && find .claude .npm | sort)"
    [ "$before" = "$after" ]
}