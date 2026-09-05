#!/usr/bin/env bash
#
# claude-dev -- the claude_orca launcher. bootstrap.sh symlinks this file to
# ~/.claude-orca/bin/claude-dev (override: CLAUDE_ORCA_HOME); that symlink
# is what ends up on PATH, never a copy inside a project.
#
# Usage:
#   claude-dev [register] [dir]   Register a project (default: current dir)
#   claude-dev --doctor           Show presence of required tools
#   claude-dev --update           Pull the template, re-pin srt, re-sync, re-test
#   claude-dev --teardown         Snapshot beads, remove the project artifacts
#   claude-dev --uninstall        Teardown, then remove the host-side install
#   claude-dev --help             Show this help
#
# Trust boundary (see .claude/plans/orca-port.md §3.1): register() only
# ever writes data files under the project -- home/tmp/state directories,
# sandbox.json, .gitignore, attachments/. It never writes or leaves behind
# an executable in the project, and never execs/sources anything under it.

set -euo pipefail

# Resolve through the ~/.claude-orca/bin/claude-dev symlink to find the real
# template root this script lives in (scripts/.. ), independent of how deep
# the symlink chain is or how the script was invoked.
resolve_script_path() {
    local src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        local link dir
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(cd "$(dirname "$src")" && pwd)"; src="$dir/$link" ;;
        esac
    done
    echo "$src"
}

SCRIPT_PATH="$(resolve_script_path)"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
TEMPLATE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOST_DIR="$(dirname "$TEMPLATE_ROOT")"

derive_project_name() {
    local raw name
    raw="$(basename "$1")"
    name=$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
    [ -z "$name" ] && name="project"
    echo "$name"
}

# Idempotent: appends only the lines that are missing, under a single
# marker comment, and never touches or duplicates existing content.
seed_gitignore() {
    local dir="$1" gitignore="$1/.gitignore"
    touch "$gitignore"
    if ! grep -qF "# claude_orca" "$gitignore"; then
        {
            echo ""
            echo "# claude_orca"
        } >> "$gitignore"
    fi
    local pattern
    for pattern in '.claude-dev/' '.mcp.json' 'attachments/' '.claude/logs/'; do
        grep -qxF "$pattern" "$gitignore" || echo "$pattern" >> "$gitignore"
    done
}

# S2 (claude-orca-3sk.14): a marker-delimited block in the user's real
# rc files that sources our shellrc.zsh/.bash -- see
# .claude/plans/orca-port.md S3.2. Idempotent by construction: every
# install first strips any existing block, then appends a fresh one, so
# re-running (or bootstrapping a second project on an already-bootstrapped
# host) never duplicates it and always reflects the current $HOST_DIR.
RC_MARKER_START="# >>> claude_orca >>>"
RC_MARKER_END="# <<< claude_orca <<<"

rc_block_for() {
    # $1 = shellrc file name to source, relative to $HOST_DIR.
    cat <<BLOCK
$RC_MARKER_START
# Added by claude-dev rc-install -- do not edit by hand between the
# markers; re-run 'claude-dev rc-uninstall' to remove.
if [ -r "$HOST_DIR/$1" ]; then
    . "$HOST_DIR/$1"
fi
$RC_MARKER_END
BLOCK
}

# Strips any existing marker-delimited block from $1, leaving everything
# else untouched -- including the single blank-line separator
# rc_install_one puts immediately before the block, which is dropped here
# too so install-then-uninstall restores the original file byte-for-byte
# instead of leaving a trailing blank line behind. A no-op if the file
# doesn't exist or has no block. (One line of lookahead: a line is only
# printed once we know it isn't the blank line immediately before START.)
rc_remove_block() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -qF "$RC_MARKER_START" "$file" || return 0

    local tmp
    tmp="$(mktemp "${file}.XXXXXX")"
    awk -v start="$RC_MARKER_START" -v end="$RC_MARKER_END" '
        $0 == start {
            skip = 1
            if (have_pending && pending != "") { print pending }
            have_pending = 0
            next
        }
        $0 == end { skip = 0; next }
        skip { next }
        {
            if (have_pending) { print pending }
            pending = $0
            have_pending = 1
        }
        END { if (have_pending) print pending }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

