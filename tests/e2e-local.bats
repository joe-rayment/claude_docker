#!/usr/bin/env bats
#
# Guards:   the REAL launcher, run the way bootstrap.sh runs it, brings a folder up on the local runtime -- the real entrypoint starts a real sshd, the launcher writes the ssh config and keys, and a real ssh (and `claude-dev pane`) gets in, lands in the folder's project path, and verifies the host key
# Fails if: register stops reaching "sshd is up", run/sshd.ready is not written, the ssh config the launcher wrote does not let `ssh <alias>` in with the host key verified, the doctor's sshd / ssh master / ssh key auth rows go red, `claude-dev pane` does not give a shell in the project, or `claude-dev stop` leaves a process of this run behind
# Run:      bats tests/e2e-local.bats
#
# The one end-to-end case in this repo. No stubs are loaded here at all --
# helpers/setup.bash is deliberately NOT sourced, because everything it puts
# on PATH (docker, open, gh, uname) is the opposite of what this case is for.
#
# Why it can run at all: a container cannot be started on this box. Its
# capability set is empty (CapEff 0000000000000000, no CAP_SYS_ADMIN in the
# bounding set), so mount and unshare fail even for root and docker, podman
# and a private dockerd all die the same way. CLAUDE_ORCA_RUNTIME=local is
# the launcher's second backend: it runs the same entrypoint, with the same
# environment contract, as an ordinary host process. Everything above the
# runtime boundary -- the launcher's argv, the entrypoint, the ssh key and
# config files, sshd, the ControlMaster, the pane -- is the same code the
# container path runs.
#
# Environment facts this case works around, none of them a weakening of
# what it asserts:
#   * A unix socket path is capped at ~108 bytes and the launcher's
#     ControlPath is $HOME/.local/state/claude-dev/cm-%C, so HOME and the
#     project go in a SHORT directory of their own (/tmp/cdev-e2e-XXXXXX)
#     rather than under $BATS_TEST_TMPDIR.
#   * The ssh tools are not on PATH on this box. Real OpenSSH 9.6 binaries
#     are extracted (no root) under ~/.cache/claude-orca-test/openssh and
#     run through three one-line wrappers that only add LD_LIBRARY_PATH.
#     A box with ssh, ssh-keygen and sshd on PATH needs no extraction.
#   * Peers on this box run their own sessions, so teardown matches only
#     processes whose argv carries THIS run's directory, never a bare name.

# bats file_tags=size:medium

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"

# Read at file level, before setup() points HOME at the fixture.
E2E_OPENSSH="${E2E_OPENSSH:-$HOME/.cache/claude-orca-test/openssh}"
E2E_NC="${E2E_NC:-$HOME/.cache/claude-orca-test/netcat/bin/nc.openbsd}"
E2E_PTY_DRIVER="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd -P)/e2e-pty-pane.py"

E2E_CLIP_PNG="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd -P)/fixtures/clipboard/red-8x8.png"

# The launcher's own wait for sshd is bounded; this is the outer belt.
E2E_TIMEOUT=240

