#!/usr/bin/env bats

# prime-hook.bats — bd's compiled-in workflow boilerplate (a session-close
# checklist ending "git push … NEVER skip this. Work is not done until
# pushed", "Create beads issue BEFORE writing code", a "Write tests for X"
# separate-bead example, "use parallel subagents" to file issues) is only
# ever contradicted by this repo's own CLAUDE.md, which never ships to a
# user project — config/claude-user-memory.md does. `bd prime
# --memories-only` drops all of that and prints just the memories.
# scripts/prime-memories.sh wires that flag into both hooks and adds a
# byte budget on the memories themselves (Claude-written, unbounded).
#
# S7 port (claude-orca-3sk.7) drops the entrypoint.sh-specific cases: this
# template has no entrypoint.sh (sandboxing is shell-level, see
# .claude/plans/orca-port.md S3.2, not a container ENTRYPOINT normalize
# step) or Dockerfile/plugin staging, so `bd init --skip-agents`, the
# settings.json bd-prime-hook-removal function, the CLAUDE.md BEADS
# INTEGRATION block normalizer, and the Dockerfile/plugin cases have no
# equivalent to test. The remaining cases -- prime-memories.sh's own
# wiring and behaviour, and the two now-deletable CLAUDE.md paragraphs --
# are unmodified from the old suite.

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SETTINGS="$REPO_DIR/config/claude-settings.json"
PRIME_MEMORIES="$REPO_DIR/scripts/prime-memories.sh"
CLAUDE_MD="$REPO_DIR/CLAUDE.md"
USER_MEMORY="$REPO_DIR/config/claude-user-memory.md"

setup() {
    # Inside the container BEADS_DIR points at the workspace's own
    # tracker, and make_bd_repo's throwaway `bd init` refuses to run
    # while some other tracker holds that variable. These tests only
    # ever mean the throwaway one.
    unset BEADS_DIR
    export TMPDIR="$BATS_TEST_TMPDIR"
    command -v bd  >/dev/null 2>&1 || skip "bd not installed"
    command -v jq  >/dev/null 2>&1 || skip "jq not installed"
    command -v git >/dev/null 2>&1 || skip "git not installed"
}

# make_bd_repo <dir> — throwaway git + bd repo, memories channel only (no
# AGENTS.md/settings.json noise from bd's own agent-file generation).
make_bd_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name "Test"
    (cd "$dir" && bd init --prefix px --quiet --non-interactive --skip-agents >/dev/null 2>&1)
}

@test "prime-hook: scripts/prime-memories.sh exists and is executable" {
    [ -f "$PRIME_MEMORIES" ]
    [ -x "$PRIME_MEMORIES" ]
}

# ── (1) SessionStart hook: prime-memories in, bare bd prime out, no PreCompact ─

@test "prime-hook: config/claude-settings.json's SessionStart hook invokes prime-memories exactly once, PreCompact carries no hooks at all, and no bare 'bd prime' command remains anywhere in the file" {
    run jq -r '[.hooks.SessionStart[]?.hooks[]?.command, .hooks.PreCompact[]?.hooks[]?.command] | map(select(. == "bd prime")) | length' "$SETTINGS"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]

    run jq -r '[.hooks.SessionStart[]?.hooks[]?.command] | map(select(contains("prime-memories"))) | length' "$SETTINGS"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    run jq -r '(.hooks | has("PreCompact")) | not' "$SETTINGS"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]

    run grep -F '"bd prime"' "$SETTINGS"
    [ "$status" -eq 1 ]
}

# ── (2) memories only: the probe survives, none of bd's injected boilerplate does ─

