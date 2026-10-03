#!/usr/bin/env bats
#
# claude-orca-1eh acceptance contract -- FROZEN from RED-AT onward.
#
# The launcher (separate bead, claude-orca-7uy) mounts four docker volumes
# under the agent home -- .cache, .npm, .local/share/opencode, worktrees --
# and names them in CLAUDE_ORCA_VOLUME_DIRS (colon-separated guest paths).
# This file is the CONTAINER half's contract:
#
#   * scripts/container/volume-dirs.sh keeps only the entries that are
#     real mount points under the agent home;
#   * the entrypoint hands a volume dir that is not the agent's to the
#     agent (docker creates volumes root-owned);
#   * the state seed points Orca's per-repo worktree base at the volume
#     and rewrites an existing orca-data.json that still names the old
#     in-folder default;
#   * provision.d/45-scratch-volumes deletes the regenerable caches'
#     shadowed copies and migrates opencode's data -- but only behind a
#     real second filesystem, because /home/agent IS
#     $PROJECT_DIR/.claude-dev/home: without the volume, D and legacy are
#     the same directory and a delete would destroy live data.
#
# The second filesystem is /dev/shm (tmpfs) against the overlayfs $TMP
# sits on; cases needing it skip when this box puts both on one device.
# `mountpoint` is stubbed on PATH: which paths are mounts is the
# launcher's decision (its docker run flags), and no test here can create
# a real docker volume. Ownership is stubbed the same way -- this suite
# runs unprivileged, so "owned by someone else" is what a stub stat says.
#
# Deliberately self-contained: no `load` of tests/helpers, so the frozen
# contract cannot drift when a shared helper changes.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VOLUME_LIB="$REPO_ROOT/scripts/container/volume-dirs.sh"
SEED="$REPO_ROOT/scripts/container/seed-orca-state.sh"
ENTRYPOINT="$REPO_ROOT/scripts/container/entrypoint.sh"
PROV_STEP="$REPO_ROOT/scripts/container/provision.d/45-scratch-volumes"

setup() {
    # Nothing ambient may answer for the fixture: PROJECT_DIR and
    # CLAUDE_ORCA_ROOT name this repo on the box running the suite, and
    # the step under test would otherwise provision THIS folder.
    unset PROJECT_DIR CLAUDE_ORCA_ROOT BEADS_DIR CLAUDE_ORCA_VOLUME_DIRS
    TMP="$(mktemp -d /tmp/co-vol-XXXXXX)"
    export TMP
    mkdir -p "$TMP/bin"
    write_mountpoint_stub
}

teardown() {
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
    [ -n "${VOLFS:-}" ] && rm -rf "$VOLFS"
    return 0
}

# mountpoint answers from $TMP/mounts (one path per line, exact match).
write_mountpoint_stub() {
    cat > "$TMP/bin/mountpoint" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
    [ "$a" = "-q" ] && continue
    if [ -f "$MOUNTS_FILE" ] && grep -Fqx "$a" "$MOUNTS_FILE"; then
        exit 0
    fi
done
exit 1
STUB
    chmod +x "$TMP/bin/mountpoint"
    : > "$TMP/mounts"
}

mark_mounts() {  # mark_mounts <home> <rel>...
    local home="$1" r
    shift
    for r in "$@"; do
        printf '%s\n' "$home/$r" >> "$TMP/mounts"
    done
}

# A home under /dev/shm: a genuinely different filesystem from the one
# $TMP sits on, which is exactly what the step's guard decides on. Skips
# the case when this box puts both on one device.
real_second_fs_home() {
    VOLFS="$(mktemp -d /dev/shm/co-vol-XXXXXX)"
    if [ "$(stat -c %d "$VOLFS")" = "$(stat -c %d "$TMP")" ]; then
        rm -rf "$VOLFS"
        VOLFS=""
        skip "/dev/shm is not a separate filesystem here"
    fi
    mkdir -p "$VOLFS/home"
    printf '%s\n' "$VOLFS/home"
}