rc_install_one() {
    local file="$1" shellrc_name="$2"
    touch "$file"
    rc_remove_block "$file"

    # $(...) strips ALL trailing newlines, however many -- including any
    # blank line left dangling right before where the removed block used
    # to be -- so re-adding exactly one blank-line separator here keeps
    # repeated installs byte-identical instead of growing a blank line
    # per run.
    local content
    content="$(cat "$file")"
    {
        if [ -n "$content" ]; then
            printf '%s\n\n' "$content"
        fi
        rc_block_for "$shellrc_name"
    } > "$file"
}

cmd_rc_install() {
    # .zprofile as well as .zshrc: zsh does not read ~/.zshrc for a
    # non-interactive login shell (`zsh -l -c '...'`), only ~/.zprofile --
    # see shellrc.zsh and .claude/plans/orca-port.md S3.2. bash already
    # reads ~/.bash_profile for any login shell, interactive or not, so it
    # needs no second file.
    rc_install_one "$HOME/.zprofile" "shellrc.zsh"
    rc_install_one "$HOME/.zshrc" "shellrc.zsh"
    rc_install_one "$HOME/.bash_profile" "shellrc.bash"
    echo "Installed claude_orca shell hook in ~/.zprofile, ~/.zshrc and ~/.bash_profile"
}

cmd_rc_uninstall() {
    rc_remove_block "$HOME/.zprofile"
    rc_remove_block "$HOME/.zshrc"
    rc_remove_block "$HOME/.bash_profile"
    echo "Removed claude_orca shell hook from ~/.zprofile, ~/.zshrc and ~/.bash_profile"
}

cmd_register() {
    local dir="${1:-$PWD}"
    [ -d "$dir" ] || { echo "Error: directory does not exist: $dir" >&2; exit 1; }
    dir="$(cd "$dir" && pwd)"
    local project_name
    project_name="$(derive_project_name "$dir")"

    mkdir -p "$dir/.claude-dev/home" "$dir/.claude-dev/tmp" "$dir/.claude-dev/state"

    # Defaults only if absent -- never reset a project's own edits.
    if [ ! -f "$dir/.claude-dev/sandbox.json" ]; then
        cat > "$dir/.claude-dev/sandbox.json" <<'JSON'
{"version":1,"network":{"extraAllowedDomains":[]},"filesystem":{"extraAllowWrite":[]},"orca":{"cli":false}}
JSON
    fi

    seed_gitignore "$dir"
    mkdir -p "$dir/attachments"

    # S12 (claude-orca-3sk.23): resume a torn-down project -- pull the most
    # recent beads snapshot back in when this project has none of its own.
    restore_beads_snapshot "$dir" "$project_name"

    # Populate .claude-dev/home/.claude from this template's config/ (S7,
    # claude-orca-3sk.7) before anything -- including the self-test below --
    # runs against this project. Checksum-gated, so a re-register is cheap.
    "$SCRIPT_DIR/config-sync.sh" --project "$dir" --host "$HOST_DIR"

    # Idempotent and cheap -- covers `claude-dev register` run standalone
    # against an already-bootstrapped host (e.g. a second project), not
    # just the bootstrap.sh call chain.
    cmd_rc_install >/dev/null

    echo "Project '$project_name' registered at $dir"

    # S3 (claude-orca-3sk.15): prove the sandbox from the inside before
    # ever handing off to Orca -- see .claude/plans/orca-port.md S3.
    if [ "${CLAUDE_ORCA_SKIP_SELFTEST:-0}" = "1" ]; then
        echo "Skipping sandbox self-test (CLAUDE_ORCA_SKIP_SELFTEST=1) -- 'claude-dev --doctor' will show it as not run"
        echo "Next: open this folder in Orca and pick Claude Code."
        return 0
    fi

    local selftest_bin="$SCRIPT_DIR/sandbox/claude-orca-shell"
    if [ -x "$selftest_bin" ] && "$selftest_bin" --selftest --root "$dir" --cwd "$dir"; then
        echo "Next: open this folder in Orca and pick Claude Code."
        return 0
    fi

    local results="$dir/.claude-dev/state/selftest.json"
    if [ -f "$results" ]; then
        doctor_print_probes "$results"
    fi
    echo "Refusing to hand off to Orca until the sandbox self-test passes (claude-dev --doctor)" >&2
    return 2
}

