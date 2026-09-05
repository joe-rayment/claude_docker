# claude_orca shellrc (zsh) -- sourced from the user's ~/.zprofile AND
# ~/.zshrc by a marker-delimited block that `claude-dev rc-install`
# manages (see scripts/launcher.sh): zsh does not read ~/.zshrc for a
# non-interactive login shell (`zsh -l -c '...'`), only ~/.zprofile, so
# both files carry the same block; the CLAUDE_ORCA_SANDBOXED guard below
# makes whichever one runs second (for an interactive login shell, which
# reads both) a no-op. Re-execs every such shell opened inside a
# bootstrapped project's folder through claude-orca-shell before any
# agent binary runs, preserving a pending `-c` command via
# $ZSH_EXECUTION_STRING (bash: $BASH_EXECUTION_STRING in shellrc.bash) so
# non-interactive login shells stay sandboxed too; fails closed by
# shadowing the agent CLIs with refusing functions when the wrapper can't
# run safely instead of silently continuing unsandboxed. See
# .claude/plans/orca-port.md S3.2.

if [[ -z "$CLAUDE_ORCA_SANDBOXED" ]]; then
    __claude_orca_home="${CLAUDE_ORCA_HOME:-$HOME/.claude-orca}"
    __claude_orca_root_bin="$__claude_orca_home/bin/claude-orca-root"
    __claude_orca_shell_bin="$__claude_orca_home/bin/claude-orca-shell"

    __claude_orca_root=""
    if [[ -x "$__claude_orca_root_bin" ]]; then
        __claude_orca_root="$("$__claude_orca_root_bin" 2>/dev/null)"
    fi

    if [[ -n "$__claude_orca_root" ]]; then
        __claude_orca_check_out=""
        __claude_orca_check_status=1
        if [[ -x "$__claude_orca_shell_bin" ]]; then
            __claude_orca_check_out="$("$__claude_orca_shell_bin" --check --root "$__claude_orca_root" 2>&1)"
            __claude_orca_check_status=$?
        fi

        if [[ "$__claude_orca_check_status" -eq 0 ]]; then
            if [[ -n "${ZSH_EXECUTION_STRING:-}" ]]; then
                exec "$__claude_orca_shell_bin" --root "$__claude_orca_root" -- zsh -c "$ZSH_EXECUTION_STRING"
            fi
            exec "$__claude_orca_shell_bin" --root "$__claude_orca_root" -- zsh
        fi

        echo "[claude-orca] REFUSING to run agents unsandboxed in $__claude_orca_root: $__claude_orca_check_out" >&2
        claude()   { echo "[claude-orca] REFUSING to run agents unsandboxed in $__claude_orca_root: $__claude_orca_check_out" >&2; return 1; }
        codex()    { echo "[claude-orca] REFUSING to run agents unsandboxed in $__claude_orca_root: $__claude_orca_check_out" >&2; return 1; }
        gemini()   { echo "[claude-orca] REFUSING to run agents unsandboxed in $__claude_orca_root: $__claude_orca_check_out" >&2; return 1; }
        opencode() { echo "[claude-orca] REFUSING to run agents unsandboxed in $__claude_orca_root: $__claude_orca_check_out" >&2; return 1; }
    fi

    # __claude_orca_root and __claude_orca_check_out stay set (not
    # unset) when the refusing functions above were defined: those
    # functions look them up BY NAME at call time, not at definition
    # time, so unsetting here would make every later `claude`/`codex`/...
    # call print an empty reason instead of the real one.
    unset __claude_orca_home __claude_orca_root_bin __claude_orca_shell_bin
    unset __claude_orca_check_status
fi
