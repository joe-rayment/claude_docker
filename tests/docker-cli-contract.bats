#!/usr/bin/env bats
#
# The launcher's docker argv, checked against the REAL docker CLI.
#
# Every other suite drives a `docker` stub, and a stub accepts anything: an
# invented flag (`--dns-server`), a misspelled one (`--voluem`) or a flag
# that belongs to a different subcommand all pass a stub and fail on a Mac.
# This file closes that gap without needing a daemon or a container: the
# launcher builds its own argv (container_create's `set --`, container_dns's
# --dns), mirrors it into <project>/.claude-dev/run/container.log, and the
# real `docker <subcommand> --help` is then asked whether each flag exists.
#
# What this does NOT do: start anything. `--help` is a pure CLI parse, so
# this runs on a box with no daemon at all. Actually starting a container
# is the one surface this repo cannot exercise anywhere (no CAP_SYS_ADMIN),
# and it is CI's job, not this file's.

load helpers/setup

# The real binary, not the stub setup() puts first on PATH.
real_docker() {
    PATH="$ORIGINAL_PATH" command docker "$@"
}

# Skips the whole test (rather than failing it) when the box has no docker
# CLI -- the suite still has to run on a machine that never installed one.
need_real_docker() {
    PATH="$ORIGINAL_PATH" command -v docker >/dev/null 2>&1 \
        || skip "no real docker CLI on this box"
}

# The launcher's own mirror of the argv it executed, one line per ctr()
# call: "<runtime> <argv...>". $1 is the subcommand.
launcher_argv() {
    grep "^docker $1 " "$2/.claude-dev/run/container.log" | tail -1
}

# Every long flag in an argv line, one per line, de-duplicated and with any
# =value suffix removed.
long_flags() {
    local word
    for word in $1; do
        case "$word" in
            --*) printf '%s\n' "${word%%=*}" ;;
        esac
    done | sort -u
}

# Does `docker <subcommand> --help` list this flag? The help lines read
# "      --cpus decimal" or "  -v, --volume list", so the flag has to be
# followed by whitespace, a comma or end-of-line -- otherwise --volume
# would be "found" by the --volume-driver line.
docker_help_has_flag() {
    real_docker $1 --help 2>&1 | grep -qE "(^|[[:space:]])$2([[:space:]]|,|\$)"
}

# A registered project whose config carries every optional knob, so the
# captured argv exercises the conditional flags (--dns, --cpus, --memory,
# the read-only extra mount) as well as the unconditional ones.
project_with_all_knobs() {
    local dir="$1" extra="$BATS_TEST_TMPDIR/extra-mount" name
    mkdir -p "$dir" "$extra"
    make_project "$dir"
    jq --arg m "$extra" \
        '.cpus = 4 | .memory = "8g" | .dns = "1.1.1.1" | .extraMounts = [$m]' \
        "$dir/.claude-dev/claude-orca.json" > "$dir/.claude-dev/orca.tmp"
    mv "$dir/.claude-dev/orca.tmp" "$dir/.claude-dev/claude-orca.json"
    # Forget the container the bootstrap already started, so `open` takes
    # the container_create path again and builds a fresh argv.
    name="claude-orca-$(basename "$dir")"
    rm -f "$CONTAINER_STUB_STATE/containers/$name"
    : > "$dir/.claude-dev/run/container.log"
    (cd "$dir" && ./claude-dev open >/dev/null 2>&1)
}

@test "every long flag the launcher puts in its 'docker run' argv exists in the real docker CLI" {
    need_real_docker

    local primary line flag missing=""
    primary="$(abspath "$PROJECT_DIR")"
    project_with_all_knobs "$primary"

    line="$(launcher_argv run "$primary")"
    [ -n "$line" ]

    # The conditional flags really are in the captured argv -- otherwise
    # this test would be quietly checking only the unconditional four.
    [[ "$line" == *" --dns "* ]]
    [[ "$line" == *" --cpus "* ]]
    [[ "$line" == *" --memory "* ]]

    for flag in $(long_flags "$line"); do
        docker_help_has_flag run "$flag" || missing="$missing $flag"
    done
    [ -z "$missing" ] || {
        echo "docker run does not accept:$missing"
        echo "argv was: $line"
        false
    }
}

@test "the flags the launcher uses on docker's other subcommands exist in the real CLI" {
    need_real_docker

    docker_help_has_flag inspect --format
    docker_help_has_flag login --password-stdin
    docker_help_has_flag login --username
    docker_help_has_flag exec --workdir
    docker_help_has_flag logs --follow

    # `docker image inspect` is a real subcommand pair, not just `inspect`.
    run real_docker image inspect --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"docker image inspect"* ]]
}

@test "the launcher's 'docker inspect -f {{.State.Status}}' template parses in the real CLI" {
    need_real_docker

    # A missing container and a broken template are different failures, and
    # only the second one is this repo's bug. Both exit nonzero, so the exit
    # status alone proves nothing -- the message is what tells them apart.
    run real_docker inspect -f '{{.State.Status}}' claude-orca-no-such-container-9d2f
    [ "$status" -ne 0 ]
    [[ "$output" != *"template parsing error"* ]]
    [[ "$output" != *"template: "* ]]
    case "$output" in
        *"annot connect to the Docker daemon"*|*"docker daemon is not running"*)
            skip "no docker daemon reachable: template parse could not be separated from lookup" ;;
    esac
    [[ "$output" == *"o such object"* ]] || [[ "$output" == *"o such container"* ]]

    # ...and the control: a genuinely broken template fails differently, so
    # the assertion above is discriminating and not just "it failed".
    run real_docker inspect -f '{{.State.Status' claude-orca-no-such-container-9d2f
    [ "$status" -ne 0 ]
    [[ "$output" == *"template"* ]]
}