@test "prime-hook: prime-memories prints a remembered probe and none of bd prime's injected workflow boilerplate" {
    local dir="$BATS_TEST_TMPDIR/probe-repo"
    make_bd_repo "$dir"
    (cd "$dir" && bd remember --key probe-marker "unique-probe-marker-9f3e: a fact, not a rule" >/dev/null 2>&1)

    run bash -c "cd '$dir' && bash '$PRIME_MEMORIES'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"unique-probe-marker-9f3e"* ]]
    [[ "$output" != *"git push"* ]]
    [[ "$output" != *"BEFORE writing code"* ]]
    [[ "$output" != *"Write tests for"* ]]
    [[ "$output" != *"parallel subagents"* ]]
    [[ "$output" != *"SESSION CLOSE"* ]]
}

# ── (3) byte budget: whole memories in bd's order, omitted keys named, never truncated ─

@test "prime-hook: PRIME_MEMORY_BUDGET caps the memory section, names every omitted key in one footer line, and never truncates a printed memory" {
    local dir="$BATS_TEST_TMPDIR/budget-repo"
    make_bd_repo "$dir"
    (cd "$dir" && bd remember --key aaa-first "aaa: this is the first memory, alphabetically first key too" >/dev/null 2>&1)
    (cd "$dir" && bd remember --key mmm-second "mmm: a second, unrelated project fact of similar length here" >/dev/null 2>&1)
    (cd "$dir" && bd remember --key zzz-third "zzz: a third fact that will not fit under the tiny test budget" >/dev/null 2>&1)

    run bash -c "cd '$dir' && PRIME_MEMORY_BUDGET=80 bash '$PRIME_MEMORIES'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"### aaa-first"* ]]
    [[ "$output" == *"aaa: this is the first memory, alphabetically first key too"* ]]
    [[ "$output" != *"### mmm-second"* ]]
    [[ "$output" != *"### zzz-third"* ]]
    [[ "$output" == *"mmm-second"* ]]
    [[ "$output" == *"zzz-third"* ]]
    [[ "$output" == *"bd memories <keyword>"* ]]
    local footer_lines
    footer_lines=$(printf '%s\n' "$output" | grep -c 'omitted')
    [ "$footer_lines" -eq 1 ]
}

@test "prime-hook: the default memory budget is 4000 bytes -- memories past it are omitted, and an invalid PRIME_MEMORY_BUDGET falls back to the same default" {
    local dir="$BATS_TEST_TMPDIR/default-budget-repo"
    make_bd_repo "$dir"
    # Six ~700-byte memories: over the 4000-byte default, under the old 8000.
    local filler i
    filler=$(printf 'x%.0s' $(seq 1 700))
    for i in 1 2 3 4 5 6; do
        (cd "$dir" && bd remember --key "mem-$i" "mem$i: $filler" >/dev/null 2>&1)
    done

    run bash -c "cd '$dir' && bash '$PRIME_MEMORIES'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"omitted"* ]]
    [[ "$output" == *"### mem-1"* ]]
    [[ "$output" != *"### mem-6"* ]]
    # Five ~730-byte blocks fit in 4000 bytes and the sixth does not; all
    # six fitted under the old 8000-byte default, so this pins the halving.
    local printed
    printed=$(printf '%s\n' "$output" | grep -c '^### ')
    [ "$printed" -eq 5 ]

    run bash -c "cd '$dir' && PRIME_MEMORY_BUDGET=not-a-number bash '$PRIME_MEMORIES'"
    [ "$status" -eq 0 ]
    printed=$(printf '%s\n' "$output" | grep -c '^### ')
    [ "$printed" -eq 5 ]
}

# ── (4) fail-open: bd absent ────────────────────────────────────────────────

@test "prime-hook: prime-memories exits 0 with empty output when bd is absent from PATH" {
    local emptydir="$BATS_TEST_TMPDIR/emptybin"
    mkdir -p "$emptydir"
    local realbd realbddir filtered
    realbd=$(command -v bd)
    realbddir=$(dirname "$realbd")
    filtered=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vF "$realbddir" | paste -sd: -)

    run env PATH="$emptydir:$filtered" bash "$PRIME_MEMORIES"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── (7) the now-deletable "argue with bd's injected text" paragraphs ───────
