#!/usr/bin/env bats
#
# Guards:   `./claude-dev --update` migrates a folder made by the Orca image:
#           it removes the leftover <container>-orca-state volume (one line,
#           only when it was there), gives a folder from before the ssh panes
#           its keys, and the container it creates no longer carries Orca's
#           port, version, theme or state mount.
# Fails if: --update leaves the old state volume behind, removes a volume
#           that was never there (or prints the line for one), a folder with
#           no state/ssh comes out of --update without keys, or `docker run`
#           gets ORCA_PORT / ORCA_VERSION / CLAUDE_ORCA_THEME / an
#           -orca-state mount back (CLAUDE_ORCA_TERMINAL_THEME must stay).
# Run:      bats tests/launcher-update-migration.bats
#
# claude-orca-9bh.12 (C2). `docker` is the stub from tests/helpers/setup.bash:
# a named volume is a file in $CONTAINER_STUB_STATE/volumes, `volume inspect`
# answers 0 when it is there and 1 when it is not, and `volume rm` is logged
# one line per call in $CONTAINER_STUB_LOG. ssh-keygen is the real OpenSSH
# one the helper puts on PATH (CLAUDE_ORCA_SSH_KEYGEN, as in launcher-ssh).

load helpers/setup

# The one line the `docker` stub logged for the invocation whose argv
# starts with $1 (its log is one line per invocation, argv joined).
ctr_line() {
    grep "^$1" "$CONTAINER_STUB_LOG" | head -1
}

# How many times the stub logged a line matching the ERE $1.
log_count() {
    grep -c -E "$1" "$CONTAINER_STUB_LOG" || true
}

# A bootstrapped, opened folder at $PROJECT_DIR. Sets $primary and $name.
open_folder() {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    name="claude-orca-$(basename "$primary")"
}

# Pretend the folder was made by the Orca image: its state volume is there.
plant_state_volume() {
    : > "$CONTAINER_STUB_STATE/volumes/$name-orca-state"
}

@test "update on a folder with a leftover orca-state volume removes it once, prints one line saying so, and a second update does nothing more" {
    open_folder
    plant_state_volume
    [ -f "$CONTAINER_STUB_STATE/volumes/$name-orca-state" ]

    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]

    # Exactly one `volume rm`, of exactly that volume, and the stub no
    # longer has it.
    [ "$(log_count '^volume rm ')" -eq 1 ]
    [ "$(log_count "^volume rm $name-orca-state\$")" -eq 1 ]
    [ ! -e "$CONTAINER_STUB_STATE/volumes/$name-orca-state" ]
    # The scratch volumes are not the migration's business.
    [ "$(log_count "^volume rm $name-(cache|npm|opencode|worktrees)\$")" -eq 0 ]

    # One printed line, naming the volume.
    [ "$(printf '%s\n' "$output" | grep -c 'removed the old Orca state volume')" -eq 1 ]
    [[ "$output" == *"removed the old Orca state volume $name-orca-state"* ]]

    # The container that held it is gone before the volume goes: a volume
    # a container still has mounted cannot be removed.
    rm_at="$(grep -n "^rm " "$CONTAINER_STUB_LOG" | head -1 | cut -d: -f1)"
    vol_at="$(grep -n "^volume rm " "$CONTAINER_STUB_LOG" | head -1 | cut -d: -f1)"
    [ -n "$rm_at" ]
    [ "$rm_at" -lt "$vol_at" ]

    # An already-migrated folder: nothing extra, nothing changed.
    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]
    [ "$(log_count '^volume rm ')" -eq 0 ]
    [[ "$output" != *"removed the old Orca state volume"* ]]
}

@test "update on a folder with no orca-state volume runs no volume rm and prints no migration line" {
    open_folder
    [ ! -e "$CONTAINER_STUB_STATE/volumes/$name-orca-state" ]

    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]

    [ "$(log_count '^volume rm ')" -eq 0 ]
    [[ "$output" != *"Orca state"* ]]
    [[ "$output" != *"removed the old"* ]]
}

@test "update on a folder with no state/ssh keys creates them before the new container starts, and keeps them on the next update" {
    open_folder
    sd="$primary/.claude-dev/state/ssh"
    # A folder from before the ssh panes. Destructive, so the fixture path
    # is asserted first.
    case "$sd" in "$BATS_TEST_TMPDIR"/*) ;; *) false ;; esac
    rm -rf "$sd"
    rm -f "$primary/.claude-dev/run/sshd.ready"
    [ ! -e "$sd" ]

    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]

    [ -s "$sd/client_ed25519" ]
    [ -s "$sd/client_ed25519.pub" ]
    [ -s "$sd/host_ed25519" ]
    [ -s "$sd/host_ed25519.pub" ]
    [ -s "$sd/authorized_keys" ]
    [ "$(file_mode "$sd")" = "700" ]
    [ "$(file_mode "$sd/client_ed25519")" = "600" ]
    [ "$(file_mode "$sd/host_ed25519")" = "600" ]

    # The docker stub writes sshd.ready only from a host key that existed
    # when `run` was called, and records that key's fingerprint in it: the
    # fingerprint matching the key on disk is the keys-before-container proof.
    want="$("${CLAUDE_ORCA_SSH_KEYGEN:-ssh-keygen}" -lf "$sd/host_ed25519.pub" | awk 'NR == 1 { print $2 }')"
    [ -n "$want" ]
    grep -qxF "host_key_sha256=$want" "$primary/.claude-dev/run/sshd.ready"

    # An existing identity is never re-made by a later update (the host
    # fingerprint would change under every pane's known_hosts).
    before="$(cksum "$sd/client_ed25519" "$sd/host_ed25519")"
    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]
    [ "$(cksum "$sd/client_ed25519" "$sd/host_ed25519")" = "$before" ]
}

@test "the container docker run creates carries no ORCA_PORT, ORCA_VERSION, CLAUDE_ORCA_THEME or -orca-state mount, and does carry CLAUDE_ORCA_TERMINAL_THEME when set" {
    open_folder
    json="$primary/.claude-dev/claude-orca.json"
    jq '.terminalTheme = "Snazzy"' "$json" > "$json.tmp" && mv "$json.tmp" "$json"
    plant_state_volume

    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]

    line="$(ctr_line "run ")"
    [ -n "$line" ]
    [[ "$line" == *"--name $name"* ]]
    [[ "$line" != *"ORCA_PORT"* ]]
    [[ "$line" != *"ORCA_VERSION"* ]]
    # (CLAUDE_ORCA_TERMINAL_THEME, which stays, does not contain this.)
    [[ "$line" != *"CLAUDE_ORCA_THEME"* ]]
    [[ "$line" != *"-orca-state"* ]]
    [[ "$line" != *"ORCA_BIN"* ]]
    # What stays: the terminal palette, and sshd's port.
    [[ "$line" == *"-e CLAUDE_ORCA_TERMINAL_THEME=Snazzy"* ]]
    [[ "$line" == *"-e CLAUDE_ORCA_SSHD_PORT="* ]]

    # What the daemon would record as the container's mounts says the same.
    ! grep -q 'orca-state' "$CONTAINER_STUB_STATE/containers/$name.meta"
    grep -q '^env=CLAUDE_ORCA_TERMINAL_THEME=Snazzy$' "$CONTAINER_STUB_STATE/containers/$name.meta"
}
