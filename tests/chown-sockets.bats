#!/usr/bin/env bats
#
# The folder home is a bind mount, and chown on a unix domain socket over
# that mount returns EINVAL. Orca leaves sockets in ~/.config/orca between
# boots, so `chown -R agent:agent /home/agent` in setup.sh's phase_user
# died on one -- seen on a real Mac run:
#
#   chown: changing ownership of '/home/agent/.config/orca/o-7563-9c89.sock': Invalid argument
#
# setup.sh runs under `set -Eeuo pipefail`, so that took setup.sh, the
# entrypoint and the container with it, on every restart from then on:
# once a socket was left behind the folder could not boot again.
#
# These cases run the real chown logic lifted out of the scripts, as this
# box's unprivileged user, against a fixture holding a real AF_UNIX
# socket. A no-op chown to the current user/group is what isolates the
# file-type behaviour from permissions, which is the only thing a
# non-root run could otherwise be measuring.
#
# This filesystem is overlayfs, where chown on a socket happens to
# succeed, so the EINVAL itself is modelled by a chown shim that refuses
# sockets exactly as the bind mount does. The shim is what makes the
# non-vacuity case honest: under it, the old `chown -R` form fails and
# the new form does not.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SETUP_SH="$REPO_ROOT/scripts/container/setup.sh"
ENTRYPOINT="$REPO_ROOT/scripts/container/entrypoint.sh"

# AF_UNIX paths cap at ~108 bytes, so the fixture lives under a short
# /tmp prefix (same reason as tests/container-entrypoint-seed.bats).
setup() {
    TMP="$(mktemp -d /tmp/co-chown-XXXXXX)"
    export TMP
    ME="$(id -un):$(id -gn)"
}

teardown() {
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
    return 0
}

# A home-shaped tree: a regular file, a subdirectory with a file in it,
# and a real unix domain socket where Orca puts its own.
make_home() {
    local home="$1"
    mkdir -p "$home/.config/orca" "$home/.claude"
    printf 'x\n' > "$home/.zshrc"
    printf 'y\n' > "$home/.claude/settings.json"
    python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])' "$home/.config/orca/o-7563-9c89.sock"
    [ -S "$home/.config/orca/o-7563-9c89.sock" ]
}

# chown as the bind mount behaves: EINVAL on a socket, real chown
# otherwise, GNU semantics (report, keep going, exit non-zero). Every
# path it is asked to change is appended to $CHOWN_LOG, so a test can
# tell "skipped the socket" from "did nothing".
write_chown_shim() {
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/chown" <<'SHIM'
#!/usr/bin/env bash
# The real tools, wherever this box keeps them: coreutils lives in
# /usr/bin on Linux and /usr/sbin (chown) on macOS, and hardcoding the
# Linux path is why this shim could only ever run on Linux.
real_chown=/usr/bin/chown; [ -x "$real_chown" ] || real_chown=/usr/sbin/chown
real_find=/usr/bin/find;   [ -x "$real_find" ]  || real_find=/usr/sbin/find
recurse=0
nodereference=0
owner=""
rc=0
targets=()
for a in "$@"; do
    case "$a" in
        -*R*) recurse=1 ;;
        -*h*) nodereference=1 ;;
        -*)   ;;
        *)    if [ -z "$owner" ]; then owner="$a"; else targets+=("$a"); fi ;;
    esac
done
expanded=()
for t in "${targets[@]}"; do
    if [ "$recurse" = "1" ] && [ -d "$t" ]; then
        while IFS= read -r -d '' f; do expanded+=("$f"); done \
            < <("$real_find" "$t" -print0)
    else
        expanded+=("$t")
    fi
done
for t in "${expanded[@]}"; do
    printf '%s\n' "$t" >> "$CHOWN_LOG"
    if [ -S "$t" ]; then
        printf "chown: changing ownership of '%s': Invalid argument\n" "$t" >&2
        rc=1
        continue
    fi
    # GNU chown follows a symlink unless -h, and says so when the target
    # is not there. macOS's chown returns 0 on the same dangling link, so
    # without this the non-vacuity half of the dangling case would be
    # measuring the local chown rather than the shipped one.
    if [ -L "$t" ] && [ ! -e "$t" ] && [ "$nodereference" = "0" ]; then
        printf "chown: cannot dereference '%s': No such file or directory\n" "$t" >&2
        rc=1
        continue
    fi
    if [ "$nodereference" = "1" ]; then
        "$real_chown" -h "$owner" "$t" || rc=1
    else
        "$real_chown" "$owner" "$t" || rc=1
    fi
