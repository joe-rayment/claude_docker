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

# ═══════════════════════════════════════════════════════════════════════════
# shim: section (beads_claude_docker-1my). scripts/code-map.sh is staged as
# /usr/local/bin/code-map — the feature's ONLY documented entry point, and the
# thing the guard's error messages point at. It resolves the engine exactly
# like the guard does (home override, then image prefix, never PATH) and adds
# the repo-shaped workflow on top: build/refresh/status, passthrough queries,
# report/html, upgrade, doctor.
#
# Two kinds of engine appear below, on purpose:
#   · the REAL engine, symlinked into the home-override prefix by
#     install_real_engine, for the build/refresh/status flows — those are only
#     worth testing against the thing that actually writes graph.json. It runs
#     AST-only (--code-only) on a one-file fixture: no network, no API key.
#   · the guard section's stub_engine, for argv-forwarding and
#     engine-resolution assertions, where the real engine would add nothing.
#
# The guard section's setup() is this file's only setup() and applies here
# too: TMPDIR/HOME are redirected into $BATS_TEST_TMPDIR, CODE_MAP_IMAGE_PREFIX
# points at a path that exists only if a test creates it, and $OVERRIDE_BIN /
# $IMAGE_BIN / claude_tree_sum are in scope.
#
# FROZEN per beads_claude_docker-1my's acceptance contract from its RED commit
# on: if a test here turns out to be wrong, stop and report — do not edit it.

SHIM=/workspace/scripts/code-map.sh

# The pinned engine, wherever this machine has it: the home-override prefix
# (installed by `code-map upgrade`, and by the feature's own bootstrap) or the
# image prefix (baked at /opt/code-map). Not resolved through PATH — `graphify`
# on PATH is the guard, which would recurse.
real_engine() {
    local cand
    for cand in "${CODE_MAP_REAL_ENGINE:-}" \
                /home/agent/.local/lib/code-map/bin/graphify \
                /opt/code-map/bin/graphify; do
        if [ -n "$cand" ] && [ -x "$cand" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    return 1
}

# Put the real engine where the shim looks first, so the resolution path under
# test is the production one.
install_real_engine() {
    local engine=""
    engine=$(real_engine) || true
    [ -n "$engine" ]
    mkdir -p "$OVERRIDE_BIN"
    ln -sf "$engine" "$OVERRIDE_BIN/graphify"
}

# A git repo with one python file and one commit. HOME is the fixture home, so
# there is no global git identity — every commit passes one inline.
fixture_repo() {
    local dir=$1
    mkdir -p "$dir"
    git -C "$dir" init -q
    cat > "$dir/sample.py" <<'PY'
def helper(x):
    return x + 1


def main():
    return helper(41)
PY
    git -C "$dir" add sample.py
    fixture_commit "$dir" -m init
}

fixture_commit() {
    local dir=$1
    shift
    git -C "$dir" -c user.email=t@example.com -c user.name=t commit -q "$@"
}

# ── build / refresh / status against the real engine ─────────────────────────

@test "shim: the shim script exists and is executable" {
    [ -x "$SHIM" ]
}

@test "shim: build creates a graph stamped at HEAD and status reports it fresh" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    run --separate-stderr sh "$SHIM" build
    [ "$status" -eq 0 ]
    [ -f "$repo/graphify-out/graph.json" ]

    head=$(git -C "$repo" rev-parse HEAD)
    [ "$(jq -r .built_at_commit "$repo/graphify-out/graph.json")" = "$head" ]

    nodes=$(jq '.nodes|length' "$repo/graphify-out/graph.json")
    links=$(jq '.links|length' "$repo/graphify-out/graph.json")
    [ "$nodes" -gt 0 ]
    [ "$links" -gt 0 ]

    run --separate-stderr sh "$SHIM" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"nodes: $nodes"* ]]
    [[ "$output" == *"links: $links"* ]]
    [[ "$output" == *"built_at_commit: $head"* ]]
    [[ "$output" == *"state: fresh"* ]]
}

@test "shim: a commit after a build makes status report STALE" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    run --separate-stderr sh "$SHIM" build
    [ "$status" -eq 0 ]

    fixture_commit "$repo" --allow-empty -m second

    run --separate-stderr sh "$SHIM" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"state: STALE"* ]]
    [[ "$output" != *"state: fresh"* ]]
}

@test "shim: refresh brings a stale graph back to fresh" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    run --separate-stderr sh "$SHIM" build
    [ "$status" -eq 0 ]

    fixture_commit "$repo" --allow-empty -m second
    head=$(git -C "$repo" rev-parse HEAD)

    run --separate-stderr sh "$SHIM" refresh
    [ "$status" -eq 0 ]

    [ "$(jq -r .built_at_commit "$repo/graphify-out/graph.json")" = "$head" ]

    run --separate-stderr sh "$SHIM" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"state: fresh"* ]]
}

