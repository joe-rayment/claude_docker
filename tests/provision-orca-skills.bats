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
