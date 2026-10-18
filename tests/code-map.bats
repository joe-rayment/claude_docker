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
# No network, ever: the engine is a STUB shell script placed at the one
# resolution point, and the host dir is redirected via CLAUDE_ORCA_HOST so
# no test reads (or needs) a real host-level install.
#
# FROZEN per beads_claude_docker-o7z's acceptance contract: this file must
# not be edited after its RED commit. If a test here turns out to be wrong,
# stop and report — do not edit it. (A later bead may ADD cases under its own
# RED-AT; that does not authorize editing these.)

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GUARD="$REPO_ROOT/scripts/code-map-guard.sh"

setup() {
    export TMPDIR="$BATS_TEST_TMPDIR"
    export HOME="$BATS_TEST_TMPDIR/home"

    # a fake ~/.claude tree: exactly the surface a stray `graphify install`
    # would rewrite. Every test checksums it; test 14 pins it across a whole
    # battery of invocations.
    mkdir -p "$HOME/.claude/skills/x" "$HOME/.claude/agents"
    printf '# fixture CLAUDE.md\n' > "$HOME/.claude/CLAUDE.md"
    printf '{"model":"claude-fable-5-1"}\n' > "$HOME/.claude/settings.json"
    printf 'fixture skill\n' > "$HOME/.claude/skills/x/SKILL.md"
    printf 'fixture agent\n' > "$HOME/.claude/agents/y.md"

    # S7 (claude-orca-3sk.7): the engine is a single, optional, host-owned
    # install (CODE_MAP_ENGINE, else <host_dir()>/code-map/bin/graphify --
    # see scripts/lib/paths.sh's host_dir() and scripts/code-map.sh's
    # header) -- no more home-override-vs-image-prefix two-tier resolution.
    # Point the host dir at a path that does NOT exist unless a test
    # creates it -- never at a real host install.
    export CLAUDE_ORCA_HOST="$BATS_TEST_TMPDIR/host"
    ENGINE_BIN="$CLAUDE_ORCA_HOST/code-map/bin"
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

@test "guard: version passes through to the default host-dir engine" {
    stub_engine "$ENGINE_BIN" "host-stub"

    run --separate-stderr bash "$GUARD" version
    [ "$status" -eq 0 ]
    [[ "$output" == *"host-stub"* ]]
    [[ "$output" == *"argv: version"* ]]
}

@test "guard: CODE_MAP_ENGINE overrides the default host-dir engine" {
    stub_engine "$ENGINE_BIN" "host-stub"
    override_dir="$BATS_TEST_TMPDIR/engine-override"
    stub_engine "$override_dir" "override-stub"
    export CODE_MAP_ENGINE="$override_dir/graphify"

    run --separate-stderr bash "$GUARD" version
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub"* ]]
    [[ "$output" != *"host-stub"* ]]
    [[ "$output" == *"argv: version"* ]]
}

@test "guard: every allowlisted subcommand reaches the engine" {
    stub_engine "$ENGINE_BIN" "override-stub"

    for sub in extract update cluster-only query explain path affected tree \
               god-nodes diagnose label watch merge-graphs merge-driver \
               export benchmark version help; do
        echo "subcommand under test: $sub"
        run --separate-stderr bash "$GUARD" "$sub"
        [ "$status" -eq 0 ]
        [[ "$output" == *"override-stub argv: $sub"* ]]
    done
}

@test "guard: --version, --help and no args pass through to the engine" {
    stub_engine "$ENGINE_BIN" "override-stub"

    run --separate-stderr bash "$GUARD" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv: --version"* ]]

    run --separate-stderr bash "$GUARD" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv: --help"* ]]

    run --separate-stderr bash "$GUARD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv:"* ]]
}

# ── blocked: everything that writes assistant config ─────────────────────────

@test "guard: install is blocked with exit 2 and points at code-map" {
    stub_engine "$ENGINE_BIN" "override-stub"

    run --separate-stderr bash "$GUARD" install
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]
    [[ "$output" != *"override-stub"* ]]
}

@test "guard: claude install is blocked" {
    stub_engine "$ENGINE_BIN" "override-stub"

    run --separate-stderr bash "$GUARD" claude install
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]
    [[ "$output" != *"override-stub"* ]]
}

