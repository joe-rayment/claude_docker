#!/usr/bin/env bats
#
# What the seeded orca-data.json carries for delegated workers.
# (The V4 cases that checked config-sync preserving Orca's hook entries went
# with that preservation, claude-orca-9bh.13; claude-orca-qa2.3 retired the
# transcriptSymlink case earlier.)

load helpers/setup

SEED() {
    "$REPO_ROOT/scripts/container/seed-orca-state.sh" "$@"
}

# claude-orca-qa2.11: orca-data.json also carries what a delegated worker
# terminal needs (.claude/plans/orca-orchestration.md, Container side) --
# where opencode finds its provider config inside the VM, the argv each
# agent id is launched with (the VM is the boundary, so Claude Code needs
# no permission prompts and opencode auto-approves), and two levels of
# nesting: an orchestrator may dispatch an epic coordinator that runs
# orca-run over its own executors; those executors do not delegate.
@test "seed-orca-state sets agentDefaultEnv.opencode.OPENCODE_CONFIG, agentDefaultArgs for claude and opencode, and nestedWorkerMaxDepth" {
    udd="$BATS_TEST_TMPDIR/udd"
    proj="$BATS_TEST_TMPDIR/seedproj"
    mkdir -p "$udd" "$proj"
    data="$udd/profiles/local-default/orca-data.json"

    run SEED --user-data-dir "$udd" --project "$proj"
    [ "$status" -eq 0 ]
    [ -f "$data" ]
    run jq -e . "$data"
    [ "$status" -eq 0 ]

    # The path is the one INSIDE the VM, where .claude-dev/home is mounted
    # as /home/agent -- not wherever the seed happened to run.
    [ "$(jq -r '.settings.agentDefaultEnv.opencode.OPENCODE_CONFIG' "$data")" \
        = "/home/agent/.config/opencode/opencode.json" ]
    [ "$(jq -r '.settings.agentDefaultArgs.claude' "$data")" \
        = "--dangerously-skip-permissions" ]
    [ "$(jq -r '.settings.agentDefaultArgs.opencode' "$data")" = "--auto" ]
    [ "$(jq -r '.settings.nestedWorkerMaxDepth' "$data")" = "2" ]

    # Nothing the earlier seed contract pinned is displaced by them.
    [ "$(jq -r '.settings.agentDefaultEnv.claude.CLAUDE_ORCA_ROOT' "$data")" = "$proj" ]
    [ "$(jq -r '.settings.theme' "$data")" = "dark" ]
    [ "$(jq -r '.repos[0].path' "$data")" = "$proj" ]
    [ "$(jq -r '.repos[0].worktreeBasePath' "$data")" = "$proj/.orca-worktrees" ]

    # And it is still the file's existence that makes this a one-shot: a
    # folder Orca has already opened keeps whatever the user changed.
    printf '%s' '{"settings":{"theme":"light"}}' > "$data"
    before="$(md5sum < "$data")"
    run SEED --user-data-dir "$udd" --project "$proj"
    [ "$status" -eq 0 ]
    [ "$(md5sum < "$data")" = "$before" ]
    [[ "$output" == *"not seeded"* ]]
}