@test "shim: refresh with no graph falls back to build" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"
    [ ! -e "$repo/graphify-out/graph.json" ]

    run --separate-stderr sh "$SHIM" refresh
    [ "$status" -eq 0 ]
    [[ "$output" == *"no graph yet"* ]]
    [ -f "$repo/graphify-out/graph.json" ]

    run --separate-stderr sh "$SHIM" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"state: fresh"* ]]
}

@test "shim: GRAPHIFY_OUT redirects the graph directory" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"
    export GRAPHIFY_OUT=graphify-out-alt

    run --separate-stderr sh "$SHIM" build
    [ "$status" -eq 0 ]
    [ -f "$repo/graphify-out-alt/graph.json" ]
    [ ! -e "$repo/graphify-out/graph.json" ]

    run --separate-stderr sh "$SHIM" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"graphify-out-alt/graph.json"* ]]
    [[ "$output" == *"state: fresh"* ]]
}

# ── exclude hygiene: .git/info/exclude only, never the project .gitignore ─────

@test "shim: two builds leave exactly one graphify-out/ line in .git/info/exclude" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    run --separate-stderr sh "$SHIM" build
    [ "$status" -eq 0 ]
    run --separate-stderr sh "$SHIM" build
    [ "$status" -eq 0 ]

    [ -f "$repo/.git/info/exclude" ]
    [ "$(grep -cxF 'graphify-out/' "$repo/.git/info/exclude")" -eq 1 ]
}

@test "shim: a pre-existing exclude entry is not duplicated" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    mkdir -p "$repo/.git/info"
    printf '# fixture exclude\ngraphify-out/\n' > "$repo/.git/info/exclude"

    run --separate-stderr sh "$SHIM" build
    [ "$status" -eq 0 ]

    [ "$(grep -cxF 'graphify-out/' "$repo/.git/info/exclude")" -eq 1 ]
    [[ "$(cat "$repo/.git/info/exclude")" == *"# fixture exclude"* ]]
}

@test "shim: build never touches the project .gitignore" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    printf '# fixture gitignore\n*.fixture-artifact\n' > "$repo/.gitignore"
    [ -f "$repo/.gitignore" ]
    before=$(sha256sum "$repo/.gitignore" | cut -d' ' -f1)
    [ -n "$before" ]

    run --separate-stderr sh "$SHIM" build
    [ "$status" -eq 0 ]

    [ -f "$repo/.gitignore" ]
    [ "$(sha256sum "$repo/.gitignore" | cut -d' ' -f1)" = "$before" ]
    [[ "$(cat "$repo/.gitignore")" == *"*.fixture-artifact"* ]]
}

@test "shim: build outside a git repo still builds and skips exclude hygiene" {
    install_real_engine
    plain="$BATS_TEST_TMPDIR/plain"
    mkdir -p "$plain"
    printf 'def loose():\n    return 1\n' > "$plain/loose.py"
    cd "$plain"

    run --separate-stderr sh "$SHIM" build
    [ "$status" -eq 0 ]
    [[ "$output" == *"not inside a git repo"* ]]
    [ -f "$plain/graphify-out/graph.json" ]
    [ ! -e "$plain/.git" ]
}

# ── passthrough ──────────────────────────────────────────────────────────────

@test "shim: explain passes through to the real engine" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    run --separate-stderr sh "$SHIM" build
    [ "$status" -eq 0 ]

    run --separate-stderr sh "$SHIM" explain "helper()"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Node: helper()"* ]]
    [[ "$output" == *"main()"* ]]
    [[ "$output" == *"sample.py"* ]]
}

@test "shim: the query subcommands forward their args to the engine verbatim" {
    stub_engine "$OVERRIDE_BIN" "override-stub"

    run --separate-stderr sh "$SHIM" query "what calls helper" --budget 500
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv: query what calls helper --budget 500"* ]]

    run --separate-stderr sh "$SHIM" path "main()" "helper()"
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv: path main() helper()"* ]]

    run --separate-stderr sh "$SHIM" affected "helper()" --depth 3
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv: affected helper() --depth 3"* ]]

    run --separate-stderr sh "$SHIM" god-nodes --top 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv: god-nodes --top 5"* ]]

    run --separate-stderr sh "$SHIM" tree
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv: tree"* ]]
}

# ── missing-artifact errors ──────────────────────────────────────────────────

@test "shim: status without a graph exits nonzero and names code-map build" {
    stub_engine "$OVERRIDE_BIN" "override-stub"
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    run --separate-stderr sh "$SHIM" status
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"no graph"* ]]
    [[ "$stderr" == *"code-map build"* ]]
}

@test "shim: report and html without their artifacts exit nonzero with a clear message" {
    stub_engine "$OVERRIDE_BIN" "override-stub"
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    run --separate-stderr sh "$SHIM" report
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"GRAPH_REPORT.md"* ]]
    [[ "$stderr" == *"code-map"* ]]

    run --separate-stderr sh "$SHIM" html
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"graph.html"* ]]
    [[ "$stderr" == *"code-map"* ]]
}

