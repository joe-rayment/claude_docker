#!/usr/bin/env bats
#
# /tier OpenRouter auth (epic claude-orca-bbk, plan
# .claude/plans/openrouter-auth.md). FROZEN from RED-AT onward.
#
# Nothing here reaches the network and nothing starts Orca: the key
# validator is a stub command, the Orca CLI is a stub that records its
# argv, and the only real process any case starts is the guard itself --
# which is the point of S2, and which works offline because a bad key only
# shows up on the first forwarded request.

bats_require_minimum_version 1.5.0

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

TSET="$REPO_ROOT/scripts/tier-set.sh"
AUTH="$REPO_ROOT/scripts/openrouter-auth.sh"
ROLES="$REPO_ROOT/scripts/lib/tier-roles.sh"

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

# A stub Orca CLI: records argv one line per arg, answers `terminal create`
# with the envelope orca_call expects.
stub_orca() {
    local mode="${1:-ok}"
    cat > "$BATS_TEST_TMPDIR/orca-stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$BATS_TEST_TMPDIR/orca-argv"
if [ "$mode" = "down" ]; then printf '%s' '{"ok":false,"error":{"message":"unreachable"}}'; exit 1; fi
case "\$1 \$2" in
  "terminal create") printf '%s' '{"ok":true,"result":{"terminal":{"handle":"term_stub"}}}' ;;
  "status --json"|"status")   printf '%s' '{"ok":true,"result":{"runtime":{"reachable":true}}}' ;;
  *) printf '%s' '{"ok":true,"result":{}}' ;;
esac
STUB
    chmod +x "$BATS_TEST_TMPDIR/orca-stub"
    export ORCA_CLI_BIN="$BATS_TEST_TMPDIR/orca-stub"
    : > "$BATS_TEST_TMPDIR/orca-argv"
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

start_stub_guard() {
    local port="$1" token="$2"
    printf '%s\n' "$token" > "$RUN_DIR/openrouter-guard.token"
    chmod 600 "$RUN_DIR/openrouter-guard.token"
    python3 -c "
import http.server, sys
http.server.HTTPServer(('127.0.0.1', $port),
    http.server.BaseHTTPRequestHandler).serve_forever()" &
    GUARD_PIDS+=($!)
    local i
    for i in $(seq 1 20); do port_open "$port" && return 0; sleep 0.2; done
    return 1
}

# -- S1: readiness-aware bind ----------------------------------------------

@test "an openrouter bind with no credential still binds and says how to authenticate" {
    run "$TSET" worker openrouter:z-ai/glm-5.3-flash
    [ "$status" -eq 0 ]
    [[ "$output" == *"headless:opencode:openrouter/z-ai/glm-5.3-flash"* ]]
    [[ "$output" == *"/tier auth openrouter"* ]]
    run jq -e '.roles.worker | .agent == "opencode" and .model == "openrouter/z-ai/glm-5.3-flash"' \
        "$RUN_DIR/tier.json"
    [ "$status" -eq 0 ]
}

@test "an openrouter bind with a live guard says nothing about auth" {
    start_stub_guard "$CLAUDE_ORCA_GUARD_PORT" tok-abc || skip "could not bind a port"
    run "$TSET" worker openrouter:z-ai/glm-5.3-flash
    [ "$status" -eq 0 ]
    [[ "$output" != *"/tier auth openrouter"* ]]
}

@test "tier_openrouter_ready is false for a token file with no listener" {
    printf 'tok-abc\n' > "$RUN_DIR/openrouter-guard.token"
    run bash -c ". '$ROLES'; tier_openrouter_ready && echo READY || echo NOT"
    [ "$status" -eq 0 ]
    [ "$output" = "NOT" ]
}

# -- S2: the auth helper ---------------------------------------------------

@test "a malformed key is refused and nothing is written" {
    stub_validator 0
    export OPENROUTER_AUTH_KEY_FILE="$CLAUDE_ORCA_ROOT/home/.openrouter.key"
    run bash -c "printf 'hunter2\n' | '$AUTH'"
    [ "$status" -ne 0 ]
    [ ! -e "$OPENROUTER_AUTH_KEY_FILE" ]
}

@test "a key the validator rejects is refused and nothing is written" {
    stub_validator 1
    export OPENROUTER_AUTH_KEY_FILE="$CLAUDE_ORCA_ROOT/home/.openrouter.key"
    run bash -c "printf 'sk-or-v1-0123456789abcdef0123\n' | '$AUTH'"
    [ "$status" -ne 0 ]
    [ ! -e "$OPENROUTER_AUTH_KEY_FILE" ]
}