# Prints one row per probe from a selftest.json results file: status,
# name, detail (see scripts/sandbox/selftest.sh for the schema). Shared
# by cmd_doctor and cmd_register's failure path.
doctor_print_probes() {
    local results="$1" entry name status detail
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        name="$(jq -r '.name' <<<"$entry" 2>/dev/null)"
        status="$(jq -r '.status' <<<"$entry" 2>/dev/null)"
        detail="$(jq -r '.detail' <<<"$entry" 2>/dev/null)"
        printf '  [%-4s] %-28s %s\n' "$status" "$name" "$detail"
    done < <(jq -c '.probes[]?' "$results" 2>/dev/null)
}

cmd_doctor() {
    local tool
    for tool in git gh brew node jq rg bats bd; do
        if command -v "$tool" >/dev/null 2>&1; then
            printf '  [ok]      %s\n' "$tool"
        else
            printf '  [missing] %s\n' "$tool"
        fi
    done

    if [ -f "$HOST_DIR/srt/node_modules/@anthropic-ai/sandbox-runtime/package.json" ]; then
        printf '  [ok]      srt\n'
    else
        printf '  [missing] srt\n'
    fi

    if brew list --cask orca >/dev/null 2>&1 || [ -d "/Applications/Orca.app" ]; then
        printf '  [ok]      orca (cask)\n'
    else
        printf '  [missing] orca (cask)\n'
    fi

    # S3: outside a registered project there is nothing more to check --
    # tool table only, exit 0 (see .claude/plans/orca-port.md S3).
    local root_bin="$SCRIPT_DIR/sandbox/claude-orca-root" root=""
    if [ -x "$root_bin" ]; then
        root="$("$root_bin" 2>/dev/null)" || root=""
    fi
    [ -n "$root" ] || return 0

    echo ""
    echo "Sandbox self-test ($root):"
    local results="$root/.claude-dev/state/selftest.json"

    if [ ! -f "$results" ]; then
        echo "  not run -- run 'claude-dev register' or 'claude-orca-shell --selftest --root $root'"
        return 2
    fi

    local mtime now age_secs
    mtime="$(stat -c '%Y' "$results" 2>/dev/null || stat -f '%m' "$results" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    age_secs=$((now - mtime))
    echo "  age: $((age_secs / 3600))h $(((age_secs % 3600) / 60))m"

    doctor_print_probes "$results"

    local fail_count launch_fail rc=0
    fail_count="$(jq -r '.summary.fail // 0' "$results" 2>/dev/null || echo 1)"
    launch_fail="$(jq -r '[.probes[]? | select(.name == "srt-launch")] | length' "$results" 2>/dev/null || echo 1)"

    if [ "$age_secs" -gt 86400 ]; then
        echo "  STALE: results are older than 24h"
        rc=2
    fi
    if [ "$launch_fail" != "0" ]; then
        echo "  srt failed to launch during the self-test -- see the detail above"
        rc=2
    fi
    if [ "$fail_count" != "0" ]; then
        rc=2
    fi
    return "$rc"
}

# --- S12 (claude-orca-3sk.23): update / teardown / uninstall -------------
#
# The template must be updatable and removable without losing beads (see
# .claude/plans/orca-port.md S3.1 and knowledge-base/TEARDOWN_RECOVERY.md).
# Beads state is the one thing in a project that is expensive to lose and
# that lives nowhere else, so teardown snapshots it OUT of the project
# tree, into the host dir, and a later registration pulls it back.

# The exact lines seed_gitignore writes -- kept next to each other so the
# unseed below can only ever remove what register put there.
GITIGNORE_MARKER="# claude_orca"

