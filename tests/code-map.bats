#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# code-map.bats — the code-map feature's tests.
#
# guard: section (beads_claude_docker-o7z). scripts/code-map-guard.sh is
# staged as the ONLY `graphify` on PATH in this container. The upstream CLI
# mixes graph work (harmless) with ~20 per-platform installers that rewrite
# assistant config — CLAUDE.md, ~/.claude hooks, skills. The guard is
# deny-by-default: an allowlist of graph subcommands execs the real engine,
# everything else exits 2 with a pointer at `code-map`.
#
# No network, ever: the engine is a STUB shell script placed at the two
# resolution points, and the image prefix is redirected via
# CODE_MAP_IMAGE_PREFIX so no test reads (or needs) the real /opt/code-map.
#
# FROZEN per beads_claude_docker-o7z's acceptance contract: this file must
# not be edited after its RED commit. If a test here turns out to be wrong,
# stop and report — do not edit it. (A later bead may ADD cases under its own
# RED-AT; that does not authorize editing these.)

GUARD=/workspace/scripts/code-map-guard.sh

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    export HOME="$BATS_TEST_TMPDIR/home"

    # a fake ~/.claude tree: exactly the surface a stray `graphify install`
    # would rewrite. Every test checksums it; test 14 pins it across a whole
    # battery of invocations.
    mkdir -p "$HOME/.claude/skills/x" "$HOME/.claude/agents"
    printf '# fixture CLAUDE.md\n' > "$HOME/.claude/CLAUDE.md"
    printf '{"model":"claude-fable-5"}\n' > "$HOME/.claude/settings.json"
    printf 'fixture skill\n' > "$HOME/.claude/skills/x/SKILL.md"
    printf 'fixture agent\n' > "$HOME/.claude/agents/y.md"

    # point the image prefix at a path that does NOT exist unless a test
    # creates it — never at the real /opt/code-map, whose presence depends on
    # whether the host has rebuilt the image yet.
    export CODE_MAP_IMAGE_PREFIX="$BATS_TEST_TMPDIR/image"
    OVERRIDE_BIN="$HOME/.local/lib/code-map/bin"
    IMAGE_BIN="$CODE_MAP_IMAGE_PREFIX/bin"
    ENGINE_LOG="$BATS_TEST_TMPDIR/engine.log"
}

# a stub engine: echoes an identifying tag + its argv, and records the call.
# It writes nothing under $HOME, so any change to the fixture ~/.claude tree
# would have to come from the guard itself.
stub_engine() {
    local dir=$1 tag=$2
    mkdir -p "$dir"
    cat > "$dir/graphify" <<EOF
#!/bin/sh
echo "$tag argv: \$*"
echo "$tag \$*" >> "$ENGINE_LOG"
EOF
    chmod +x "$dir/graphify"
}

# structure + content of the fixture ~/.claude tree, as one hash
claude_tree_sum() {
    {
        find "$HOME/.claude" | sort
        find "$HOME/.claude" -type f | sort | xargs -r sha256sum
    } | sha256sum | cut -d' ' -f1
}

# Every blocked-path assertion below checks for "blocked" as well as
# "code-map": a MISSING guard script makes `sh $GUARD …` exit 2 with
# "Can't open /workspace/scripts/code-map-guard.sh" on stderr, which would
# otherwise satisfy both the exit code and a bare "code-map" match. The extra
# token is what keeps those tests genuinely red before the guard exists.

@test "guard: the guard script exists and is executable" {
    [ -x "$GUARD" ]
}

# ── pass-through: the allowlist reaches the engine ───────────────────────────

@test "guard: version passes through to the engine, home override preferred" {
    stub_engine "$OVERRIDE_BIN" "override-stub"
    stub_engine "$IMAGE_BIN" "image-stub"

    run --separate-stderr sh "$GUARD" version
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub"* ]]
    [[ "$output" != *"image-stub"* ]]
    [[ "$output" == *"argv: version"* ]]
}

@test "guard: the image-prefix engine is used when no home override exists" {
    stub_engine "$IMAGE_BIN" "image-stub"
    [ ! -e "$OVERRIDE_BIN/graphify" ]

    run --separate-stderr sh "$GUARD" version
    [ "$status" -eq 0 ]
    [[ "$output" == *"image-stub"* ]]
    [[ "$output" == *"argv: version"* ]]
}

@test "guard: every allowlisted subcommand reaches the engine" {
    stub_engine "$OVERRIDE_BIN" "override-stub"

    for sub in extract update cluster-only query explain path affected tree \
               god-nodes diagnose label watch merge-graphs merge-driver \
               export benchmark version help; do
        echo "subcommand under test: $sub"
        run --separate-stderr sh "$GUARD" "$sub"
        [ "$status" -eq 0 ]
        [[ "$output" == *"override-stub argv: $sub"* ]]
    done
}

@test "guard: --version, --help and no args pass through to the engine" {
    stub_engine "$OVERRIDE_BIN" "override-stub"

    run --separate-stderr sh "$GUARD" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv: --version"* ]]

    run --separate-stderr sh "$GUARD" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv: --help"* ]]

    run --separate-stderr sh "$GUARD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv:"* ]]
}

