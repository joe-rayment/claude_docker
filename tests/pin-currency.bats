#!/usr/bin/env bats

# pin-currency.bats — scripts/pin-currency.sh reports drift between the
# Dockerfile's pinned tool versions and each tool's latest upstream release
# (beads_claude_docker-xq9). Companion wiring checks confirm the Node pin
# actually moved to setup_24.x and that the host launcher's --update path
# calls the checker.
#
# FROZEN per beads_claude_docker-xq9's acceptance contract: this file must
# not be edited after its RED commit. If a test here turns out to be wrong,
# stop and report — do not edit it.
#
# Network is never hit in this file. Two techniques stand in for it, both
# built once in setup() and exercised separately so each is proven to work
# on its own (kb/GUARD_VERIFICATION.md fake-binary-on-PATH technique):
#   - PIN_CURRENCY_FETCH_CMD pointed straight at a fake fetch script
#   - a fake `curl` staged earlier on PATH, with PIN_CURRENCY_FETCH_CMD unset
# Both fakes answer the same two URLs (helix-editor/helix with a DIFFERENT
# tag than the Dockerfile pin, homeport/termshot with the SAME tag) so the
# same DRIFT/OK expectations apply to whichever route a test drives.

SCRIPT=/workspace/scripts/pin-currency.sh
DOCKERFILE=/workspace/Dockerfile
LAUNCHER=/workspace/scripts/launcher.sh

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"

    FAKE_FETCH="$BATS_TEST_TMPDIR/fake-fetch.sh"
    cat > "$FAKE_FETCH" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    *helix-editor/helix*) echo '{"tag_name":"1.0.0"}' ;;
    *homeport/termshot*)  echo '{"tag_name":"v0.6.1"}' ;;
    *) echo '{}' ;;
esac
EOF
    chmod +x "$FAKE_FETCH"

    FAKE_BIN_DIR="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$FAKE_BIN_DIR"
    cat > "$FAKE_BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do
    case "$a" in
        http*) url="$a" ;;
    esac
done
case "$url" in
    *helix-editor/helix*) echo '{"tag_name":"1.0.0"}' ;;
    *homeport/termshot*)  echo '{"tag_name":"v0.6.1"}' ;;
    *) echo '{}' ;;
esac
EOF
    chmod +x "$FAKE_BIN_DIR/curl"
}

# ── extract mode ─────────────────────────────────────────────────────────

@test "pin-currency.sh extract: finds at least 10 pinned tools with real versions from /workspace/Dockerfile" {
    run bash "$SCRIPT" extract
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -ge 10 ]
    [ "$(echo "$output" | awk -F'\t' '$2 == "" || $2 == "unknown"' | wc -l)" -eq 0 ]
}

@test "pin-currency.sh extract: known tool names are present with the exact Dockerfile-pinned values" {
    run bash "$SCRIPT" extract
    [ "$status" -eq 0 ]
    [[ "$output" == *$'node\t22'* || "$output" == *$'node\t24'* ]]
    [[ "$output" == *$'helix\t25.07.1'* ]]
    [[ "$output" == *$'termshot\t0.6.1'* ]]
}

@test "pin-currency.sh extract: opencode is tracked with the pinned version 1.18.25" {
    run bash "$SCRIPT" extract
    [ "$status" -eq 0 ]
    [[ "$output" == *$'opencode\t1.18.25'* ]]
}

# ── drift detection, via PIN_CURRENCY_FETCH_CMD ─────────────────────────

@test "pin-currency.sh report: a mocked upstream latest that DIFFERS from the pin is flagged DRIFT (fetch-cmd seam)" {
    run env PIN_CURRENCY_FETCH_CMD="$FAKE_FETCH" bash "$SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE '^helix +25\.07\.1 +1\.0\.0 +DRIFT$'
}

@test "pin-currency.sh report: a mocked upstream latest EQUAL to the pin is flagged OK, v-prefix stripped (fetch-cmd seam)" {
    run env PIN_CURRENCY_FETCH_CMD="$FAKE_FETCH" bash "$SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE '^termshot +0\.6\.1 +0\.6\.1 +OK$'
}

# ── drift detection, via a PATH-shimmed curl (no PIN_CURRENCY_FETCH_CMD) ──

@test "pin-currency.sh report: the same DRIFT/OK outcome holds with only a fake curl staged on PATH" {
    run env PATH="$FAKE_BIN_DIR:$PATH" bash "$SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE '^helix +25\.07\.1 +1\.0\.0 +DRIFT$'
    echo "$output" | grep -qE '^termshot +0\.6\.1 +0\.6\.1 +OK$'
}

# ── base image and network failure: never a gate ─────────────────────────

@test "pin-currency.sh report: base-image digest is reported manual-check, never resolved" {
    run env PIN_CURRENCY_FETCH_CMD="$FAKE_FETCH" bash "$SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE '^base-image .* manual-check +manual-check$'
}

@test "pin-currency.sh report: a fetch command that fails entirely still exits 0 with unresolved rows degraded to unknown" {
    run env PIN_CURRENCY_FETCH_CMD="/no/such/fetch/binary" bash "$SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE '^helix +25\.07\.1 +unknown +unknown$'
}

# ── wiring: Node pin bumped ───────────────────────────────────────────────

@test "Dockerfile: NodeSource pin is setup_24.x, not setup_22.x" {
    grep -q 'setup_24\.x' "$DOCKERFILE"
    ! grep -q 'setup_22\.x' "$DOCKERFILE"
}

# ── wiring: launcher --update path calls the checker ──────────────────────

@test "launcher.sh: cmd_update invokes pin-currency" {
    run sed -n '/^cmd_update()/,/^}/p' "$LAUNCHER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pin-currency"* ]]
}