# Removes the marker block seed_gitignore added (marker line, the blank
# separator before it, and the seeded patterns that follow) and nothing
# else: any other line -- including a user's own '.mcp.json' elsewhere in
# the file -- is left byte-identical. Same one-line-lookahead trick as
# rc_remove_block.
gitignore_unseed() {
    local file="$1/.gitignore"
    [ -f "$file" ] || return 0
    grep -qF "$GITIGNORE_MARKER" "$file" || return 0

    local tmp
    tmp="$(mktemp "${file}.XXXXXX")"
    awk -v marker="$GITIGNORE_MARKER" '
        function seeded(l) {
            return l == ".claude-dev/" || l == ".mcp.json" || \
                   l == "attachments/" || l == ".claude/logs/"
        }
        $0 == marker {
            skip = 1
            if (have_pending && pending != "") { print pending }
            have_pending = 0
            next
        }
        skip && seeded($0) { next }
        {
            skip = 0
            if (have_pending) { print pending }
            pending = $0
            have_pending = 1
        }
        END { if (have_pending) print pending }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# Copies .beads/issues.jsonl (+ metadata.json) to
# $HOST/state/<project>/<timestamp>/ and prints the snapshot dir. Silent
# no-op when the project has no exported beads. The Dolt DB itself is not
# copied -- it rebuilds from the JSONL.
snapshot_beads() {
    local dir="$1" name="$2" ts snap
    [ -f "$dir/.beads/issues.jsonl" ] || return 0
    ts="$(date +%Y%m%d-%H%M%S)"
    snap="$HOST_DIR/state/$name/$ts"
    mkdir -p "$snap"
    cp "$dir/.beads/issues.jsonl" "$snap/issues.jsonl"
    if [ -f "$dir/.beads/metadata.json" ]; then
        cp "$dir/.beads/metadata.json" "$snap/metadata.json"
    fi
    printf '%s\n' "$snap"
}

# The other half of the round trip, called from cmd_register: automatic and
# unprompted ONLY when the project side has no issues.jsonl of its own --
# that case is unambiguous (nothing here to lose). A project that already
# carries beads data keeps it; we never overwrite it with a possibly older
# snapshot.
restore_beads_snapshot() {
    local dir="$1" name="$2" state_root latest
    state_root="$HOST_DIR/state/$name"
    [ -d "$state_root" ] || return 0
    if [ -f "$dir/.beads/issues.jsonl" ]; then
        return 0
    fi
    latest="$(ls -1 "$state_root" 2>/dev/null | sort -r | head -1)"
    [ -n "$latest" ] || return 0
    [ -f "$state_root/$latest/issues.jsonl" ] || return 0

    mkdir -p "$dir/.beads"
    cp "$state_root/$latest/issues.jsonl" "$dir/.beads/issues.jsonl"
    if [ -f "$state_root/$latest/metadata.json" ]; then
        cp "$state_root/$latest/metadata.json" "$dir/.beads/metadata.json"
    fi
    echo "Restored beads snapshot $latest from $state_root/$latest (Dolt DB rebuilds from the JSONL)"
}

cmd_update() {
    local dir="${1:-$PWD}" tmpl before after
    tmpl="$HOST_DIR/template"
    if [ ! -d "$tmpl/.git" ]; then
        echo "Error: no template clone at $tmpl -- re-run the bootstrap one-liner." >&2
        return 1
    fi

    echo "==> Updating the template at $tmpl"
    before="$(git -C "$tmpl" rev-parse HEAD 2>/dev/null || echo unknown)"
    git -C "$tmpl" pull --ff-only
    after="$(git -C "$tmpl" rev-parse HEAD)"
    if [ "$before" = "$after" ]; then
        echo "  template: already up to date (${after:0:7})"
    else
        echo "  template: ${before:0:7} -> ${after:0:7}"
        git -C "$tmpl" log --oneline "$before..$after" 2>/dev/null | sed 's/^/    /' || true
    fi

    # After the pull, so a moved srt pin in the new template takes effect.
    echo "==> Installing sandbox-runtime at the template's pinned version"
    "$SCRIPT_DIR/install-srt.sh"

    dir="$(cd "$dir" && pwd)"
    if [ ! -d "$dir/.claude-dev" ]; then
        echo "  $dir is not a registered project -- skipped config sync and self-test"
        echo "Update complete."
        return 0
    fi

    echo "==> Syncing config into $dir"
    "$SCRIPT_DIR/config-sync.sh" --project "$dir" --host "$HOST_DIR"

    echo "==> Re-running the sandbox self-test"
    local selftest_bin="$SCRIPT_DIR/sandbox/claude-orca-shell"
    if [ -x "$selftest_bin" ] && "$selftest_bin" --selftest --root "$dir" --cwd "$dir"; then
        echo "Update complete."
        return 0
    fi
    echo "Sandbox self-test failed after the update -- run 'claude-dev --doctor'" >&2
    return 2
}

cmd_teardown() {
    local purge=0 dir="$PWD"
    while [ $# -gt 0 ]; do
        case "$1" in
            --purge-beads) purge=1 ;;
            -*) echo "Unknown option: $1" >&2; return 1 ;;
            *)  dir="$1" ;;
        esac
        shift
    done
    [ -d "$dir" ] || { echo "Error: directory does not exist: $dir" >&2; return 1; }
    dir="$(cd "$dir" && pwd)"

    local name snap
    name="$(derive_project_name "$dir")"
    snap="$(snapshot_beads "$dir" "$name")"
    if [ -n "$snap" ]; then
        echo "Beads snapshot saved to $snap"
    fi

    rm -rf "$dir/.claude-dev"
    gitignore_unseed "$dir"

    if [ "$purge" = "1" ]; then
        rm -rf "$dir/.beads"
        echo "Removed $dir/.beads (--purge-beads)"
    fi

    echo "Teardown complete for '$name' at $dir"
    if [ -n "$snap" ]; then
        echo "Re-register this directory later to restore the snapshot."
    fi
}

