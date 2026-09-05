# claude_orca shellrc (bash) -- the body of the marker-delimited block that
# `claude-dev rc-install` writes into the user's ~/.bash_profile (see
# scripts/launcher.sh). Unlike zsh, bash already reads ~/.bash_profile for
# ANY login shell, interactive or not (`bash -l -c '...'` included), so
# this one file is enough -- no separate ~/.bashrc hook needed.
#
# V1 (claude-orca-qt9.1): GENERIC -- it names no install path. It walks up
# from $PWD looking for .claude-dev/bin/claude-orca-shell and re-execs the
# shell through it before any agent binary runs, so one block covers every
# bootstrapped folder on the machine and does nothing at all everywhere
# else. A pending `-c` command survives the re-exec via
# $BASH_EXECUTION_STRING (zsh: $ZSH_EXECUTION_STRING in shellrc.zsh), so
# non-interactive login shells stay sandboxed too; when the wrapper is
# there but cannot run safely this fails CLOSED, shadowing the agent CLIs
# with refusing functions rather than silently continuing unsandboxed.
# See .claude/plans/orca-port.md S3.2 and S9.2.

if [[ -z "$CLAUDE_ORCA_SANDBOXED" ]]; then
    __claude_orca_root=""
    __claude_orca_dir="$PWD"
    while [[ -n "$__claude_orca_dir" ]]; do
        if [[ -x "$__claude_orca_dir/.claude-dev/bin/claude-orca-shell" ]]; then
            __claude_orca_root="$__claude_orca_dir"
            break
        fi
        [[ "$__claude_orca_dir" == "/" ]] && break
        __claude_orca_dir="${__claude_orca_dir%/*}"
        [[ -z "$__claude_orca_dir" ]] && __claude_orca_dir="/"
    done

    # Orca's default worktree location is a SIBLING of the repo, so a
    # worktree shell finds nothing above it: fall back to the shared git
    # dir's parent, which is the primary checkout that holds .claude-dev.
    if [[ -z "$__claude_orca_root" ]]; then
        __claude_orca_common="$(git rev-parse --git-common-dir 2>/dev/null)"
        if [[ -n "$__claude_orca_common" ]]; then
            [[ "$__claude_orca_common" != /* ]] && \
                __claude_orca_common="$PWD/$__claude_orca_common"
            __claude_orca_primary="${__claude_orca_common%/*}"
            if [[ -x "$__claude_orca_primary/.claude-dev/bin/claude-orca-shell" ]]; then
                __claude_orca_root="$__claude_orca_primary"
            fi
        fi
    fi

    if [[ -n "$__claude_orca_root" ]]; then
        __claude_orca_shell_bin="$__claude_orca_root/.claude-dev/bin/claude-orca-shell"
        __claude_orca_check_out="$("$__claude_orca_shell_bin" --check --root "$__claude_orca_root" 2>&1)"
        __claude_orca_check_status=$?

        if [[ "$__claude_orca_check_status" -eq 0 ]]; then
            if [[ -n "${BASH_EXECUTION_STRING:-}" ]]; then
                exec "$__claude_orca_shell_bin" --root "$__claude_orca_root" -- bash -c "$BASH_EXECUTION_STRING"
            fi
            exec "$__claude_orca_shell_bin" --root "$__claude_orca_root" -- bash
        fi

        echo "[claude-orca] REFUSING to run agents unsandboxed in $__claude_orca_root: $__claude_orca_check_out" >&2
        claude()   { echo "[claude-orca] REFUSING to run agents unsandboxed in $__claude_orca_root: $__claude_orca_check_out" >&2; return 1; }
        codex()    { echo "[claude-orca] REFUSING to run agents unsandboxed in $__claude_orca_root: $__claude_orca_check_out" >&2; return 1; }
        gemini()   { echo "[claude-orca] REFUSING to run agents unsandboxed in $__claude_orca_root: $__claude_orca_check_out" >&2; return 1; }
        opencode() { echo "[claude-orca] REFUSING to run agents unsandboxed in $__claude_orca_root: $__claude_orca_check_out" >&2; return 1; }
    fi

    # __claude_orca_root and __claude_orca_check_out stay set (not unset)
    # when the refusing functions above were defined: those functions look
    # them up BY NAME at call time, not at definition time, so unsetting
    # here would make every later `claude`/`codex`/... call print an empty
    # reason instead of the real one.
    unset __claude_orca_dir __claude_orca_common __claude_orca_primary
    unset __claude_orca_shell_bin __claude_orca_check_status
fi