@test "guard: uninstall is blocked" {
    stub_engine "$ENGINE_BIN" "override-stub"

    run --separate-stderr bash "$GUARD" uninstall
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]

    run --separate-stderr bash "$GUARD" uninstall --purge
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]
}

@test "guard: hook install is blocked" {
    stub_engine "$ENGINE_BIN" "override-stub"

    run --separate-stderr bash "$GUARD" hook install
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]
    [[ "$output" != *"override-stub"* ]]
}

@test "guard: global is blocked" {
    stub_engine "$ENGINE_BIN" "override-stub"

    run --separate-stderr bash "$GUARD" global list
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]
    [[ "$output" != *"override-stub"* ]]
}

@test "guard: clone is blocked" {
    stub_engine "$ENGINE_BIN" "override-stub"

    run --separate-stderr bash "$GUARD" clone https://github.com/example/repo
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]
    [[ "$output" != *"override-stub"* ]]
}

@test "guard: an unknown future subcommand is blocked" {
    stub_engine "$ENGINE_BIN" "override-stub"

    run --separate-stderr bash "$GUARD" frobnicate --all
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]
    [[ "$output" != *"override-stub"* ]]
}

@test "guard: every per-platform install/uninstall is blocked" {
    stub_engine "$ENGINE_BIN" "override-stub"

    for platform in claude codebuddy codex opencode kilo aider copilot vscode \
                    claw droid trae trae-cn gemini cursor antigravity hermes \
                    kiro pi devin windows amp agents; do
        for verb in install uninstall; do
            echo "platform under test: $platform $verb"
            run --separate-stderr bash "$GUARD" "$platform" "$verb"
            [ "$status" -eq 2 ]
            [[ "$stderr" == *"code-map"* ]]
            [[ "$stderr" == *"blocked"* ]]
        done
    done
}

@test "guard: a blocked subcommand never executes the engine" {
    stub_engine "$ENGINE_BIN" "override-stub"

    run --separate-stderr bash "$GUARD" install
    [ "$status" -eq 2 ]
    [ ! -e "$ENGINE_LOG" ]

    run --separate-stderr bash "$GUARD" claude install
    [ "$status" -eq 2 ]
    [ ! -e "$ENGINE_LOG" ]

    # the log only appears once an allowlisted call goes through
    run --separate-stderr bash "$GUARD" query "what calls foo"
    [ "$status" -eq 0 ]
    [ -s "$ENGINE_LOG" ]
}