@test "shim: report prints the report and html prints an absolute path" {
    stub_engine "$OVERRIDE_BIN" "override-stub"
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    mkdir -p "$repo/graphify-out"
    printf '# Fixture Graph Report\n\nDISTINCTIVE-REPORT-TOKEN\n' \
        > "$repo/graphify-out/GRAPH_REPORT.md"
    printf '<html>fixture</html>\n' > "$repo/graphify-out/graph.html"

    run --separate-stderr sh "$SHIM" report
    [ "$status" -eq 0 ]
    [[ "$output" == *"DISTINCTIVE-REPORT-TOKEN"* ]]

    run --separate-stderr sh "$SHIM" html
    [ "$status" -eq 0 ]
    [[ "$output" == "/"* ]]
    [[ "$output" == *"graphify-out/graph.html"* ]]
}

# ── engine resolution, doctor, help ──────────────────────────────────────────

@test "shim: the home override engine wins over the image prefix" {
    stub_engine "$OVERRIDE_BIN" "override-stub"
    stub_engine "$IMAGE_BIN" "image-stub"

    run --separate-stderr sh "$SHIM" god-nodes
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub"* ]]
    [[ "$output" != *"image-stub"* ]]
}

@test "shim: the image-prefix engine is used when no home override exists" {
    stub_engine "$IMAGE_BIN" "image-stub"
    [ ! -e "$OVERRIDE_BIN/graphify" ]

    run --separate-stderr sh "$SHIM" god-nodes
    [ "$status" -eq 0 ]
    [[ "$output" == *"image-stub argv: god-nodes"* ]]
}

@test "shim: with no engine installed the error names code-map doctor" {
    [ ! -e "$OVERRIDE_BIN/graphify" ]
    [ ! -e "$IMAGE_BIN/graphify" ]

    run --separate-stderr sh "$SHIM" god-nodes
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"engine not found"* ]]
    [[ "$stderr" == *"code-map doctor"* ]]
}

@test "shim: doctor reports the engine, the image pin, the graph state and the exclude entry" {
    stub_engine "$OVERRIDE_BIN" "override-stub"
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    pin=$(grep -o 'graphifyy==[0-9][0-9.]*' /workspace/Dockerfile | head -1)
    [ -n "$pin" ]

    run --separate-stderr sh "$SHIM" doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"engine: $OVERRIDE_BIN/graphify"* ]]
    [[ "$output" == *"$pin"* ]]
    [[ "$output" == *"graph: absent"* ]]
    [[ "$output" == *"exclude:"* ]]
    [[ "$output" == *"graphify-out/"* ]]
}

@test "shim: help lists the documented subcommands" {
    run --separate-stderr sh "$SHIM" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"usage: code-map"* ]]
    for sub in build refresh status explain query report html upgrade doctor; do
        echo "subcommand in usage: $sub"
        [[ "$output" == *"$sub"* ]]
    done

    run --separate-stderr sh "$SHIM"
    [ "$status" -eq 0 ]
    [[ "$output" == *"usage: code-map"* ]]
}

# ── upgrade: resolution and the ~/.claude blast radius ───────────────────────
#
# `upgrade` runs `uv tool install`, which is network work — live proof of an
# actual upgrade is not this suite's job. What IS testable offline: it refuses
# clearly without uv, it never writes assistant config, and the engine it would
# shadow resolves override-first.

@test "shim: upgrade without uv on PATH fails clearly and leaves ~/.claude untouched" {
    stub_engine "$OVERRIDE_BIN" "override-stub"
    before=$(claude_tree_sum)
    [ -n "$before" ]

    run --separate-stderr env PATH=/usr/bin:/bin sh "$SHIM" upgrade 0.9.48
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"uv"* ]]
    [[ "$stderr" == *"code-map upgrade"* ]]
    [ "$(claude_tree_sum)" = "$before" ]
}

@test "shim: the fixture ~/.claude tree is unchanged after a full battery" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"
    before=$(claude_tree_sum)
    [ -n "$before" ]
    [ -f "$HOME/.claude/CLAUDE.md" ]

    run --separate-stderr sh "$SHIM" build
    [ "$status" -eq 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr sh "$SHIM" status
    [ "$status" -eq 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr sh "$SHIM" refresh
    [ "$status" -eq 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr sh "$SHIM" explain "helper()"
    [ "$status" -eq 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr sh "$SHIM" doctor
    [ "$status" -eq 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr sh "$SHIM" help
    [ "$status" -eq 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    # `report` is deliberately unasserted on status: the report file is written
    # by the engine's clustering pass, not by `extract --code-only`, so whether
    # it exists after a build is the engine's call, not this test's contract.
    run --separate-stderr sh "$SHIM" report
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr env PATH=/usr/bin:/bin sh "$SHIM" upgrade
    [ "$status" -ne 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    [ -f "$HOME/.claude/CLAUDE.md" ]
    [ -f "$HOME/.claude/settings.json" ]
}
