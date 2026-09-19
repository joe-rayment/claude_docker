#!/usr/bin/env bats
#
# setup.sh --check's agent-user row has to want the uid a RUNNING container
# shows. The image creates agent at 1000; on a Mac the launcher passes
# HOST_UID and the entrypoint re-maps agent to it (usermod -u), so that the
# bind mounts stay the owner's. A check that still wants 1000 fails every
# Mac folder on its first prompt -- seen 2026-09-19 on a real rebuilt
# container: "[check] FAIL  agent user: want uid 1000, got 501".
#
# The row reads the box, so the cases follow the box's own agent user and
# skip where there is none.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SETUP="$REPO_ROOT/scripts/container/setup.sh"

setup() {
    AGENT_UID_HERE="$(id -u agent 2>/dev/null || true)"
    [ -n "$AGENT_UID_HERE" ] || skip "this box has no agent user"
}

@test "--check wants the agent user at HOST_UID when the launcher passed one" {
    run env HOST_UID="$AGENT_UID_HERE" bash "$SETUP" --check
    [[ "$output" == *"[check] ok    agent user at uid ${AGENT_UID_HERE}"* ]]
    [[ "$output" != *"FAIL  agent user"* ]]
}

@test "--check FAILs the row, naming both uids, when agent is not at HOST_UID" {
    local other=$((AGENT_UID_HERE + 1))
    run env HOST_UID="$other" bash "$SETUP" --check
    [ "$status" -ne 0 ]
    [[ "$output" == *"[check] FAIL  agent user: want uid ${other}, got ${AGENT_UID_HERE}"* ]]
}

@test "--check without HOST_UID still wants the image's uid 1000" {
    run env -u HOST_UID bash "$SETUP" --check
    if [ "$AGENT_UID_HERE" = "1000" ]; then
        [[ "$output" == *"[check] ok    agent user at uid 1000"* ]]
    else
        [[ "$output" == *"[check] FAIL  agent user: want uid 1000, got ${AGENT_UID_HERE}"* ]]
    fi
}