# Runs the sourced lib the way its two consumers do, with stderr kept
# aside so the 'ignored' lines can be counted apart from the kept paths.
run_volume_dirs() {  # run_volume_dirs <agent-home> <value> <stderr-file>
    CLAUDE_ORCA_VOLUME_DIRS="$2" MOUNTS_FILE="$TMP/mounts" \
        PATH="$TMP/bin:$PATH" \
        bash -c '. "$0"; volume_dirs "$1" 2>"$2"' \
        "$VOLUME_LIB" "$1" "$3"
}

# `stat -c %u` answers 4242 for exactly one path, the real stat otherwise.
write_stat_stub() {  # write_stat_stub <path-that-looks-foreign>
    cat > "$TMP/bin/stat" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "-c" ] && [ "\$2" = "%u" ] && [ "\$3" = "$1" ]; then
    echo 4242
    exit 0
fi
real=/usr/bin/stat; [ -x "\$real" ] || real=/usr/sbin/stat
exec "\$real" "\$@"
STUB
    chmod +x "$TMP/bin/stat"
}

# chown that logs every target it was pointed at, then does it for real.
write_chown_log_shim() {
    cat > "$TMP/bin/chown" <<'SHIM'
#!/usr/bin/env bash
real=/usr/bin/chown; [ -x "$real" ] || real=/usr/sbin/chown
seen_owner=0
for a in "$@"; do
    case "$a" in
        -*) ;;
        *)  if [ "$seen_owner" = "0" ]; then seen_owner=1
            else printf '%s\n' "$a" >> "$CHOWN_LOG"; fi ;;
    esac
done
exec "$real" "$@"
SHIM
    chmod +x "$TMP/bin/chown"
    : > "$TMP/chown.log"
}

# --- the lib -------------------------------------------------------------