@test "guard: the fixture ~/.claude tree is unchanged after every invocation" {
    stub_engine "$ENGINE_BIN" "override-stub"
    before=$(claude_tree_sum)
    [ -n "$before" ]
    [ -f "$HOME/.claude/CLAUDE.md" ]

    # each run also asserts its own exit status, so this test cannot pass
    # vacuously by way of a guard that never ran at all
    run --separate-stderr bash "$GUARD" version
    [ "$status" -eq 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr bash "$GUARD" query "what calls foo"
    [ "$status" -eq 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr bash "$GUARD" install
    [ "$status" -eq 2 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr bash "$GUARD" claude install
    [ "$status" -eq 2 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr bash "$GUARD" hook install
    [ "$status" -eq 2 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr bash "$GUARD" global list
    [ "$status" -eq 2 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr bash "$GUARD" clone https://github.com/example/repo
    [ "$status" -eq 2 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr bash "$GUARD" frobnicate
    [ "$status" -eq 2 ]
    [ "$(claude_tree_sum)" = "$before" ]

    [ -f "$HOME/.claude/CLAUDE.md" ]
    [ -f "$HOME/.claude/settings.json" ]
}

# ── engine resolution failure ────────────────────────────────────────────────

@test "guard: blocking does not depend on an engine being installed" {
    [ ! -e "$ENGINE_BIN/graphify" ]

    run --separate-stderr bash "$GUARD" install
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"code-map"* ]]
    [[ "$stderr" == *"blocked"* ]]
}

@test "guard: with no engine installed the error names code-map doctor" {
    [ ! -e "$ENGINE_BIN/graphify" ]

    run --separate-stderr bash "$GUARD" version
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"code-map doctor"* ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# shim: section (beads_claude_docker-1my). scripts/code-map.sh is staged as
# /usr/local/bin/code-map — the feature's ONLY documented entry point, and the
# thing the guard's error messages point at. It resolves the engine exactly
# like the guard does (CODE_MAP_ENGINE, else <host_dir()>/code-map/bin/
# graphify, never PATH) and adds the repo-shaped workflow on top: build/
# refresh/status, passthrough queries, report/html, upgrade, doctor.
#
# Two kinds of engine appear below, on purpose:
#   · the REAL engine, symlinked into the host-dir resolution point by
#     install_real_engine, for the build/refresh/status flows — those are only
#     worth testing against the thing that actually writes graph.json. It runs
#     AST-only (--code-only) on a one-file fixture: no network, no API key.
#   · the guard section's stub_engine, for argv-forwarding and
#     engine-resolution assertions, where the real engine would add nothing.
#
# The guard section's setup() is this file's only setup() and applies here
# too: TMPDIR/HOME are redirected into $BATS_TEST_TMPDIR, CLAUDE_ORCA_HOST
# points at a path that exists only if a test creates it, and $ENGINE_BIN /
# claude_tree_sum are in scope.
#
# FROZEN per beads_claude_docker-1my's acceptance contract from its RED commit
# on: if a test here turns out to be wrong, stop and report — do not edit it.

SHIM="$REPO_ROOT/scripts/code-map.sh"

# A real engine, wherever this machine has it (CODE_MAP_REAL_ENGINE override,
# or a couple of conventional install spots) -- purely so the build/refresh
# tests below exercise real graph.json output; unrelated to the shim's own
# CODE_MAP_ENGINE/host_dir() production resolution, which the guard/shim
# "engine resolution" tests cover separately. Not resolved through PATH —
# `graphify` on PATH is the guard, which would recurse.
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
# The real graphify engine is an OPTIONAL dependency: it is not one of
# setup.sh's pinned phases, so it is absent from the image, from CI and
# from a stock Mac. Twenty-two cases here need it, and they used to fail
# rather than skip -- so a suite run anywhere but a box that happened to
# have it reported 22 failures that meant nothing, and the whole suite
# could never be a gate. Skipping says the same thing honestly, and leaves
# room for CI to run the rest.
install_real_engine() {
    local engine=""
    engine=$(real_engine) || true
    [ -n "$engine" ] || skip "no graphify engine on this box (set CODE_MAP_REAL_ENGINE to point at one)"
    mkdir -p "$ENGINE_BIN"
    ln -sf "$engine" "$ENGINE_BIN/graphify"
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

    run --separate-stderr bash "$SHIM" build
    [ "$status" -eq 0 ]
    [ -f "$repo/graphify-out/graph.json" ]

    head=$(git -C "$repo" rev-parse HEAD)
    [ "$(jq -r .built_at_commit "$repo/graphify-out/graph.json")" = "$head" ]

    nodes=$(jq '.nodes|length' "$repo/graphify-out/graph.json")
    links=$(jq '.links|length' "$repo/graphify-out/graph.json")
    [ "$nodes" -gt 0 ]
    [ "$links" -gt 0 ]

    run --separate-stderr bash "$SHIM" status
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

    run --separate-stderr bash "$SHIM" build
    [ "$status" -eq 0 ]

    fixture_commit "$repo" --allow-empty -m second

    run --separate-stderr bash "$SHIM" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"state: STALE"* ]]
    [[ "$output" != *"state: fresh"* ]]
}

@test "shim: refresh brings a stale graph back to fresh" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    run --separate-stderr bash "$SHIM" build
    [ "$status" -eq 0 ]

    fixture_commit "$repo" --allow-empty -m second
    head=$(git -C "$repo" rev-parse HEAD)

    run --separate-stderr bash "$SHIM" refresh
    [ "$status" -eq 0 ]

    [ "$(jq -r .built_at_commit "$repo/graphify-out/graph.json")" = "$head" ]

    run --separate-stderr bash "$SHIM" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"state: fresh"* ]]
}

@test "shim: refresh with no graph falls back to build" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"
    [ ! -e "$repo/graphify-out/graph.json" ]

    run --separate-stderr bash "$SHIM" refresh
    [ "$status" -eq 0 ]
    [[ "$output" == *"no graph yet"* ]]
    [ -f "$repo/graphify-out/graph.json" ]

    run --separate-stderr bash "$SHIM" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"state: fresh"* ]]
}

