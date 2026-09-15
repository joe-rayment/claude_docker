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
    # Real `orca skills installed` shape (mirroring case 6): a name (hash)
    # selector line at column 0 per skill, with an indented prose
    # description line under it -- never a flush-left space-separated list
    # of bare names, which Orca does not emit.
    local listing
    listing=$'beads (aaaa1111)\n    Bead tracking and issue management.\norchestration (cccc3333)\n    Enables native multi-agent orchestration.'
    cli="$(stub_orca "$bindir" "$listing")"
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

# ---------------------------------------------------------------------
# claude-orca-01u: cases 9-13. --json becomes AUTHORITATIVE in both
# directions (exit 0 AND parses as JSON -> that answer is final, plain
# fallback never consulted either way), and the plain-text fallback
# anchors to the START of the line (a selector line begins with the
# name; prose, warnings and locations do not). Every assertion here is
# on CAPTURED ARGV (was `skills install` actually invoked?), never on
# exit code alone -- a wrongful skip exits 0.
# ---------------------------------------------------------------------

@test "case 9: --json unsupported; plain has no orchestration selector but a flush-left PROSE line mentions it -> MUST INSTALL" {
    local proj="$BATS_TEST_TMPDIR/proj9" bindir="$BATS_TEST_TMPDIR/bin9" cli
    mkdir -p "$proj"
    local plain
    plain=$'Note: orchestration features are documented separately.\nbeads (aaaa1111)\n    Bead tracking and issue management.'
    cli="$(stub_orca_json "$bindir" "UNSUPPORTED" "$plain")"
    run orca_skills_step "$proj" "$cli"
    [ -f "$bindir/install.log" ]
    grep -q -- "--skill orchestration" "$bindir/install.log"
}

@test "case 10: --json unsupported; plain has no orchestration selector but a flush-left WARNING line mentions it -> MUST INSTALL" {
    local proj="$BATS_TEST_TMPDIR/proj10" bindir="$BATS_TEST_TMPDIR/bin10" cli
    mkdir -p "$proj"
    local plain
    plain=$'warning: orchestration index stale\nbeads (aaaa1111)\n    Bead tracking and issue management.'
    cli="$(stub_orca_json "$bindir" "UNSUPPORTED" "$plain")"
    run orca_skills_step "$proj" "$cli"
    [ -f "$bindir/install.log" ]
    grep -q -- "--skill orchestration" "$bindir/install.log"
}