@test "volume_dirs keeps only real mounts under the agent home" {
    [ -f "$VOLUME_LIB" ]

    local home="$TMP/home"
    mkdir -p "$home/.cache" "$home/.npm" "$home/plain"
    mark_mounts "$home" .cache .npm

    # Dropped: an entry outside the home, one carrying a '..' segment, one
    # the stub does not recognise as a mount. Kept: the two mounts, in the
    # order the variable names them.
    run run_volume_dirs "$home" \
        "$TMP/elsewhere:$home/../x:$home/plain:$home/.cache:$home/.npm" \
        "$TMP/err"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n%s' "$home/.cache" "$home/.npm")" ]
    [ "$(grep -c ignored "$TMP/err")" = "3" ]

    # Unset variable: nothing, and a clean exit either way.
    unset CLAUDE_ORCA_VOLUME_DIRS
    run run_volume_dirs "$home" "" "$TMP/err2"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- the entrypoint's privilege drop --------------------------------------

@test "the entrypoint chowns a volume dir owned by someone else, and only then" {
    [ -f "$ENTRYPOINT" ]

    # The two chown helpers, lifted the way tests/chown-sockets.bats lifts
    # its phase_user chown: the real shipped code, driven against stubs.
    local fn
    fn="$(sed -n '/^chown_agent_tree()/,/^}/p' "$ENTRYPOINT")
$(sed -n '/^chown_volume_dirs()/,/^}/p' "$ENTRYPOINT")"
    [[ "$fn" == *chown_volume_dirs* ]]
    [[ "$fn" == *"volume_dirs"* ]]

    # ...and the call sits with the other privilege-drop chowns, after the
    # user-data dir's.
    run grep -n 'chown_volume_dirs$' "$ENTRYPOINT"
    [ "$status" -eq 0 ]

    local home="$TMP/home"
    mkdir -p "$home/.cache/sub" "$home/.npm"
    printf 'f\n' > "$home/.cache/sub/file"
    printf 'g\n' > "$home/.npm/file"
    mark_mounts "$home" .cache .npm
    write_stat_stub "$home/.cache"
    write_chown_log_shim

    run env SCRIPT_DIR="$REPO_ROOT/scripts/container" \
        AGENT_UID="$(id -u)" AGENT_GID="$(id -g)" AGENT_HOME="$home" \
        CLAUDE_ORCA_VOLUME_DIRS="$home/.cache:$home/.npm" \
        MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin:$PATH" \
        CHOWN_LOG="$TMP/chown.log" \
        bash -c "set -uo pipefail
log() { :; }
$fn
chown_volume_dirs"
    [ "$status" -eq 0 ]

    # .cache looked foreign, so it (and its tree) was handed over; .npm was
    # already the agent's and was never walked.
    run grep -c "$home/.cache" "$TMP/chown.log"
    [ "$output" -ge 1 ]
    run grep -c "$home/.npm" "$TMP/chown.log"
    [ "$output" = "0" ]
}

# --- the state seed -------------------------------------------------------

@test "a fresh seed puts worktrees on the volume when it is mounted" {
    [ -f "$SEED" ]

    local home="$TMP/h3" udd="$TMP/udd3" proj="$TMP/p3" data
    mkdir -p "$home" "$udd"
    mark_mounts "$home" worktrees

    run env -u PROJECT_DIR -u BEADS_DIR HOME="$home" \
        CLAUDE_ORCA_VOLUME_DIRS="$home/worktrees" \
        MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin:$PATH" \
        bash "$SEED" --user-data-dir "$udd" --project "$proj"
    [ "$status" -eq 0 ]

    data="$udd/profiles/local-default/orca-data.json"
    [ -f "$data" ]
    [ "$(jq -r '.repos[0].worktreeBasePath' "$data")" = "$home/worktrees" ]
}

@test "without the volume the seed keeps <project>/.orca-worktrees" {
    [ -f "$SEED" ]

    local home="$TMP/h4" udd="$TMP/udd4" proj="$TMP/p4" data
    mkdir -p "$home" "$udd"

    run env -u PROJECT_DIR -u BEADS_DIR -u CLAUDE_ORCA_VOLUME_DIRS \
        HOME="$home" MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin:$PATH" \
        bash "$SEED" --user-data-dir "$udd" --project "$proj"
    [ "$status" -eq 0 ]

    data="$udd/profiles/local-default/orca-data.json"
    [ -f "$data" ]
    [ "$(jq -r '.repos[0].worktreeBasePath' "$data")" = "$proj/.orca-worktrees" ]
}

@test "an existing orca-data.json on the old default is rewritten, a custom path is left alone" {
    [ -f "$SEED" ]

    local home="$TMP/h5" udd="$TMP/udd5" proj="$TMP/p5" data before
    mkdir -p "$home" "$udd/profiles/local-default"
    mark_mounts "$home" worktrees
    data="$udd/profiles/local-default/orca-data.json"

    write_existing() {
        cat > "$data" <<JSON
{"schemaVersion":1,"repos":[
 {"id":"a","path":"$proj","worktreeBasePath":"$proj/.orca-worktrees"},
 {"id":"b","path":"$proj","worktreeBasePath":"$proj/custom"}]}
JSON
    }
    write_existing
    before="$(md5sum < "$data")"

    run env -u PROJECT_DIR -u BEADS_DIR HOME="$home" \
        CLAUDE_ORCA_VOLUME_DIRS="$home/worktrees" \
        MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin:$PATH" \
        bash "$SEED" --user-data-dir "$udd" --project "$proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not seeded"* ]]
    [ "$(jq -r '.repos[0].worktreeBasePath' "$data")" = "$home/worktrees" ]
    [ "$(jq -r '.repos[0].path' "$data")" = "$proj" ]
    # A base path the user (or a future Orca) chose is nobody's to rewrite.
    [ "$(jq -r '.repos[1].worktreeBasePath' "$data")" = "$proj/custom" ]

    # jq broken (standing in for missing): the file stays byte-identical,
    # the seed says why, and the folder still boots.
    mkdir -p "$TMP/bin2"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin2/jq"
    chmod +x "$TMP/bin2/jq"
    write_existing
    before="$(md5sum < "$data")"

    run env -u PROJECT_DIR -u BEADS_DIR HOME="$home" \
        CLAUDE_ORCA_VOLUME_DIRS="$home/worktrees" \
        MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin2:$TMP/bin:$PATH" \
        bash "$SEED" --user-data-dir "$udd" --project "$proj"
    [ "$status" -eq 0 ]
    [ "$(md5sum < "$data")" = "$before" ]
    [[ "$output" == *"could not rewrite"* ]]
}

@test "a SQLite-era profile (profile-state.db present) is never rewritten" {
    # Guards:   Orca >= 1.4.219 keeps a profile's state in
    #           profiles/<id>/profile-state.db and treats orca-data.json
    #           as its own export -- a byte change behind the db makes the
    #           next start refuse outright ("cannot safely choose a
    #           profile-state authority", claude-orca-cey). With the db
    #           present, the seed writes NOTHING, not even a rewrite it
    #           would have made on its own pre-SQLite rules.
    # Fails if: orca-data.json changes by a single byte, or the seed does
    #           not say it is leaving the export alone.
    # Run:      setsid -w bats -f 'SQLite-era profile' \
    #               tests/scratch-volumes-container.bats </dev/null
    local home="$TMP/h13" udd="$TMP/udd13" proj="$TMP/p13" data db before
    mkdir -p "$home" "$udd/profiles/local-default"
    mark_mounts "$home" worktrees
    data="$udd/profiles/local-default/orca-data.json"
    db="$udd/profiles/local-default/profile-state.db"
    : > "$db"

    # A record that WOULD be rewritten under the old rules: it still names
    # the old in-folder default while the volume is mounted.
    cat > "$data" <<JSON
{"schemaVersion":1,"repos":[
 {"id":"a","path":"$proj","worktreeBasePath":"$proj/.orca-worktrees"}]}
JSON
    before="$(sha256sum < "$data")"

    run env -u PROJECT_DIR -u BEADS_DIR HOME="$home" \
        CLAUDE_ORCA_VOLUME_DIRS="$home/worktrees" \
        MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin:$PATH" \
        bash "$SEED" --user-data-dir "$udd" --project "$proj"
    [ "$status" -eq 0 ]
    [ "$(sha256sum < "$data")" = "$before" ]
    [[ "$output" == *"$db"* ]]
    [[ "$output" == *"orca state present in SQLite ($db); orca-data.json is Orca's own export -- not rewriting it"* ]]
}

@test "without a db, an orca-data.json with nothing to rewrite is left byte-identical" {
    # Guards:   the no-db rewrite fires only when at least one record
    #           still names the old default; anything else -- here two
    #           repos, neither naming it -- must not be written at all,
    #           because a needless write of the export is exactly the byte
    #           change a later Orca refuses to start over.
    # Fails if: the file changes by a single byte when no record matches.
    # Run:      setsid -w bats -f 'nothing to rewrite is left byte-identical' \
    #               tests/scratch-volumes-container.bats </dev/null
    local home="$TMP/h14" udd="$TMP/udd14" proj="$TMP/p14" data before
    mkdir -p "$home" "$udd/profiles/local-default"
    mark_mounts "$home" worktrees
    data="$udd/profiles/local-default/orca-data.json"
    cat > "$data" <<JSON
{"schemaVersion":1,"repos":[
 {"id":"a","path":"$proj","worktreeBasePath":"$proj/custom"},
 {"id":"b","path":"$proj/other","worktreeBasePath":"$proj/other/.orca-worktrees"}]}
JSON
    before="$(sha256sum < "$data")"

    run env -u PROJECT_DIR -u BEADS_DIR HOME="$home" \
        CLAUDE_ORCA_VOLUME_DIRS="$home/worktrees" \
        MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin:$PATH" \
        bash "$SEED" --user-data-dir "$udd" --project "$proj"
    [ "$status" -eq 0 ]
    [ "$(sha256sum < "$data")" = "$before" ]
    [[ "$output" == *"not seeded"* ]]
}

# --- the migration step ----------------------------------------------------

@test "shadowed caches are deleted only behind a separate mount" {
    [ -f "$PROV_STEP" ]

    # Same directory -- the container's real shape, /home/agent IS
    # $PROJECT_DIR/.claude-dev/home. Same device: the guard must leave the
    # live cache exactly where it is.
    local proj="$TMP/p6" home legacy
    proj="$TMP/p6"
    home="$proj/.claude-dev/home"
    legacy="$home/.cache"
    mkdir -p "$legacy"
    printf 'keep\n' > "$legacy/live.txt"
    mark_mounts "$home" .cache .npm .local/share/opencode worktrees

    run env -u BEADS_DIR PROJECT_DIR="$proj" HOME="$home" \
        MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin:$PATH" \
        CLAUDE_ORCA_VOLUME_DIRS="$home/.cache:$home/.npm:$home/.local/share/opencode:$home/worktrees" \
        bash "$PROV_STEP"
    [ "$status" -eq 0 ]
    [ "$(cat "$legacy/live.txt")" = "keep" ]
    [ "$(grep -cF 'not a separate mount -- untouched' <<<"$output")" -ge 1 ]
    [ "$(grep -cF "$legacy: not a separate mount -- untouched" <<<"$output")" -ge 1 ]

    # A real second filesystem: now the shadowed copies are deletable.
    local h2 p2
    h2="$(real_second_fs_home)"
    p2="$TMP/p6b"
    mkdir -p "$p2/.claude-dev/home/.cache" "$p2/.claude-dev/home/.npm" \
        "$h2/.cache" "$h2/.npm"
    printf 'l\n' > "$p2/.claude-dev/home/.cache/legacy.txt"
    printf 'n\n' > "$p2/.claude-dev/home/.npm/legacy.txt"
    printf 'v\n' > "$h2/.cache/volume-own.txt"
    mark_mounts "$h2" .cache .npm

    run env -u BEADS_DIR PROJECT_DIR="$p2" HOME="$h2" \
        MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin:$PATH" \
        CLAUDE_ORCA_VOLUME_DIRS="$h2/.cache:$h2/.npm" \
        bash "$PROV_STEP"
    [ "$status" -eq 0 ]
    [ ! -e "$p2/.claude-dev/home/.cache" ]
    [ ! -e "$p2/.claude-dev/home/.npm" ]
    [ "$(cat "$h2/.cache/volume-own.txt")" = "v" ]
}

@test "opencode data is copied before the old copy is removed and nothing on the volume is overwritten" {
    [ -f "$PROV_STEP" ]

    local proj="$TMP/p7" home vol legacy
    home="$(real_second_fs_home)"
    proj="$TMP/p7"
    vol="$home/.local/share/opencode"
    legacy="$proj/.claude-dev/home/.local/share/opencode"
    mkdir -p "$legacy" "$vol"
    printf 'legacy db\n'   > "$legacy/opencode.db"
    printf 'legacy auth\n' > "$legacy/auth.json"
    printf 'own auth\n'    > "$vol/auth.json"
    mark_mounts "$home" .local/share/opencode

    run env -u BEADS_DIR PROJECT_DIR="$proj" HOME="$home" \
        MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin:$PATH" \
        CLAUDE_ORCA_VOLUME_DIRS="$home/.local/share/opencode" \
        bash "$PROV_STEP"
    [ "$status" -eq 0 ]

    [ "$(cat "$vol/opencode.db")" = "legacy db" ]
    [ "$(cat "$vol/auth.json")" = "own auth" ]
    [ "$(cat "$vol/auth.json.from-home")" = "legacy auth" ]
    [ -f "$vol/.migrated-from-home" ]
    [ ! -e "$vol/.migrating" ]
    [ ! -e "$legacy" ]
}

@test "a failed copy leaves the old data where it was" {
    [ -f "$PROV_STEP" ]

    local proj="$TMP/p8" home vol legacy
    home="$(real_second_fs_home)"
    proj="$TMP/p8"
    vol="$home/.local/share/opencode"
    legacy="$proj/.claude-dev/home/.local/share/opencode"
    mkdir -p "$legacy" "$vol"
    printf 'legacy db\n'   > "$legacy/opencode.db"
    printf 'legacy auth\n' > "$legacy/auth.json"
    mark_mounts "$home" .local/share/opencode

    mkdir -p "$TMP/bin-cpfail"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin-cpfail/cp"
    chmod +x "$TMP/bin-cpfail/cp"

    run env -u BEADS_DIR PROJECT_DIR="$proj" HOME="$home" \
        MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin-cpfail:$TMP/bin:$PATH" \
        CLAUDE_ORCA_VOLUME_DIRS="$home/.local/share/opencode" \
        bash "$PROV_STEP"
    [ "$status" -ne 0 ]

    [ -f "$legacy/opencode.db" ]
    [ -f "$legacy/auth.json" ]
    [ ! -e "$vol/.migrated-from-home" ]
    [ ! -e "$vol/.migrating" ]
}

@test "the step is idempotent" {
    [ -f "$PROV_STEP" ]

    local proj="$TMP/p9" home vol legacy before
    home="$(real_second_fs_home)"
    proj="$TMP/p9"
    vol="$home/.local/share/opencode"
    legacy="$proj/.claude-dev/home/.local/share/opencode"
    mkdir -p "$legacy" "$home/.cache" "$proj/.claude-dev/home/.cache" "$vol"
    printf 'legacy db\n'   > "$legacy/opencode.db"
    printf 'legacy auth\n' > "$legacy/auth.json"
    printf 'l\n' > "$proj/.claude-dev/home/.cache/legacy.txt"
    mark_mounts "$home" .cache .local/share/opencode

    run env -u BEADS_DIR PROJECT_DIR="$proj" HOME="$home" \
        MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin:$PATH" \
        CLAUDE_ORCA_VOLUME_DIRS="$home/.cache:$home/.local/share/opencode" \
        bash "$PROV_STEP"
    [ "$status" -eq 0 ]
    [ -f "$vol/.migrated-from-home" ]

    before="$(find "$home" -mindepth 1 | sort)"
    run env -u BEADS_DIR PROJECT_DIR="$proj" HOME="$home" \
        MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin:$PATH" \
        CLAUDE_ORCA_VOLUME_DIRS="$home/.cache:$home/.local/share/opencode" \
        bash "$PROV_STEP"
    [ "$status" -eq 0 ]
    [ "$(find "$home" -mindepth 1 | sort)" = "$before" ]
    [ ! -e "$legacy" ]
}

# --- the legacy dir the step cannot remove (claude-orca-d89) ---------------
#
# On the Mac, $PROJECT_DIR/.claude-dev/home/<rel> IS the scratch volume's
# mount point in the /workspace view, so the rmdir of the emptied legacy
# dir fails EBUSY on every boot. The parent being read-only (chmod 555)
# denies the same rmdir on this box; the contents inside are still
# deletable, which is exactly the shape being contracted for.

@test "a shadowed cache whose dir cannot be removed is emptied, and the log says so" {
    # Guards: step 45 empties a legacy cache dir it cannot remove itself
    # (the dir stays -- it is the volume's mount point), reports
    # 'emptied shadowed', and never claims 'removed shadowed' nor leaks an
    # rm/rmdir error into the log; a second run says 'already empty'.
    # Fails if: the step claims a removal that did not happen, its log
    # carries 'cannot remove'/'rmdir:' noise, the contents survive, or the
    # second run is not clean.
    # Run: setsid -w bats tests/scratch-volumes-container.bats </dev/null
    local proj home legacy
    home="$(real_second_fs_home)"
    proj="$TMP/p10"
    legacy="$proj/.claude-dev/home/.cache"
    mkdir -p "$legacy" "$home/.cache"
    printf 'l\n' > "$legacy/legacy.txt"
    printf 'v\n' > "$home/.cache/volume-own.txt"
    mark_mounts "$home" .cache
    chmod 555 "$proj/.claude-dev/home"

    run env -u BEADS_DIR PROJECT_DIR="$proj" HOME="$home" \
        MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin:$PATH" \
        CLAUDE_ORCA_VOLUME_DIRS="$home/.cache" \
        bash "$PROV_STEP"
    chmod u+w "$proj/.claude-dev/home"
    [ "$status" -eq 0 ]
    [ ! -e "$legacy/legacy.txt" ]
    [ -d "$legacy" ]
    [ "$(cat "$home/.cache/volume-own.txt")" = "v" ]
    [[ "$output" == *"emptied shadowed"* ]]
    [[ "$output" != *"removed shadowed"* ]]
    [[ "$output" != *"cannot remove"* ]]
    [[ "$output" != *"rmdir:"* ]]

    run env -u BEADS_DIR PROJECT_DIR="$proj" HOME="$home" \
        MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin:$PATH" \
        CLAUDE_ORCA_VOLUME_DIRS="$home/.cache" \
        bash "$PROV_STEP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"is already empty"* ]]
}

