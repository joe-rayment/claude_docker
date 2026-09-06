#!/usr/bin/env bats
#
# Acceptance contract for claude-orca-qa2.3 -- FROZEN from RED-AT onward.
#
# v3 replaces the Seatbelt/srt design wholesale (.claude/plans/container-v3.md
# S6): the sandbox is the container VM, so nothing on the Mac generates a
# Seatbelt profile, installs srt or a DMG, runs a self-test, or writes a block
# into the user's shell rc. Two designs in one tree is how the next blind fix
# happens -- this case is the gate that says only one of them is left.

load helpers/setup

# Where the v2 half used to live. Absent, not merely unreferenced: a file
# nothing calls is still a file the next reader has to rule out.
@test "no v2 sandbox scripts, installs or rc hook remain and the README quick start names the container flow" {
    [ ! -e "$REPO_ROOT/scripts/sandbox" ]
    [ ! -e "$REPO_ROOT/scripts/install-srt.sh" ]
    [ ! -e "$REPO_ROOT/scripts/install-orca.sh" ]
    [ ! -e "$REPO_ROOT/scripts/setup-menu.sh" ]

    # No token of the old design anywhere the Mac side or the docs can reach.
    # (.claude/plans/orca-port.md is history and deliberately out of scope.)
    cd "$REPO_ROOT"
    run grep -rlE 'sandbox-exec|\bsrt\b|Seatbelt|selftest|orca-launch|setup-menu' \
        scripts bootstrap.sh README.md CLAUDE.md AGENTS.md
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    # The launcher dispatches only v3 verbs: no shell-rc install, no v1
    # removal, no uninstall, no guided walk-through.
    launcher="$REPO_ROOT/scripts/launcher.sh"
    run grep -nE '^[[:space:]]*(rc-install|rc-uninstall|setup|--uninstall|--remove-v1)\)' "$launcher"
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    # And the README's quick start is the container one.
    readme="$REPO_ROOT/README.md"
    grep -qF -- 'container system start' "$readme"
    grep -qF -- 'claude-orca.json' "$readme"
    run grep -qF -- 'Orca.app' "$readme"
    [ "$status" -ne 0 ]
}
