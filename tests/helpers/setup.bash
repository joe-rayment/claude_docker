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

# --- per-test environment -------------------------------------------------

setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"

    export CLAUDE_ORCA_HOME="$BATS_TEST_TMPDIR/claude-orca-home"
    export CLAUDE_ORCA_TEMPLATE_URL="$TEMPLATE_SRC"

    export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    : > "$STUB_LOG"

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