done
exit $rc
SHIM
    chmod +x "$TMP/bin/chown"
    : > "$TMP/chown.log"
}

# The chown phase_user actually runs, lifted from setup.sh and pointed at
# the fixture instead of /home/agent.
lift_phase_user_chown() {
    # The range has to END on the xargs line as setup.sh really spells it,
    # `chown -h agent:agent`. Matching `chown agent:agent` closed no range
    # at all, so sed printed from the find line to the end of the file and
    # the "lifted function" was 236 lines of invalid bash. The -h is
    # optional in the pattern so the range survives either spelling; that
    # -h is asserted on its own below.
    sed -n '/^ *find \/home\/agent -xdev/,/xargs -0 -r chown \(-h \)\{0,1\}agent:agent/p' \
        "$SETUP_SH"
}

@test "setup.sh phase_user chowns a home containing a live unix socket without failing" {
    lifted="$(lift_phase_user_chown)"
    [[ "$lifted" == *"! -type s"* ]]
    [[ "$lifted" == *"xargs -0 -r chown -h agent:agent"* ]]

    home="$TMP/home"
    make_home "$home"

    # The real command, with the real chown, under phase_user's own
    # shell options.
    run bash -c "set -Eeuo pipefail
${lifted//\/home\/agent/$home}"
    [ "$status" -eq 0 ]

    # The socket is still there: nothing was deleted to make chown work.
    [ -S "$home/.config/orca/o-7563-9c89.sock" ]
    [ -f "$home/.claude/settings.json" ]
}

@test "the old chown -R form is what the socket kills, and the new one survives it" {
    write_chown_shim
    home="$TMP/home"
    make_home "$home"

    # OLD form: this is the line that aborted setup.sh on the Mac.
    : > "$TMP/old.log"
    run env PATH="$TMP/bin:$PATH" CHOWN_LOG="$TMP/old.log" \
        bash -c "set -Eeuo pipefail; chown -R $ME '$home'; echo REACHED_END"
    [ "$status" -ne 0 ]
    [[ "$output" == *"o-7563-9c89.sock"* ]]
    [[ "$output" == *"Invalid argument"* ]]
    [[ "$output" != *"REACHED_END"* ]]

    # NEW form: same fixture, same shim, same shell options.
    lifted="$(lift_phase_user_chown)"
    : > "$TMP/new.log"
    run env PATH="$TMP/bin:$PATH" CHOWN_LOG="$TMP/new.log" \
        bash -c "set -Eeuo pipefail
${lifted//\/home\/agent/$home}
echo REACHED_END"
    [ "$status" -eq 0 ]
    [[ "$output" == *"REACHED_END"* ]]
    [[ "$output" != *"Invalid argument"* ]]

    # ...and it was not vacuous: chown saw the real files and never the
    # socket.
    run grep -c 'settings.json' "$TMP/new.log"
    [ "$output" = "1" ]
    run grep -c 'o-7563-9c89.sock' "$TMP/new.log"
    [ "$output" = "0" ]
}

@test "setup.sh no longer carries a blanket chown -R over the folder home" {
    run grep -n 'chown -R agent:agent /home/agent' "$SETUP_SH"
    [ "$status" -ne 0 ]
}

@test "the entrypoint's recursive chowns skip sockets and stay non-fatal" {
    write_chown_shim
    fn="$(sed -n '/^chown_agent_tree()/,/^}/p' "$ENTRYPOINT")"
    [[ "$fn" == *"! -type s"* ]]

    # Every -R chown on this side goes through the helper (comments
    # naming the old form do not count).
    run grep -nE '^[^#]*chown -R' "$ENTRYPOINT"
    [ "$status" -ne 0 ]

    home="$TMP/home"
    make_home "$home"
    : > "$TMP/ep.log"

    run env PATH="$TMP/bin:$PATH" CHOWN_LOG="$TMP/ep.log" \
        bash -c "set -uo pipefail
AGENT_UID='$(id -u)'
AGENT_GID='$(id -g)'
$fn
chown_agent_tree '$home'
echo REACHED_END"
    [ "$status" -eq 0 ]
    [[ "$output" == *"REACHED_END"* ]]

    run grep -c 'settings.json' "$TMP/ep.log"
    [ "$output" = "1" ]
    run grep -c 'o-7563-9c89.sock' "$TMP/ep.log"
    [ "$output" = "0" ]

    # A missing directory is not fatal either.
    run env PATH="$TMP/bin:$PATH" CHOWN_LOG="$TMP/ep.log" \
        bash -c "set -uo pipefail
AGENT_UID='$(id -u)'
AGENT_GID='$(id -g)'
$fn
chown_agent_tree '$TMP/nope'
echo REACHED_END"
    [ "$status" -eq 0 ]
    [[ "$output" == *"REACHED_END"* ]]
}

# --- and the other thing that outlives a container: a dangling symlink ---
#
# Orca leaves SingletonCookie -> <cookie>, SingletonLock -> <host>-<pid>
# and SingletonSocket -> /tmp/scoped_dir.../SingletonSocket in its
# user-data dir. That dir is a docker volume now, so it survives the
# container that made it and all three point at nothing on the next start.
# Plain chown follows a symlink: "cannot dereference", xargs 123,
# pipefail, and setup.sh takes the container with it -- on every recreate,
# which is exactly the shape of the socket bug this file was written for.
#
# CI run 34154457951 caught it on Linux. A Mac does not see it: .config/orca
# is a different DEVICE there (a docker volume against virtiofs) so `find
# -xdev` never descends into it, while on Linux both live on the same
# filesystem and it does. -h makes the device question irrelevant.

make_home_with_dangling_links() {
    local home="$1"
    mkdir -p "$home/.config/orca"
    printf 'x\n' > "$home/.zshrc"
    ln -s "16491037762841382642" "$home/.config/orca/SingletonCookie"
    ln -s "068b8e393ba3-7473" "$home/.config/orca/SingletonLock"
    ln -s "/tmp/scoped_dirGone/SingletonSocket" "$home/.config/orca/SingletonSocket"
    [ -L "$home/.config/orca/SingletonLock" ]
    [ ! -e "$home/.config/orca/SingletonLock" ]
}

@test "setup.sh's phase_user chowns a home whose Orca links dangle, instead of dying on them" {
    local home="$TMP/home"
    make_home_with_dangling_links "$home"

    # Through the shim, for the same reason the socket cases use it: this
    # box's own chown returns 0 on a dangling symlink where GNU's does not,
    # so the local one would answer a question about macOS rather than
    # about the image.
    write_chown_shim

    # The real command, lifted out of phase_user.
    run env PATH="$TMP/bin:$PATH" CHOWN_LOG="$TMP/dangling.log" \
        bash -c "set -Eeuo pipefail
find '$home' -xdev ! -type s -print0 | xargs -0 -r chown -h $ME"
    [ "$status" -eq 0 ]

    # Non-vacuity: without -h the same command fails on the same tree.
    run env PATH="$TMP/bin:$PATH" CHOWN_LOG="$TMP/dangling.log" \
        bash -c "set -Eeuo pipefail
find '$home' -xdev ! -type s -print0 | xargs -0 -r chown $ME"
    [ "$status" -ne 0 ]

    # And the links are still links, pointing where Orca left them.
    [ -L "$home/.config/orca/SingletonLock" ]
    [ "$(readlink "$home/.config/orca/SingletonLock")" = "068b8e393ba3-7473" ]
}

@test "the shipped chowns both pass -h" {
    run grep -qE 'xargs -0 -r chown -h agent:agent' "$SETUP_SH"
    [ "$status" -eq 0 ]
    run grep -qE 'xargs -0 -r chown -h "\$AGENT_UID:\$AGENT_GID"' "$ENTRYPOINT"
    [ "$status" -eq 0 ]
}
