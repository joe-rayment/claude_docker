#!/usr/bin/env bash
#
# orca-stub.bash -- a fake Orca CLI (and a fake `bd`) on PATH, for the tests
# that exercise orca-dispatch/orca-wait without a runtime (claude-orca-8a0.1).
#
# The stub replays canned JSON per subcommand from files in $ORCA_STUB_DIR
# and appends every argv it was called with to $ORCA_STUB_LOG, so a test can
# assert both on what the script did with an answer and on what it asked.
#
#   orca_stub_init                      stub orca-ide/orca/bd onto PATH
#   orca_stub_reply <key> <json>        the answer for every call of <key>
#   orca_stub_reply_nth <key> <n> <j>   the answer for the n-th call of <key>
#   orca_stub_calls [<pattern>]         the argv log (optionally grepped)
#
# <key> is the first argv word, or "<word1>-<word2>" for the two-word groups
# (`orchestration check` -> orchestration-check, `terminal read` ->
# terminal-read). With no fixture the stub answers {"ok":true,"result":{}}.

orca_stub_init() {
    ORCA_STUB_DIR="${BATS_TEST_TMPDIR:?}/orca-stub"
    ORCA_STUB_BIN="$ORCA_STUB_DIR/bin"
    ORCA_STUB_LOG="$ORCA_STUB_DIR/calls.log"
    mkdir -p "$ORCA_STUB_BIN"
    : >"$ORCA_STUB_LOG"
    export ORCA_STUB_DIR ORCA_STUB_BIN ORCA_STUB_LOG

    cat >"$ORCA_STUB_BIN/orca-ide" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ORCA_STUB_LOG"
key="${1:-none}"
case "${1:-}" in
    orchestration|terminal) key="$1-${2:-none}" ;;
esac
count_file="$ORCA_STUB_DIR/.count.$key"
n=1
if [ -f "$count_file" ]; then n=$(( $(cat "$count_file") + 1 )); fi
printf '%s' "$n" >"$count_file"
f="$ORCA_STUB_DIR/$key.$n.json"
[ -f "$f" ] || f="$ORCA_STUB_DIR/$key.json"
if [ -f "$f" ]; then cat "$f"; else printf '{"ok":true,"result":{}}\n'; fi
STUB
    chmod +x "$ORCA_STUB_BIN/orca-ide"
    cp "$ORCA_STUB_BIN/orca-ide" "$ORCA_STUB_BIN/orca"

    # `bd` is stubbed too: orch_bead_json/orch_spec read a bead through it,
    # and no test here should touch the repo's real tracker.
    cat >"$ORCA_STUB_BIN/bd" <<'BDSTUB'
#!/usr/bin/env bash
printf 'bd %s\n' "$*" >>"$ORCA_STUB_LOG"
case "${1:-}" in
    show) cat "$ORCA_STUB_DIR/bead.json" 2>/dev/null || printf '{}\n' ;;
    *)    : ;;
esac
BDSTUB
    chmod +x "$ORCA_STUB_BIN/bd"

    orca_stub_reply status '{"ok":true,"result":{"runtime":{"reachable":true}}}'
    printf '%s\n' '{"id":"b1","title":"probe slice","description":"do the slice","acceptance_criteria":"CHECK: true"}' \
        >"$ORCA_STUB_DIR/bead.json"

    PATH="$ORCA_STUB_BIN:$PATH"
    export PATH
}

orca_stub_reply() {
    printf '%s\n' "$2" >"$ORCA_STUB_DIR/$1.json"
}

orca_stub_reply_nth() {
    printf '%s\n' "$3" >"$ORCA_STUB_DIR/$1.$2.json"
}

orca_stub_calls() {
    if [ "$#" -gt 0 ]; then
        grep -e "$1" "$ORCA_STUB_LOG" 2>/dev/null || true
    else
        cat "$ORCA_STUB_LOG" 2>/dev/null || true
    fi
}

# orca_stub_dispatch_record <root> <dispatch-id> <json> -- one dispatch
# record under the orchestration run dir, the way orca-dispatch writes it.
orca_stub_dispatch_record() {
    local root="$1" id="$2" json="$3" dir
    dir="$root/.claude-dev/run/orchestration/dispatch"
    mkdir -p "$dir"
    printf '%s\n' "$json" >"$dir/$id.json"
}

# orca_stub_git_fixture <dir> [<committer date>] -- a git repo with one
# commit, whose HEAD date the caller chooses (default: now).
orca_stub_git_fixture() {
    local dir="$1" when="${2:-}"
    mkdir -p "$dir"
    (
        cd "$dir" || exit 1
        git init -q .
        git config user.email orca@test
        git config user.name orca
        echo one >file.txt
        git add -A
        if [ -n "$when" ]; then
            GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
                git commit -qm init
        else
            git commit -qm init
        fi
    )
}
