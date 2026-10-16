#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# Guards:   the entrypoint's config sync and project wiring: config-sync
#           reads the folder's own template clone, runs once BEFORE sshd is
#           started (never fatal, never run twice destructively), the
#           provision.d steps run after sshd is supervised, and the managed
#           settings file is written, merged or left alone as policy says.
# Fails if: the early sync reads the image's frozen copy, runs after sshd
#           starts, kills the boot when it fails, rewrites config-hash again
#           from provision.d, a provision.d step gets no status, or managed
#           settings overwrite an operator's autoContinueAtUsageLimit.
# Run:      bats tests/container-entrypoint-sync.bats
#
# The entrypoint never exits by itself (PID 1 waits on the sshd
# supervisor), so cases boot it with run_entrypoint_once or in the
# background (tests/helpers/entrypoint-boot.bash). Where a case needs to
# see WHEN sshd started, CLAUDE_ORCA_SSHD_BIN is a stub that records the
# folder's state at that instant and then listens with an SSH banner.

load helpers/entrypoint-boot

# Stage the ssh keys the supervisor insists on before it will start sshd.
sync_stage_ssh_keys() {
    local proj="$1" d="$1/.claude-dev/state/ssh"
    mkdir -p "$d"
    printf 'stub-private-key\n' > "$d/host_ed25519"
    printf 'ssh-ed25519 %s stub\n' "$(printf 'stub-host-key' | base64)" > "$d/host_ed25519.pub"
    printf 'ssh-ed25519 AAAAstub client\n' > "$d/authorized_keys"
}

# A stand-in sshd: records what the folder looked like the moment sshd was
# started (the settings file, its statusLine key, the config-hash), then
# listens on the Port of the config it was given and greets with an SSH
# banner, which is all the supervisor's readiness probe wants.
sync_write_sshd_stub() {
    local path="$1" proj="$2"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<STUB
#!/usr/bin/env bash
cfg=""; prev=""
for a in "\$@"; do [ "\$prev" = "-f" ] && cfg="\$a"; prev="\$a"; done
port="\$(awk '\$1=="Port"{print \$2}' "\$cfg")"
s="$proj/.claude-dev/home/.claude/settings.json"
{
    [ -s "\$s" ] && echo settings=yes || echo settings=no
    grep -q statusLine "\$s" 2>/dev/null && echo statusline=yes || echo statusline=no
    [ -s "$proj/.claude-dev/run/config-hash" ] && echo hash=yes || echo hash=no
} > "$TMP/sshd.saw"
exec python3 -I -c '
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(5)
while True:
    c, _ = s.accept()
    c.sendall(b"SSH-2.0-stub\r\n")
    c.close()' "\$port"
STUB
    chmod +x "$path"
}

# The environment every case here shares (the privilege drop, setup.sh and
# beads are other files' business).
sync_env() {
    export HOME="$1/.claude-dev/home" PROJECT_DIR="$1"
    export CLAUDE_ORCA_SKIP_SETUP=1 CLAUDE_ORCA_SKIP_BEADS=1
    export CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    export CLAUDE_ORCA_RUNTIME_DIR="$RT"
}

@test "entrypoint config-syncs from the folder's own template clone, not the image's frozen copy" {
    # Guards:   config-sync reads <folder>/.claude-dev/template/config even on a box that bakes /opt/claude-orca.
    # Fails if: the early sync prefers the image's copy, so a marker command only the folder's clone has never lands.
    # Run:      bats -f "folder's own template clone" tests/container-entrypoint-sync.bats
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project"
    make_project "$proj"

    # A folder clone carrying a config/ the image's copy could not have:
    # the marker command is what proves which source config-sync read.
    local tcfg="$proj/.claude-dev/template/config"
    mkdir -p "$tcfg/claude-commands"
    printf '{"hooks":{}}\n'        > "$tcfg/claude-settings.json"
    printf 'folder memory\n'       > "$tcfg/claude-user-memory.md"
    printf '#!/bin/sh\necho hi\n'  > "$tcfg/statusline.sh"
    printf 'folder-clone-marker\n' > "$tcfg/claude-commands/marker.md"

    run_entrypoint_once HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_SKIP_SETUP=1 CLAUDE_ORCA_SKIP_BEADS=1 \
        CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1

    # On a prebuilt image /opt/claude-orca exists and used to win here; the
    # folder's clone is the source now, whichever box this runs on.
    [[ "$output" == *"early config sync from $proj/.claude-dev/template/config: ok"* ]]
    [ -f "$proj/.claude-dev/home/.claude/commands/marker.md" ]
    run cat "$proj/.claude-dev/home/.claude/CLAUDE.md"
    [ "$output" = "folder memory" ]
}