@test "an already-migrated opencode legacy whose dir cannot be removed is emptied, and the log says so" {
    # Guards: the opencode 'already migrated' path empties a legacy dir it
    # cannot remove itself and reports it in the same honest vocabulary as
    # the cache branch -- 'emptied shadowed', never 'removed shadowed',
    # never an rm/rmdir error line; a second run says 'already empty'.
    # Fails if: the already-migrated branch claims a removal that did not
    # happen, leaks error text into the log, or leaves contents behind.
    # Run: setsid -w bats tests/scratch-volumes-container.bats </dev/null
    local proj home vol legacy
    home="$(real_second_fs_home)"
    proj="$TMP/p11"
    vol="$home/.local/share/opencode"
    legacy="$proj/.claude-dev/home/.local/share/opencode"
    mkdir -p "$legacy" "$vol"
    printf 'l\n' > "$legacy/legacy.txt"
    printf 'own\n' > "$vol/auth.json"
    : > "$vol/.migrated-from-home"
    mark_mounts "$home" .local/share/opencode
    chmod 555 "$proj/.claude-dev/home/.local/share"

    run env -u BEADS_DIR PROJECT_DIR="$proj" HOME="$home" \
        MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin:$PATH" \
        CLAUDE_ORCA_VOLUME_DIRS="$home/.local/share/opencode" \
        bash "$PROV_STEP"
    chmod u+w "$proj/.claude-dev/home/.local/share"
    [ "$status" -eq 0 ]
    [ ! -e "$legacy/legacy.txt" ]
    [ -d "$legacy" ]
    [ "$(cat "$vol/auth.json")" = "own" ]
    [[ "$output" == *"emptied shadowed"* ]]
    [[ "$output" != *"removed shadowed"* ]]
    [[ "$output" != *"cannot remove"* ]]
    [[ "$output" != *"rmdir:"* ]]

    run env -u BEADS_DIR PROJECT_DIR="$proj" HOME="$home" \
        MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin:$PATH" \
        CLAUDE_ORCA_VOLUME_DIRS="$home/.local/share/opencode" \
        bash "$PROV_STEP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"is already empty"* ]]
}