@test "shim: GRAPHIFY_OUT redirects the graph directory" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"
    export GRAPHIFY_OUT=graphify-out-alt

    run --separate-stderr bash "$SHIM" build
    [ "$status" -eq 0 ]
    [ -f "$repo/graphify-out-alt/graph.json" ]
    [ ! -e "$repo/graphify-out/graph.json" ]

    run --separate-stderr bash "$SHIM" status
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

    run --separate-stderr bash "$SHIM" build
    [ "$status" -eq 0 ]
    run --separate-stderr bash "$SHIM" build
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

    run --separate-stderr bash "$SHIM" build
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

    run --separate-stderr bash "$SHIM" build
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

    run --separate-stderr bash "$SHIM" build
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

    run --separate-stderr bash "$SHIM" build
    [ "$status" -eq 0 ]

    run --separate-stderr bash "$SHIM" explain "helper()"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Node: helper()"* ]]
    [[ "$output" == *"main()"* ]]
    [[ "$output" == *"sample.py"* ]]
}

@test "shim: the query subcommands forward their args to the engine verbatim" {
    stub_engine "$ENGINE_BIN" "override-stub"

    run --separate-stderr bash "$SHIM" query "what calls helper" --budget 500
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv: query what calls helper --budget 500"* ]]

    run --separate-stderr bash "$SHIM" path "main()" "helper()"
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv: path main() helper()"* ]]

    run --separate-stderr bash "$SHIM" affected "helper()" --depth 3
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv: affected helper() --depth 3"* ]]

    run --separate-stderr bash "$SHIM" god-nodes --top 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv: god-nodes --top 5"* ]]

    run --separate-stderr bash "$SHIM" tree
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv: tree"* ]]
}

# ── missing-artifact errors ──────────────────────────────────────────────────

@test "shim: status without a graph exits nonzero and names code-map build" {
    stub_engine "$ENGINE_BIN" "override-stub"
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    run --separate-stderr bash "$SHIM" status
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"no graph"* ]]
    [[ "$stderr" == *"code-map build"* ]]
}

@test "shim: report and html without their artifacts exit nonzero with a clear message" {
    stub_engine "$ENGINE_BIN" "override-stub"
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    run --separate-stderr bash "$SHIM" report
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"GRAPH_REPORT.md"* ]]
    [[ "$stderr" == *"code-map"* ]]

    run --separate-stderr bash "$SHIM" html
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"graph.html"* ]]
    [[ "$stderr" == *"code-map"* ]]
}

@test "shim: report prints the report and html prints an absolute path" {
    stub_engine "$ENGINE_BIN" "override-stub"
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    mkdir -p "$repo/graphify-out"
    printf '# Fixture Graph Report\n\nDISTINCTIVE-REPORT-TOKEN\n' \
        > "$repo/graphify-out/GRAPH_REPORT.md"
    printf '<html>fixture</html>\n' > "$repo/graphify-out/graph.html"

    run --separate-stderr bash "$SHIM" report
    [ "$status" -eq 0 ]
    [[ "$output" == *"DISTINCTIVE-REPORT-TOKEN"* ]]

    run --separate-stderr bash "$SHIM" html
    [ "$status" -eq 0 ]
    [[ "$output" == "/"* ]]
    [[ "$output" == *"graphify-out/graph.html"* ]]
}

# ── engine resolution, doctor, help ──────────────────────────────────────────

@test "shim: the default host-dir engine is used" {
    stub_engine "$ENGINE_BIN" "host-stub"

    run --separate-stderr bash "$SHIM" god-nodes
    [ "$status" -eq 0 ]
    [[ "$output" == *"host-stub argv: god-nodes"* ]]
}

@test "shim: CODE_MAP_ENGINE overrides the default host-dir engine" {
    stub_engine "$ENGINE_BIN" "host-stub"
    override_dir="$BATS_TEST_TMPDIR/engine-override"
    stub_engine "$override_dir" "override-stub"
    export CODE_MAP_ENGINE="$override_dir/graphify"

    run --separate-stderr bash "$SHIM" god-nodes
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub"* ]]
    [[ "$output" != *"host-stub"* ]]
}

@test "shim: with no engine installed the error names code-map doctor" {
    [ ! -e "$ENGINE_BIN/graphify" ]

    run --separate-stderr bash "$SHIM" god-nodes
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"engine not found"* ]]
    [[ "$stderr" == *"code-map doctor"* ]]
}