# --- early config sync (claude-orca-0jn) ---------------------------------
#
# config-sync used to run only from provision.d, after the folder was
# already reachable -- so a Claude Code session started the moment the
# workspace opened could read a settings.json that did not exist yet, or
# existed without statusLine, and Claude Code only reads statusLine at
# process start. These cases pin the fix: a first sync BEFORE sshd is even
# started, never fatal, never a second source of truth for the checksum gate.

@test "entrypoint syncs config before sshd starts, on a brand-new project" {
    # Guards:   settings.json (with statusLine) already exists at the instant sshd is started.
    # Fails if: the early sync is moved after start_sshd, or dropped, so a first session sees no statusLine.
    # Run:      bats -f "before sshd starts" tests/container-entrypoint-sync.bats
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" tcfg port
    mkdir -p "$proj"
    tcfg="$proj/.claude-dev/template/config"
    mkdir -p "$tcfg"
    cat > "$tcfg/claude-settings.json" <<'JSON'
{"statusLine": {"type": "command", "command": "__HOST__/template/bin/statusline"}, "hooks": {}}
JSON
    printf 'folder memory\n' > "$tcfg/claude-user-memory.md"
    printf '#!/bin/sh\necho hi\n' > "$tcfg/statusline.sh"

    sync_stage_ssh_keys "$proj"
    sync_write_sshd_stub "$TMP/bin/sshd-stub" "$proj"
    port="$(free_port)"
    sync_env "$proj"
    export CLAUDE_ORCA_SSHD_BIN="$TMP/bin/sshd-stub" CLAUDE_ORCA_SSHD_PORT="$port"
    export CLAUDE_ORCA_SKIP_PROVISION=1

    start_entrypoint_bg
    if ! wait_for_file "$TMP/sshd.saw" 30; then
        cat "$TMP/entrypoint.out" >&2 || true
        false
    fi

    # What sshd saw the instant it was started.
    run cat "$TMP/sshd.saw"
    [[ "$output" == *"settings=yes"* ]]
    [[ "$output" == *"statusline=yes"* ]]
    [[ "$output" == *"hash=yes"* ]]

    # And the log agrees on the order: sync line first, sshd line after.
    local sync_ln sshd_ln
    sync_ln="$(grep -n 'early config sync from' "$TMP/entrypoint.out" | head -1 | cut -d: -f1)"
    sshd_ln="$(grep -n 'sshd supervisor started' "$TMP/entrypoint.out" | head -1 | cut -d: -f1)"
    [ -n "$sync_ln" ] && [ -n "$sshd_ln" ] && [ "$sync_ln" -lt "$sshd_ln" ]
}

