#!/usr/bin/env bats
#
# 75-orca-skills -- restores claude-orca-riu.3's already-decided default
# (native Orca orchestration on by default for every registered folder)
# through the mechanism that replaced riu.3's Mac-side sandbox.json/socket
# path once the 8uo epic moved Orca inside the same container as the agent
# (claude-orca-ndy).
#
# claude-orca-qxc: the install is at HOME scope, never --local. HOME inside
# the container is <project>/.claude-dev/home and belongs to this one
# folder, so home scope IS folder scope now -- and it is the only scope
# Orca's Settings > Orchestration panel and its per-agent coverage rows
# count (measured 2026-09-19: a --local install left the panel reading
# 'Not installed' with every agent 'Missing'). The idempotency check asks
# `skills installed --json` for an entry named exactly "orchestration" with
# sourceKind "home" and a "claude" provider (the ~/.claude/skills link);
# anything else -- no such entry, a repo-scope entry, a home entry without
# the claude provider, non-JSON output, an unsupported --json, jq missing --
# falls through to the install, which is itself idempotent. There is no
# plain-text fallback: `skills installed` prose cannot tell home from repo
# scope.
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

# stub_orca_json <dir> <json-body|UNSUPPORTED> [install-exit]
#
# A stub `orca` that answers `skills installed --json` with the given body
# (exit 0), or -- when the body is the literal string UNSUPPORTED -- prints
# "unknown flag: --json" to stderr and exits 2, the way an Orca predating
# the flag would. Every invocation's environment is dumped to <dir>/env.log
# (last call wins), and `skills install` logs its full argv to
# <dir>/install.log and exits with the given code. Anything else exits 1.
stub_orca_json() {
    local dir="$1" json="$2" install_exit="${3:-0}"
    mkdir -p "$dir"
    if [ "$json" = "UNSUPPORTED" ]; then
        : > "$dir/installed.json.unsupported"
    else
        printf '%s\n' "$json" > "$dir/installed.json"
    fi
    cat > "$dir/orca" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "skills" ] && [ "\$2" = "installed" ]; then
    env > "$dir/env.log"
    if [ -f "$dir/installed.json.unsupported" ]; then
        echo "unknown flag: --json" >&2
        exit 2
    fi
    cat "$dir/installed.json"
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

@test "orchestration absent from 'skills installed --json' -> the step installs it with --skill orchestration" {
    # Guards: a fresh folder gets the orchestration skill, by the exact
    # install argv the step has always used minus --local.
    # Fails if: the install is skipped, or carries --local, or drops
    # --skill orchestration.
    # Run: bats -f 'the step installs it with' tests/provision-orca-skills.bats
    local proj="$BATS_TEST_TMPDIR/proj1" bindir="$BATS_TEST_TMPDIR/bin1" cli
    mkdir -p "$proj"
    cli="$(stub_orca_json "$bindir" '{"result":{"skills":[{"name":"beads"}]}}')"
    run orca_skills_step "$proj" "$cli"
    [ "$status" -eq 0 ]
    [ "$(cat "$bindir/install.log")" = "skills install --skill orchestration" ]
}

@test "a repo-scope orchestration entry does not satisfy the home-scope check -> MUST INSTALL" {
    # Guards: the whole point of claude-orca-qxc -- a --local install's
    # entry (sourceKind "repo", providers agent-skills+claude) is exactly
    # what Orca's Settings panel ignores, so it must not read as installed.
    # Fails if: the check matches on name alone and wrongly skips.
    # Run: bats -f 'repo-scope orchestration entry' tests/provision-orca-skills.bats
    local proj="$BATS_TEST_TMPDIR/proj2" bindir="$BATS_TEST_TMPDIR/bin2" cli
    mkdir -p "$proj"
    local json
    json='{"result":{"skills":[{"name":"orchestration","sourceKind":"repo","providers":["agent-skills","claude"]}]}}'
    cli="$(stub_orca_json "$bindir" "$json")"
    run orca_skills_step "$proj" "$cli"
    [ "$status" -eq 0 ]
    [ "$(cat "$bindir/install.log")" = "skills install --skill orchestration" ]
}

