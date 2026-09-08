#!/usr/bin/env bats
#
# /tier OpenRouter auth (epic claude-orca-bbk, bead claude-orca-bbk.5,
# plan .claude/plans/openrouter-auth.md). Supersedes three vacuous cases
# from tests/tier-openrouter-auth.bats (frozen): with
# scripts/openrouter-auth.sh absent, `bash -c "... | $AUTH"` exits 127, so
# "refused and nothing written" and "the key never appears in the output"
# held trivially. These cases assert POSITIVE evidence instead -- the
# script exists and is executable, and each refusal path names its own
# reason on stderr.
#
# Setup/teardown/stub idiom copied from tests/tier-openrouter-auth.bats.

bats_require_minimum_version 1.5.0

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

AUTH="$REPO_ROOT/scripts/openrouter-auth.sh"

free_port() {
    python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

port_open() {
    python3 -c "import socket,sys
s = socket.socket(); s.settimeout(0.3)
sys.exit(0 if s.connect_ex(('127.0.0.1', $1)) == 0 else 1)" >/dev/null 2>&1
}

setup() {
    command -v jq >/dev/null 2>&1 || skip "jq is not installed"
    export CLAUDE_ORCA_ROOT="$BATS_TEST_TMPDIR/root"
    export CLAUDE_CONFIG_DIR="$CLAUDE_ORCA_ROOT/.claude"
    export RUN_DIR="$CLAUDE_ORCA_ROOT/.claude-dev/run"
    mkdir -p "$RUN_DIR" "$CLAUDE_CONFIG_DIR/agents" "$CLAUDE_ORCA_ROOT/home"
    unset OPENROUTER_API_KEY
    export TIER_DERIVE="$REPO_ROOT/scripts/tier-derive.sh"
    export TIER_OPENROUTER_KEY_FILE="$BATS_TEST_TMPDIR/no-such.key"
    export CLAUDE_ORCA_GUARD_PORT="$(free_port)"
    GUARD_PIDS=()
}

teardown() {
    local p
    for p in ${GUARD_PIDS[@]+"${GUARD_PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
    [ -f "$RUN_DIR/openrouter-guard.pid" ] &&
        kill "$(cat "$RUN_DIR/openrouter-guard.pid")" 2>/dev/null || true
}

# A validator stub: exit 0 accepts whatever key it is handed, 1 rejects.
stub_validator() {
    cat > "$BATS_TEST_TMPDIR/validate" <<STUB
#!/usr/bin/env bash
cat >/dev/null
exit $1
STUB
    chmod +x "$BATS_TEST_TMPDIR/validate"
    export OPENROUTER_AUTH_VALIDATE_CMD="$BATS_TEST_TMPDIR/validate"
}

@test "the auth helper exists and is executable" {
    [ -x "$REPO_ROOT/scripts/openrouter-auth.sh" ]
}

@test "a malformed key is refused with a message naming the expected sk-or-v1 format" {
    stub_validator 0
    export OPENROUTER_AUTH_KEY_FILE="$CLAUDE_ORCA_ROOT/home/.openrouter.key"
    run bash -c "printf 'hunter2\n' | '$AUTH'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"openrouter-auth: that does not look like an OpenRouter key (expected sk-or-v1-...)"* ]]
}

@test "a validator rejection is refused with a message naming the validator, not the format" {
    stub_validator 1
    export OPENROUTER_AUTH_KEY_FILE="$CLAUDE_ORCA_ROOT/home/.openrouter.key"
    run bash -c "printf 'sk-or-v1-0123456789abcdef0123\n' | '$AUTH'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"openrouter-auth: OpenRouter did not accept that key"* ]]
    [[ "$output" != *"sk-or-v1"* ]]
}

@test "the accepted path reports the key file and the guard port without the key" {
    stub_validator 0
    export OPENROUTER_AUTH_KEY_FILE="$CLAUDE_ORCA_ROOT/home/.openrouter.key"
    run bash -c "printf 'sk-or-v1-0123456789abcdef0123\n' | '$AUTH'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$OPENROUTER_AUTH_KEY_FILE"* ]]
    [[ "$output" == *"$CLAUDE_ORCA_GUARD_PORT"* ]]
    [[ "$output" != *"0123456789abcdef0123"* ]]
    [ -f "$OPENROUTER_AUTH_KEY_FILE" ]
    [ "$(stat -c '%a' "$OPENROUTER_AUTH_KEY_FILE")" = "600" ]
}