@test "an accepted key is written mode 600 and the guard comes up on its port" {
    stub_validator 0
    export OPENROUTER_AUTH_KEY_FILE="$CLAUDE_ORCA_ROOT/home/.openrouter.key"
    run bash -c "printf 'sk-or-v1-0123456789abcdef0123\n' | '$AUTH'"
    [ "$status" -eq 0 ]
    [ -f "$OPENROUTER_AUTH_KEY_FILE" ]
    [ "$(stat -c '%a' "$OPENROUTER_AUTH_KEY_FILE")" = "600" ]
    port_open "$CLAUDE_ORCA_GUARD_PORT"
    [ -s "$RUN_DIR/openrouter-guard.token" ]
}

@test "the key never appears in the script output" {
    stub_validator 0
    export OPENROUTER_AUTH_KEY_FILE="$CLAUDE_ORCA_ROOT/home/.openrouter.key"
    run bash -c "printf 'sk-or-v1-0123456789abcdef0123\n' | '$AUTH'"
    [[ "$output" != *"0123456789abcdef0123"* ]]
}

# -- S3: the tab -----------------------------------------------------------

@test "auth openrouter prints the two-line sign-in command for a split and makes no Orca call" {
    # Guards: /tier auth openrouter opens nothing -- it prints the line
    #   telling the user to open a split (cmd+d) and the command that runs
    #   this folder's scripts/openrouter-auth.sh there, and exits 0.
    # Fails if: the command ran another helper, the first line was missing,
    #   or the Orca CLI was called (a terminal create).
    # Run: bats -f 'two-line sign-in command for a split' tests/tier-openrouter-auth.bats
    stub_orca ok
    run "$TSET" auth openrouter
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "Sign-in runs in a terminal of its own: open a split (cmd+d) and run:" ]
    [[ "${lines[1]}" == "cd "*" && "*"openrouter-auth.sh" ]]
    [ ! -s "$BATS_TEST_TMPDIR/orca-argv" ]
}

@test "auth openrouter still prints the command and exits 0 when the Orca CLI is down" {
    # Guards: sign-in no longer depends on any Orca runtime -- an Orca CLI
    #   that would fail is never even called, and the command still prints.
    # Fails if: the code reached for the Orca CLI again (its argv log gets
    #   a line) or exited non-zero because the CLI was unreachable.
    # Run: bats -f 'Orca CLI is down' tests/tier-openrouter-auth.bats
    stub_orca down
    run "$TSET" auth openrouter
    [ "$status" -eq 0 ]
    [[ "$output" == *"openrouter-auth.sh"* ]]
    [ ! -s "$BATS_TEST_TMPDIR/orca-argv" ]
}

# -- S4: dispatch carries the credential -----------------------------------

@test "an opencode dispatch sources the guard env when a token file exists" {
    printf 'tok-abc\n' > "$RUN_DIR/openrouter-guard.token"
    run bash -c ". '$REPO_ROOT/scripts/lib/workers.sh'; workers_opencode_command 'openrouter/z-ai/glm-5.3-flash' '$RUN_DIR'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"openrouter-guard.env"* ]]
    [[ "$output" == *"opencode --model openrouter/z-ai/glm-5.3-flash"* ]]
    [ -f "$RUN_DIR/openrouter-guard.env" ]
    [ "$(stat -c '%a' "$RUN_DIR/openrouter-guard.env")" = "600" ]
}

@test "an opencode dispatch without a guard token carries no credential, only the permission config" {
    # Since claude-orca-gh9 every launch writes a per-launch opencode config
    # (permission allow-all, git push denied) and an env file naming it, so
    # the command is never the bare one; what "no token" means is that the
    # env file carries no OPENROUTER_API_KEY and the config no baseURL.
    run bash -c ". '$REPO_ROOT/scripts/lib/workers.sh'; workers_opencode_command 'openrouter/z-ai/glm-5.3-flash' '$RUN_DIR'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"opencode --model openrouter/z-ai/glm-5.3-flash" ]]
    [ -f "$RUN_DIR/openrouter-guard.env" ]
    run grep -c 'OPENROUTER_API_KEY' "$RUN_DIR/openrouter-guard.env"
    [ "$output" = "0" ]
    cfg="$(sed -n "s/^OPENCODE_CONFIG='\(.*\)'/\1/p" "$RUN_DIR/openrouter-guard.env")"
    [ -f "$cfg" ]
    [ "$(jq -r '.permission["*"]' "$cfg")" = "allow" ]
    [ "$(jq -r '.provider.openrouter.options.baseURL // "none"' "$cfg")" = "none" ]
}

@test "the guard token is not passed on the command line" {
    printf 'tok-abc\n' > "$RUN_DIR/openrouter-guard.token"
    run bash -c ". '$REPO_ROOT/scripts/lib/workers.sh'; workers_opencode_command 'openrouter/z-ai/glm-5.3-flash' '$RUN_DIR'"
    [ "$status" -eq 0 ]
    [[ "$output" != *"tok-abc"* ]]
}