@test "a home entry without a claude provider (agent-skills only) -> MUST INSTALL" {
    # Guards: the measured state of /workspace/claude-orca on 2026-10-02 --
    # ~/.agents/skills/orchestration present (sourceKind home, providers
    # [agent-skills]) but the ~/.claude/skills link wiped by config-sync.
    # Orca's panel counts the claude provider, so neither the home check
    # nor the provider check may be dropped.
    # Fails if: sourceKind alone (without the claude provider) reads as
    # installed and the step skips.
    # Run: bats -f 'without a claude provider' tests/provision-orca-skills.bats
    local proj="$BATS_TEST_TMPDIR/proj3" bindir="$BATS_TEST_TMPDIR/bin3" cli
    mkdir -p "$proj"
    local json
    json='{"result":{"skills":[{"name":"orchestration","sourceKind":"home","providers":["agent-skills"]}]}}'
    cli="$(stub_orca_json "$bindir" "$json")"
    run orca_skills_step "$proj" "$cli"
    [ "$status" -eq 0 ]
    [ "$(cat "$bindir/install.log")" = "skills install --skill orchestration" ]
}

@test "a home entry with a claude provider -> nothing to do, install never invoked" {
    # Guards: idempotence at the scope that counts -- after a real
    # home-scope install (~/.agents/skills/orchestration plus the
    # ~/.claude/skills link) the second boot must not reinstall.
    # Fails if: the check never says yes and every boot pays one network
    # call.
    # Run: bats -f 'with a claude provider' tests/provision-orca-skills.bats
    local proj="$BATS_TEST_TMPDIR/proj4" bindir="$BATS_TEST_TMPDIR/bin4" cli
    mkdir -p "$proj"
    local json
    json='{"result":{"skills":[{"name":"orchestration","sourceKind":"home","providers":["agent-skills","claude"]}]}}'
    cli="$(stub_orca_json "$bindir" "$json")"
    run orca_skills_step "$proj" "$cli"
    [ "$status" -eq 0 ]
    [ ! -e "$bindir/install.log" ]
    printf '%s\n' "$output" | grep -q "already installed"
    printf '%s\n' "$output" | grep -q "nothing to do"
}

