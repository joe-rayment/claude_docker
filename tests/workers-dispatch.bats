# Guards: scripts/dispatch.sh turns a bead into a worktree, a job directory and a started (stubbed) runner, and prints one valid receipt line, with no Orca anywhere
# Fails if: dispatch stops creating work/<bead>, writes a spec that still tells the worker to call orca-ide, ignores tier.json, or does not hand the runner its job dir
# Run: bats tests/workers-dispatch.bats
bats_require_minimum_version 1.5.0

setup() {
    FIX="$BATS_TEST_TMPDIR"
    DISPATCH="$BATS_TEST_DIRNAME/../scripts/dispatch.sh"
    LIB="$BATS_TEST_DIRNAME/../scripts/lib/workers.sh"
    ROOTD="$FIX/proj"
    mkdir -p "$ROOTD" "$FIX/bin" "$FIX/home" "$FIX/wt"
    git -C "$ROOTD" init -q -b main
    git -C "$ROOTD" -c user.name=t -c user.email=t@example.invalid \
        commit -q --allow-empty -m init

    # A bd that only knows `bd show <id> --json`.
    cat >"$FIX/bin/bd" <<'EOF'
#!/bin/sh
if [ "$1" = show ] && [ "$2" != nope ]; then
    printf '[{"id":"%s","title":"Make hello","description":"Create hello.txt","acceptance_criteria":"","notes":""}]\n' "$2"
    exit 0
fi
exit 1
EOF
    chmod +x "$FIX/bin/bd"
    export PATH="$FIX/bin:$PATH"

    # The runner seam: a stub that records the job dir it was started with.
    cat >"$FIX/runner.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >"$STUB_OUT"
EOF
    chmod +x "$FIX/runner.sh"
    export STUB_OUT="$FIX/runner-arg"
    export CLAUDE_ORCA_WORKER_RUN="$FIX/runner.sh"

    export PROJECT_DIR="$ROOTD" CLAUDE_ORCA_ROOT="$ROOTD" HOME="$FIX/home"
    export CLAUDE_ORCA_WORKTREES_DIR="$FIX/wt" TIER_STATE_FILE="$FIX/tier.json"
    unset CLAUDE_ORCA_MAX_WORKERS
}

# The runner is started in the background; wait for its file.
wait_runner() {
    local i=0
    while [ ! -s "$STUB_OUT" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    [ -s "$STUB_OUT" ]
}

jobdir_of() { printf '%s' "$1" | jq -r '.job' | { read -r j; printf '%s/.claude-dev/run/workers/%s' "$ROOTD" "$j"; }; }

@test "creates worktree and branch work/<bead> and prints one JSON receipt" {
    run --separate-stderr "$DISPATCH" demo-1
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    printf '%s' "$output" | jq -e '.bead == "demo-1" and .state == "started"
        and .branch == "work/demo-1" and (.job | startswith("demo-1-"))' >/dev/null
    [ "$(printf '%s' "$output" | jq -r .dir)" = "$FIX/wt/demo-1" ]
    [ -d "$FIX/wt/demo-1" ]
    git -C "$ROOTD" show-ref --verify --quiet refs/heads/work/demo-1
    [ "$(git -C "$FIX/wt/demo-1" rev-parse --abbrev-ref HEAD)" = "work/demo-1" ]
    wait_runner
}

@test "a second dispatch of the same bead reuses the worktree and branch" {
    run --separate-stderr "$DISPATCH" demo-1
    [ "$status" -eq 0 ]
    run --separate-stderr "$DISPATCH" demo-1
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r .dir)" = "$FIX/wt/demo-1" ]
    [ "$(git -C "$ROOTD" worktree list | wc -l)" -eq 2 ]
    [ "$(ls "$ROOTD/.claude-dev/run/workers" | grep -c '^demo-1-')" -eq 2 ]
}

@test "a leftover branch without a directory is checked out again, not recreated" {
    git -C "$ROOTD" branch work/demo-2
    run --separate-stderr "$DISPATCH" demo-2
    [ "$status" -eq 0 ]
    [ "$(git -C "$FIX/wt/demo-2" rev-parse --abbrev-ref HEAD)" = "work/demo-2" ]
}

@test "--worktree main works in the project root and makes no worktree" {
    run --separate-stderr "$DISPATCH" demo-1 --worktree main
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r .dir)" = "$ROOTD" ]
    [ "$(printf '%s' "$output" | jq -r .branch)" = "main" ]
    [ ! -e "$FIX/wt/demo-1" ]
}

