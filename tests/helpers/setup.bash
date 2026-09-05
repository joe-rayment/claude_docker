#!/usr/bin/env bash
#
# Shared bats helper for tests/bootstrap.bats (S1, claude-orca-3sk.1).
#
# Builds a local git fixture that stands in for the real
# https://github.com/joe-rayment/claude_orca.git template -- assembled from
# the CURRENT WORKING TREE (not HEAD), so edits made while iterating on
# bootstrap.sh/scripts/* are exercised immediately -- and stubs
# brew/npm/gh/node on PATH so bootstrap.sh and its helper scripts run
# deterministically with no network and no real macOS tooling.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# Runs once per bats FILE (bats-core setup_file hook). Vars exported here
# survive into every test's setup()/body: bats forks a fresh process per
# test off an environment that already carries them (verified: a var
# exported in setup_file is visible, unchanged, inside every later setup()
# and test body even though each runs with a different pid).
setup_file() {
    # Captured before any test's setup() prepends the stub bin dir, so
    # helpers that need the REAL node/npm (schema validation against the
    # pinned srt package, never the stub) can ask for it explicitly.
    export ORIGINAL_PATH="$PATH"

    # $BATS_RUN_TMPDIR (private per bats invocation), never $BATS_TMPDIR
    # (== ${TMPDIR:-/tmp}, machine-wide and identical for every concurrent
    # agent in this container when TMPDIR is unset) -- a shared literal
    # /tmp/template.git meant two agents' parallel bats runs could rm -rf
    # and rebuild out from under each other, seen as random failures in
    # unrelated suites.
    TEMPLATE_SRC="$BATS_RUN_TMPDIR/template.git"
    rm -rf "$TEMPLATE_SRC"
    mkdir -p "$TEMPLATE_SRC"
    git init --quiet -b main "$TEMPLATE_SRC" >/dev/null 2>&1

    # Always leave at least one file to commit, even before bootstrap.sh/
    # Brewfile/scripts exist yet (RED phase) -- keeps setup_file itself from
    # failing so each test's own assertions produce the real, specific
    # failure instead of a blanket "setup_file failed".
    : > "$TEMPLATE_SRC/.template-stub"
    [ -f "$REPO_ROOT/bootstrap.sh" ] && cp "$REPO_ROOT/bootstrap.sh" "$TEMPLATE_SRC/bootstrap.sh"
    [ -f "$REPO_ROOT/Brewfile" ] && cp "$REPO_ROOT/Brewfile" "$TEMPLATE_SRC/Brewfile"
    [ -d "$REPO_ROOT/scripts" ] && cp -R "$REPO_ROOT/scripts" "$TEMPLATE_SRC/scripts"
    # S4 (claude-orca-3sk.4): config-sync's source and the bin/ symlinks it
    # and tier-gate/tier-set etc. are resolved through -- `cp -R` preserves
    # bin/<name>'s relative symlinks (e.g. bin/tier-set -> ../scripts/
    # tier-set.sh) as symlinks, so they still resolve correctly once re-rooted
    # under $TEMPLATE_SRC and, later, under $CLAUDE_ORCA_HOME/template.
    [ -d "$REPO_ROOT/config" ] && cp -R "$REPO_ROOT/config" "$TEMPLATE_SRC/config"
    [ -d "$REPO_ROOT/bin" ] && cp -R "$REPO_ROOT/bin" "$TEMPLATE_SRC/bin"

    git -C "$TEMPLATE_SRC" add -A >/dev/null 2>&1
    git -C "$TEMPLATE_SRC" \
        -c user.email=test@example.com -c user.name=test \
        commit --quiet -m "template snapshot" >/dev/null 2>&1

    export TEMPLATE_SRC
}

# --- stub executables ----------------------------------------------------

write_stub_brew() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
echo "brew $*" >> "$STUB_LOG"
if [ "$1" = "list" ] && [ "$2" = "--cask" ] && [ "$3" = "orca" ]; then
    [ "${STUB_ORCA_INSTALLED:-}" = "1" ] && exit 0
    exit 1
fi
exit 0
STUB
    chmod +x "$1"
}

write_stub_npm() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
echo "npm $*" >> "$STUB_LOG"