# ── blocked: everything that writes assistant config ─────────────────────────

@test "guard: install is blocked with exit 2 and points at code-map" {
    stub_engine "$OVERRIDE_BIN" "override-stub"

    run --separate-stderr sh "$GUARD" install
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]
    [[ "$output" != *"override-stub"* ]]
}

@test "guard: claude install is blocked" {
    stub_engine "$OVERRIDE_BIN" "override-stub"

    run --separate-stderr sh "$GUARD" claude install
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]
    [[ "$output" != *"override-stub"* ]]
}

@test "guard: uninstall is blocked" {
    stub_engine "$OVERRIDE_BIN" "override-stub"

    run --separate-stderr sh "$GUARD" uninstall
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]

    run --separate-stderr sh "$GUARD" uninstall --purge
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]
}

@test "guard: hook install is blocked" {
    stub_engine "$OVERRIDE_BIN" "override-stub"

    run --separate-stderr sh "$GUARD" hook install
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]
    [[ "$output" != *"override-stub"* ]]
}

@test "guard: global is blocked" {
    stub_engine "$OVERRIDE_BIN" "override-stub"

    run --separate-stderr sh "$GUARD" global list
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]
    [[ "$output" != *"override-stub"* ]]
}

@test "guard: clone is blocked" {
    stub_engine "$OVERRIDE_BIN" "override-stub"

    run --separate-stderr sh "$GUARD" clone https://github.com/example/repo
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]
    [[ "$output" != *"override-stub"* ]]
}

@test "guard: an unknown future subcommand is blocked" {
    stub_engine "$OVERRIDE_BIN" "override-stub"

    run --separate-stderr sh "$GUARD" frobnicate --all
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]
    [[ "$output" != *"override-stub"* ]]
}

@test "guard: every per-platform install/uninstall is blocked" {
    stub_engine "$OVERRIDE_BIN" "override-stub"

    for platform in claude codebuddy codex opencode kilo aider copilot vscode \
                    claw droid trae trae-cn gemini cursor antigravity hermes \
                    kiro pi devin windows amp agents; do
        for verb in install uninstall; do
            echo "platform under test: $platform $verb"
            run --separate-stderr sh "$GUARD" "$platform" "$verb"
            [ "$status" -eq 2 ]
            [[ "$stderr" == *"code-map"* ]]
            [[ "$stderr" == *"blocked"* ]]
    [[ "$stderr" == *"blocked"* ]]
        done
    done
}

@test "guard: a blocked subcommand never executes the engine" {
    stub_engine "$OVERRIDE_BIN" "override-stub"
    stub_engine "$IMAGE_BIN" "image-stub"

    run --separate-stderr sh "$GUARD" install
    [ "$status" -eq 2 ]
    [ ! -e "$ENGINE_LOG" ]

    run --separate-stderr sh "$GUARD" claude install
    [ "$status" -eq 2 ]
    [ ! -e "$ENGINE_LOG" ]

    # the log only appears once an allowlisted call goes through
    run --separate-stderr sh "$GUARD" query "what calls foo"
    [ "$status" -eq 0 ]
    [ -s "$ENGINE_LOG" ]
}

@test "guard: the fixture ~/.claude tree is unchanged after every invocation" {
    stub_engine "$OVERRIDE_BIN" "override-stub"
    before=$(claude_tree_sum)
    [ -n "$before" ]
    [ -f "$HOME/.claude/CLAUDE.md" ]

    # each run also asserts its own exit status, so this test cannot pass
    # vacuously by way of a guard that never ran at all
    run --separate-stderr sh "$GUARD" version
    [ "$status" -eq 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr sh "$GUARD" query "what calls foo"
    [ "$status" -eq 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr sh "$GUARD" install
    [ "$status" -eq 2 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr sh "$GUARD" claude install
    [ "$status" -eq 2 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr sh "$GUARD" hook install
    [ "$status" -eq 2 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr sh "$GUARD" global list
    [ "$status" -eq 2 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr sh "$GUARD" clone https://github.com/example/repo
    [ "$status" -eq 2 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr sh "$GUARD" frobnicate
    [ "$status" -eq 2 ]
    [ "$(claude_tree_sum)" = "$before" ]

    [ -f "$HOME/.claude/CLAUDE.md" ]
    [ -f "$HOME/.claude/settings.json" ]
}

# ── engine resolution failure ────────────────────────────────────────────────

@test "guard: blocking does not depend on an engine being installed" {
    [ ! -e "$OVERRIDE_BIN/graphify" ]
    [ ! -e "$IMAGE_BIN/graphify" ]

    run --separate-stderr sh "$GUARD" install
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]
}

@test "guard: with no engine installed the error names code-map doctor" {
    [ ! -e "$OVERRIDE_BIN/graphify" ]
    [ ! -e "$IMAGE_BIN/graphify" ]

    run --separate-stderr sh "$GUARD" version
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"code-map doctor"* ]]
}