@test "a failing early config sync does not stop sshd: sshd.ready and run/port still appear" {
    # Guards:   a broken early config sync is logged, named as retried later, and the boot goes on to start sshd.
    # Fails if: a failing early sync aborts the entrypoint (set -e leak), so run/port or sshd.ready never appear.
    # Run:      bats -f "does not stop sshd" tests/container-entrypoint-sync.bats
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" runp port
    make_project "$proj"
    # A template config directory that exists but is missing every file
    # config-sync.sh actually needs -- a real failure, not a stand-in.
    mkdir -p "$proj/.claude-dev/template/config"

    sync_stage_ssh_keys "$proj"
    sync_write_sshd_stub "$TMP/bin/sshd-stub" "$proj"
    port="$(free_port)"
    sync_env "$proj"
    export CLAUDE_ORCA_SSHD_BIN="$TMP/bin/sshd-stub" CLAUDE_ORCA_SSHD_PORT="$port"
    export CLAUDE_ORCA_SKIP_PROVISION=1

    start_entrypoint_bg

    runp="$proj/.claude-dev/run"
    if ! wait_for_file "$runp/sshd.ready" 40; then
        cat "$TMP/entrypoint.out" >&2 || true
        false
    fi
    wait_for_file "$runp/port" 5

    run cat "$runp/port"
    [ "$status" -eq 0 ]
    [ "$output" = "$port" ]

    # Not silent: named as the early sync, and named as retried later --
    # exactly the pattern every other non-fatal step here follows.
    grep -qF 'early config sync' "$TMP/entrypoint.out"
    grep -qF 'provision.d/20-config-sync will retry' "$TMP/entrypoint.out"
}

# Pin the folder's template as TEMPLATE_ROOT (entrypoint.sh picks it when it
# carries an executable scripts/container/setup.sh). Without the pin a box
# that bakes /opt/claude-orca provisions from the IMAGE's frozen copy.
sync_pin_template_root() {
    local d="$1/.claude-dev/template/scripts/container"
    mkdir -p "$d"
    : > "$d/setup.sh"
    chmod +x "$d/setup.sh"
}

@test "the early config sync and the later provision.d/20-config-sync do not double-run destructively" {
    # Guards:   the checksum gate is shared: provision.d/20-config-sync finds the early sync's hash and rewrites nothing.
    # Fails if: provision.d re-syncs from scratch (a second source of truth), so config-hash changes after provisioning starts.
    # Run:      bats -f "do not double-run" tests/container-entrypoint-sync.bats
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" tcfg port hashfile pdir before
    make_project "$proj"
    tcfg="$proj/.claude-dev/template/config"
    mkdir -p "$tcfg/claude-commands"
    printf '{"hooks":{}}\n'        > "$tcfg/claude-settings.json"
    printf 'folder memory\n'       > "$tcfg/claude-user-memory.md"
    printf '#!/bin/sh\necho hi\n'  > "$tcfg/statusline.sh"
    printf 'marker\n'              > "$tcfg/claude-commands/marker.md"

    # Provisioning is the real runner from this repo, but entered through a
    # wrapper that notes config-hash's timestamp the instant provisioning
    # starts -- i.e. what the EARLY sync left, before any provision.d step.
    sync_pin_template_root "$proj"
    cat > "$proj/.claude-dev/template/scripts/container/provision-run.sh" <<WRAP
#!/usr/bin/env bash
stat -c %y "$proj/.claude-dev/run/config-hash" > "$TMP/hash.before"
exec bash "$REPO_ROOT/scripts/container/provision-run.sh"
WRAP
    chmod +x "$proj/.claude-dev/template/scripts/container/provision-run.sh"

    sync_stage_ssh_keys "$proj"
    sync_write_sshd_stub "$TMP/bin/sshd-stub" "$proj"
    port="$(free_port)"
    sync_env "$proj"
    export CLAUDE_ORCA_SSHD_BIN="$TMP/bin/sshd-stub" CLAUDE_ORCA_SSHD_PORT="$port"
    export CLAUDE_ORCA_SKIP_PROVISION=0

    start_entrypoint_bg

    hashfile="$proj/.claude-dev/run/config-hash"
    pdir="$proj/.claude-dev/run/provision"
    if ! wait_for_file "$pdir/20-config-sync.status" 90; then
        cat "$TMP/entrypoint.out" >&2 || true
        ls -la "$pdir" >&2 || true
        false
    fi
    [ "$(tr -d '[:space:]' < "$pdir/20-config-sync.status")" = "0" ]

    # The step really ran (and said it synced from the folder's clone) ...
    grep -qF "config synced from $proj/.claude-dev/template/config" "$pdir/20-config-sync.log"
    # ... yet it left the early sync's hash file untouched.
    [ -s "$TMP/hash.before" ]
    before="$(cat "$TMP/hash.before")"
    [ "$(stat -c %y "$hashfile")" = "$before" ]
}