# e2e_wrap <name> <real binary> -- a wrapper that adds the extracted libs.
e2e_wrap() {
    local lib="" d
    for d in "$E2E_OPENSSH"/usr/lib/*-linux-gnu; do
        [ -d "$d" ] && lib="$d"
    done
    printf '#!/bin/sh\nLD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\nexport LD_LIBRARY_PATH\nexec "%s" "$@"\n' \
        "$lib" "$2" > "$E2E_BIN/$1"
    chmod +x "$E2E_BIN/$1"
}

# The three ssh tools: the extracted ones when present, else the box's own.
e2e_ssh_tools() {
    local t real
    mkdir -p "$E2E_BIN"
    for t in ssh ssh-keygen sshd; do
        real="$E2E_OPENSSH/usr/bin/$t"
        [ "$t" = sshd ] && real="$E2E_OPENSSH/usr/sbin/sshd"
        if [ -x "$real" ]; then
            e2e_wrap "$t" "$real"
        elif command -v "$t" >/dev/null 2>&1; then
            e2e_wrap "$t" "$(command -v "$t")"
        else
            return 1
        fi
    done
}

setup() {
    command -v python3 >/dev/null 2>&1 || skip "no python3 on this box"

    # A short path, for the unix-socket limit, and unique, so teardown can
    # match this run's processes and only this run's.
    E2E_ROOT="$(mktemp -d /tmp/cdev-e2e-XXXXXX)"
    E2E_PROJECT="$E2E_ROOT/p"
    E2E_BIN="$E2E_ROOT/bin"
    e2e_ssh_tools || skip "no OpenSSH: neither $E2E_OPENSSH nor ssh/ssh-keygen/sshd on PATH"
    mkdir -p "$E2E_PROJECT/.claude-dev/template" "$E2E_ROOT/tmp" "$E2E_ROOT/rt"

    git -C "$E2E_PROJECT" init --quiet -b main
    git -C "$E2E_PROJECT" -c user.email=e2e@example.com -c user.name=e2e \
        commit --quiet --allow-empty -m init

    # The template clone a real folder carries, taken from the WORKING tree
    # rather than from HEAD: this case must exercise the launcher as edited.
    tar -cf - -C "$REPO_ROOT" \
        --exclude=.git --exclude=node_modules --exclude=__pycache__ . \
        | tar -xf - -C "$E2E_PROJECT/.claude-dev/template"
    "$E2E_PROJECT/.claude-dev/template/scripts/link-bin.sh" "$E2E_PROJECT/.claude-dev"

    # Every launcher and ssh call below inherits this environment. HOME,
    # PROJECT_DIR, CLAUDE_ORCA_ROOT and BEADS_DIR all point at the fixture:
    # the shell this runs in carries the real project's values, and a stray
    # one would make the run touch the real tracker or the real tree.
    export HOME="$E2E_ROOT"
    export PROJECT_DIR="$E2E_PROJECT" CLAUDE_ORCA_ROOT="$E2E_PROJECT"
    export BEADS_DIR="$E2E_PROJECT/.beads" TMPDIR="$E2E_ROOT/tmp"
    unset BEADS_ACTOR CLAUDE_ORCA_IMAGE CLAUDE_ORCA_PROJECT_NAME CLAUDE_ORCA_HOST_PROJECT_DIR
    export PATH="$E2E_BIN:$PATH"
    export CLAUDE_ORCA_RUNTIME=local CLAUDE_ORCA_OPEN=0 CLAUDE_ORCA_PORT_BASE=7810
    export CLAUDE_ORCA_RUNTIME_DIR="$E2E_ROOT/rt" CLAUDE_ORCA_PANE_SHELL=/bin/bash
    export CLAUDE_ORCA_SSH="$E2E_BIN/ssh" CLAUDE_ORCA_SSH_KEYGEN="$E2E_BIN/ssh-keygen"
    export CLAUDE_ORCA_SSHD_BIN="$E2E_BIN/sshd"
    E2E_CLAUDE_DEV="$E2E_PROJECT/.claude-dev/bin/claude-dev"
    E2E_CFG="$E2E_PROJECT/.claude-dev/state/ssh/config"
}

# The folder's own way down: close the ssh master, then the launcher's stop
# for the local runtime. Used by the case and, as a net, by teardown.
e2e_stop() {
    if [ -f "$E2E_CFG" ]; then
        "$E2E_BIN/ssh" -F "$E2E_CFG" -O exit "$(e2e_alias)" >/dev/null 2>&1 || true
    fi
    if [ -x "$E2E_CLAUDE_DEV" ]; then
        timeout 60 "$E2E_CLAUDE_DEV" stop </dev/null >/dev/null 2>&1 || true
    fi
}

# The Host alias the launcher wrote on the first line of the ssh config.
e2e_alias() {
    awk '/^Host /{print $2; exit}' "$E2E_CFG"
}

# Pids of every process whose argv carries this run's directory (pgrep
# leaves itself out). Empty means the run left nothing behind.
e2e_leftovers() {
    pgrep -f -- "$E2E_ROOT" || true
}

teardown() {
    [ -n "${E2E_ROOT:-}" ] || return 0
    e2e_stop
    # Net: anything of THIS run still alive is killed -- only by the
    # fixture dir in its argv, never by a bare process name.
    pkill -f -- "$E2E_ROOT" 2>/dev/null || true
    sleep 1
    pkill -KILL -f -- "$E2E_ROOT" 2>/dev/null || true
    # The clipboard case's RemoteForward ends at the host's own /tmp.
    [ -z "${E2E_CLIP_USED:-}" ] || rm -f /tmp/cdev-clip.sock
    rm -rf "$E2E_ROOT"
}

# e2e_register -- the entry bootstrap.sh ends on: `claude-dev register <dir>`.
e2e_register() {
    timeout "$E2E_TIMEOUT" "$E2E_CLAUDE_DEV" register "$E2E_PROJECT" </dev/null
}

@test "end to end on the local runtime: register brings sshd up, ssh gets in with the host key verified, the doctor is green on the ssh rows, stop leaves nothing" {
    run e2e_register
    echo "$output" >&2
    [ "$status" -eq 0 ]
    [[ "$output" == *"sshd is up"* ]]
    [ -e "$E2E_PROJECT/.claude-dev/run/sshd.ready" ]
    # The launcher's `ctr exec -u agent ... config-sync.sh` reached the real
    # script (the local runtime once took "agent" for the container name).
    [[ "$output" == *"config: already current"* || "$output" == *"config: re-synced"* ]]
    [[ "$output" != *"could not re-sync"* ]]

    # The config the launcher wrote is what ssh uses, untouched: strict host
    # key checking stays on, so a first connection that works means the
    # host key the entrypoint staged IS the one the launcher pinned.
    [ -f "$E2E_CFG" ]
    grep -Eq '^[[:space:]]*StrictHostKeyChecking[[:space:]]+yes' "$E2E_CFG"
    alias_="$(e2e_alias)"
    [ -n "$alias_" ]

    run "$E2E_BIN/ssh" -F "$E2E_CFG" "$alias_" pwd
    echo "$output" >&2
    [ "$status" -eq 0 ]
    [ "$output" = "$(cd "$E2E_PROJECT" && pwd -P)" ]
    [[ "$output" != *"Permanently added"* ]]

    # The master the call above started is up, then the doctor reads all
    # three ssh rows green (the master row is asked before key auth).
    run timeout 120 "$E2E_CLAUDE_DEV" --doctor </dev/null
    echo "$output" >&2
    [[ "$output" =~ \[ok\ +\]\ +sshd ]]
    [[ "$output" =~ \[ok\ +\]\ +ssh\ master ]]
    [[ "$output" =~ \[ok\ +\]\ +ssh\ key\ auth ]]

    # The launcher's own stop, then nothing of this run is left running.
    e2e_stop
    local i=0
    while [ "$i" -lt 20 ] && [ -n "$(e2e_leftovers)" ]; do
        sleep 1
        i=$((i + 1))
    done
    left="$(e2e_leftovers)"
    [ -z "$left" ] || { ps -o pid,args -p "$(echo $left | tr ' ' ',')" >&2; false; }
}

@test "end to end on the local runtime: claude-dev pane, run on a real pty, gives a shell in the project and leaves the ssh master up" {
    run e2e_register
    echo "$output" >&2
    [ "$status" -eq 0 ]

    # The pane is `exec ssh -tt <alias>`, so it needs a terminal: a pty
    # driver stands in for the Ghostty tab (it answers the kitty keyboard
    # and XTVERSION probes the way Ghostty does), runs the pane, types one
    # command line into it and prints what the terminal showed.
    run timeout 180 python3 -I "$E2E_PTY_DRIVER" "$E2E_CLAUDE_DEV" pane "$E2E_PROJECT"
    echo "$output" >&2
    [ "$status" -eq 0 ]
    real="$(cd "$E2E_PROJECT" && pwd -P)"
    # `pwd` printed the project on a line of its own (the prompt shows the
    # path too, so a bare substring match would prove nothing).
    printf '%s\n' "$output" | grep -qx -- "$real"
    [[ "$output" =~ PANE-OK-[0-9]+ ]]
    # No master was up, so this was the launcher's whole-bring-up path.
    grep -q ' slow ' "$E2E_PROJECT/.claude-dev/run/pane.log"

    # The pane left a ControlMaster behind (ControlPersist), under HOME's
    # literal state dir -- the path the launcher's ssh config names.
    run ls "$E2E_ROOT"/.local/state/claude-dev/cm-*
    echo "$output" >&2
    [ "$status" -eq 0 ]
    run "$E2E_BIN/ssh" -F "$E2E_CFG" -O check "$(e2e_alias)"
    [ "$status" -eq 0 ]

    e2e_stop
    local i=0
    while [ "$i" -lt 20 ] && [ -n "$(e2e_leftovers)" ]; do
        sleep 1
        i=$((i + 1))
    done
    left="$(e2e_leftovers)"
    [ -z "$left" ] || { ps -o pid,args -p "$(echo $left | tr ' ' ',')" >&2; false; }
}

# e2e_clip_env -- the Mac half of the clipboard bridge, with the one thing
# that cannot exist on Linux replaced: `osascript` (it reads the Mac
# pasteboard). Everything else is the real code -- the launcher starts the
# real scripts/mac/clip-listen (a real netcat on a unix socket) and
# clip-serve, ssh's RemoteForward carries the socket into the "container",
# and the pane's `xclip` is the real shim. The stub answers from a mode file
# ($E2E_ROOT/clip.mode: "png" = an image on the pasteboard, anything else =
# plain text) and logs every call so the case can see what the Mac was asked.
e2e_clip_env() {
    [ -x "$E2E_NC" ] || skip "no OpenBSD netcat at $E2E_NC"
    cp "$E2E_NC" "$E2E_BIN/nc"
    export E2E_ROOT E2E_CLIP_PNG
    mkdir -p "$E2E_ROOT/stubs"
    printf 'png\n' > "$E2E_ROOT/clip.mode"
    cat > "$E2E_ROOT/stubs/osascript" <<'EOF'
#!/bin/bash
all="$*"
printf 'osascript %s\n' "$all" >>"$E2E_ROOT/osascript.log"
mode="$(cat "$E2E_ROOT/clip.mode" 2>/dev/null)"
case "$all" in
    *'clipboard info'*)
        if [ "$mode" = png ]; then
            printf '%s\n' '«class PNGf», 75, «class TIFF», 80'
        else
            printf '%s\n' '«class utf8», 12, string, 12'
        fi
        exit 0 ;;
    *'open for access'*)
        [ "$mode" = png ] || exit 1
        dest=$(printf '%s\n' "$all" | sed -n 's/.*POSIX file "\([^"]*\)".*/\1/p')
        [ -n "$dest" ] || exit 1
        cp "$E2E_CLIP_PNG" "$dest"
        exit 0 ;;
esac
exit 1
EOF
    chmod +x "$E2E_ROOT/stubs/osascript"
    export CLAUDE_ORCA_OSASCRIPT="$E2E_ROOT/stubs/osascript"
    export CLAUDE_ORCA_SIPS=/bin/false CLAUDE_ORCA_PBCOPY=/bin/false
    # The listener ends by itself once the ssh master is gone; a short poll
    # keeps the case's wait for that short.
    export CLAUDE_ORCA_CLIP_WATCH_S=3
    # The forward's far end is /tmp/cdev-clip.sock, and on the local runtime
    # /tmp is the host's: teardown removes the socket this run left there.
    E2E_CLIP_USED=1
}

