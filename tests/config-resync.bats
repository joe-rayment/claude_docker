#!/usr/bin/env bats
#
# The host side asks for the config sync itself, from the folder's own
# template clone, every time a container comes up.
#
# The hole this closes, found 2026-09-08: the entrypoint is what syncs a
# folder's ~/.claude, and the entrypoint change that makes the folder's
# clone beat the image's frozen config/ ships inside the image. A folder
# on an older image therefore syncs BACKWARDS, silently -- and the pull
# that was supposed to refresh that image came back 403 while
# run/image-source still said "pulled". Two committed, user-visible
# changes (green terminal text, /tier's GLM help) were in the folder's
# clone and not in ~/.claude, twice in one day.
#
# So registration -- which is what bootstrap ends in -- and `--update`
# both re-run config-sync over `docker exec` from
# <project>/.claude-dev/template, the copy no image can make stale. Both
# go through cmd_open_v3, so the assertions below drive the two entry
# points the user actually types.

load helpers/setup

# Every `docker exec` line the launcher issued for the config sync.
resync_lines() {
    grep '^exec ' "$CONTAINER_STUB_LOG" 2>/dev/null | grep 'config-sync\.sh' || true
}

@test "registration re-syncs config from the folder's own template clone, not the image's" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    run resync_lines
    [ -n "$output" ]
    # The folder's clone, addressed by its GUEST path -- never the image's
    # /opt/claude-orca copy, which is the whole point.
    [[ "$output" == *"/workspace/"*"/.claude-dev/template/scripts/config-sync.sh"* ]]
    [[ "$output" != *"/opt/claude-orca/"* ]]
}

@test "the re-sync names the project and host by their guest paths" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    run resync_lines
    [ "$status" -eq 0 ]
    [[ "$output" == *"--project /workspace/"* ]]
    [[ "$output" == *"--host /workspace/"*"/.claude-dev"* ]]
    # A Mac path inside the container would resolve to nothing, and would
    # bake /Users into every hook command config-sync renders.
    [[ "$output" != *"--project /Users/"* ]]
    [[ "$output" != *"--host /Users/"* ]]
}

@test "the re-sync runs as the agent user, never as root" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    run resync_lines
    # The entrypoint re-maps agent to HOST_UID, so the NAME is the only
    # stable spelling; a root exec would leave a home the agent cannot
    # rewrite.
    [[ "$output" == *"-u agent"* ]]
}

@test "update re-syncs config as well as rebuilding the image" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]
    [[ "$output" == *"config:"* ]]

    run resync_lines
    [ -n "$output" ]
    [[ "$output" == *"/.claude-dev/template/scripts/config-sync.sh"* ]]
}

@test "a re-sync that cannot run warns and does not fail the open" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    export CLAUDE_ORCA_TEST_RESYNC_FAIL=1
    run bash -c "cd '$primary' && ./claude-dev --update"
    # A folder that is up and serving is not worth failing over a config
    # refresh.
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not re-sync from the folder's template"* ]]
}

@test "the re-sync says whether the config moved" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    # The stub exec does not run the real config-sync, so run/config-hash
    # does not move: the "already current" half of the report.
    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]
    [[ "$output" == *"config: already current"* ]]
}
