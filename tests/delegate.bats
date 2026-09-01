#!/usr/bin/env bats

# delegate.bats — scripts/delegate.sh: routes config, `check` health table,
# `run` (ephemeral worktree, scrubbed-env opencode invocation, JSON
# receipt, bead stamping), and `ps` job listing (beads_claude_docker-z16).
#
# FROZEN per beads_claude_docker-z16's acceptance contract: this file must
# not be edited after its RED commit. If a test here turns out to be wrong,
# stop and report — do not edit it.
#
# SUPERSEDED RED BASELINE: the original RED-AT (5f41051) used a
# FAKE_OPENCODE_REC_DIR env var to tell the fake opencode where to record
# its argv/env. delegate.sh's env -i scrub (correctly, per spec) strips
# any var that isn't PATH/HOME/XDG_CONFIG_HOME/TERM/OPENROUTER_API_KEY, so
# that var never reached the fake and every run-flow test failed for a
# reason unrelated to the implementation. Fixed by recording into $HOME
# instead — delegate.sh always sets HOME to the job's own home dir, and it
# survives the scrub by design. No assertion changed; see the bead's notes
# for the exact diff against 5f41051. This file is FROZEN again as of the
# new RED-AT.
#
# No real network and no real opencode call anywhere below. A FAKE
# opencode goes first on PATH (records argv + full env under $HOME, emits
# a realistic --format json NDJSON stream including a usage/cost event,
# exits 0); `iptables` and the ollama reachability `curl` call are faked
# the same way (pin-currency.bats's fake-binary-on-PATH technique) since
# this container has neither a real iptables nor a real ollama. `bd init
# --prefix test --quiet --non-interactive` works cleanly in a scratch git
# repo in this sandbox (confirmed live), so every test gets its own real
# scratch bd DB rather than a mocked `bd` — no mock was needed.
#
# Every git-worktree / bd operation goes through a scratch fixture repo via
# $DELEGATE_REPO, which delegate.sh threads into both `git -C` and `bd -C`
# — the real /workspace repo's own worktree list and bd DB are never
# touched by this file.
#
# ADDENDUM (beads_claude_docker-clt): unfrozen for this bead (its own
# predecessor, beads_claude_docker-z16, verified+closed) to append the
# "cost-mirror ledger ingest" section at the bottom — delegate.sh itself is
# untouched (its cost-mirror.py call already existed, gated on the flag
# string being present in the file). Every test below points
# COST_MIRROR_STATE_DIR/COST_MIRROR_PROJECTS_DIR at scratch tmpdirs, never
# the real ~/.claude/cache. FROZEN again as of this bead's own RED-AT.

SCRIPT=/workspace/scripts/delegate.sh
SHIPPED_ROUTES=/workspace/config/delegate-routes.json
GITIGNORE=/workspace/.gitignore
MIRROR=/workspace/scripts/cost-mirror.py

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"

    # Isolated routes config, deliberately identical in shape/values to the
    # shipped one — tests use the $DELEGATE_ROUTES override (per the task
    # brief) so they never depend on production config staying byte-for-byte
    # stable; the shipped-content contract itself is checked separately
    # below by reading $SHIPPED_ROUTES directly.
    ROUTES="$BATS_TEST_TMPDIR/delegate-routes.json"
    cat >"$ROUTES" <<'EOF'
{ "routes": {
    "glm":   { "runner": "opencode", "model": "openrouter/z-ai/glm-5.2",
               "pin": { "order": ["novita","parasail"], "allow_fallbacks": false },
               "grade": "executor" },
    "local": { "runner": "opencode", "model": "ollama/qwen3-coder:30b",
               "grade": "scout" } } }
EOF

    # FAKE opencode: records argv (one per line) and full env under $HOME
    # — the job-scoped home dir delegate.sh's scrub always passes through
    # (unlike an arbitrary test env var, which the scrub correctly strips)
    # — emits a realistic NDJSON --format json stream (including a finish
    # event with usage/cost), always exits 0.
    FAKE_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$FAKE_BIN"
    cat >"$FAKE_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
REC_DIR="$HOME"
mkdir -p "$REC_DIR"
printf '%s\n' "$@" >"$REC_DIR/argv"
env >"$REC_DIR/env"
cat <<'JSON'
{"type":"session.updated","timestamp":1788224900000,"sessionID":"ses_fake"}
{"type":"message","timestamp":1788224900500,"role":"assistant","text":"working"}
{"type":"finish","timestamp":1788224901000,"sessionID":"ses_fake","usage":{"inputTokens":1234,"outputTokens":567,"cost":0.0089}}
JSON
exit 0
EOF
    chmod +x "$FAKE_BIN/opencode"

    # A curated PATH with every tool delegate.sh needs EXCEPT opencode, for
    # the "opencode absent" reason test — built from whatever this
    # container's real PATH resolves, so it never goes stale.
    NO_OPENCODE_BIN="$BATS_TEST_TMPDIR/no-opencode-bin"
    mkdir -p "$NO_OPENCODE_BIN"
    for b in jq curl git bd python3 sed awk grep cat mkdir date dirname basename env tee wc bash; do
        src=$(command -v "$b" 2>/dev/null) || continue
        ln -s "$src" "$NO_OPENCODE_BIN/$b"
    done
}