# e2e_clip_pane_script -- what the pane runs: plain `xclip` (found through the
# pane's own PATH, which is what the test then asserts is the template's shim)
# giving its three answers with an image on the pasteboard, then with text.
# Paths are baked in (the local
# runtime shares the filesystem), so the heredoc is unquoted; the \$ ones are
# the pane's own. The DONE marker is arithmetic so the typed command line
# cannot satisfy a match on its output.
e2e_clip_pane_script() {
    cat > "$E2E_ROOT/pane-clip.sh" <<EOF
echo "XCLIP-WHICH=\$(command -v xclip)"
echo "PATH-HEAD=\${PATH%%:*}"
echo "TARGETS-PNG=[\$(xclip -selection clipboard -t TARGETS -o)]"
xclip -selection clipboard -t image/png -o | cmp - "$E2E_CLIP_PNG"
echo "CMP-RC=\$?"
echo "DONE1-\$((6*7))"
echo text > "$E2E_ROOT/clip.mode"
echo "TARGETS-TEXT=[\$(xclip -selection clipboard -t TARGETS -o)]"
OUT="\$(xclip -selection clipboard -o)"
echo "TEXTREAD-RC=\$? OUT=[\$OUT]"
xclip -selection clipboard -t image/png -o >/dev/null
echo "PNGREAD-AFTER-RC=\$?"
echo "DONE2-\$((6*7))"
EOF
}