@test "shim: doctor reports the engine, the graph state and the exclude entry" {
    stub_engine "$ENGINE_BIN" "override-stub"
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    run --separate-stderr bash "$SHIM" doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"engine: $ENGINE_BIN/graphify"* ]]
    [[ "$output" == *"graph: absent"* ]]
    [[ "$output" == *"exclude:"* ]]
    [[ "$output" == *"graphify-out/"* ]]
}

@test "shim: help lists the documented subcommands" {
    run --separate-stderr bash "$SHIM" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"usage: code-map"* ]]
    for sub in build refresh status explain query report html upgrade doctor; do
        echo "subcommand in usage: $sub"
        [[ "$output" == *"$sub"* ]]
    done

    run --separate-stderr bash "$SHIM"
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
    stub_engine "$ENGINE_BIN" "override-stub"
    before=$(claude_tree_sum)
    [ -n "$before" ]

    run --separate-stderr env PATH=/usr/bin:/bin bash "$SHIM" upgrade 0.9.48
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

    run --separate-stderr bash "$SHIM" build
    [ "$status" -eq 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr bash "$SHIM" status
    [ "$status" -eq 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr bash "$SHIM" refresh
    [ "$status" -eq 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr bash "$SHIM" explain "helper()"
    [ "$status" -eq 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr bash "$SHIM" doctor
    [ "$status" -eq 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr bash "$SHIM" help
    [ "$status" -eq 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    # `report` is deliberately unasserted on status: the report file is written
    # by the engine's clustering pass, not by `extract --code-only`, so whether
    # it exists after a build is the engine's call, not this test's contract.
    run --separate-stderr bash "$SHIM" report
    [ "$(claude_tree_sum)" = "$before" ]

    run --separate-stderr env PATH=/usr/bin:/bin bash "$SHIM" upgrade
    [ "$status" -ne 0 ]
    [ "$(claude_tree_sum)" = "$before" ]

    [ -f "$HOME/.claude/CLAUDE.md" ]
    [ -f "$HOME/.claude/settings.json" ]
}

# ═══════════════════════════════════════════════════════════════════════════
# prime: section (beads_claude_docker-fi7). scripts/code-map-prime.sh is staged
# as /usr/local/bin/code-map-prime and wired as a SessionStart hook: it keeps
# the graph current and injects the two-line block that makes the map
# first-source. A SessionStart hook may never break session start, so every
# inapplicable case is a SILENT exit 0 — which is exactly why each silent test
# below also asserts the exit status: a MISSING prime script makes
# `sh $PRIME` print nothing on stdout either, so emptiness alone would pass
# vacuously, and the status assertion is what keeps these red before the
# script exists (same trap the guard section documents at the top of the file).
#
# Nothing here needs a host-level code-map install to exist -- the host may
# never have installed one. The shim is injected via CODE_MAP_BIN and
# the engine via the fixture HOME (setup() + install_real_engine), and the log
# is redirected under the fixture repo via CODE_MAP_LOG so no test writes to
# the real config-dir logs/.
#
# FROZEN per beads_claude_docker-fi7's acceptance contract from its RED commit
# on: if a test here turns out to be wrong, stop and report — do not edit it.

PRIME="$REPO_ROOT/scripts/code-map-prime.sh"
SETTINGS="$REPO_ROOT/config/claude-settings.json"

# A repo with no code at all: prime must stay silent rather than map a docs
# tree.
fixture_docs_repo() {
    local dir=$1
    mkdir -p "$dir"
    git -C "$dir" init -q
    printf '# just docs\n' > "$dir/README.md"
    git -C "$dir" add README.md
    fixture_commit "$dir" -m init
}

# ── silent when inapplicable ─────────────────────────────────────────────────

@test "prime: the prime script exists and is executable" {
    [ -x "$PRIME" ]
}

@test "prime: outside a git repo it says nothing and exits 0" {
    plain="$BATS_TEST_TMPDIR/plain"
    mkdir -p "$plain"
    cd "$plain"

    # guard against a $TMPDIR that is itself inside some repo, which would make
    # this test assert the wrong branch
    run git -C "$plain" rev-parse --show-toplevel
    [ "$status" -ne 0 ]

    run --separate-stderr bash "$PRIME"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "prime: CODE_MAP_DISABLE=1 silences a repo that would otherwise emit" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    run --separate-stderr bash "$SHIM" build
    [ "$status" -eq 0 ]
    [ -f "$repo/graphify-out/graph.json" ]

    export CODE_MAP_BIN="$SHIM"
    export CODE_MAP_LOG="$repo/.claude/logs/code-map.log"
    export CODE_MAP_DISABLE=1

    run --separate-stderr bash "$PRIME"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "prime: a repo with no code files says nothing and starts no build" {
    install_real_engine
    docs="$BATS_TEST_TMPDIR/docs"
    fixture_docs_repo "$docs"
    cd "$docs"

    export CODE_MAP_BIN="$SHIM"
    export CODE_MAP_LOG="$docs/.claude/logs/code-map.log"

    run --separate-stderr bash "$PRIME"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$docs/graphify-out/graph.json" ]
    [ ! -e "$CODE_MAP_LOG" ]
}

@test "prime: an unavailable code-map shim says nothing" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    export CODE_MAP_BIN="$BATS_TEST_TMPDIR/no-such-code-map"
    [ ! -e "$CODE_MAP_BIN" ]

    run --separate-stderr bash "$PRIME"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── the injected block ───────────────────────────────────────────────────────

@test "prime: an existing graph produces the two-line context block" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    run --separate-stderr bash "$SHIM" build
    [ "$status" -eq 0 ]

    head=$(git -C "$repo" rev-parse HEAD)
    sha8=${head:0:8}
    [ -n "$sha8" ]

    export CODE_MAP_BIN="$SHIM"
    export CODE_MAP_LOG="$repo/.claude/logs/code-map.log"

    run --separate-stderr bash "$PRIME"
    [ "$status" -eq 0 ]

    nodes=$(jq '.nodes|length' "$repo/graphify-out/graph.json")
    links=$(jq '.links|length' "$repo/graphify-out/graph.json")
    [ "$nodes" -gt 0 ]
    [ "$links" -gt 0 ]

    # exactly two lines: the refresh the hook runs first prints engine chatter,
    # and none of it may reach the context block
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[0]}" == "[code-map] $nodes nodes"* ]]
    [[ "${lines[0]}" == *"$links edges"* ]]
    [[ "${lines[0]}" == *"built at $sha8"* ]]
    [[ "${lines[0]}" == *"(fresh)"* ]]
    [[ "${lines[0]}" == *"code-map explain"* ]]
    [[ "${lines[1]}" == *"INFERRED"* ]]
    [[ "${lines[1]}" == *"verify before acting"* ]]
}

# bats test_tags=size:medium
@test "prime: with no graph it emits one building line and the build really runs" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"
    [ ! -e "$repo/graphify-out/graph.json" ]

    export CODE_MAP_BIN="$SHIM"
    export CODE_MAP_LOG="$repo/.claude/logs/code-map.log"

    run --separate-stderr bash "$PRIME"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "[code-map] no graph yet — building in background (log: .claude/logs/code-map.log); code-map status when done" ]

    # the line is a promise: a detached build must actually be running
    built=0
    for _ in $(seq 1 60); do
        if [ -f "$repo/graphify-out/graph.json" ]; then
            built=1
            break
        fi
        sleep 1
    done
    [ "$built" -eq 1 ]
    [ -s "$CODE_MAP_LOG" ]
}

# ── the SessionStart wiring ──────────────────────────────────────────────────

@test "prime: claude-settings.json is valid and runs code-map-prime after context-detect" {
    run --separate-stderr jq empty "$SETTINGS"
    [ "$status" -eq 0 ]

    cmds='[.hooks.SessionStart[0].hooks[].command]'
    cd_idx=$(jq "$cmds | map(test(\"context-detect\")) | index(true)" "$SETTINGS")
    cm_idx=$(jq "$cmds | map(test(\"code-map-prime\")) | index(true)" "$SETTINGS")

    # numeric comparisons on purpose: an absent entry is the string "null",
    # which is non-empty and would satisfy a [ -n ] check
    [ "$cd_idx" -ge 0 ]
    [ "$cm_idx" -gt "$cd_idx" ]
}

# ═══════════════════════════════════════════════════════════════════════════
# e2e: section (beads_claude_docker-7vz). The seams the earlier sections left
# to the end: what a FIRST build leaves behind, what a query run from a
# subdirectory resolves against, and the one prime branch that only exists
# when a refresh runs long.
#
# These are regression cases over behavior the earlier slices already shipped,
# so — unlike the guard/shim/prime sections — they were BORN GREEN. They are
# here to keep that behavior from regressing silently, not to have driven it;
# the honest record is in beads_claude_docker-7vz's notes. Everything above
# applies unchanged: setup()'s fixture HOME and CLAUDE_ORCA_HOST, the
# real engine via install_real_engine, and no network anywhere.
#
# FROZEN per beads_claude_docker-7vz's acceptance contract from its RED commit
# on: if a test here turns out to be wrong, stop and report — do not edit it.

# ── what a first build leaves behind ─────────────────────────────────────────

@test "e2e: a first build leaves a readable report and an html view behind" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    # one build, no refresh: `extract --code-only` stops at graph.json, so the
    # report and the html view exist only because cmd_build runs the
    # clustering pass itself. Without that step `code-map report` errors on a
    # freshly built repo — which is what the shim section's report/html test
    # deliberately left unasserted.
    run --separate-stderr bash "$SHIM" build
    [ "$status" -eq 0 ]
    [ -f "$repo/graphify-out/graph.json" ]
    [ -f "$repo/graphify-out/GRAPH_REPORT.md" ]
    [ -f "$repo/graphify-out/graph.html" ]

    run --separate-stderr bash "$SHIM" report
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run --separate-stderr bash "$SHIM" html
    [ "$status" -eq 0 ]
    [[ "$output" == "/"* ]]
    [[ "$output" == *"graphify-out/graph.html"* ]]

    # the clustering pass rewrites graph.json, so the commit stamp has to
    # survive it — status is the shim's freshness contract, not the engine's
    run --separate-stderr bash "$SHIM" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"state: fresh"* ]]
}