# make_repo <dir> — scratch git repo + scratch bd DB, one commit so
# `worktree add ... HEAD` has something to branch from.
make_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name "Test"
    echo "scratch fixture" >"$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -qm "init"
    # `bd init` (unlike every other bd subcommand) has no project yet for
    # `-C` to detect, so it must be run with cwd actually inside $dir.
    ( cd "$dir" && bd init --prefix test --quiet --non-interactive >/dev/null 2>&1 )
}

# make_bead <dir> <title> — creates a bead with a real CHECK/PASS-IF block,
# prints its id.
make_bead() {
    local dir="$1" title="$2"
    bd -C "$dir" create "$title" -d "Do the delegated thing." \
        --acceptance "CHECK: true
PASS-IF: always green" 2>&1 | grep -oE '[a-z]+-[a-z0-9]+' | head -1
}

# fake_curl <bindir> ok|fail — stands in for the real curl used only for
# the ollama reachability probe.
fake_curl() {
    local bindir="$1" mode="$2"
    mkdir -p "$bindir"
    if [[ "$mode" == "ok" ]]; then
        cat >"$bindir/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    else
        cat >"$bindir/curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
    fi
    chmod +x "$bindir/curl"
}

# fake_iptables <bindir> blocked|open — stands in for the real iptables
# (absent in this container) so the egress reason path is exercisable.
fake_iptables() {
    local bindir="$1" mode="$2"
    mkdir -p "$bindir"
    if [[ "$mode" == "blocked" ]]; then
        cat >"$bindir/iptables" <<'EOF'
#!/usr/bin/env bash
cat <<'RULES'
-P OUTPUT DROP
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -p udp --dport 53 -j ACCEPT
RULES
EOF
    else
        cat >"$bindir/iptables" <<'EOF'
#!/usr/bin/env bash
cat <<'RULES'
-P OUTPUT ACCEPT
RULES
EOF
    fi
    chmod +x "$bindir/iptables"
}

# ── check: per-route reason table ──────────────────────────────────────

@test "check: opencode absent on PATH -> both routes degraded with that reason" {
    PATH="$NO_OPENCODE_BIN" DELEGATE_ROUTES="$ROUTES" run "$SCRIPT" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"glm"*"degraded"*"opencode not found on PATH"* ]]
    [[ "$output" == *"local"*"degraded"*"opencode not found on PATH"* ]]
}

@test "check: missing OPENROUTER_API_KEY -> glm degraded with that reason" {
    fake_curl "$FAKE_BIN" ok
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" run env -u OPENROUTER_API_KEY "$SCRIPT" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"glm"*"degraded"*"OPENROUTER_API_KEY not set"* ]]
    [[ "$output" == *"local"*"live"* ]]
}

@test "check: ollama unreachable -> local degraded with that reason" {
    fake_curl "$FAKE_BIN" fail
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" OPENROUTER_API_KEY=sk-test run "$SCRIPT" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"local"*"degraded"*"ollama unreachable"* ]]
    [[ "$output" == *"glm"*"live"* ]]
}

@test "check: egress blocked with no allow rule -> glm degraded with that reason" {
    fake_curl "$FAKE_BIN" ok
    fake_iptables "$FAKE_BIN" blocked
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" OPENROUTER_API_KEY=sk-test run "$SCRIPT" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"glm"*"degraded"*"egress blocked (flag off)"* ]]
}

@test "check: open egress and present key/ollama -> both routes live" {
    fake_curl "$FAKE_BIN" ok
    fake_iptables "$FAKE_BIN" open
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" OPENROUTER_API_KEY=sk-test run "$SCRIPT" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"glm"*"live"* ]]
    [[ "$output" == *"local"*"live"* ]]
}

@test "check: unavailable route never blocks the command — exit is always 0" {
    PATH="$NO_OPENCODE_BIN" DELEGATE_ROUTES="$ROUTES" run "$SCRIPT" check
    [ "$status" -eq 0 ]
}

# ── run: unknown route / preflight failure — loud errors, no fallback ──

@test "run: unknown route lists known routes and exits nonzero" {
    REPO="$BATS_TEST_TMPDIR/repo1"
    make_repo "$REPO"
    fake_curl "$FAKE_BIN" ok
    fake_iptables "$FAKE_BIN" open
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" DELEGATE_REPO="$REPO" OPENROUTER_API_KEY=sk-test \
        run "$SCRIPT" run --route bogus --prompt "hi"
    [ "$status" -ne 0 ]
    [[ "$output" == *"bogus"* ]]
    [[ "$output" == *"glm"* ]]
    [[ "$output" == *"local"* ]]
}

