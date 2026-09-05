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

    TEMPLATE_SRC="$BATS_TMPDIR/template.git"
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
prev=""
for arg in "$@"; do
    case "$arg" in
        install) do_install=1 ;;
        --prefix=*) prefix="${arg#--prefix=}" ;;
    esac
    [ "$prev" = "--prefix" ] && prefix="$arg"
    prev="$arg"
done

if [ "$do_install" = "1" ] && [ -n "$prefix" ]; then
    mkdir -p "$prefix/node_modules/@anthropic-ai/sandbox-runtime"
    printf '{"name":"@anthropic-ai/sandbox-runtime","version":"0.0.75"}' \
        > "$prefix/node_modules/@anthropic-ai/sandbox-runtime/package.json"
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
if [ "$1" = "api" ]; then
    echo ""
    exit 0
fi
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
    export PATH="$STUB_BIN:$PATH"

    export PROJECT_DIR="$BATS_TEST_TMPDIR/project"
    mkdir -p "$PROJECT_DIR"
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

    bash "$REPO_ROOT/bootstrap.sh" "$dir" >/dev/null

    write_stub_srt "$CLAUDE_ORCA_HOME/srt/node_modules/.bin/srt"
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
tree_checksum() {
    {
        find "$1" -not -path '*/.git*' -type f -exec sha256sum {} + 2>/dev/null
        find "$1" -not -path '*/.git*' -type l 2>/dev/null | while IFS= read -r link; do
            printf 'SYMLINK %s -> %s\n' "$link" "$(readlink "$link")"
        done
    } | sort | sha256sum | cut -d' ' -f1
}
