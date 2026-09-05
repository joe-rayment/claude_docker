#!/usr/bin/env bash
#
# claude-dev -- the claude_orca launcher. bootstrap.sh symlinks this file to
# ~/.claude-orca/bin/claude-dev (override: CLAUDE_ORCA_HOME); that symlink
# is what ends up on PATH, never a copy inside a project.
#
# Usage:
#   claude-dev [register] [dir]   Register a project (default: current dir)
#   claude-dev --doctor           Show presence of required tools
#   claude-dev --update           (stub until S12)
#   claude-dev --teardown         (stub until S12)
#   claude-dev --uninstall        (stub until S12)
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

    echo "Project '$project_name' registered at $dir"
    echo "Next: open this folder in Orca and pick Claude Code."
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
}

cmd_help() {
    cat <<'HELP'
claude-dev -- claude_orca project launcher

Usage:
  claude-dev [register] [dir]   Register a project (default: current directory)
  claude-dev --doctor           Show presence of required tools
  claude-dev --update           Update the host-side template and tools
  claude-dev --teardown         Remove a project's claude_orca artifacts
  claude-dev --uninstall        Remove the host-side install
  claude-dev --help             Show this help
HELP
}

cmd_not_implemented() {
    echo "claude-dev $1: not implemented until S12" >&2
    exit 64
}

case "${1:-}" in
    register)     shift; cmd_register "${1:-$PWD}" ;;
    --doctor)     cmd_doctor; exit 0 ;;
    --update)     cmd_not_implemented "--update" ;;
    --teardown)   cmd_not_implemented "--teardown" ;;
    --uninstall)  cmd_not_implemented "--uninstall" ;;
    --help|-h)    cmd_help ;;
    "")           cmd_register "$PWD" ;;
    *)
        echo "Unknown option: $1" >&2
        cmd_help
        exit 1
        ;;
esac