@test "run: preflight failure is a loud error with the concrete reason, no worktree created" {
    REPO="$BATS_TEST_TMPDIR/repo2"
    make_repo "$REPO"
    fake_curl "$FAKE_BIN" ok
    fake_iptables "$FAKE_BIN" open
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" DELEGATE_REPO="$REPO" \
        run env -u OPENROUTER_API_KEY "$SCRIPT" run --route glm --prompt "hi"
    [ "$status" -ne 0 ]
    [[ "$output" == *"glm"* ]]
    [[ "$output" == *"OPENROUTER_API_KEY not set"* ]]
    [ ! -d "$REPO/.delegate/jobs" ]
}

# ── run: scout-grade route refuses --bead, allows --prompt ─────────────

@test "run: scout-grade route refuses --bead dispatch" {
    REPO="$BATS_TEST_TMPDIR/repo3"
    make_repo "$REPO"
    BEAD=$(make_bead "$REPO" "Scout refusal bead")
    fake_curl "$FAKE_BIN" ok
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" DELEGATE_REPO="$REPO" \
        run "$SCRIPT" run --route local --bead "$BEAD"
    [ "$status" -ne 0 ]
    [[ "$output" == *"local"* ]]
    [[ "$output" == *"scout"* ]]
    [ ! -d "$REPO/.delegate/jobs" ]
}