@test "case 11: --json exits 0 but prints non-JSON garbage; nothing indicates orchestration is installed -> MUST INSTALL" {
    local proj="$BATS_TEST_TMPDIR/proj11" bindir="$BATS_TEST_TMPDIR/bin11" cli
    mkdir -p "$proj"
    local plain
    plain=$'beads (aaaa1111)\n    Bead tracking and issue management.'
    cli="$(stub_orca_json "$bindir" "not json at all, just some plain text {[" "$plain")"
    run orca_skills_step "$proj" "$cli"
    [ -f "$bindir/install.log" ]
    grep -q -- "--skill orchestration" "$bindir/install.log"
}

@test "case 12: --json exits 0 with VALID JSON listing orchestration installed, plain does not mention it at all -> MUST NOT INSTALL (json authoritative, positive)" {
    local proj="$BATS_TEST_TMPDIR/proj12" bindir="$BATS_TEST_TMPDIR/bin12" cli
    mkdir -p "$proj"
    local json='{"result":{"skills":[{"name":"beads"},{"name":"orchestration"}]}}'
    local plain
    plain=$'beads (aaaa1111)\n    Bead tracking and issue management.'
    cli="$(stub_orca_json "$bindir" "$json" "$plain")"
    run orca_skills_step "$proj" "$cli"
    [ ! -e "$bindir/install.log" ]
}

@test "case 13: --json exits 0 with VALID JSON that does NOT list orchestration, plain has a flush-left line mentioning it -> MUST INSTALL (json authoritative, negative; fallback never overrules it)" {
    local proj="$BATS_TEST_TMPDIR/proj13" bindir="$BATS_TEST_TMPDIR/bin13" cli
    mkdir -p "$proj"
    local json='{"result":{"skills":[{"name":"beads"}]}}'
    local plain
    plain=$'orchestration diagnostic: skill index rebuilding, not yet installed.\nbeads (aaaa1111)\n    Bead tracking and issue management.'
    cli="$(stub_orca_json "$bindir" "$json" "$plain")"
    run orca_skills_step "$proj" "$cli"
    [ -f "$bindir/install.log" ]
    grep -q -- "--skill orchestration" "$bindir/install.log"
}

# ---------------------------------------------------------------------
# claude-orca-8v9: cases 14-17. The loose "flush-left line of bare
# space-separated tokens" branch that satisfied ndy's now-corrected case 2
# is indistinguishable from ordinary unpunctuated English prose mentioning
# "orchestration" -- these are the probes that branch always failed.
# Every assertion here is on CAPTURED ARGV (was `skills install` actually
# invoked?), never on exit code alone.
# ---------------------------------------------------------------------

@test "case 14: plain fallback, flush-left UNPUNCTUATED prose 'pairs with the orchestration skill' -> MUST INSTALL" {
    local proj="$BATS_TEST_TMPDIR/proj14" bindir="$BATS_TEST_TMPDIR/bin14" cli
    mkdir -p "$proj"
    local plain
    plain=$'pairs with the orchestration skill\nbeads (aaaa1111)\n    Bead tracking and issue management.'
    cli="$(stub_orca_json "$bindir" "UNSUPPORTED" "$plain")"
    run orca_skills_step "$proj" "$cli"
    [ -f "$bindir/install.log" ]
    grep -q -- "--skill orchestration" "$bindir/install.log"
}

@test "case 15: plain fallback, flush-left 'requires the orchestration skill present' -> MUST INSTALL" {
    local proj="$BATS_TEST_TMPDIR/proj15" bindir="$BATS_TEST_TMPDIR/bin15" cli
    mkdir -p "$proj"
    local plain
    plain=$'requires the orchestration skill present\nbeads (aaaa1111)\n    Bead tracking and issue management.'
    cli="$(stub_orca_json "$bindir" "UNSUPPORTED" "$plain")"
    run orca_skills_step "$proj" "$cli"
    [ -f "$bindir/install.log" ]
    grep -q -- "--skill orchestration" "$bindir/install.log"
}

@test "case 16: plain fallback, a line that is exactly 'orchestration' with no paren and nothing else -> MUST INSTALL (not a selector line)" {
    local proj="$BATS_TEST_TMPDIR/proj16" bindir="$BATS_TEST_TMPDIR/bin16" cli
    mkdir -p "$proj"
    local plain
    plain=$'orchestration\nbeads (aaaa1111)\n    Bead tracking and issue management.'
    cli="$(stub_orca_json "$bindir" "UNSUPPORTED" "$plain")"
    run orca_skills_step "$proj" "$cli"
    [ -f "$bindir/install.log" ]
    grep -q -- "--skill orchestration" "$bindir/install.log"
}

@test "case 17: plain fallback, 'orchestration index stale' flush-left, no paren -> MUST INSTALL" {
    local proj="$BATS_TEST_TMPDIR/proj17" bindir="$BATS_TEST_TMPDIR/bin17" cli
    mkdir -p "$proj"
    local plain
    plain=$'orchestration index stale\nbeads (aaaa1111)\n    Bead tracking and issue management.'
    cli="$(stub_orca_json "$bindir" "UNSUPPORTED" "$plain")"
    run orca_skills_step "$proj" "$cli"
    [ -f "$bindir/install.log" ]
    grep -q -- "--skill orchestration" "$bindir/install.log"
}

@test "case 18: plain fallback, flush-left PROSE 'orchestration (see docs)' -- parenthesised but not a hash -> MUST INSTALL" {
    local proj="$BATS_TEST_TMPDIR/proj18" bindir="$BATS_TEST_TMPDIR/bin18" cli
    mkdir -p "$proj"
    # A paren alone never proved selector-ness: an Orca notice, a changelog
    # line or a '(deprecated)' banner can start with the skill name and
    # parenthesise the next word. Only the hex id a real entry carries does
    # (claude-orca-clw, from claude-orca-8v9's verifier probe 5).
    local plain
    plain=$'orchestration (see docs)\nbeads (aaaa1111)\n    Bead tracking and issue management.'
    cli="$(stub_orca_json "$bindir" "UNSUPPORTED" "$plain")"
    run orca_skills_step "$proj" "$cli"
    [ -f "$bindir/install.log" ]
    grep -q -- "--skill orchestration" "$bindir/install.log"
}