prefix=""
do_install=0
spec=""
prev=""
for arg in "$@"; do
    case "$arg" in
        install) do_install=1 ;;
        --prefix=*) prefix="${arg#--prefix=}" ;;
        @*/*@*) spec="$arg" ;;
    esac
    [ "$prev" = "--prefix" ] && prefix="$arg"
    prev="$arg"
done

# The version actually asked for, so a moved pin is observable in the
# fabricated package.json and not just in $STUB_LOG.
want_version="${spec##*@}"

# V1 (claude-orca-qt9.1): Claude Code now installs per folder through the
# same `npm --prefix` path as srt -- fabricate its package.json and the
# node_modules/.bin/claude executable a real install would leave.
if [ "$do_install" = "1" ] && [ -n "$prefix" ] && [ "${spec#*claude-code}" != "$spec" ]; then
    mkdir -p "$prefix/node_modules/@anthropic-ai/claude-code" "$prefix/node_modules/.bin"
    printf '{"name":"@anthropic-ai/claude-code","version":"%s"}' "$want_version" \
        > "$prefix/node_modules/@anthropic-ai/claude-code/package.json"
    printf '#!/usr/bin/env bash\necho "claude-code %s"\n' "$want_version" \
        > "$prefix/node_modules/.bin/claude"
    chmod +x "$prefix/node_modules/.bin/claude"
    exit 0
fi

if [ "$do_install" = "1" ] && [ -n "$prefix" ]; then
    mkdir -p "$prefix/node_modules/@anthropic-ai/sandbox-runtime"
    printf '{"name":"@anthropic-ai/sandbox-runtime","version":"%s"}' \
        "${want_version:-0.0.75}" \
        > "$prefix/node_modules/@anthropic-ai/sandbox-runtime/package.json"

    # S3 (claude-orca-3sk.15): real `npm install` of a package with a
    # "bin" field also creates node_modules/.bin/<name> -- claude-dev
    # register's new sandbox self-test step (claude-orca-shell
    # --selftest) needs a working srt binary to exist by the time
    # bootstrap.sh reaches it, so the stub mirrors that instead of
    # depending on a separately-timed second setup call.
    mkdir -p "$prefix/node_modules/.bin"
    cat > "$prefix/node_modules/.bin/srt" <<'SRTSTUB'
#!/usr/bin/env bash
{
    echo "=== srt invocation ==="
    printf '%s\n' "$@"
    echo "=== end argv ==="
} >> "$STUB_LOG"
env > "$STUB_ENV"

command=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "-c" ]; then
        command="$arg"
    fi
    prev="$arg"
done

if [ "${STUB_SRT_NOEXEC:-}" = "1" ]; then
    exit 0
fi
if [ -n "$command" ]; then
    exec sh -c "$command"
fi
exit 0
SRTSTUB
    chmod +x "$prefix/node_modules/.bin/srt"
fi
exit 0
STUB
    chmod +x "$1"
}

write_stub_gh() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    [ "${STUB_GH_UNAUTH:-}" = "1" ] && exit 1
    exit 0
fi
# S5 (claude-orca-3sk.17): the wrapper reads the GitHub token on the HOST
# side via `gh auth token` and passes it to srt as GH_TOKEN. Fixed fake
# value (override with STUB_GH_TOKEN); STUB_GH_UNAUTH=1 stands in for "no
# token on this machine" (real gh exits nonzero, prints nothing).
if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
    [ "${STUB_GH_UNAUTH:-}" = "1" ] && exit 1
    printf '%s\n' "${STUB_GH_TOKEN:-gho_stubfaketoken0123456789abcdef}"
    exit 0
fi
if [ "$1" = "api" ]; then
    echo ""
    exit 0
fi
exit 0
STUB
    chmod +x "$1"
}

# V1 (claude-orca-qt9.1): the Orca DMG download. Only a download (`-o
# <file>`) is faked -- every other curl call is handed to the real binary
# so suites that probe reachability keep their unstubbed behaviour.
write_stub_curl() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
out=""
prev=""
for arg in "$@"; do
    [ "$prev" = "-o" ] && out="$arg"
    prev="$arg"
done

if [ -z "$out" ]; then
    PATH="${ORIGINAL_PATH:-/usr/bin:/bin}" exec curl "$@"
fi

echo "curl $*" >> "$STUB_LOG"
mkdir -p "$(dirname "$out")"
printf 'FAKE-DMG %s\n' "${STUB_DMG_BODY:-orca}" > "$out"
exit "${STUB_CURL_EXIT:-0}"
STUB
    chmod +x "$1"
}

# V1: `hdiutil attach -nobrowse -readonly -mountpoint <mnt> <dmg>` fakes a
# mounted Orca.app (Info.plist carrying $STUB_ORCA_DMG_VERSION); `detach`
# unmounts it. macOS-only tool, so there is nothing to fall back to.
write_stub_hdiutil() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
echo "hdiutil $*" >> "$STUB_LOG"

mnt=""
prev=""
for arg in "$@"; do
    [ "$prev" = "-mountpoint" ] && mnt="$arg"
    prev="$arg"
done

case "$1" in
    attach)
        [ -n "$mnt" ] || exit 1
        [ "${STUB_HDIUTIL_EXIT:-0}" = "0" ] || exit "$STUB_HDIUTIL_EXIT"
        mkdir -p "$mnt/Orca.app/Contents/MacOS"
        printf 'fake orca binary\n' > "$mnt/Orca.app/Contents/MacOS/Orca"
        chmod +x "$mnt/Orca.app/Contents/MacOS/Orca"
        cat > "$mnt/Orca.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleShortVersionString</key>
	<string>${STUB_ORCA_DMG_VERSION:-1.4.197}</string>
</dict>
</plist>
PLIST
        ;;
    detach)
        [ -d "$2" ] && rm -rf "$2"
        ;;
esac
exit 0
STUB
    chmod +x "$1"
}

write_stub_node() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
    echo "${STUB_NODE_VERSION:-v24.0.0}"
    exit 0
fi
exit 0
STUB
    chmod +x "$1"
}

# S10 (claude-orca-3sk.21): a `node` stub that records what take-screenshot
# asked for -- one argv element per line to $STUB_ARGV, a full env dump to
# $STUB_NODE_ENV -- and fakes Playwright's side effect by creating the PNG
# path it was handed (the argument that ends in .png). Replaces the plain
# write_stub_node on PATH for tests that need to inspect the invocation.
write_stub_node_recording() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
    echo "${STUB_NODE_VERSION:-v24.0.0}"
    exit 0
fi
printf '%s\n' "$@" >> "$STUB_ARGV"
env > "$STUB_NODE_ENV"
for arg in "$@"; do
    case "$arg" in
        /*.png) mkdir -p "$(dirname "$arg")"; : > "$arg" ;;
    esac
done
exit "${STUB_NODE_EXIT:-0}"
STUB
    chmod +x "$1"
}

# S10 (claude-orca-3sk.21): a resolvable-but-inert `playwright` package under
# $1/node_modules, standing in for `npm i -g playwright@<pin>` having been run
# -- take-screenshot only checks that the package directory exists before
# handing the work to node, which is stubbed too.
fake_playwright_package() {
    mkdir -p "$1/node_modules/playwright"
    printf '{"name":"playwright","version":"1.61.1"}' \
        > "$1/node_modules/playwright/package.json"
}

# S2 (claude-orca-3sk.14): stands in for the real, pinned srt binary at
# $CLAUDE_ORCA_HOME/srt/node_modules/.bin/srt. Records every invocation's
# argv (one arg per line, delimited) to $STUB_LOG and a full environment
# dump to $STUB_ENV (overwritten each call -- tests that need more than
# one call's env capture it between calls), then actually runs the `-c`
# command via `sh -c` so end-to-end wrapper tests observe a real shell
# outcome -- unless STUB_SRT_NOEXEC=1, which stops after logging (for
# tests that only care about the generated settings/env, not spawning a
# shell).
write_stub_srt() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
{
    echo "=== srt invocation ==="
    printf '%s\n' "$@"
    echo "=== end argv ==="
} >> "$STUB_LOG"
env > "$STUB_ENV"

command=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "-c" ]; then
        command="$arg"
    fi
    prev="$arg"
done

if [ "${STUB_SRT_NOEXEC:-}" = "1" ]; then
    exit 0
fi
if [ -n "$command" ]; then
    exec sh -c "$command"
fi
exit 0
STUB
    chmod +x "$1"
}

# --- S8 delegation stubs (claude-orca-3sk.19) ------------------------------
#
# delegate.sh hands every runner a scrubbed env (`env -i` + only PATH, HOME,
# XDG_CONFIG_HOME, TERM and the route's provider key), so an arbitrary
# "record here" variable never reaches the stub. The job's own HOME does,
# by design -- so every runner stub records into $HOME: <name>.argv (one
# argv element per line), <name>.env (a full env dump) and `runner` (the
# name that ran). Each emits a realistic NDJSON stream carrying one
# usage/cost event, and exits with $STUB_RUNNER_EXIT (default 0).

write_stub_opencode() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
mkdir -p "$HOME"
printf '%s\n' "$@" > "$HOME/opencode.argv"
env > "$HOME/opencode.env"
echo opencode > "$HOME/runner"
cat <<'JSON'
{"type":"session.updated","timestamp":1788224900000,"sessionID":"ses_fake"}
{"type":"message","timestamp":1788224900500,"role":"assistant","text":"working"}
{"type":"finish","timestamp":1788224901000,"sessionID":"ses_fake","usage":{"inputTokens":1234,"outputTokens":567,"cost":0.0089}}
JSON
exit "${STUB_RUNNER_EXIT:-0}"
STUB
    chmod +x "$1"
}

write_stub_codex() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
mkdir -p "$HOME"
printf '%s\n' "$@" > "$HOME/codex.argv"
env > "$HOME/codex.env"
echo codex > "$HOME/runner"
cat <<'JSON'
{"type":"thread.started","thread_id":"th_fake"}
{"type":"item.completed","item":{"type":"agent_message","text":"working"}}
{"type":"turn.completed","usage":{"input_tokens":2048,"output_tokens":301,"cost":0.0042}}
JSON
exit "${STUB_RUNNER_EXIT:-0}"
STUB
    chmod +x "$1"
}

write_stub_gemini() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
mkdir -p "$HOME"
printf '%s\n' "$@" > "$HOME/gemini.argv"
env > "$HOME/gemini.env"
echo gemini > "$HOME/runner"
pwd > "$HOME/gemini.cwd"
cat <<'JSON'
{"type":"content","text":"working"}
{"type":"result","usage":{"promptTokens":900,"completionTokens":120,"cost":0.0011}}
JSON
exit "${STUB_RUNNER_EXIT:-0}"
STUB
    chmod +x "$1"
}

# A `bd` stub backed by one JSON file per project dir (<dir>/.bd-stub.json).
# Covers exactly the four calls delegate.sh makes -- create (tests only),
# show --json, update --append-notes, list --notes-contains --json -- and
# logs every invocation's argv to $BD_STUB_LOG when set. Never touches a
# real Dolt DB, so no test can reach this repo's own beads.
write_stub_bd() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
[ -n "${BD_STUB_LOG:-}" ] && printf '%s\n' "$*" >> "$BD_STUB_LOG"

dir="$PWD"
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -C) dir="$2"; shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
db="$dir/.bd-stub.json"
[ -f "$db" ] || echo '[]' > "$db"

cmd="${args[0]}"
case "$cmd" in
    create)
        title="${args[1]}"; desc=""; acc=""
        i=2
        while [ "$i" -lt "${#args[@]}" ]; do
            case "${args[$i]}" in
                -d|--description) i=$((i+1)); desc="${args[$i]}" ;;
                --acceptance) i=$((i+1)); acc="${args[$i]}" ;;
            esac
            i=$((i+1))
        done
        id="test-$(jq 'length + 1' "$db")"
        jq --arg id "$id" --arg t "$title" --arg d "$desc" --arg a "$acc" \
            '. + [{id: $id, title: $t, description: $d, acceptance_criteria: $a, notes: ""}]' \
            "$db" > "$db.tmp" && mv "$db.tmp" "$db"
        echo "created $id"
        ;;
    show)
        jq --arg id "${args[1]}" '[.[] | select(.id == $id)]' "$db"
        ;;
    update)
        id="${args[1]}"; notes=""
        i=2
        while [ "$i" -lt "${#args[@]}" ]; do
            [ "${args[$i]}" = "--append-notes" ] && { i=$((i+1)); notes="${args[$i]}"; }
            i=$((i+1))
        done
        jq --arg id "$id" --arg n "$notes" \
            'map(if .id == $id then .notes = ((.notes // "") + (if (.notes // "") == "" then "" else "\n" end) + $n) else . end)' \
            "$db" > "$db.tmp" && mv "$db.tmp" "$db"
        ;;
    list)
        needle=""
        i=1
        while [ "$i" -lt "${#args[@]}" ]; do
            [ "${args[$i]}" = "--notes-contains" ] && { i=$((i+1)); needle="${args[$i]}"; }
            i=$((i+1))
        done
        jq --arg n "$needle" '[.[] | select(($n == "") or ((.notes // "") | contains($n))) | {id: .id}]' "$db"
        ;;
    *)
        exit 0
        ;;
esac
exit 0
STUB
    chmod +x "$1"
}

# --- per-test environment -------------------------------------------------

setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"

    export CLAUDE_ORCA_HOME="$BATS_TEST_TMPDIR/claude-orca-home"
    export CLAUDE_ORCA_TEMPLATE_URL="$TEMPLATE_SRC"

    export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    : > "$STUB_LOG"
    export STUB_ENV="$BATS_TEST_TMPDIR/stub.env"
    : > "$STUB_ENV"

    STUB_BIN="$BATS_TEST_TMPDIR/stubs"
    mkdir -p "$STUB_BIN"
    write_stub_brew "$STUB_BIN/brew"
    write_stub_npm  "$STUB_BIN/npm"
    write_stub_gh   "$STUB_BIN/gh"
    write_stub_node "$STUB_BIN/node"
    write_stub_curl "$STUB_BIN/curl"
    write_stub_hdiutil "$STUB_BIN/hdiutil"
    export PATH="$STUB_BIN:$PATH"

    export PROJECT_DIR="$BATS_TEST_TMPDIR/project"
    mkdir -p "$PROJECT_DIR"

    # V1 (claude-orca-qt9.1): the per-folder host root -- everything the
    # bootstrap installs lives under the project itself now, so this is
    # derived from $PROJECT_DIR rather than being a place of its own.
    export ORCA_HOST="$PROJECT_DIR/.claude-dev"

    # S3 (claude-orca-3sk.15): `claude-dev register` now runs the sandbox
    # self-test (scripts/sandbox/selftest.sh via claude-orca-shell
    # --selftest) as its last step and refuses to hand off on failure.
    # Every probe faked to PASS by default so the pre-existing S1/S2
    # registration cases -- which know nothing about self-tests -- keep
    # passing unmodified; a test that wants to exercise the failure path
    # overrides one line (see tests/bootstrap.bats and tests/selftest.bats).
    export CLAUDE_ORCA_SELFTEST_FAKE="$BATS_TEST_TMPDIR/selftest-fake-allpass.txt"
    {
        echo "write-outside-denied=0"
        echo "read-real-home-denied=0"
        echo "keychain-denied=0"
        echo "project-writable=0"
        echo "worktree-writable=0"
        echo "sibling-worktree-denied=0"
        echo "tmp-outside-denied=0"
        echo "network-blocked-domain=0"
        echo "network-allowed-domain=0"
        echo "orca-socket-unreachable=0"
        echo "sandbox-exec-present=0"
        echo "srt-version-pinned=0"
        echo "git-hooks-audit=0"
    } > "$CLAUDE_ORCA_SELFTEST_FAKE"
}

# --- S2 fixtures (claude-orca-3sk.14) --------------------------------------

# Bootstraps the host (template clone, srt "install", ~/.claude-orca/bin
# symlinks, rc-install) and registers a fresh git repo as a project, all
# through the real bootstrap.sh with brew/npm/gh/node stubbed -- then
# drops in a working srt stub, since the stubbed `npm install` only
# fabricates a package.json, not an executable.
make_project() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init --quiet -b main >/dev/null 2>&1
    git -C "$dir" -c user.email=test@example.com -c user.name=test \
        commit --quiet --allow-empty -m init >/dev/null 2>&1

    # S3 (claude-orca-3sk.15): bootstrap.sh's own final step now runs
    # `claude-dev register`, which runs the sandbox self-test -- so the
    # working srt stub must exist BEFORE bootstrap.sh runs, not after.
    # (The stubbed npm install a few lines up in bootstrap.sh only
    # fabricates a package.json, never an executable at .bin/srt.)
    write_stub_srt "$CLAUDE_ORCA_HOME/srt/node_modules/.bin/srt"

    bash "$REPO_ROOT/bootstrap.sh" "$dir" >/dev/null
}

# Adds a linked worktree as a sibling of $1 (Orca's default layout:
# <repo>/../<repoName>-<name>) and prints its path.
make_worktree() {
    local project="$1" name="$2" wt
    wt="$(dirname "$project")/$(basename "$project")-$name"
    git -C "$project" worktree add --quiet -b "$name" "$wt" >/dev/null 2>&1
    printf '%s\n' "$wt"
}

# A fake "real" (unsandboxed) HOME, distinct from $HOME (which setup()
# already points at a fixture root used for other purposes) -- stands in
# for CLAUDE_ORCA_REAL_HOME, pre-populated with the directories the S2
# contract re-opens allowRead for.
make_real_home() {
    local home="$BATS_TEST_TMPDIR/real-home"
    mkdir -p "$home/.local/bin" "$home/.local/share/claude" "$home/.orca/agent-hooks" "$home/.ssh"
    printf '%s\n' "$home"
}

# S2b (claude-orca-3sk.24): seeds $HOME's three shell rc files with one
# identical pre-existing line each (e.g. a Homebrew shellenv eval),
# standing in for a user's existing dotfiles that claude-dev rc-install
# must always append AFTER, never disturb.
seed_pre_existing_rc_line() {
    local line="$1"
    printf '%s\n' "$line" > "$HOME/.zprofile"
    printf '%s\n' "$line" > "$HOME/.zshrc"
    printf '%s\n' "$line" > "$HOME/.bash_profile"
}

# Canonical absolute path -- matches how gen-settings.sh/claude-orca-shell
# resolve every path (`cd ... && pwd -P`), so expected-value strings built
# in tests agree with what the scripts under test actually produce.
abspath() {
    (cd "$1" && pwd -P)
}

# Portable file-permission-bits read (GNU stat here, BSD/macOS stat on the
# real target platform).
file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# Resolves to a real, installed copy of @anthropic-ai/sandbox-runtime for
# schema validation (never the stub): reuses the scratchpad clone this
# session already built when present, otherwise installs it once into
# tests/.cache (gitignored, real node/npm via $ORIGINAL_PATH) so repeat
# runs are free. Prints the package directory on success; callers `skip`
# the case with a clear reason on failure (no real node, or the install
# failed) rather than pretend a pinned-schema check passed.
ensure_real_srt() {
    [ -n "${ORIGINAL_PATH:-}" ] || return 1
    PATH="$ORIGINAL_PATH" command -v node >/dev/null 2>&1 || return 1

    local scratchpad="${CLAUDE_ORCA_SRT_REAL:-/tmp/claude-1000/-workspace/7037bfad-67da-4b5e-9adb-944b260fc264/scratchpad/srt-real/node_modules/@anthropic-ai/sandbox-runtime}"
    if [ -f "$scratchpad/dist/index.js" ]; then
        printf '%s\n' "$scratchpad"
        return 0
    fi

    local cache_pkg="$REPO_ROOT/tests/.cache/srt-real/node_modules/@anthropic-ai/sandbox-runtime"
    if [ -f "$cache_pkg/dist/index.js" ]; then
        printf '%s\n' "$cache_pkg"
        return 0
    fi

    PATH="$ORIGINAL_PATH" command -v npm >/dev/null 2>&1 || return 1

    mkdir -p "$REPO_ROOT/tests/.cache/srt-real"
    if ! (cd "$REPO_ROOT/tests/.cache/srt-real" && \
          PATH="$ORIGINAL_PATH" npm install --no-audit --no-fund \
              "@anthropic-ai/sandbox-runtime@0.0.75") >/dev/null 2>&1; then
        return 1
    fi

    [ -f "$cache_pkg/dist/index.js" ] || return 1
    printf '%s\n' "$cache_pkg"
}

# --- assertion helpers -----------------------------------------------------

# Content-addressed checksum of a directory tree, ignoring .git internals:
# `git pull --ff-only` legitimately rewrites reflogs/FETCH_HEAD (with a
# fresh timestamp) even when nothing new was fetched, so including .git
# would make an otherwise-true no-op look like a change.
#
# S3 (claude-orca-3sk.15) also excludes selftest.json/srt-debug-*.log for
# the same reason: `claude-dev register` now runs the sandbox self-test
# every time, and its results carry a live UTC timestamp (selftest.json)
# and captured stderr (srt-debug-*.log) that legitimately differ run to
# run even when nothing else changed.
tree_checksum() {
    {
        find "$1" -not -path '*/.git*' \
            -not -name 'selftest.json' -not -name 'srt-debug-*.log' \
            -type f -exec sha256sum {} + 2>/dev/null
        find "$1" -not -path '*/.git*' -type l 2>/dev/null | while IFS= read -r link; do
            printf 'SYMLINK %s -> %s\n' "$link" "$(readlink "$link")"
        done
    } | sort | sha256sum | cut -d' ' -f1
}