@test "run: scout-grade route accepts prompt-only dispatch" {
    REPO="$BATS_TEST_TMPDIR/repo4"
    make_repo "$REPO"
    fake_curl "$FAKE_BIN" ok
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" DELEGATE_REPO="$REPO" \
        run "$SCRIPT" run --route local --prompt "hello from prompt test"
    [ "$status" -eq 0 ]
    JOB_DIR=$(find "$REPO/.delegate/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
    [ -f "$JOB_DIR/home/argv" ]
}

# ── run: full flow — worktree, exact argv, generated config, scrubbed env ──

@test "run --route glm --bead: creates ephemeral worktree and branch, never touches the real repo" {
    REPO="$BATS_TEST_TMPDIR/repo5"
    make_repo "$REPO"
    BEAD=$(make_bead "$REPO" "Full flow bead")
    fake_curl "$FAKE_BIN" ok
    fake_iptables "$FAKE_BIN" open
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" DELEGATE_REPO="$REPO" OPENROUTER_API_KEY=sk-test-secret-abc123 \
        run "$SCRIPT" run --route glm --bead "$BEAD"
    [ "$status" -eq 0 ]

    JOB_DIR=$(find "$REPO/.delegate/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
    [ -n "$JOB_DIR" ]
    [ -d "$JOB_DIR/worktree" ]
    [ -f "$JOB_DIR/worktree/README.md" ]

    BRANCH=$(git -C "$JOB_DIR/worktree" rev-parse --abbrev-ref HEAD)
    [[ "$BRANCH" =~ ^delegate/glm-[0-9]+-[0-9a-f]{4}$ ]]

    # the real /workspace repo's own worktree list is untouched
    run git -C /workspace worktree list
    [[ "$output" != *"$JOB_DIR"* ]]
}

@test "run --route glm --bead: invokes opencode with the exact expected argv" {
    REPO="$BATS_TEST_TMPDIR/repo6"
    make_repo "$REPO"
    BEAD=$(make_bead "$REPO" "Argv check bead")
    fake_curl "$FAKE_BIN" ok
    fake_iptables "$FAKE_BIN" open
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" DELEGATE_REPO="$REPO" OPENROUTER_API_KEY=sk-test \
        run "$SCRIPT" run --route glm --bead "$BEAD"
    [ "$status" -eq 0 ]

    JOB_DIR=$(find "$REPO/.delegate/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
    ARGV="$JOB_DIR/home/argv"
    [ -f "$ARGV" ]
    HEAD8=$(sed -n '1,8p' "$ARGV")
    EXPECTED=$(printf 'run\n-m\nopenrouter/z-ai/glm-5.2\n--dir\n%s\n--auto\n--format\njson' "$JOB_DIR/worktree")
    [ "$HEAD8" = "$EXPECTED" ]

    # argv[9..] is the composed prompt: bead id/title, description, the
    # acceptance CHECK, and the standing instructions all present.
    PROMPT_TAIL=$(sed -n '9,$p' "$ARGV")
    [[ "$PROMPT_TAIL" == *"$BEAD"* ]]
    [[ "$PROMPT_TAIL" == *"Argv check bead"* ]]
    [[ "$PROMPT_TAIL" == *"Do the delegated thing."* ]]
    [[ "$PROMPT_TAIL" == *"CHECK: true"* ]]
    [[ "$PROMPT_TAIL" == *"PASS-IF: always green"* ]]
    [[ "$PROMPT_TAIL" == *"worktree"* ]]
    [[ "$PROMPT_TAIL" == *"commit"* ]]
    [[ "$PROMPT_TAIL" == *"never edit this bead"* ]]
}

@test "run --route local --prompt: invokes opencode with the exact expected argv, verbatim prompt" {
    REPO="$BATS_TEST_TMPDIR/repo7"
    make_repo "$REPO"
    fake_curl "$FAKE_BIN" ok
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" DELEGATE_REPO="$REPO" \
        run "$SCRIPT" run --route local --prompt "hello from prompt test"
    [ "$status" -eq 0 ]

    JOB_DIR=$(find "$REPO/.delegate/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
    EXPECTED=$(printf 'run\n-m\nollama/qwen3-coder:30b\n--dir\n%s\n--auto\n--format\njson\nhello from prompt test' "$JOB_DIR/worktree")
    ACTUAL=$(cat "$JOB_DIR/home/argv")
    [ "$ACTUAL" = "$EXPECTED" ]
}

@test "run --route local --prompt-file: prompt content is passed through verbatim" {
    REPO="$BATS_TEST_TMPDIR/repo8"
    make_repo "$REPO"
    fake_curl "$FAKE_BIN" ok
    PROMPT_FILE="$BATS_TEST_TMPDIR/prompt.txt"
    printf 'do the scout task exactly as written' >"$PROMPT_FILE"
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" DELEGATE_REPO="$REPO" \
        run "$SCRIPT" run --route local --prompt-file "$PROMPT_FILE"
    [ "$status" -eq 0 ]

    JOB_DIR=$(find "$REPO/.delegate/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
    LAST_LINE=$(tail -1 "$JOB_DIR/home/argv")
    [ "$LAST_LINE" = "do the scout task exactly as written" ]
}

@test "run --route glm --bead: generated opencode config carries pin order, allow_fallbacks, and the env-var apiKey placeholder" {
    REPO="$BATS_TEST_TMPDIR/repo9"
    make_repo "$REPO"
    BEAD=$(make_bead "$REPO" "Config shape bead")
    fake_curl "$FAKE_BIN" ok
    fake_iptables "$FAKE_BIN" open
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" DELEGATE_REPO="$REPO" OPENROUTER_API_KEY=sk-test \
        run "$SCRIPT" run --route glm --bead "$BEAD"
    [ "$status" -eq 0 ]

    JOB_DIR=$(find "$REPO/.delegate/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
    CFG="$JOB_DIR/config/opencode/opencode.json"
    [ -f "$CFG" ]

    run jq -e '.provider.openrouter.options.apiKey == "{env:OPENROUTER_API_KEY}"' "$CFG"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]

    run jq -e '.provider.openrouter.models["z-ai/glm-5.2"].options.provider.order == ["novita","parasail"]' "$CFG"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]

    run jq -e '.provider.openrouter.models["z-ai/glm-5.2"].options.provider.allow_fallbacks == false' "$CFG"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]

    # config lives outside the worktree, reached only via XDG_CONFIG_HOME
    [[ "$CFG" != "$JOB_DIR/worktree"* ]]
}

@test "run --route local --prompt: generated config uses the openai-compatible ollama provider at host.docker.internal" {
    REPO="$BATS_TEST_TMPDIR/repo10"
    make_repo "$REPO"
    fake_curl "$FAKE_BIN" ok
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" DELEGATE_REPO="$REPO" \
        run "$SCRIPT" run --route local --prompt "hi"
    [ "$status" -eq 0 ]

    JOB_DIR=$(find "$REPO/.delegate/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
    CFG="$JOB_DIR/config/opencode/opencode.json"

    run jq -e '.provider.ollama.options.baseURL == "http://host.docker.internal:11434/v1"' "$CFG"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]

    run jq -e '.provider.ollama.models["qwen3-coder:30b"] != null' "$CFG"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "run --route glm --bead: env handed to opencode has no ANTHROPIC_* vars and carries the key only because it's needed" {
    REPO="$BATS_TEST_TMPDIR/repo11"
    make_repo "$REPO"
    BEAD=$(make_bead "$REPO" "Env scrub bead")
    fake_curl "$FAKE_BIN" ok
    fake_iptables "$FAKE_BIN" open
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" DELEGATE_REPO="$REPO" OPENROUTER_API_KEY=sk-test-secret-xyz \
        ANTHROPIC_API_KEY=sk-ant-should-not-leak ANTHROPIC_MODEL=claude-should-not-leak \
        run "$SCRIPT" run --route glm --bead "$BEAD"
    [ "$status" -eq 0 ]

    JOB_DIR=$(find "$REPO/.delegate/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
    ENVFILE="$JOB_DIR/home/env"
    [ -f "$ENVFILE" ]
    run grep -c '^ANTHROPIC_' "$ENVFILE"
    [ "$output" -eq 0 ]
    run grep -c '^OPENROUTER_API_KEY=sk-test-secret-xyz$' "$ENVFILE"
    [ "$output" -eq 1 ]
}

@test "run --route local --prompt: env handed to opencode carries no OPENROUTER_API_KEY (not needed by this route)" {
    REPO="$BATS_TEST_TMPDIR/repo12"
    make_repo "$REPO"
    fake_curl "$FAKE_BIN" ok
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" DELEGATE_REPO="$REPO" OPENROUTER_API_KEY=sk-should-not-appear \
        run "$SCRIPT" run --route local --prompt "hi"
    [ "$status" -eq 0 ]

    JOB_DIR=$(find "$REPO/.delegate/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
    run grep -c '^OPENROUTER_API_KEY=' "$JOB_DIR/home/env"
    [ "$output" -eq 0 ]
}

# ── run: receipt schema, no key material, bead stamping ────────────────

@test "run --route glm --bead: writes a receipt with the full schema and correct values" {
    REPO="$BATS_TEST_TMPDIR/repo13"
    make_repo "$REPO"
    BEAD=$(make_bead "$REPO" "Receipt bead")
    fake_curl "$FAKE_BIN" ok
    fake_iptables "$FAKE_BIN" open
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" DELEGATE_REPO="$REPO" OPENROUTER_API_KEY=sk-test \
        run "$SCRIPT" run --route glm --bead "$BEAD"
    [ "$status" -eq 0 ]

    JOB_DIR=$(find "$REPO/.delegate/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
    RECEIPT="$JOB_DIR/receipt.json"
    [ -f "$RECEIPT" ]

    run jq -e 'has("job") and has("route") and has("model") and has("bead") and has("branch") and has("tokens_in") and has("tokens_out") and has("wall_seconds") and has("usd") and has("exit_code") and has("started_at") and has("finished_at")' "$RECEIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]

    run jq -r '.route' "$RECEIPT"
    [ "$output" = "glm" ]
    run jq -r '.model' "$RECEIPT"
    [ "$output" = "openrouter/z-ai/glm-5.2" ]
    run jq -r '.bead' "$RECEIPT"
    [ "$output" = "$BEAD" ]
    run jq -r '.branch' "$RECEIPT"
    [[ "$output" =~ ^delegate/glm- ]]
    run jq -r '.tokens_in' "$RECEIPT"
    [ "$output" = "1234" ]
    run jq -r '.tokens_out' "$RECEIPT"
    [ "$output" = "567" ]
    run jq -r '.usd' "$RECEIPT"
    [ "$output" = "0.0089" ]
    run jq -r '.exit_code' "$RECEIPT"
    [ "$output" = "0" ]
}

@test "run --route local --prompt: receipt has null bead and null tokens/usd when the event stream carries none" {
    REPO="$BATS_TEST_TMPDIR/repo14"
    make_repo "$REPO"
    fake_curl "$FAKE_BIN" ok
    NO_USAGE_BIN="$BATS_TEST_TMPDIR/no-usage-bin"
    mkdir -p "$NO_USAGE_BIN"
    cat >"$NO_USAGE_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
REC_DIR="$HOME"
mkdir -p "$REC_DIR"
printf '%s\n' "$@" >"$REC_DIR/argv"
env >"$REC_DIR/env"
echo '{"type":"message","timestamp":1788224900500,"role":"assistant","text":"no usage here"}'
exit 0
EOF
    chmod +x "$NO_USAGE_BIN/opencode"
    PATH="$NO_USAGE_BIN:$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" DELEGATE_REPO="$REPO" \
        run "$SCRIPT" run --route local --prompt "hi"
    [ "$status" -eq 0 ]

    JOB_DIR=$(find "$REPO/.delegate/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
    RECEIPT="$JOB_DIR/receipt.json"
    run jq -r '.bead' "$RECEIPT"
    [ "$output" = "null" ]
    run jq -r '.tokens_in' "$RECEIPT"
    [ "$output" = "null" ]
    run jq -r '.tokens_out' "$RECEIPT"
    [ "$output" = "null" ]
    run jq -r '.usd' "$RECEIPT"
    [ "$output" = "null" ]
}

@test "run --route glm --bead: no key material anywhere in the receipt or the log" {
    REPO="$BATS_TEST_TMPDIR/repo15"
    make_repo "$REPO"
    BEAD=$(make_bead "$REPO" "Redaction bead")
    fake_curl "$FAKE_BIN" ok
    fake_iptables "$FAKE_BIN" open
    SECRET="sk-super-secret-do-not-leak-99887766"
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" DELEGATE_REPO="$REPO" OPENROUTER_API_KEY="$SECRET" \
        run "$SCRIPT" run --route glm --bead "$BEAD"
    [ "$status" -eq 0 ]

    JOB_DIR=$(find "$REPO/.delegate/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
    run grep -rc -- "$SECRET" "$JOB_DIR/receipt.json" "$JOB_DIR/opencode.log"
    [[ "$output" == *":0"* ]]
    run grep -c -- "$SECRET" "$JOB_DIR/receipt.json"
    [ "$status" -ne 0 ]
    run grep -c -- "$SECRET" "$JOB_DIR/opencode.log"
    [ "$status" -ne 0 ]
}

@test "run --route glm --bead: stamps the bead's notes with route, branch, and receipt path" {
    REPO="$BATS_TEST_TMPDIR/repo16"
    make_repo "$REPO"
    BEAD=$(make_bead "$REPO" "Stamping bead")
    fake_curl "$FAKE_BIN" ok
    fake_iptables "$FAKE_BIN" open
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" DELEGATE_REPO="$REPO" OPENROUTER_API_KEY=sk-test \
        run "$SCRIPT" run --route glm --bead "$BEAD"
    [ "$status" -eq 0 ]

    JOB_DIR=$(find "$REPO/.delegate/jobs" -mindepth 1 -maxdepth 1 -type d | head -1)
    run bd -C "$REPO" show "$BEAD" --json
    [ "$status" -eq 0 ]
    NOTES=$(jq -r '.[0].notes' <<<"$output")
    [[ "$NOTES" == *"delegated-to: glm"* ]]
    [[ "$NOTES" == *"branch: delegate/glm-"* ]]
    [[ "$NOTES" == *"receipt: $JOB_DIR/receipt.json"* ]]

    # the bead's acceptance field itself must be untouched by the wrapper
    run bd -C "$REPO" show "$BEAD" --json
    ACCEPTANCE=$(jq -r '.[0].acceptance_criteria' <<<"$output")
    [[ "$ACCEPTANCE" == *"CHECK: true"* ]]
    [[ "$ACCEPTANCE" == *"PASS-IF: always green"* ]]
}

@test "run --route local --prompt: no bead given -> no bd stamping attempted, run still succeeds" {
    REPO="$BATS_TEST_TMPDIR/repo17"
    make_repo "$REPO"
    fake_curl "$FAKE_BIN" ok
    PATH="$FAKE_BIN:$PATH" DELEGATE_ROUTES="$ROUTES" DELEGATE_REPO="$REPO" \
        run "$SCRIPT" run --route local --prompt "hi"
    [ "$status" -eq 0 ]
}

# ── ps: running vs done, non-destructive ────────────────────────────────

@test "ps: lists a running job (pid alive, no receipt) and a done job (receipt present, retained)" {
    REPO="$BATS_TEST_TMPDIR/repo18"
    make_repo "$REPO"
    mkdir -p "$REPO/.delegate/jobs/local-1700000000-aaaa"
    echo '{"job":"local-1700000000-aaaa","route":"local"}' >"$REPO/.delegate/jobs/local-1700000000-aaaa/receipt.json"

    mkdir -p "$REPO/.delegate/jobs/glm-1700000001-bbbb"
    sleep 60 &
    SLEEP_PID=$!
    echo "$SLEEP_PID" >"$REPO/.delegate/jobs/glm-1700000001-bbbb/pid"

    DELEGATE_REPO="$REPO" run "$SCRIPT" ps
    kill "$SLEEP_PID" 2>/dev/null || true

    [ "$status" -eq 0 ]
    [[ "$output" == *"local-1700000000-aaaa"*"done"* ]]
    [[ "$output" == *"glm-1700000001-bbbb"*"running"* ]]

    # non-destructive: the receipt is still there after `ps` ran
    [ -f "$REPO/.delegate/jobs/local-1700000000-aaaa/receipt.json" ]
}

@test "ps: a job whose pid is no longer alive and has no receipt is not reported as running" {
    REPO="$BATS_TEST_TMPDIR/repo19"
    make_repo "$REPO"
    mkdir -p "$REPO/.delegate/jobs/glm-1700000002-cccc"
    echo "999999999" >"$REPO/.delegate/jobs/glm-1700000002-cccc/pid"

    DELEGATE_REPO="$REPO" run "$SCRIPT" ps
    [ "$status" -eq 0 ]
    [[ "$output" != *"glm-1700000002-cccc"*"running"* ]]
}

@test "ps: no jobs dir yet -> empty table, exit 0" {
    REPO="$BATS_TEST_TMPDIR/repo20"
    make_repo "$REPO"
    DELEGATE_REPO="$REPO" run "$SCRIPT" ps
    [ "$status" -eq 0 ]
    [[ "$output" == *"JOB"*"ROUTE"*"STATE"* ]]
}

# ── shipped config content + .gitignore ─────────────────────────────────

@test "config/delegate-routes.json: ships glm (executor-grade, pinned) and local (scout-grade ollama)" {
    run jq -e '.routes.glm.grade == "executor"' "$SHIPPED_ROUTES"
    [ "$output" = "true" ]
    run jq -e '.routes.glm.model == "openrouter/z-ai/glm-5.2"' "$SHIPPED_ROUTES"
    [ "$output" = "true" ]
    run jq -e '.routes.glm.pin.order == ["novita","parasail"]' "$SHIPPED_ROUTES"
    [ "$output" = "true" ]
    run jq -e '.routes.glm.pin.allow_fallbacks == false' "$SHIPPED_ROUTES"
    [ "$output" = "true" ]
    run jq -e '.routes.local.grade == "scout"' "$SHIPPED_ROUTES"
    [ "$output" = "true" ]
    run jq -e '.routes.local.model == "ollama/qwen3-coder:30b"' "$SHIPPED_ROUTES"
    [ "$output" = "true" ]
}

@test ".gitignore: .delegate/ is ignored" {
    run grep -qxF ".delegate/" "$GITIGNORE"
    [ "$status" -eq 0 ]
}

# ── cost-mirror ledger ingest: delegate receipts -> lifetime.json ──────
# (beads_claude_docker-clt) scripts/cost-mirror.py --ingest-delegate-receipt
# <path>, called by delegate.sh's cmd_run after every job (see its own
# receipt-writing block above). Never goes through delegate.sh here — the
# entry point is exercised directly against a hand-built receipt, isolated
# via COST_MIRROR_STATE_DIR/COST_MIRROR_PROJECTS_DIR (the same overrides
# tests/tier-hooks.bats uses), so the real ~/.claude/cache is never touched.

# make_receipt <path> <job> <model> <usd> [<tokens_in> <tokens_out>] — a
# delegate.sh-shaped receipt.json (see cmd_run's own jq -n block).
# usd/tokens_in/tokens_out go through --argjson, so passing the bare word
# `null` writes a real JSON null, exactly like delegate.sh does when the
# opencode event stream carried no usage/cost.
make_receipt() {
    local path="$1" job="$2" model="$3" usd="$4" tin="${5:-null}" tout="${6:-null}"
    jq -n --arg job "$job" --arg route "${job%%-*}" --arg model "$model" \
        --argjson usd "$usd" --argjson tokens_in "$tin" --argjson tokens_out "$tout" \
        '{job: $job, route: $route, model: $model, bead: null,
          branch: ("delegate/" + $job), tokens_in: $tokens_in,
          tokens_out: $tokens_out, wall_seconds: 12, usd: $usd, exit_code: 0,
          started_at: "2026-08-31T00:00:00Z", finished_at: "2026-08-31T00:00:12Z"}' \
        >"$path"
}

@test "cost-mirror --ingest-delegate-receipt: writes a lifetime.json row with side delegate, the receipt's model, and its real USD verbatim" {
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cm-state"
    RECEIPT="$BATS_TEST_TMPDIR/receipt.json"
    make_receipt "$RECEIPT" "glm-1700000010-aaaa" "openrouter/z-ai/glm-5.2" 0.0089 1234 567

    run python3 "$MIRROR" --ingest-delegate-receipt "$RECEIPT"
    [ "$status" -eq 0 ]

    LIFETIME="$COST_MIRROR_STATE_DIR/lifetime.json"
    [ -f "$LIFETIME" ]
    KEY='.sessions["glm-1700000010-aaaa|delegate|openrouter/z-ai/glm-5.2|1700000010"]'

    # presence checked against the raw file (has()), not a jq {a,b,c}
    # projection that would null-fill a genuinely absent key
    run jq -e "$KEY != null" "$LIFETIME"
    [ "$output" = "true" ]
    run jq -e "$KEY | has(\"cost_total\") and has(\"tokens_in\") and has(\"tokens_out\")" "$LIFETIME"
    [ "$output" = "true" ]
    run jq -r "$KEY.side" "$LIFETIME"
    [ "$output" = "delegate" ]
    run jq -r "$KEY.model" "$LIFETIME"
    [ "$output" = "openrouter/z-ai/glm-5.2" ]
    run jq -r "$KEY.cost_total" "$LIFETIME"
    [ "$output" = "0.0089" ]
    run jq -r "$KEY.tokens_in" "$LIFETIME"
    [ "$output" = "1234" ]
    run jq -r "$KEY.tokens_out" "$LIFETIME"
    [ "$output" = "567" ]
}

@test "cost-mirror --ingest-delegate-receipt: re-ingesting the same job's receipt REPLACES its row, never duplicates it" {
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cm-state"
    RECEIPT="$BATS_TEST_TMPDIR/receipt.json"
    make_receipt "$RECEIPT" "glm-1700000020-bbbb" "openrouter/z-ai/glm-5.2" 0.05 100 50
    LIFETIME="$COST_MIRROR_STATE_DIR/lifetime.json"

    run python3 "$MIRROR" --ingest-delegate-receipt "$RECEIPT"
    [ "$status" -eq 0 ]
    run jq '[.sessions | keys[] | select(startswith("glm-1700000020-bbbb|delegate|"))] | length' "$LIFETIME"
    [ "$output" -eq 1 ]

    run python3 "$MIRROR" --ingest-delegate-receipt "$RECEIPT"
    [ "$status" -eq 0 ]
    run jq '[.sessions | keys[] | select(startswith("glm-1700000020-bbbb|delegate|"))] | length' "$LIFETIME"
    [ "$output" -eq 1 ]
    run jq -r '.sessions["glm-1700000020-bbbb|delegate|openrouter/z-ai/glm-5.2|1700000020"].cost_total' "$LIFETIME"
    [ "$output" = "0.05" ]
}

@test "cost-mirror --ingest-delegate-receipt: a second job (even same model) gets its own second row, first row untouched" {
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cm-state"
    RECEIPT1="$BATS_TEST_TMPDIR/receipt1.json"
    RECEIPT2="$BATS_TEST_TMPDIR/receipt2.json"
    make_receipt "$RECEIPT1" "glm-1700000030-cccc" "openrouter/z-ai/glm-5.2" 0.01 10 5
    make_receipt "$RECEIPT2" "glm-1700000031-dddd" "openrouter/z-ai/glm-5.2" 0.02 20 15
    LIFETIME="$COST_MIRROR_STATE_DIR/lifetime.json"

    run python3 "$MIRROR" --ingest-delegate-receipt "$RECEIPT1"
    [ "$status" -eq 0 ]
    run python3 "$MIRROR" --ingest-delegate-receipt "$RECEIPT2"
    [ "$status" -eq 0 ]

    run jq '[.sessions | keys[] | select(contains("|delegate|"))] | length' "$LIFETIME"
    [ "$output" -eq 2 ]
    run jq -r '.sessions["glm-1700000030-cccc|delegate|openrouter/z-ai/glm-5.2|1700000030"].cost_total' "$LIFETIME"
    [ "$output" = "0.01" ]
    run jq -r '.sessions["glm-1700000031-dddd|delegate|openrouter/z-ai/glm-5.2|1700000031"].cost_total' "$LIFETIME"
    [ "$output" = "0.02" ]
}

@test "cost-mirror --report: renders delegated spend as its own segment, separate from and after the native side|model table" {
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cm-state"
    # a minimal real session so run_report_all has native spend to report
    # alongside the delegate segment (session_rows must be non-empty or the
    # aggregate report exits before rendering anything at all)
    PROJDIR="$BATS_TEST_TMPDIR/cm-projects"
    mkdir -p "$PROJDIR/proj-x"
    printf '{"message":{"model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":5}}}\n' \
        > "$PROJDIR/proj-x/sess-x.jsonl"
    export COST_MIRROR_PROJECTS_DIR="$PROJDIR"

    RECEIPT="$BATS_TEST_TMPDIR/receipt.json"
    make_receipt "$RECEIPT" "glm-1700000040-eeee" "openrouter/z-ai/glm-5.2" 0.0123 100 50
    run python3 "$MIRROR" --ingest-delegate-receipt "$RECEIPT"
    [ "$status" -eq 0 ]

    run python3 "$MIRROR" --report
    [ "$status" -eq 0 ]
    [[ "$output" == *"delegated:"* ]]
    [[ "$output" == *"openrouter/z-ai/glm-5.2"* ]]
    [[ "$output" == *'$0.01'* ]]

    TOTAL_LINE=$(grep -n '^TOTAL' <<<"$output" | head -1 | cut -d: -f1)
    DELEGATED_LINE=$(grep -n '^delegated:' <<<"$output" | head -1 | cut -d: -f1)
    [ -n "$TOTAL_LINE" ]
    [ -n "$DELEGATED_LINE" ]
    [ "$DELEGATED_LINE" -gt "$TOTAL_LINE" ]
}

@test "cost-mirror --ingest-delegate-receipt: malformed or missing receipt exits nonzero, stderr names it, ledger untouched" {
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cm-state"
    LIFETIME="$COST_MIRROR_STATE_DIR/lifetime.json"

    BAD="$BATS_TEST_TMPDIR/bad.json"
    echo 'not json at all' >"$BAD"
    run python3 "$MIRROR" --ingest-delegate-receipt "$BAD"
    [ "$status" -ne 0 ]
    [ -n "$output" ]
    [ ! -f "$LIFETIME" ]

    MISSING="$BATS_TEST_TMPDIR/does-not-exist.json"
    run python3 "$MIRROR" --ingest-delegate-receipt "$MISSING"
    [ "$status" -ne 0 ]
    [ -n "$output" ]
    [ ! -f "$LIFETIME" ]

    NOMODEL="$BATS_TEST_TMPDIR/nomodel.json"
    echo '{"job":"glm-1700000050-ffff"}' >"$NOMODEL"
    run python3 "$MIRROR" --ingest-delegate-receipt "$NOMODEL"
    [ "$status" -ne 0 ]
    [ ! -f "$LIFETIME" ]
}

@test "cost-mirror --ingest-delegate-receipt: a null-usd receipt writes a 0.0-dollar row but still records tokens" {
    export COST_MIRROR_STATE_DIR="$BATS_TEST_TMPDIR/cm-state"
    RECEIPT="$BATS_TEST_TMPDIR/receipt.json"
    make_receipt "$RECEIPT" "local-1700000060-gggg" "ollama/qwen3-coder:30b" null 42 null

    run python3 "$MIRROR" --ingest-delegate-receipt "$RECEIPT"
    [ "$status" -eq 0 ]

    LIFETIME="$COST_MIRROR_STATE_DIR/lifetime.json"
    KEY='.sessions["local-1700000060-gggg|delegate|ollama/qwen3-coder:30b|1700000060"]'
    run jq -e "$KEY != null" "$LIFETIME"
    [ "$output" = "true" ]
    run jq -r "$KEY.cost_total" "$LIFETIME"
    [ "$output" = "0.0" ]
    run jq -r "$KEY.tokens_in" "$LIFETIME"
    [ "$output" = "42" ]
    run jq -r "$KEY.tokens_out" "$LIFETIME"
    [ "$output" = "0" ]
}