@test "contents that cannot be emptied fail the step and say so" {
    # Guards: when the shadowed contents themselves survive (here the
    # legacy dir is read-only, so its entries cannot be deleted), the step
    # exits 1 with 'could not empty' on stderr instead of claiming success.
    # Fails if: the step exits 0, claims any removal, or leaves no
    # diagnostic behind.
    # Run: setsid -w bats tests/scratch-volumes-container.bats </dev/null
    local proj home legacy
    home="$(real_second_fs_home)"
    proj="$TMP/p12"
    legacy="$proj/.claude-dev/home/.cache"
    mkdir -p "$legacy" "$home/.cache"
    printf 'l\n' > "$legacy/legacy.txt"
    mark_mounts "$home" .cache
    chmod 555 "$legacy"

    run env -u BEADS_DIR PROJECT_DIR="$proj" HOME="$home" \
        MOUNTS_FILE="$TMP/mounts" PATH="$TMP/bin:$PATH" \
        CLAUDE_ORCA_VOLUME_DIRS="$home/.cache" \
        bash "$PROV_STEP"
    chmod u+w "$legacy"
    [ "$status" -eq 1 ]
    [ -f "$legacy/legacy.txt" ]
    [[ "$output" == *"could not empty"* ]]
    [[ "$output" != *"removed shadowed"* ]]
}