@test "writes job.json and a private spec.md under .claude-dev/run/workers/<job>" {
    run --separate-stderr "$DISPATCH" demo-1
    [ "$status" -eq 0 ]
    jd="$(jobdir_of "$output")"
    [ -f "$jd/spec.md" ]
    [ "$(stat -c %a "$jd/spec.md")" = "600" ]
    jq -e --arg d "$FIX/wt/demo-1" '.bead == "demo-1" and .role == "worker" and .state == "started"
        and .dir == $d and .branch == "work/demo-1" and has("frozen_hooks")
        and has("effort") and has("variant") and (.created | type == "number")' "$jd/job.json" >/dev/null
    wait_runner
}

@test "the spec is the headless one: report in the final message, QUESTION: line, no orca-ide" {
    run --separate-stderr "$DISPATCH" demo-1
    [ "$status" -eq 0 ]
    spec="$(cat "$(jobdir_of "$output")/spec.md")"
    [[ "$spec" == *"Create hello.txt"* ]]
    [[ "$spec" == *"FINAL message"* ]]
    [[ "$spec" == *"QUESTION:"* ]]
    [[ "$spec" != *"orca-ide"* ]]
}

@test "orch_spec without the third argument still carries the Orca heartbeat rules" {
    run bash -c '. "$1"; orch_spec "{\"title\":\"T\",\"description\":\"D\"}" b-1' _ "$LIB"
    [ "$status" -eq 0 ]
    [[ "$output" == *"orca-ide orchestration send"* ]]
    [[ "$output" != *"QUESTION:"* ]]
}

@test "--prompt-file replaces the composed spec verbatim" {
    printf 'just do the thing\n' >"$FIX/p.txt"
    run --separate-stderr "$DISPATCH" demo-1 --prompt-file "$FIX/p.txt"
    [ "$status" -eq 0 ]
    [ "$(cat "$(jobdir_of "$output")/spec.md")" = "just do the thing" ]
}

@test "starts the runner detached with the job dir as its only argument" {
    run --separate-stderr "$DISPATCH" demo-1
    [ "$status" -eq 0 ]
    wait_runner
    [ "$(cat "$STUB_OUT")" = "$(jobdir_of "$output")" ]
}

@test "agent, model and effort come from the worker role in a v2 tier.json" {
    printf '%s' '{"version":2,"roles":{"worker":{"backend":"orca","agent":"claude","model":"sonnet","variant":"minimal"}}}' >"$FIX/tier.json"
    run --separate-stderr "$DISPATCH" demo-1
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.agent == "claude" and .model == "sonnet"' >/dev/null
    jq -e '.variant == "minimal" and .effort == "low"' "$(jobdir_of "$output")/job.json" >/dev/null
}

@test "the checker role reads the checker binding, and flags beat tier.json" {
    printf '%s' '{"version":2,"roles":{"worker":{"agent":"claude","model":"sonnet"},"checker":{"agent":"claude","model":"opus"}}}' >"$FIX/tier.json"
    run --separate-stderr "$DISPATCH" demo-1 --checker
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.model == "opus"' >/dev/null
    run --separate-stderr "$DISPATCH" demo-1 --checker --model haiku --effort high
    printf '%s' "$output" | jq -e '.model == "haiku"' >/dev/null
    jq -e '.role == "checker" and .effort == "high"' "$(jobdir_of "$output")/job.json" >/dev/null
}

@test "an openrouter model forces the opencode agent whatever the binding says" {
    printf '%s' '{"version":2,"roles":{"worker":{"agent":"claude","model":"openrouter/qwen/qwen3-coder"}}}' >"$FIX/tier.json"
    run --separate-stderr "$DISPATCH" demo-1
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.agent == "opencode" and .model == "openrouter/qwen/qwen3-coder"' >/dev/null
    [ "$(jq -r .effort "$(jobdir_of "$output")/job.json")" = "" ]
}

@test "an unknown bead exits 2 and starts nothing" {
    run --separate-stderr "$DISPATCH" nope
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"bd show nope failed"* ]]
    [ ! -e "$FIX/wt/nope" ]
    [ ! -e "$STUB_OUT" ]
}

@test "no bead argument exits 2 with the usage line" {
    run --separate-stderr "$DISPATCH"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"usage: dispatch"* ]]
}