# Guards:   the clipboard bridge end to end -- with an image on the (stubbed) Mac pasteboard, the shim `xclip` run INSIDE a real pane reads TARGETS=image/png and the exact PNG bytes through the pane's ssh RemoteForward, the real clip-listen and clip-serve; once the pasteboard holds text, the same calls get nothing, the Mac is asked only `clipboard info` (never to read the text out), and stop leaves no listener behind
# Fails if: the launcher stops starting clip-listen on a pane, the config's RemoteForward line goes missing or points at the wrong socket, the shim speaks a different protocol than clip-serve, an image comes through altered, text on the pasteboard is ever served to the pane, or a stop leaves a clip-listen / nc of this run alive
# Run:      bats -f 'clipboard bridge' tests/e2e-local.bats
@test "end to end on the local runtime: clipboard bridge -- a pane's xclip gets the Mac's image bytes through the real forward, gets nothing for text, and stop leaves no listener" {
    e2e_clip_env
    run e2e_register
    echo "$output" >&2
    [ "$status" -eq 0 ]
    e2e_clip_pane_script

    # The pane runs the script and exits; the driver prints what it showed.
    E2E_PANE_LINE="bash $E2E_ROOT/pane-clip.sh; exit" E2E_PANE_WAIT=60 \
        run timeout 180 python3 -I "$E2E_PTY_DRIVER" "$E2E_CLAUDE_DEV" pane "$E2E_PROJECT"
    echo "$output" >&2
    [ "$status" -eq 0 ]
    # The marker lines are computed (6*7), so the typed command line, which
    # the terminal echoes, can never be mistaken for the output.
    printf '%s\n' "$output" | grep -qx -- 'DONE1-42'
    # Plain `xclip` in the pane is the template's shim, not /usr/bin/xclip:
    # pane-entry puts the template bin on PATH for every pane.
    printf '%s\n' "$output" | grep -qxF -- "XCLIP-WHICH=$E2E_PROJECT/.claude-dev/template/bin/xclip"
    printf '%s\n' "$output" | grep -qx -- 'DONE2-42'

    # Image on the pasteboard: TARGETS names it, the PNG is byte for byte.
    printf '%s\n' "$output" | grep -qx -- 'TARGETS-PNG=\[image/png\]'
    printf '%s\n' "$output" | grep -qx -- 'CMP-RC=0'
    # Text on the pasteboard: no target, no text, no image -- every read fails.
    printf '%s\n' "$output" | grep -qx -- 'TARGETS-TEXT=\[\]'
    printf '%s\n' "$output" | grep -qx -- 'TEXTREAD-RC=1 OUT=\[\]'
    printf '%s\n' "$output" | grep -qx -- 'PNGREAD-AFTER-RC=1'

    # What the Mac side saw: the listener's own log, one line per request.
    logf="$(ls "$E2E_ROOT"/.local/state/claude-dev/clip-*.log | head -n 1)"
    [ -f "$logf" ]
    cat "$logf" >&2
    [ "$(grep -c 'GET /png -> 200' "$logf")" -eq 1 ]
    n200="$(grep -c ' -> 200' "$logf")"
    # The only 200s are the two answered while the pasteboard held an image
    # (TARGETS and the PNG); after the switch there are only 204s and 404s.
    [ "$n200" -eq 2 ]
    grep -Eq 'GET /png -> (204|404)' "$logf"
    # The Mac was never asked to read anything but the pasteboard's type
    # list once the text was on it: the last `open for access` (a read of
    # the image) is before the last `clipboard info`.
    cat "$E2E_ROOT/osascript.log" >&2
    last_open="$(grep -n 'open for access' "$E2E_ROOT/osascript.log" | tail -n 1 | cut -d: -f1)"
    last_info="$(grep -n 'clipboard info' "$E2E_ROOT/osascript.log" | tail -n 1 | cut -d: -f1)"
    [ -n "$last_open" ] && [ "$last_info" -gt "$last_open" ]
    [ "$(grep -c 'open for access' "$E2E_ROOT/osascript.log")" -eq 1 ]

    e2e_stop
    local i=0
    while [ "$i" -lt 20 ] && [ -n "$(e2e_leftovers)" ]; do
        sleep 1
        i=$((i + 1))
    done
    left="$(e2e_leftovers)"
    [ -z "$left" ] || { ps -o pid,args -p "$(echo $left | tr ' ' ',')" >&2; false; }
}