# ── queries from anywhere in the repo ────────────────────────────────────────

@test "e2e: explain works from a subdirectory via the injected --graph" {
    install_real_engine
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    run --separate-stderr bash "$SHIM" build
    [ "$status" -eq 0 ]

    # the engine resolves its --graph default against the CURRENT directory,
    # so an uninjected query from here would look for ./graphify-out/graph.json
    mkdir -p "$repo/sub/deeper"
    cd "$repo/sub/deeper"
    [ ! -e "./graphify-out/graph.json" ]

    run --separate-stderr bash "$SHIM" explain "helper()"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Node: helper()"* ]]
    [[ "$output" == *"main()"* ]]
    [[ "$output" == *"sample.py"* ]]
}

@test "e2e: an explicit --graph wins and no default is appended" {
    stub_engine "$ENGINE_BIN" "override-stub"
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    # the caller's own --graph must reach the engine exactly once: a second,
    # appended one would silently override the choice the caller made
    run --separate-stderr bash "$SHIM" explain "helper()" --graph /tmp/caller-chosen.json
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv: explain helper() --graph /tmp/caller-chosen.json"* ]]
    [[ "$output" != *"graphify-out/graph.json"* ]]

    run --separate-stderr bash "$SHIM" query "what calls helper" --graph=/tmp/caller-chosen.json
    [ "$status" -eq 0 ]
    [[ "$output" == *"override-stub argv: query what calls helper --graph=/tmp/caller-chosen.json"* ]]
    [[ "$output" != *"graphify-out/graph.json"* ]]
}