# --- provision.d (claude-orca-dbu.4) -------------------------------------
#
# The project-shaped work -- the toolchain verify, the config sync, the
# seeds, the tracker, the guard check -- is no longer in front of the thing
# that reports it. It runs from scripts/container/provision.d/ once the sshd
# supervisor is started, and what it leaves behind is a status per step.
# The contract for the steps themselves is tests/provision.bats; this case
# is the wiring.

@test "entrypoint provisions the folder through provision.d after sshd is supervised" {
    # Guards:   every provision.d step runs and leaves a status, after run/port is written and with sshd up.
    # Fails if: provisioning is skipped, runs before sshd/run/port, or a step is added without being reached.
    # Run:      bats -f "through provision.d" tests/container-entrypoint-sync.bats
    [ -x "$ENTRYPOINT" ]
    [ -d "$REPO_ROOT/scripts/container/provision.d" ]

    local proj="$TMP/project" port pdir step name first i
    make_project "$proj"
    # Without the pin a box that bakes /opt/claude-orca provisions from the
    # IMAGE's frozen provision.d, and a step added since that build has no
    # status here.
    sync_pin_template_root "$proj"
    pdir="$proj/.claude-dev/run/provision"

    sync_stage_ssh_keys "$proj"
    sync_write_sshd_stub "$TMP/bin/sshd-stub" "$proj"
    port="$(free_port)"
    sync_env "$proj"
    export CLAUDE_ORCA_SSHD_BIN="$TMP/bin/sshd-stub" CLAUDE_ORCA_SSHD_PORT="$port"
    export CLAUDE_ORCA_SKIP_PROVISION=0

    start_entrypoint_bg

    # Every real step ran and said how it went. The last one is what the
    # wait is on: they run in order, so a status for it means a status for
    # all of them.
    name="$(basename "$(ls -1 "$REPO_ROOT/scripts/container/provision.d" | sort | tail -1)")"
    if ! wait_for_file "$pdir/$name.status" 120; then
        cat "$TMP/entrypoint.out" >&2 || true
        ls -la "$pdir" >&2 || true
        false
    fi
    for step in "$REPO_ROOT"/scripts/container/provision.d/*; do
        [ -f "$pdir/$(basename "$step").status" ] \
            || { echo "no status for $(basename "$step")" >&3; false; }
    done

    # run/port was written before the first step started ...
    first="$pdir/$(ls -1 "$REPO_ROOT/scripts/container/provision.d" | sort | head -1).status"
    [ -s "$proj/.claude-dev/run/port" ]
    [ ! "$proj/.claude-dev/run/port" -nt "$first" ]
    run cat "$proj/.claude-dev/run/port"
    [ "$output" = "$port" ]

    # ... sshd is up and answering ...
    wait_for_file "$proj/.claude-dev/run/sshd.ready" 30

    # ... and PID 1 only settles into waiting once provisioning is done.
    for i in $(seq 1 100); do
        grep -qF 'waiting on the sshd supervisor' "$TMP/entrypoint.out" && break
        sleep 0.1
    done
    local start_ln wait_ln
    start_ln="$(grep -n 'sshd supervisor started' "$TMP/entrypoint.out" | head -1 | cut -d: -f1)"
    wait_ln="$(grep -n 'waiting on the sshd supervisor' "$TMP/entrypoint.out" | head -1 | cut -d: -f1)"
    [ -n "$start_ln" ] && [ -n "$wait_ln" ] && [ "$start_ln" -lt "$wait_ln" ]
}
