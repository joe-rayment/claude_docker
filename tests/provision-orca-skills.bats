#!/usr/bin/env bats
#
# 75-orca-skills -- restores claude-orca-riu.3's already-decided default
# (native Orca orchestration on by default for every registered folder)
# through the mechanism that replaced riu.3's Mac-side sandbox.json/socket
# path once the 8uo epic moved Orca inside the same container as the agent
# (claude-orca-ndy).
#
# Assertions are `[ ]` and functions, never a bare `[[ ]]` (run-tests.sh).

STEP="${BATS_TEST_DIRNAME}/../scripts/container/provision.d/75-orca-skills"

# The step as the runner starts it: PROJECT_DIR set, ORCA_CLI pointed at a
# stub, nothing else inherited -- the same env -i shape
# tests/provision-git-init.bats uses for 55-git-init.
orca_skills_step() {  # orca_skills_step <project> <cli> [NAME=value ...]
    local d="$1" cli="$2"
    shift 2
    env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR/home" PROJECT_DIR="$d" \
        ORCA_CLI="$cli" "$@" bash "$STEP"
}

# A stub `orca` answering `skills installed` with a fixed listing and
# `skills install` by logging its full argv to install.log and exiting
# with the given code -- the same "one stub binary, one recorded line per
# call" shape tests/container-entrypoint.bats uses for ORCA_CLI.
stub_orca() {  # stub_orca <dir> <installed-listing> [install-exit]
    local dir="$1" listing="$2" install_exit="${3:-0}"
    mkdir -p "$dir"
    cat > "$dir/orca" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "skills" ] && [ "\$2" = "installed" ]; then
    printf '%s\n' '$listing'
    exit 0
fi
if [ "\$1" = "skills" ] && [ "\$2" = "install" ]; then
    printf '%s\n' "\$*" >> "$dir/install.log"
    exit $install_exit
fi
exit 1
EOF
    chmod +x "$dir/orca"
    printf '%s\n' "$dir/orca"
}

@test "orchestration missing from 'skills installed' -> the step installs it with --skill orchestration --local" {
    local proj="$BATS_TEST_TMPDIR/proj1" bindir="$BATS_TEST_TMPDIR/bin1" cli
    mkdir -p "$proj"
    cli="$(stub_orca "$bindir" "beads snowpark-deploy")"
    run orca_skills_step "$proj" "$cli"
    [ "$status" -eq 0 ]
    [ -f "$bindir/install.log" ]
    grep -q -- "--skill orchestration" "$bindir/install.log"
    grep -q -- "--local" "$bindir/install.log"
}

@test "orchestration already in 'skills installed' -> the step does not call install again" {
    local proj="$BATS_TEST_TMPDIR/proj2" bindir="$BATS_TEST_TMPDIR/bin2" cli
    mkdir -p "$proj"
    cli="$(stub_orca "$bindir" "beads orchestration snowpark-deploy")"
    run orca_skills_step "$proj" "$cli"
    [ "$status" -eq 0 ]
    [ ! -e "$bindir/install.log" ]
}

@test "a failing install is not swallowed: the step's own exit is non-zero" {
    local proj="$BATS_TEST_TMPDIR/proj3" bindir="$BATS_TEST_TMPDIR/bin3" cli
    mkdir -p "$proj"
    cli="$(stub_orca "$bindir" "beads snowpark-deploy" 1)"
    run orca_skills_step "$proj" "$cli"
    [ "$status" -ne 0 ]
    [ -f "$bindir/install.log" ]
}

@test "the install call never omits --local" {
    local proj="$BATS_TEST_TMPDIR/proj4" bindir="$BATS_TEST_TMPDIR/bin4" cli
    mkdir -p "$proj"
    cli="$(stub_orca "$bindir" "beads snowpark-deploy")"
    run orca_skills_step "$proj" "$cli"
    [ "$status" -eq 0 ]
    [ "$(cat "$bindir/install.log")" = "skills install --skill orchestration --local" ]
}

# ---------------------------------------------------------------------
# claude-orca-4gx: cases 5-8, re-frozen at this bead's RED-AT. Cases 1-4
# above are ndy's, kept verbatim.
#
# A richer stub than stub_orca(): `skills installed --json` and
# `skills installed` (plain) can be scripted to answer differently, and
# --json can be made to fail outright (an older Orca that predates it).
# ---------------------------------------------------------------------

