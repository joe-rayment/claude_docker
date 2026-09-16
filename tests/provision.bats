#!/usr/bin/env bats
#
# S4 acceptance contract (claude-orca-dbu.4) -- FROZEN from RED-AT onward.
#
# Everything that is about THIS FOLDER rather than about the image comes out
# of the blocking path and becomes a numbered, idempotent step under
# scripts/container/provision.d/, run by scripts/container/provision-run.sh
# after `orca-ide --serve` has published its URL.
#
# The ordering constraint that made this necessary: the steps a folder needs
# are exactly the steps most likely to fail (a network hiccup, a half-written
# config, a bad token), and they were all in front of the thing that could
# have reported them. So the contract is about ordering and blast radius,
# not about what any one step does:
#
#   * every file in provision.d runs twice in a row with the same final
#     status -- idempotence, asserted per step, because a folder is started
#     many times and the second start re-runs everything the first one did;
#   * a step that exits non-zero leaves its status file non-zero and does not
#     stop later steps or the Orca process;
#   * the web URL is written BEFORE the first step runs.
#
# This box cannot run containers, so the entrypoint is exercised NATIVELY
# with a stub Orca that speaks serve's URL line, exactly as
# tests/container-entrypoint.bats does.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRYPOINT="$REPO_ROOT/scripts/container/entrypoint.sh"
PROVISION_RUN="$REPO_ROOT/scripts/container/provision-run.sh"
PROVISION_D="$REPO_ROOT/scripts/container/provision.d"
CONFIG_SYNC="$REPO_ROOT/scripts/config-sync.sh"

# Orca's Electron runtime binds unix sockets under the user-data-dir and
# AF_UNIX paths cap at ~108 bytes, so every fixture lives under a short
# /tmp prefix (see tests/container-entrypoint.bats).
short_tmpdir() {
    mktemp -d /tmp/co-pv-XXXXXX
}

free_port() {
    python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

make_project() {
    local dir="$1"
    mkdir -p "$dir/.claude-dev/run" "$dir/.claude-dev/home"
    git init --quiet -b main "$dir" >/dev/null 2>&1
    git -C "$dir" -c user.email=test@example.com -c user.name=test \
        commit --quiet --allow-empty -m init >/dev/null 2>&1
}

# A stub Orca that records its own pid, speaks serve's URL line and stays
# up. That pid is what "does not stop the Orca process" is asserted against.
write_serving_orca() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'STUB'
#!/usr/bin/env bash
echo $$ > "$TMP/orca.pid"
port=""
prev=""
for arg in "$@"; do
    [ "$prev" = "--port" ] && port="$arg"
    prev="$arg"
done
echo "Web client URL: http://127.0.0.1:${port}/web-index.html#pairing=x"
exec sleep 300
STUB
    chmod +x "$path"
}