cmd_uninstall() {
    # Safety: only ever delete the host dir this very launcher was resolved
    # through. A CLAUDE_ORCA_HOME pointing somewhere else means the user is
    # running the wrong claude-dev, and rm -rf is not the place to guess.
    local host_env resolved
    host_env="${CLAUDE_ORCA_HOME:-$HOME/.claude-orca}"
    if [ -d "$host_env" ]; then
        host_env="$(cd "$host_env" && pwd -P)"
    fi
    resolved="$(cd "$HOST_DIR" && pwd -P)"
    if [ "$host_env" != "$resolved" ]; then
        echo "Error: refusing to uninstall -- this launcher lives under $resolved, but CLAUDE_ORCA_HOME resolves to $host_env." >&2
        return 2
    fi

    if [ -d "$PWD/.claude-dev" ]; then
        cmd_teardown "$PWD"
    fi
    cmd_rc_uninstall
    echo "Removing $resolved"
    rm -rf "$resolved"
    echo "claude_orca uninstalled. Open a new shell to drop the hook from this session."
}

cmd_help() {
    cat <<'HELP'
claude-dev -- claude_orca project launcher

Usage:
  claude-dev [register] [dir]   Register a project (default: current directory)
  claude-dev --doctor           Show presence of required tools
  claude-dev --update           Update the host-side template and tools
  claude-dev --teardown [--purge-beads]
                                Snapshot beads, then remove this project's artifacts
  claude-dev --uninstall        Remove the host-side install
  claude-dev rc-install         Install the shell hook in ~/.zprofile, ~/.zshrc, ~/.bash_profile
  claude-dev rc-uninstall       Remove the shell hook
  claude-dev --help             Show this help
HELP
}

case "${1:-}" in
    register)      shift; cmd_register "${1:-$PWD}" ;;
    --doctor)      cmd_doctor || exit $?; exit 0 ;;
    --update)      shift; cmd_update "${1:-$PWD}" || exit $?; exit 0 ;;
    --teardown)    shift; cmd_teardown "$@" || exit $?; exit 0 ;;
    --uninstall)   shift; cmd_uninstall || exit $?; exit 0 ;;
    rc-install)    cmd_rc_install; exit 0 ;;
    rc-uninstall)  cmd_rc_uninstall; exit 0 ;;
    --help|-h)     cmd_help ;;
    "")            cmd_register "$PWD" ;;
    *)
        echo "Unknown option: $1" >&2
        cmd_help
        exit 1
        ;;
esac