# stub_orca_json <dir> <json-or-UNSUPPORTED> <plain-listing> [install-exit]
#
# <json-or-UNSUPPORTED> is either the literal JSON body `skills installed
# --json` should print (exit 0), or the literal string UNSUPPORTED, in
# which case `--json` prints an error to stderr and exits non-zero, the
# way an Orca predating the flag would.
stub_orca_json() {
    local dir="$1" json="$2" plain="$3" install_exit="${4:-0}"
    mkdir -p "$dir"
    printf '%s\n' "$plain" > "$dir/installed.plain"
    if [ "$json" = "UNSUPPORTED" ]; then
        : > "$dir/installed.json.unsupported"
    else
        printf '%s\n' "$json" > "$dir/installed.json"
    fi
    cat > "$dir/orca" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "skills" ] && [ "\$2" = "installed" ]; then
    if [ "\$3" = "--json" ]; then
        if [ -f "$dir/installed.json.unsupported" ]; then
            echo "unknown flag: --json" >&2
            exit 2
        fi
        cat "$dir/installed.json"
        exit 0
    fi
    cat "$dir/installed.plain"
    exit 0
fi
if [ "\$1" = "skills" ] && [ "\$2" = "install" ]; then
    printf '%s\n' "\$*" >> "$dir/install.log"
    exit $install_exit
fi
exit 1
EOF
    chmod +x "$dir/orca"
    printf '%s\n' "$dir/orca"
}

@test "case 5 (the regression case): another skill's DESCRIPTION mentions 'orchestration' in prose, but no skill is NAMED orchestration -> the step still installs" {
    local proj="$BATS_TEST_TMPDIR/proj5" bindir="$BATS_TEST_TMPDIR/bin5" cli
    mkdir -p "$proj"
    local json='{"result":{"skills":[{"name":"beads"},{"name":"snowpark-deploy"}]}}'
    local plain
    plain=$'beads (aaaa1111)\n    Bead tracking and issue management.\nsnowpark-deploy (bbbb2222)\n    Pairs with the orchestration skill for coordinated Snowpark deploys.'
    cli="$(stub_orca_json "$bindir" "$json" "$plain")"
    run orca_skills_step "$proj" "$cli"
    [ "$status" -eq 0 ]
    [ -f "$bindir/install.log" ]
    grep -q -- "--skill orchestration" "$bindir/install.log"
}

@test "case 6: orchestration genuinely present as a NAME (real selector entry) -> install is not invoked" {
    local proj="$BATS_TEST_TMPDIR/proj6" bindir="$BATS_TEST_TMPDIR/bin6" cli
    mkdir -p "$proj"
    local json='{"result":{"skills":[{"name":"beads"},{"name":"orchestration"}]}}'
    local plain
    plain=$'beads (aaaa1111)\n    Bead tracking and issue management.\norchestration (cccc3333)\n    Enables native multi-agent orchestration.'
    cli="$(stub_orca_json "$bindir" "$json" "$plain")"
    run orca_skills_step "$proj" "$cli"
    [ "$status" -eq 0 ]
    [ ! -e "$bindir/install.log" ]
}

@test "case 7: --json unsupported -> the anchored plain-text fallback is used and still discriminates the regression case correctly" {
    local proj="$BATS_TEST_TMPDIR/proj7" bindir="$BATS_TEST_TMPDIR/bin7" cli
    mkdir -p "$proj"
    local plain
    plain=$'beads (aaaa1111)\n    Bead tracking and issue management.\nsnowpark-deploy (bbbb2222)\n    Pairs with the orchestration skill for coordinated Snowpark deploys.'
    cli="$(stub_orca_json "$bindir" "UNSUPPORTED" "$plain")"
    run orca_skills_step "$proj" "$cli"
    [ "$status" -eq 0 ]
    [ -f "$bindir/install.log" ]
    grep -q -- "--skill orchestration" "$bindir/install.log"
}

@test "case 8: every install invocation carries --local, across every case that installs (missing, regression, and json-unsupported-fallback)" {
    local proj bindir cli

    proj="$BATS_TEST_TMPDIR/proj8a" bindir="$BATS_TEST_TMPDIR/bin8a"
    mkdir -p "$proj"
    cli="$(stub_orca "$bindir" "beads snowpark-deploy")"
    run orca_skills_step "$proj" "$cli"
    [ -f "$bindir/install.log" ]
    grep -q -- "--local" "$bindir/install.log"

    proj="$BATS_TEST_TMPDIR/proj8b" bindir="$BATS_TEST_TMPDIR/bin8b"
    mkdir -p "$proj"
    local json='{"result":{"skills":[{"name":"beads"}]}}'
    local plain
    plain=$'beads (aaaa1111)\n    Mentions orchestration in passing.'
    cli="$(stub_orca_json "$bindir" "$json" "$plain")"
    run orca_skills_step "$proj" "$cli"
    [ -f "$bindir/install.log" ]
    grep -q -- "--local" "$bindir/install.log"

    proj="$BATS_TEST_TMPDIR/proj8c" bindir="$BATS_TEST_TMPDIR/bin8c"
    mkdir -p "$proj"
    cli="$(stub_orca_json "$bindir" "UNSUPPORTED" "$plain")"
    run orca_skills_step "$proj" "$cli"
    [ -f "$bindir/install.log" ]
    grep -q -- "--local" "$bindir/install.log"
}