start_entrypoint_bg() {
    setsid bash -c 'echo $$ > "$EP_PGID_FILE"; exec bash "$EP_SCRIPT"' \
        >"$TMP/entrypoint.out" 2>&1 &
    local i=0
    while [ "$i" -lt 50 ]; do
        [ -s "$TMP/ep.pgid" ] && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

stop_entrypoint() {
    local pgid
    if [ -s "$TMP/ep.pgid" ]; then
        pgid="$(cat "$TMP/ep.pgid")"
        kill -TERM -"$pgid" 2>/dev/null || true
        sleep 1
        kill -KILL -"$pgid" 2>/dev/null || true
    fi
}

wait_for_file() {
    local path="$1" deadline="$2" i=0
    while [ "$i" -lt "$deadline" ]; do
        [ -s "$path" ] && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

dump_entrypoint() {
    echo "--- entrypoint stdout ---" >&2
    cat "$TMP/entrypoint.out" >&2 || true
}

setup() {
    TMP="$(short_tmpdir)"
    export TMP
    export EP_PGID_FILE="$TMP/ep.pgid"
    export EP_SCRIPT="$ENTRYPOINT"
}

teardown() {
    stop_entrypoint
    # Guards a case started by hand (claude-orca-qa2.25) outlive the
    # entrypoint's process group, so they get their own kill -- only the
    # pids this test recorded, never a peer's.
    [ -n "${GUARD_PIDS:-}" ] && kill -KILL $GUARD_PIDS 2>/dev/null
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
    return 0
}

# --- the contract ---------------------------------------------------------

# Everything the real steps need that is NOT the folder: a setup script that
# answers --check, an Orca CLI that answers `repo add`, a template config for
# the sync, and a web-url file, because a step that registers the project
# with a server skips itself when no server has published one.
prepare_real_steps_fixture() {  # prepare_real_steps_fixture <project>
    local proj="$1" tcfg="$1/.claude-dev/template/config"
    make_project "$proj"
    mkdir -p "$TMP/bin" "$TMP/home" "$tcfg/claude-commands"
    printf '{"hooks":{}}\n'        > "$tcfg/claude-settings.json"
    printf 'folder memory\n'       > "$tcfg/claude-user-memory.md"
    printf '#!/bin/sh\necho hi\n'  > "$tcfg/statusline.sh"
    printf 'folder-clone-marker\n' > "$tcfg/claude-commands/marker.md"

    cat > "$TMP/setup.sh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "--check" ] && exit 0
exit 0
STUB
    chmod +x "$TMP/setup.sh"

    cat > "$TMP/bin/orca" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/cli.log"
exit 0
STUB
    chmod +x "$TMP/bin/orca"
    : > "$TMP/cli.log"

    printf 'http://127.0.0.1:1/web-index.html#pairing=x\n' \
        > "$proj/.claude-dev/run/orca-web-url.txt"
}

# One provisioning pass over the REAL provision.d, with nothing of this box
# leaking in: BEADS_DIR belongs to whatever project this suite runs from and
# would point the tracker step somewhere that is not the fixture.
run_real_provision() {  # run_real_provision <project>
    env -u BEADS_DIR HOME="$TMP/home" PROJECT_DIR="$1" \
        ORCA_CLI="$TMP/bin/orca" CLAUDE_ORCA_SETUP="$TMP/setup.sh" \
        CLAUDE_ORCA_PROJECT_NAME=fixture \
        bash "$PROVISION_RUN"
}

@test "every file in provision.d runs twice in a row with the same final status" {
    [ -d "$PROVISION_D" ]
    [ -x "$PROVISION_RUN" ]

    local proj="$TMP/project" pdir step name s1 s2 seen=0
    prepare_real_steps_fixture "$proj"
    pdir="$proj/.claude-dev/run/provision"

    run_real_provision "$proj"
    [ -d "$pdir" ]
    cp -a "$pdir" "$TMP/run1"

    # A folder is started many times: the second start re-runs every step
    # over a folder the first one already provisioned.
    run_real_provision "$proj"

    for step in "$PROVISION_D"/*; do
        name="$(basename "$step")"
        # Numbered, so the order a human reads is the order they run in.
        [[ "$name" == [0-9][0-9]-* ]] || { echo "not numbered: $name" >&3; false; }
        # Accounted for in both passes: a step that silently did not run is
        # a step whose idempotence nothing checked.
        [ -f "$TMP/run1/$name.status" ] || { echo "no first-pass status: $name" >&3; false; }
        [ -f "$pdir/$name.status" ] || { echo "no second-pass status: $name" >&3; false; }
        s1="$(tr -d '[:space:]' < "$TMP/run1/$name.status")"
        s2="$(tr -d '[:space:]' < "$pdir/$name.status")"
        [ "$s1" = "$s2" ] || { echo "$name: run1=$s1 run2=$s2" >&3; false; }
        seen=$((seen + 1))
    done
    [ "$seen" -gt 0 ]
}

# A steps directory of this test's own, so what a broken step does to the
# ones after it can be asserted without breaking a real one.
write_step() {  # write_step <name> <body...>
    local name="$1"; shift
    mkdir -p "$TMP/steps"
    { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$TMP/steps/$name"
    chmod +x "$TMP/steps/$name"
}

# The entrypoint, booted against a stub Orca that serves, with this test's
# own steps directory in place of the real one.
export_provision_test_env() {  # export_provision_test_env <project> <port>
    export HOME="$TMP/home"
    export PROJECT_DIR="$1"
    export ORCA_PORT="$2"
    export ORCA_BIN="$TMP/bin/orca-ide"
    export ORCA_CLI=/bin/true
    export CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    export CLAUDE_ORCA_SKIP_SETUP=1
    export CLAUDE_ORCA_SKIP_BEADS=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT=30
    export CLAUDE_ORCA_PROVISION_STEPS="$TMP/steps"
}

@test "a step that exits non-zero leaves its status file non-zero and does not stop later steps or the Orca process" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" pdir port
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin"
    write_serving_orca "$TMP/bin/orca-ide"
    port="$(free_port)"
    pdir="$proj/.claude-dev/run/provision"

    write_step 10-first 'echo "the first step ran"' 'touch "$TMP/ran.10"'
    write_step 20-boom  'echo "this step is broken" >&2' 'exit 3'
    write_step 30-last  'echo "the last step ran"' 'touch "$TMP/ran.30"'

    export_provision_test_env "$proj" "$port"
    start_entrypoint_bg
    wait_for_file "$proj/.claude-dev/run/orca-web-url.txt" 40 || { dump_entrypoint; false; }
    wait_for_file "$pdir/30-last.status" 40 || { dump_entrypoint; false; }

    # The failure is on disk, readable by a human and by an agent, and it is
    # the step's own exit code rather than a flattened 1.
    [ "$(tr -d '[:space:]' < "$pdir/20-boom.status")" = "3" ]
    grep -qF 'this step is broken' "$pdir/20-boom.log"

    # ... and it stopped nothing. The step after it ran and succeeded.
    [ -f "$TMP/ran.10" ]
    [ -f "$TMP/ran.30" ]
    [ "$(tr -d '[:space:]' < "$pdir/30-last.status")" = "0" ]

    # The Orca process is the one thing a provisioning step must never take
    # with it: this is the process the whole container's life is tied to.
    [ -s "$TMP/orca.pid" ]
    kill -0 "$(cat "$TMP/orca.pid")"
}

@test "the web URL is written BEFORE the first step runs" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" port
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin"
    write_serving_orca "$TMP/bin/orca-ide"
    port="$(free_port)"

    # The probe reads the handshake file the Mac side waits on. Anything
    # other than the published URL means provisioning got in front of the
    # one thing that lets a person open the folder.
    write_step 10-probe \
        'if [ -s "$PROJECT_DIR/.claude-dev/run/orca-web-url.txt" ]; then' \
        '    printf "url:%s\n" "$(cat "$PROJECT_DIR/.claude-dev/run/orca-web-url.txt")" > "$TMP/probe.out"' \
        'else' \
        '    printf "url:MISSING\n" > "$TMP/probe.out"' \
        'fi'

    export_provision_test_env "$proj" "$port"
    start_entrypoint_bg
    wait_for_file "$TMP/probe.out" 40 || { dump_entrypoint; false; }

    run cat "$TMP/probe.out"
    [ "$status" -eq 0 ]
    [ "$output" = "url:http://127.0.0.1:${port}/web-index.html#pairing=x" ]
}

# --- what the steps leave behind for a person to read --------------------

@test "each step writes run/provision/<step>.log and run/provision/<step>.status" {
    [ -x "$PROVISION_RUN" ]

    local proj="$TMP/project" pdir
    make_project "$proj"
    mkdir -p "$TMP/home"
    pdir="$proj/.claude-dev/run/provision"

    write_step 10-talkative \
        'echo "a line on stdout"' \
        'echo "a line on stderr" >&2'

    env HOME="$TMP/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_PROVISION_STEPS="$TMP/steps" bash "$PROVISION_RUN"

    [ -f "$pdir/10-talkative.log" ]
    grep -qF 'a line on stdout' "$pdir/10-talkative.log"
    grep -qF 'a line on stderr' "$pdir/10-talkative.log"
    [ "$(tr -d '[:space:]' < "$pdir/10-talkative.status")" = "0" ]

    # The log is this run's, not every run's: a folder started fifty times
    # must not hand a person fifty copies of the same failure to scroll past.
    env HOME="$TMP/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_PROVISION_STEPS="$TMP/steps" bash "$PROVISION_RUN"
    run grep -c 'a line on stdout' "$pdir/10-talkative.log"
    [ "$output" = "1" ]
}

@test "a folder whose Orca cannot start is still provisioned, right before the die" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" pdir
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/bin"
    pdir="$proj/.claude-dev/run/provision"

    write_step 10-anyway 'echo "provisioned anyway"'

    # No Orca to serve, so no URL will ever be written -- and that is
    # exactly the folder that most needs its config, its seeds and a
    # readable status, because someone has to work out what went wrong.
    run env HOME="$TMP/home" PROJECT_DIR="$proj" \
        ORCA_BIN="$TMP/bin/no-such-orca" CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        CLAUDE_ORCA_PROVISION_STEPS="$TMP/steps" \
        bash "$ENTRYPOINT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ORCA_BIN is not executable"* ]]

    [ "$(tr -d '[:space:]' < "$pdir/10-anyway.status")" = "0" ]
    grep -qF 'provisioned anyway' "$pdir/10-anyway.log"
    [ ! -f "$proj/.claude-dev/run/orca-web-url.txt" ]
}

@test "a step that hangs is bounded by CLAUDE_ORCA_PROVISION_TIMEOUT and the steps after it still run" {
    [ -x "$PROVISION_RUN" ]

    local proj="$TMP/project" pdir
    make_project "$proj"
    mkdir -p "$TMP/home"
    pdir="$proj/.claude-dev/run/provision"

    write_step 10-hang 'sleep 60'
    write_step 20-after 'echo "still got here"'

    env HOME="$TMP/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_PROVISION_STEPS="$TMP/steps" \
        CLAUDE_ORCA_PROVISION_TIMEOUT=2 bash "$PROVISION_RUN"

    [ "$(tr -d '[:space:]' < "$pdir/10-hang.status")" != "0" ]
    [ "$(tr -d '[:space:]' < "$pdir/20-after.status")" = "0" ]
    grep -qF 'still got here' "$pdir/20-after.log"
}

@test "the real OpenRouter key reaches the guard step and no other step" {
    [ -x "$PROVISION_RUN" ]

    local proj="$TMP/project"
    make_project "$proj"
    mkdir -p "$TMP/home"

    write_step 10-plain           'env > "$TMP/env.plain"'
    write_step 60-openrouter-guard 'env > "$TMP/env.guard"'

    env HOME="$TMP/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_PROVISION_STEPS="$TMP/steps" \
        CLAUDE_ORCA_OPENROUTER_REAL_KEY="sk-or-v1-real-secret-never-in-a-step" \
        bash "$PROVISION_RUN"

    # The chokepoint's whole point is that the real key lives in exactly one
    # process. Provisioning must not be the thing that spreads it.
    run grep -c -- 'sk-or-v1-real-secret-never-in-a-step' "$TMP/env.guard"
    [ "$output" = "1" ]
    run grep -c -- 'sk-or-v1-real-secret-never-in-a-step' "$TMP/env.plain"
    [ "$output" = "0" ]
}

@test "config-sync serialises concurrent runs with a flock" {
    [ -x "$CONFIG_SYNC" ]
    command -v flock >/dev/null 2>&1

    local proj="$TMP/project" tcfg lock started ended elapsed
    make_project "$proj"
    tcfg="$proj/.claude-dev/template/config"
    mkdir -p "$tcfg" "$TMP/home"
    printf '{"hooks":{}}\n'       > "$tcfg/claude-settings.json"
    printf 'folder memory\n'      > "$tcfg/claude-user-memory.md"
    printf '#!/bin/sh\necho hi\n' > "$tcfg/statusline.sh"

    # The host side resyncs over `docker exec` after the URL is published,
    # so a provisioning sync and a hand-run one can land at the same moment
    # on the same settings.json. Holding the lock from outside proves the
    # sync waits for it rather than racing it.
    lock="$proj/.claude-dev/run/config-sync.lock"
    mkdir -p "$proj/.claude-dev/run"
    : > "$lock"
    flock "$lock" sleep 4 &

    sleep 0.5
    started="$(date +%s)"
    run env HOME="$TMP/home" bash "$CONFIG_SYNC" --project "$proj" --host "$proj/.claude-dev"
    ended="$(date +%s)"
    [ "$status" -eq 0 ]

    elapsed=$((ended - started))
    [ "$elapsed" -ge 2 ] || { echo "config-sync did not wait for the lock (${elapsed}s)" >&3; false; }

    # It waited, and then it did the work.
    [ -f "$proj/.claude-dev/home/.claude/CLAUDE.md" ]
    wait
}

# --- S5 (claude-orca-dbu.5): the agent inside can see and repair it -------
#
# Provisioning that reports nothing is provisioning nobody can fix. These
# three cases are the whole of S5's contract: a status table that a person
# or an agent can read, a way to re-run exactly the step that broke, and a
# session start that puts a FAILED step in front of the agent without
# saying a word about a folder that is fine.

PROVISION_BIN="$REPO_ROOT/bin/provision"
SETTINGS="$REPO_ROOT/config/claude-settings.json"

# A step's leavings without running a step: the two files provision-run.sh
# writes, which are the only thing `provision status` reads.
seed_provision_status() {  # seed_provision_status <project> <step> <status> <last log line>
    local pdir="$1/.claude-dev/run/provision"
    mkdir -p "$pdir"
    printf '%s\n' "$3" > "$pdir/$2.status"
    printf 'a line this step wrote earlier\n%s\n' "$4" > "$pdir/$2.log"
}

@test "with one step's status file non-zero, 'provision status' exits non-zero and names that step" {
    [ -x "$PROVISION_BIN" ]

    local proj="$TMP/project"
    make_project "$proj"
    mkdir -p "$TMP/home"
    seed_provision_status "$proj" 10-toolchain-verify 0 "toolchain ok"
    seed_provision_status "$proj" 20-config-sync 3 "cp: cannot create the settings file"

    run env HOME="$TMP/home" CLAUDE_ORCA_ROOT="$proj" "$PROVISION_BIN" status
    [ "$status" -ne 0 ]
    # The name, because that is what `provision run <step>` takes, and the
    # last line of its log, because that is the sentence that says why.
    [[ "$output" == *"20-config-sync"* ]]
    [[ "$output" == *"cp: cannot create the settings file"* ]]
    # A table, not a complaint: every step is a row, passing ones included.
    [[ "$output" == *"10-toolchain-verify"* ]]

    # ... and a folder whose steps all passed is a clean exit, so this is
    # usable as the condition of a script.
    printf '0\n' > "$proj/.claude-dev/run/provision/20-config-sync.status"
    run env HOME="$TMP/home" CLAUDE_ORCA_ROOT="$proj" "$PROVISION_BIN" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"10-toolchain-verify"* ]]
}

@test "'provision run <step>' re-runs exactly that step and rewrites its status" {
    [ -x "$PROVISION_BIN" ]

    local proj="$TMP/project" pdir
    make_project "$proj"
    mkdir -p "$TMP/home"
    pdir="$proj/.claude-dev/run/provision"

    write_step 10-first  'echo "10 ran" >> "$TMP/order"'
    write_step 20-middle 'echo "20 ran" >> "$TMP/order"' \
                         'if [ -f "$TMP/repaired" ]; then echo "the repair took"; exit 0; fi' \
                         'echo "still broken" >&2' \
                         'exit 3'
    write_step 30-last   'echo "30 ran" >> "$TMP/order"'

    env HOME="$TMP/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_PROVISION_STEPS="$TMP/steps" bash "$PROVISION_RUN"
    [ "$(tr -d '[:space:]' < "$pdir/20-middle.status")" = "3" ]
    [ "$(grep -c . "$TMP/order")" = "3" ]

    # The repair a person or an agent makes, and then the one step again.
    touch "$TMP/repaired"
    run env HOME="$TMP/home" CLAUDE_ORCA_ROOT="$proj" \
        CLAUDE_ORCA_PROVISION_STEPS="$TMP/steps" "$PROVISION_BIN" run 20-middle
    [ "$status" -eq 0 ]

    # EXACTLY that step: re-running a whole provision to fix one line of it
    # is what makes people stop doing it.
    [ "$(grep -c . "$TMP/order")" = "4" ]
    [ "$(grep -c '20 ran' "$TMP/order")" = "2" ]
    [ "$(grep -c '10 ran' "$TMP/order")" = "1" ]
    [ "$(grep -c '30 ran' "$TMP/order")" = "1" ]

    # ... and what it leaves behind is THIS run: the status is rewritten,
    # and the log no longer carries the failure that has been fixed.
    [ "$(tr -d '[:space:]' < "$pdir/20-middle.status")" = "0" ]
    grep -qF 'the repair took' "$pdir/20-middle.log"
    run grep -c 'still broken' "$pdir/20-middle.log"
    [ "$output" = "0" ]

    # And the table agrees with it.
    run env HOME="$TMP/home" CLAUDE_ORCA_ROOT="$proj" "$PROVISION_BIN" status
    [ "$status" -eq 0 ]
}

@test "the session-start hook output contains the failing step name when one has failed and no provision lines at all when none has" {
    local proj="$TMP/project" cmd hook
    make_project "$proj"
    mkdir -p "$TMP/home" "$TMP/host"
    # The hook runs from <project>/.claude-dev/template, which is this repo.
    ln -sfn "$REPO_ROOT" "$TMP/host/template"

    # The hook the folder actually runs, taken out of the settings file that
    # ships rather than hand-written here -- a wiring this test approximates
    # is a wiring this test cannot prove.
    cmd="$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command]
                  | map(select(contains("bin/provision"))) | .[0] // empty' "$SETTINGS")"
    [ -n "$cmd" ]
    hook="${cmd//__HOST__/$TMP/host}"

    seed_provision_status "$proj" 10-toolchain-verify 0 "toolchain ok"
    seed_provision_status "$proj" 20-config-sync 3 "cp: cannot create the settings file"

    run env HOME="$TMP/home" CLAUDE_ORCA_ROOT="$proj" bash -c "$hook"
    # A SessionStart hook never fails the session, whatever it found.
    [ "$status" -eq 0 ]
    [[ "$output" == *"20-config-sync"* ]]
    [[ "$output" == *"cp: cannot create the settings file"* ]]
    # Only the broken one: the passing steps are not news.
    [[ "$output" != *"10-toolchain-verify"* ]]

    # A folder with nothing wrong says nothing at all. Every prompt pays for
    # this line, so a folder that is fine must not spend it.
    printf '0\n' > "$proj/.claude-dev/run/provision/20-config-sync.status"
    run env HOME="$TMP/home" CLAUDE_ORCA_ROOT="$proj" bash -c "$hook"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- the guard step's own job (claude-orca-qa2.25) ------------------------
#
# 70-openrouter-guard is a probe on every start but the one where the guard
# has died, and on that one it is a restart -- on the SAME token, because a
# fresh one is a credential no terminal in this container has heard of. The
# key it restarts with goes over a mode-600 file the guard reads once and
# unlinks, never argv or the environment: the guard runs as the same uid as
# every terminal here, so a key in /proc/<guard>/environ is a key `ps -ef`
# hands out for the guard's whole uptime.

GUARD_STEP="$REPO_ROOT/scripts/container/provision.d/70-openrouter-guard"
GUARD_PY="$REPO_ROOT/scripts/container/openrouter-guard.py"
GUARD_POLICY="$REPO_ROOT/config/provider-policy.json"
PROV_REAL_KEY="sk-or-v1-real-secret-never-in-a-guard-argv"

wait_tcp_port() {  # wait_tcp_port <port>
    local i=0
    while [ "$i" -lt 100 ]; do
        if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.3); sys.exit(0 if s.connect_ex(('127.0.0.1',$1))==0 else 1)"; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.2
    done
    return 1
}

wait_tcp_closed() {  # wait_tcp_closed <port>
    local i=0
    while [ "$i" -lt 100 ]; do
        if ! python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.3); sys.exit(0 if s.connect_ex(('127.0.0.1',$1))==0 else 1)"; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.2
    done
    return 1
}

@test "the guard step restarts a guard that has died, on the same token, and a live one is left alone" {
    [ -x "$GUARD_STEP" ]
    [ -f "$GUARD_PY" ]
    command -v curl >/dev/null 2>&1

    local proj="$TMP/project" rund port pid1 pid2 token
    make_project "$proj"
    mkdir -p "$TMP/home"
    rund="$proj/.claude-dev/run"
    port="$(free_port)"
    token="tok-same-across-restarts"

    # The token Orca's environment already carries, from a previous boot.
    printf '%s\n' "$token" > "$rund/openrouter-guard.token"
    chmod 600 "$rund/openrouter-guard.token"

    # A guard that is already up, started the way the entrypoint starts it:
    # the key over a mode-600 file, nothing on the command line.
    printf '%s\n' "$PROV_REAL_KEY" > "$rund/openrouter-guard.key"
    chmod 600 "$rund/openrouter-guard.key"
    env -u OPENROUTER_API_KEY \
        CLAUDE_ORCA_GUARD_KEY_FILE="$rund/openrouter-guard.key" \
        OPENROUTER_GUARD_TOKEN="$token" \
        OPENROUTER_UPSTREAM="http://127.0.0.1:1" \
        python3 "$GUARD_PY" --port "$port" --policy "$GUARD_POLICY" \
        --run-dir "$rund" >>"$rund/openrouter-guard.log" 2>&1 &
    pid1=$!
    GUARD_PIDS="$pid1"
    wait_tcp_port "$port"
    printf '%s\n' "$pid1" > "$rund/openrouter-guard.pid"
    # read once and unlinked: the window is startup, not uptime
    [ ! -e "$rund/openrouter-guard.key" ]

    # A live guard is left alone: a probe, and nothing else.
    run env -u OPENROUTER_API_KEY HOME="$TMP/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_GUARD_PORT="$port" \
        CLAUDE_ORCA_GUARD_SCRIPT="$GUARD_PY" \
        CLAUDE_ORCA_GUARD_TIMEOUT=20 \
        CLAUDE_ORCA_OPENROUTER_REAL_KEY="$PROV_REAL_KEY" \
        bash "$GUARD_STEP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"answering"* ]]
    kill -0 "$pid1"
    [ "$(cat "$rund/openrouter-guard.pid")" = "$pid1" ]

    # Now it dies.
    kill -KILL "$pid1" 2>/dev/null
    wait_tcp_closed "$port"

    run env -u OPENROUTER_API_KEY HOME="$TMP/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_GUARD_PORT="$port" \
        CLAUDE_ORCA_GUARD_SCRIPT="$GUARD_PY" \
        CLAUDE_ORCA_GUARD_TIMEOUT=20 \
        CLAUDE_ORCA_OPENROUTER_REAL_KEY="$PROV_REAL_KEY" \
        OPENROUTER_UPSTREAM="http://127.0.0.1:1" \
        bash "$GUARD_STEP"
    [ "$status" -eq 0 ]
    [ -s "$rund/openrouter-guard.pid" ]
    pid2="$(cat "$rund/openrouter-guard.pid")"
    GUARD_PIDS="$pid1 $pid2"
    [ "$pid2" != "$pid1" ]
    kill -0 "$pid2"
    wait_tcp_port "$port"

    # Same token, and the restarted guard still honours it: a request that
    # carries it gets as far as the (unreachable) upstream, one that does
    # not is refused at the door.
    [ "$(cat "$rund/openrouter-guard.token")" = "$token" ]
    run curl -s -o /dev/null -w '%{http_code}' \
        -X POST "http://127.0.0.1:$port/api/v1/chat/completions" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        --data-binary '{"model":"m","messages":[]}'
    [ "$output" = "502" ]
    run curl -s -o /dev/null -w '%{http_code}' \
        -X POST "http://127.0.0.1:$port/api/v1/chat/completions" \
        -H "Authorization: Bearer not-the-token" \
        -H 'Content-Type: application/json' \
        --data-binary '{"model":"m","messages":[]}'
    [ "$output" = "401" ]

    # The restarted guard holds the key the same way the first one did:
    # not in its environment, not on its command line, and not in a file
    # left behind under run/.
    run bash -c "tr '\0' '\n' < /proc/$pid2/environ | grep -c -- '$PROV_REAL_KEY'"
    [ "$output" = "0" ]
    run bash -c "tr '\0' '\n' < /proc/$pid2/cmdline | grep -c -- '$PROV_REAL_KEY'"
    [ "$output" = "0" ]
    [ ! -e "$rund/openrouter-guard.key" ]
    run bash -c "grep -rl -- '$PROV_REAL_KEY' '$rund' | wc -l"
    [ "$output" = "0" ]

    kill -KILL "$pid2" 2>/dev/null || true
}

# --- claude-orca-8tx: fail closed when the client config still points at
# the guard but no key exists to start one ---------------------------------
#
# config-sync copies opencode.json into every folder unconditionally
# (scripts/config-sync.sh:216-219) -- its baseURL names the guard whether
# or not a key exists to start one. Before this bead, a folder with no key
# reported "nothing to guard" and exited 0, even though opencode is
# already configured to call a guard that will never come up: every
# opencode request in that folder fails ECONNREFUSED with no row anywhere
# saying why.

@test "the guard step fails closed when opencode.json names the guard and there is no key" {
    [ -x "$GUARD_STEP" ]

    local proj="$TMP/project-noguard" home port
    make_project "$proj"
    home="$TMP/home-noguard"
    port="$(free_port)"
    mkdir -p "$home/.config/opencode"
    printf '{"provider":{"openrouter":{"options":{"baseURL":"http://127.0.0.1:%s/api/v1"}}}}\n' \
        "$port" > "$home/.config/opencode/opencode.json"

    run env -u OPENROUTER_API_KEY HOME="$home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_GUARD_PORT="$port" \
        CLAUDE_ORCA_GUARD_SCRIPT="$GUARD_PY" \
        bash "$GUARD_STEP"
    [ "$status" -ne 0 ]
    [[ "$output" == *"opencode.json"* ]]
    # claude-orca-376: the primary instruction names the in-container file
    # -- writable from any terminal here -- not a Mac-side command.
    [[ "$output" == *"$home/.openrouter.key"* ]]
    [[ "$output" == *"./claude-dev key openrouter"* ]]
}

@test "the guard step still says there is nothing to guard when opencode has no guard configured" {
    [ -x "$GUARD_STEP" ]

    local proj="$TMP/project-noopencode" home port
    make_project "$proj"
    home="$TMP/home-noopencode"
    port="$(free_port)"
    mkdir -p "$home"

    run env -u OPENROUTER_API_KEY HOME="$home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_GUARD_PORT="$port" \
        CLAUDE_ORCA_GUARD_SCRIPT="$GUARD_PY" \
        bash "$GUARD_STEP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to guard"* ]]
}