@test "--json exits 0 but prints non-JSON garbage -> MUST INSTALL (idempotent fall-through)" {
    # Guards: a zero exit carrying garbage is no confident answer; the
    # step attempts the install rather than skipping the whole feature.
    # Fails if: garbage is read as "installed" and the step skips.
    # Run: bats -f 'non-JSON garbage' tests/provision-orca-skills.bats
    local proj="$BATS_TEST_TMPDIR/proj5" bindir="$BATS_TEST_TMPDIR/bin5" cli
    mkdir -p "$proj"
    cli="$(stub_orca_json "$bindir" "not json at all, just some plain text {[")"
    run orca_skills_step "$proj" "$cli"
    [ "$status" -eq 0 ]
    [ "$(cat "$bindir/install.log")" = "skills install --skill orchestration" ]
}

@test "--json unsupported by an older Orca -> MUST INSTALL (idempotent fall-through)" {
    # Guards: an Orca predating `skills installed --json` still gets the
    # skill -- the install is idempotent, so an attempt is always safe.
    # Fails if: the unsupported flag reads as "installed" and the step
    # skips forever with a green status row.
    # Run: bats -f 'unsupported by an older Orca' tests/provision-orca-skills.bats
    local proj="$BATS_TEST_TMPDIR/proj6" bindir="$BATS_TEST_TMPDIR/bin6" cli
    mkdir -p "$proj"
    cli="$(stub_orca_json "$bindir" "UNSUPPORTED")"
    run orca_skills_step "$proj" "$cli"
    [ "$status" -eq 0 ]
    [ "$(cat "$bindir/install.log")" = "skills install --skill orchestration" ]
}

@test "a failing install is not swallowed: the step's own exit is non-zero" {
    # Guards: provision-run.sh's no-step-is-fatal contract relies on the
    # step reporting its own failure so `provision status` surfaces it.
    # Fails if: an install failure is turned into exit 0.
    # Run: bats -f "not swallowed" tests/provision-orca-skills.bats
    local proj="$BATS_TEST_TMPDIR/proj7" bindir="$BATS_TEST_TMPDIR/bin7" cli
    mkdir -p "$proj"
    cli="$(stub_orca_json "$bindir" '{"result":{"skills":[{"name":"beads"}]}}' 1)"
    run orca_skills_step "$proj" "$cli"
    [ "$status" -ne 0 ]
    [ -f "$bindir/install.log" ]
}

@test "the install call never omits the home scope: argv is exactly 'skills install --skill orchestration', no --local" {
    # Guards: no --local (claude-orca-qxc -- the panel does not count a
    # repo-scope install) and nothing else creeping into the argv.
    # Fails if: --local returns, or any other flag is added silently.
    # Run: bats -f 'never omits the home scope' tests/provision-orca-skills.bats
    local proj bindir cli
    proj="$BATS_TEST_TMPDIR/proj8a" bindir="$BATS_TEST_TMPDIR/bin8a"
    mkdir -p "$proj"
    cli="$(stub_orca_json "$bindir" '{"result":{"skills":[{"name":"beads"}]}}')"
    run orca_skills_step "$proj" "$cli"
    [ -f "$bindir/install.log" ]
    [ "$(cat "$bindir/install.log")" = "skills install --skill orchestration" ]

    proj="$BATS_TEST_TMPDIR/proj8b" bindir="$BATS_TEST_TMPDIR/bin8b"
    mkdir -p "$proj"
    cli="$(stub_orca_json "$bindir" "UNSUPPORTED")"
    run orca_skills_step "$proj" "$cli"
    [ -f "$bindir/install.log" ]
    [ "$(cat "$bindir/install.log")" = "skills install --skill orchestration" ]
}

@test "every CLI call learns this container's Orca: ORCA_USER_DATA_PATH is exported at \$HOME/.config/orca" {
    # Guards: without ORCA_USER_DATA_PATH the CLI asks whichever Orca its
    # own default user-data dir points at, not the one this entrypoint
    # started (the same contract 60-orca-repo-add carries).
    # Fails if: the export is dropped or points anywhere but the agent
    # home's .config/orca.
    # Run: bats -f 'ORCA_USER_DATA_PATH is exported' tests/provision-orca-skills.bats
    local proj="$BATS_TEST_TMPDIR/proj9" bindir="$BATS_TEST_TMPDIR/bin9" cli
    mkdir -p "$proj"
    cli="$(stub_orca_json "$bindir" '{"result":{"skills":[{"name":"beads"}]}}')"
    run orca_skills_step "$proj" "$cli"
    [ "$status" -eq 0 ]
    grep -q "^ORCA_USER_DATA_PATH=$BATS_TEST_TMPDIR/home/.config/orca$" "$bindir/env.log"
}

@test "no Orca CLI resolvable -> the step skips cleanly with exit 0" {
    # Guards: a folder whose image lost Orca still boots -- the step says
    # so on stderr and exits 0, it never fails the boot.
    # Fails if: a missing CLI is turned into a provision failure.
    # Run: bats -f 'skips cleanly with exit 0' tests/provision-orca-skills.bats
    local proj="$BATS_TEST_TMPDIR/proj10"
    mkdir -p "$proj"
    # No ORCA_CLI, an ORCA_BIN with no resources/bin beside it, a scratch
    # HOME with no .local/bin, and a PATH with no orca on it (this
    # container's /usr/bin carries an orca-ide shim, so PATH cannot be a
    # normal value here).
    run env -i PATH="/nonexistent" HOME="$BATS_TEST_TMPDIR/home" \
        PROJECT_DIR="$proj" ORCA_BIN="$BATS_TEST_TMPDIR/no-such-orca" \
        /bin/bash "$STEP"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q "no Orca CLI found"
}
