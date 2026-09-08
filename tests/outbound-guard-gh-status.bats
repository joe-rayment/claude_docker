#!/usr/bin/env bats
# outbound-guard-gh-status.bats — beads_claude_docker-iih3: github_auth_present()
# must validate the gh token via `gh auth status` (bounded by a timeout,
# cached per-HOME with a short TTL), not just find one via `gh auth token`.
# Discovered by actually pushing after beads_claude_docker-t1ym landed: a
# STALE/EXPIRED token is still returned by `gh auth token`, so the old guard
# allowed exactly the no-auth push it exists to prevent.
#
# tests/outbound-guard.bats holds the base guard contract (snow deny,
# GH_TOKEN/GITHUB_TOKEN, ssh key, fail-open, wiring) and is FROZEN by this
# bead's acceptance contract -- it is not touched here. This file covers only
# the new gh-auth-status validation/timeout/cache behavior.

GUARD=${OUTBOUND_GUARD_BIN:-/workspace/scripts/outbound-guard.sh}

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"

    # Isolated HOME per test -- also isolates the guard's per-HOME gh-auth
    # cache, so no state leaks between tests.
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"

    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    export PATH="$STUB_BIN:$PATH"

    # Counter file: every gh stub below appends one line per invocation, so
    # tests can prove exactly how many times (if at all) gh was invoked.
    export COUNTER="$BATS_TEST_TMPDIR/gh-call-count"
    : > "$COUNTER"

    unset GH_TOKEN GITHUB_TOKEN
}

gh_call_count() {
    wc -l < "$COUNTER" | tr -d ' '
}

# stub_gh_stale: `gh auth token` prints a token (present locally) but `gh
# auth status` fails -- the exact scenario that broke t1ym's guard: a token
# exists on disk but GitHub has invalidated it.
stub_gh_stale() {
    cat > "$STUB_BIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >> "$COUNTER"
if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
    echo "fake-stale-token"
    exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    exit 1
fi
exit 1
STUBEOF
    chmod +x "$STUB_BIN/gh"
}

# stub_gh_valid: both `gh auth token` and `gh auth status` succeed.
stub_gh_valid() {
    cat > "$STUB_BIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >> "$COUNTER"
if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
    echo "fake-valid-token"
    exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    exit 0
fi
exit 1
STUBEOF
    chmod +x "$STUB_BIN/gh"
}

# stub_gh_hangs: `gh auth status` sleeps far longer than the guard's timeout
# -- proves a slow/wedged gh cannot wedge the hook.
stub_gh_hangs() {
    cat > "$STUB_BIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >> "$COUNTER"
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    sleep 30
    exit 0
fi
exit 1
STUBEOF
    chmod +x "$STUB_BIN/gh"
}

# stub_gh_never_called: any invocation is recorded (test asserts count == 0)
# -- used to prove GH_TOKEN/GITHUB_TOKEN short-circuits before gh is touched.
stub_gh_never_called() {
    cat > "$STUB_BIN/gh" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >> "$COUNTER"
exit 1
STUBEOF
    chmod +x "$STUB_BIN/gh"
}

run_pretool() {
    local cmd="$1"
    run bash -c 'jq -n --arg c "$1" "{tool_name:\"Bash\", session_id:\"s1\", tool_input:{command:\$c}}" | "$0"' "$GUARD" "$cmd"
}

@test "outbound-guard: a token present via 'gh auth token' but invalid per 'gh auth status' DENIES the push" {
    stub_gh_stale
    run_pretool 'git push origin main'
    [ "$status" -eq 0 ]
    [[ "$output" == *"no GitHub authentication"* ]]
}

@test "outbound-guard: 'gh auth token' and 'gh auth status' both succeeding ALLOWS the push" {
    stub_gh_valid
    run_pretool 'git push origin main'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "outbound-guard: GH_TOKEN set allows the push without invoking gh at all" {
    stub_gh_never_called
    export GH_TOKEN="fake-gh-token-value"
    run_pretool 'git push origin main'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(gh_call_count)" -eq 0 ]
}

@test "outbound-guard: GITHUB_TOKEN set allows the push without invoking gh at all" {
    stub_gh_never_called
    export GITHUB_TOKEN="fake-gh-token-value"
    run_pretool 'git push origin main'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(gh_call_count)" -eq 0 ]
}

@test "outbound-guard: a hanging 'gh auth status' is bounded by a timeout and does not hang the hook" {
    stub_gh_hangs
    start=$(date +%s)
    run_pretool 'git push origin main'
    end=$(date +%s)
    elapsed=$((end - start))
    [ "$status" -eq 0 ]
    [ "$elapsed" -lt 15 ]
    [[ "$output" == *"no GitHub authentication"* ]]
}

@test "outbound-guard: a second identical push check within the TTL skips the gh invocation (cache hit)" {
    stub_gh_valid
    run_pretool 'git push origin main'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    first_count="$(gh_call_count)"
    [ "$first_count" -ge 1 ]

    run_pretool 'git push origin main'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(gh_call_count)" -eq "$first_count" ]
}