# ── prime's slow-refresh branch ──────────────────────────────────────────────

# bats test_tags=size:medium
@test "e2e: a refresh too slow for session start is detached and the block still prints" {
    # GNU coreutils' timeout; macOS ships none, so this case skips there
    # rather than failing for a reason that is about the box.
    command -v timeout >/dev/null 2>&1 || skip "no timeout(1) on this box"
    repo="$BATS_TEST_TMPDIR/repo"
    fixture_repo "$repo"
    cd "$repo"

    # a graph must exist for prime to take the refresh branch at all; its
    # contents never matter — prime reads its counts from `code-map status`
    mkdir -p "$repo/graphify-out"
    printf '{}\n' > "$repo/graphify-out/graph.json"

    # a shim that is too slow on purpose. No real engine here: the branch
    # under test is prime's handling of rc=124, and a stub is the only way to
    # make "too slow" deterministic rather than machine-dependent.
    calls="$BATS_TEST_TMPDIR/calls.log"
    slow="$BATS_TEST_TMPDIR/slow-code-map"
    cat > "$slow" <<EOF
#!/bin/sh
echo "\$1-start" >> "$calls"
case "\$1" in
    refresh) sleep 20 ;;
    status)
        echo "nodes: 7"
        echo "links: 9"
        echo "built_at_commit: 0123456789abcdef0123456789abcdef01234567"
        echo "state: STALE"
        ;;
esac
EOF
    chmod +x "$slow"

    export CODE_MAP_BIN="$slow"
    export CODE_MAP_LOG="$repo/.claude/logs/code-map.log"
    export CODE_MAP_REFRESH_TIMEOUT=1

    run --separate-stderr bash "$PRIME"
    [ "$status" -eq 0 ]

    # the whole point of the branch: a session start never waits on the slow
    # refresh, and the block prints anyway from the graph we already have
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[0]}" == "[code-map] 7 nodes"* ]]
    [[ "${lines[0]}" == *"9 edges"* ]]
    [[ "${lines[0]}" == *"built at 01234567"* ]]
    [[ "${lines[0]}" == *"(STALE)"* ]]
    [[ "${lines[1]}" == *"INFERRED"* ]]

    # ...and the refresh is not dropped: rc=124 hands it to a detached retry,
    # so the stub records a SECOND start after the timed-out first one
    detached=0
    for _ in $(seq 1 30); do
        if [ "$(grep -c '^refresh-start$' "$calls")" -ge 2 ]; then
            detached=1
            break
        fi
        sleep 1
    done
    [ "$detached" -eq 1 ]
    [ "$(grep -c '^status-start$' "$calls")" -eq 1 ]
}

# ── 3fp: one graph set — no dated snapshot dirs under graphify-out ───────────
# The engine has been seen to write a dated YYYY-MM-DD copy next to the root
# set on build/update. These stubs do exactly that; build/refresh must sweep
# them so only the root set survives.

dated_stub_engine() {
    local dir=$1 out=$2
    mkdir -p "$dir"
    cat > "$dir/graphify" <<STUB
#!/bin/sh
printf '{}' > "$out/graph.json"
printf 'report' > "$out/GRAPH_REPORT.md"
mkdir -p "$out/2026-09-05" "$out/cache"
printf '{}' > "$out/2026-09-05/graph.json"
printf '{}' > "$out/cache/e.json"
STUB
    chmod +x "$dir/graphify"
}

@test "3fp build: a dated snapshot dir under graphify-out is pruned; the root set stays" {
    ws="$BATS_TEST_TMPDIR/ws-build"
    mkdir -p "$ws" && (cd "$ws" && git init -q .)
    out="$ws/graphify-out"
    dated_stub_engine "$BATS_TEST_TMPDIR/engine-3fp" "$out"
    export CODE_MAP_ENGINE="$BATS_TEST_TMPDIR/engine-3fp/graphify"
    cd "$ws"

    run --separate-stderr bash "$REPO_ROOT/scripts/code-map.sh" build
    [ "$status" -eq 0 ]
    [ ! -d "$out/2026-09-05" ]
    [ -f "$out/graph.json" ]
    [ -f "$out/GRAPH_REPORT.md" ]
    [ -f "$out/cache/e.json" ]
}

@test "3fp refresh: a dated snapshot dir under graphify-out is pruned; the root set stays" {
    ws="$BATS_TEST_TMPDIR/ws-refresh"
    mkdir -p "$ws" && (cd "$ws" && git init -q .)
    out="$ws/graphify-out"
    dated_stub_engine "$BATS_TEST_TMPDIR/engine-3fp" "$out"
    export CODE_MAP_ENGINE="$BATS_TEST_TMPDIR/engine-3fp/graphify"
    mkdir -p "$out/2026-09-08"
    printf '{}' > "$out/graph.json"
    printf '{}' > "$out/2026-09-08/manifest.json"
    cd "$ws"

    run --separate-stderr bash "$REPO_ROOT/scripts/code-map.sh" refresh
    [ "$status" -eq 0 ]
    [ ! -d "$out/2026-09-08" ]
    [ -f "$out/graph.json" ]
}
