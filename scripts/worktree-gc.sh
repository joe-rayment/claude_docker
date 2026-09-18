#!/usr/bin/env bash
#
# worktree-gc.sh -- one sweep for everything a finished piece of work
# leaves behind in this project (claude-orca-6zg): checked-out worktrees
# whose work is already merged, the local branches that pointed at it, and
# the delegate job dirs whose npm/opencode caches (329 MB measured in this
# folder) outlive the job that made them.
#
#   1. Refuses to collect while the main worktree's HEAD is not on
#      main/master: that is reported STRANDED and NOTHING is deleted --
#      while HEAD points somewhere else, what "the live version" is, is
#      not ours to guess. It never switches branches itself.
#   2. Removes every worktree other than the main one, exactly the
#      semantics of the boot-time sweep it absorbed (busy process /
#      uncommitted changes -> kept; directory gone -> pruned; clean ->
#      removed through Orca's CLI when it is reachable, plain git
#      otherwise). Removing a worktree frees its branch for step 3, so
#      the branch of a merged piece of work goes in the same sweep.
#      A clean worktree whose branch, or detached HEAD, carries commits
#      main does not contain is kept instead and reported STRANDED with
#      "kept: unmerged" -- that is a finished worker whose verification
#      may still be running in it, and the ~4 MB removing it would free
#      buys nothing (claude-orca-mpt, after claude-orca-kbu).
#   3. Deletes every local branch other than main/master and the
#      branches still checked out in some worktree that main contains
#      (`git branch -d`). A branch main does NOT contain is reported
#      "STRANDED branch ... N commit(s) not in main" and is never
#      deleted -- work you could lose must be impossible to miss.
#   4. Sweeps home/ and config/ (the npm cache and opencode node_modules)
#      out of delegate job dirs whose pid is dead (or absent) and whose
#      worktree/ is already gone: receipts, logs, the branch name and the
#      env stay; a live job is untouched.
#   5. Appends one block per run to <project>/.claude-dev/run/
#      worktree-gc.log -- a header line "<ISO-8601 UTC> mode=<mode>
#      orca=<reachable|unreachable> exit=<n>", then a caller= line naming
#      who invoked the sweep (parent, grandparent, great-grandparent
#      cmdline, 100 chars each, " <- " joined -- claude-orca-jh7), then
#      every line the run emitted (the ones --quiet suppresses on stdout
#      included) and, for a busy worktree, the pid, ppid and cmdline of
#      the first process that made it busy; --after-merge also logs the
#      command that triggered it (first 200 chars). A hook run that left
#      a worktree behind explains itself (claude-orca-jqh).
#
# Usage: worktree-gc [--report] [--quiet] [--after-merge] [--project <dir>]
#   --report        print what would happen, delete nothing
#   --after-merge   PostToolUse mode: read the hook JSON from stdin and run
#                   the sweep (quietly) only when the command was a git
#                   merge or a `git branch -d/-D`; exit 0 silently otherwise
#   --quiet         print only STRANDED/FAIL lines and one summary line
#   --project <dir> operate on <dir> (default: $PROJECT_DIR, else the
#                   repo containing $PWD)
# Exit: 0 when nothing is stranded, 1 when any STRANDED/FAIL line was
# printed, 0 with "not a git repo" when there is no repo.

set -uo pipefail

_resolve_script_path() {
    local src="${BASH_SOURCE[0]}" link dir
    while [ -L "$src" ]; do
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(cd "$(dirname "$src")" && pwd)"; src="$dir/$link" ;;
        esac
    done
    printf '%s' "$src"
}
SCRIPT_DIR="$(cd "$(dirname "$(_resolve_script_path)")" && pwd)"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"

REPORT=0
QUIET=0
AFTER_MERGE=0
PROJECT=""
GC_TRIGGER=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --report)    REPORT=1 ;;
        --quiet)     QUIET=1 ;;
        --after-merge) AFTER_MERGE=1 ;;
        --project)
            [ -n "${2:-}" ] || { echo "worktree-gc: --project needs a directory" >&2; exit 2; }
            PROJECT="$2"
            shift
            ;;
        --project=*) PROJECT="${1#--project=}" ;;
        -h|--help)   sed -n '/^# Usage:/,/^# printed/p' "$(_resolve_script_path)" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           echo "worktree-gc: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# --- PostToolUse mode (--after-merge) ----------------------------------------
# The PostToolUse hook runs this on every Bash command; sweeping after
# `git status` would be pure overhead, so the hook payload decides: only a
# git merge or a `git branch -d/-D` (word boundaries -- not mergetool, not
# a bare `git branch`, not --delete) sweeps, and it sweeps quietly.
# Anything else exits 0 silently before git is even consulted.
if [ "$AFTER_MERGE" = "1" ]; then
    am_payload="$(cat 2>/dev/null || true)"
    am_cmd=""
    if [ -n "$am_payload" ] && command -v jq >/dev/null 2>&1; then
        am_cmd="$(printf '%s' "$am_payload" | jq -r '.tool_input.command // empty' 2>/dev/null)" || am_cmd=""
    fi
    am_hit="$(printf '%s' "$am_cmd" 2>/dev/null \
        | grep -E '(^|[^[:alnum:]_])git[[:space:]]+(merge|branch[[:space:]]+-[dD])([^[:alnum:]_]|$)' || true)"
    if [ -z "$am_hit" ]; then
        exit 0
    fi
    QUIET=1
    # The sweep is happening because of this command -- log it (first 200
    # chars) so the run-log block names its own trigger.
    GC_TRIGGER="$am_cmd"
fi

# The SessionStart hook runs this with --quiet and Claude Code's event JSON
# on stdin; the log's hook-session-start mode needs that payload to tell
# the hook run apart from a human's --quiet. Peek only when stdin is not a
# tty (a human at a terminal is never read), bound the read, and fail safe
# to plain quiet. An --after-merge run already consumed stdin above and is
# labeled after-merge regardless.
GC_SESSION_START=0
if [ "$QUIET" = "1" ] && [ "$REPORT" = "0" ] && [ "$AFTER_MERGE" = "0" ] && [ ! -t 0 ]; then
    ss_line=""
    read -r -t 2 ss_line 2>/dev/null || true
    case "$ss_line" in
        *'"hook_event_name":"SessionStart"'*|*'"hook_event_name": "SessionStart"'*) GC_SESSION_START=1 ;;
    esac
fi

if [ -z "$PROJECT" ] && [ -n "${PROJECT_DIR:-}" ]; then
    PROJECT="$PROJECT_DIR"
fi
if [ -z "$PROJECT" ]; then
    PROJECT="$(git rev-parse --show-toplevel 2>/dev/null)" || PROJECT=""
fi
if [ -z "$PROJECT" ] || [ ! -d "$PROJECT" ] || \
   ! git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "${PROJECT:-.} is not a git repo"
    exit 0
fi

# --- the run log -------------------------------------------------------------
# Every run past the repo check appends one block (gc_log_write at each
# exit); a payload that is not a merge/branch-delete exits above and logs
# nothing -- otherwise every Bash tool call would append a block and churn
# the 200 KB cap. Fail-open: a broken log must never break the sweep.
LOG_FILE=""
log_lines=()
_gc_run_dir="$PROJECT/.claude-dev/run"
if mkdir -p "$_gc_run_dir" 2>/dev/null; then
    LOG_FILE="$_gc_run_dir/worktree-gc.log"
fi

# Every block names its caller (claude-orca-jh7): the cmdline of this
# run's parent, then its parent, then its parent, each cut to 100 chars,
# joined with " <- " -- read from /proc/<pid>/cmdline (NUL -> space).
GC_CALLER=""
_gc_caller_pid="${PPID:-}"
_gc_caller_i=0
while [ "$_gc_caller_i" -lt 3 ]; do
    _gc_caller_i=$((_gc_caller_i + 1))
    case "$_gc_caller_pid" in
        ''|*[!0-9]*) break ;;
    esac
    [ -r "/proc/$_gc_caller_pid/cmdline" ] || break
    _gc_caller_cmd="$(tr '\0' ' ' < "/proc/$_gc_caller_pid/cmdline" 2>/dev/null \
        | sed -e 's/[[:space:]]*$//')" || break
    [ -n "$_gc_caller_cmd" ] || break
    _gc_caller_cmd="${_gc_caller_cmd:0:100}"
    if [ -n "$GC_CALLER" ]; then
        GC_CALLER="$GC_CALLER <- $_gc_caller_cmd"
    else
        GC_CALLER="$_gc_caller_cmd"
    fi
    _gc_caller_pid="$(awk '/^PPid:/{print $2}' "/proc/$_gc_caller_pid/status" 2>/dev/null)"
done
[ -n "$GC_CALLER" ] || GC_CALLER="unknown"

removed_wt=0
deleted_br=0
swept_jobs=0
stranded=0
kept_paths=()
kept_branches=()
kept_reasons=()

# emit <line> -- --report prints exactly the lines a deleting run would
# print, each prefixed "would "; --quiet prints only the STRANDED/FAIL
# lines (the summary line at the end carries the counts); otherwise print
# the line as-is. Every line goes into the run log as the run emitted it
# -- the canonical line, before the --report/--quiet transformation -- so
# the log carries what --quiet suppressed too.
emit() {
    local line="$1"
    gc_log_add "$line"
    if [ "$REPORT" = "1" ]; then
        printf 'would %s\n' "$line"
    elif [ "$QUIET" = "1" ]; then
        case "$line" in
            STRANDED*|FAIL*) printf '%s\n' "$line" ;;
        esac
    else
        printf '%s\n' "$line"
    fi
}

# gc_log_add <line> -- queue one line for this run's log block.
gc_log_add() {
    log_lines=(${log_lines[@]+"${log_lines[@]}"} "$1")
}

# gc_log_write <exit-code> -- append the block: the header line, then (for
# an --after-merge run) the command that triggered it, then every line the
# run emitted. orca= names Orca only as far as this run learned it: only a
# run that probed and was answered reachable says reachable -- a run whose
# probe failed and one that never probed (nothing to remove, --report)
# both say unreachable, i.e. "no Orca help was available to this run".
gc_log_write() {
    [ -n "$LOG_FILE" ] || return 0
    local gc_mode="cli" gc_orca="unreachable" gl_line gc_trig
    if [ "$AFTER_MERGE" = "1" ]; then
        gc_mode="after-merge"
    elif [ "$REPORT" = "1" ]; then
        gc_mode="report"
    elif [ "$QUIET" = "1" ] && [ "$GC_SESSION_START" = "1" ]; then
        gc_mode="hook-session-start"
    elif [ "$QUIET" = "1" ]; then
        gc_mode="quiet"
    fi
    [ "$reachable" = "1" ] && gc_orca="reachable"
    {
        printf '%s mode=%s orca=%s exit=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$gc_mode" "$gc_orca" "$1"
        printf 'caller=%s\n' "$GC_CALLER"
        if [ -n "$GC_TRIGGER" ]; then
            gc_trig="$(printf '%s' "$GC_TRIGGER" | tr '\n' ' ')"
            printf 'command: %.200s\n' "$gc_trig"
        fi
        for gl_line in ${log_lines[@]+"${log_lines[@]}"}; do
            printf '%s\n' "$gl_line"
        done
    } >> "$LOG_FILE" 2>/dev/null || return 0
    gc_log_truncate
    return 0
}

# Keep the log bounded: once past 200 KB, keep only the newer half -- the
# newest data (the block a reader is looking for) always survives.
gc_log_truncate() {
    local gc_size gc_half gc_tmp
    gc_size="$(wc -c < "$LOG_FILE" 2>/dev/null)" || return 0
    case "$gc_size" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$gc_size" -gt 204800 ] || return 0
    gc_half=$((gc_size / 2))
    gc_tmp="$LOG_FILE.tmp.$$"
    if tail -c "$gc_half" "$LOG_FILE" 2>/dev/null | tail -n +2 > "$gc_tmp" 2>/dev/null; then
        mv -f "$gc_tmp" "$LOG_FILE" 2>/dev/null || rm -f "$gc_tmp"
    else
        rm -f "$gc_tmp"
    fi
    return 0
}

# The CLI is resolved exactly the way 65-worktree-sweep resolved it,
# because a folder that registered with Orca under one path must ask the
# same CLI about it.
AGENT_HOME="${HOME:-/home/agent}"
ORCA_BIN="${ORCA_BIN:-/opt/orca/orca-ide}"
USER_DATA_DIR="${ORCA_USER_DATA_DIR:-$AGENT_HOME/.config/orca}"

resolve_cli() {
    if [ -n "${ORCA_CLI:-}" ]; then
        printf '%s\n' "$ORCA_CLI"
        return 0
    fi
    for candidate in \
        "$(dirname "$ORCA_BIN")/resources/bin/orca-ide" \
        "$AGENT_HOME/.local/bin/orca-ide" \
        "$AGENT_HOME/.local/bin/orca"
    do
        [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    for name in orca orca-ide; do
        found="$(command -v "$name" 2>/dev/null)"
        [ -n "$found" ] && { printf '%s\n' "$found"; return 0; }
    done
    return 1
}

cli="$(resolve_cli || true)"

orca_call() {  # orca_call <args...> -- CLI call, bounded, with the runtime's user-data dir
    if command -v timeout >/dev/null 2>&1; then
        env ORCA_USER_DATA_PATH="$USER_DATA_DIR" timeout 15 "$cli" "$@"
    else
        env ORCA_USER_DATA_PATH="$USER_DATA_DIR" "$cli" "$@"
    fi
}

# Reachable is asked once per run, lazily: only when a clean worktree is
# about to be removed, and never in --report (nothing is removed there) --
# so a run with nothing to remove makes no round trip at all.
orca_reachable() {
    [ -n "$cli" ] || return 1
    local out
    out="$(orca_call status --json 2>/dev/null)" || return 1
    if command -v jq >/dev/null 2>&1; then
        [ "$(printf '%s' "$out" | jq -r '.result.runtime.reachable // false' 2>/dev/null)" = "true" ]
        return
    fi
    case "$out" in
        *'"reachable":true'*|*'"reachable": true'*) return 0 ;;
    esac
    return 1
}
reachable=""

# Is <pid> an idle Orca worktree terminal rather than live work?
# Measured 2026-09-18 on the real folder: every Orca worktree carries a
# default terminal -- a shell whose parent is the orca-ide daemon process
# and which has no children -- and that shell holds the worktree as its
# cwd forever, so the /proc cwd scan called a finished, merged worktree
# "busy" forever. Such a shell is not work: `orca worktree rm` closes it.
# Anything else (a user's editor, a running build, a shell with children,
# a shell whose parent is not orca-ide) is live work.
is_idle_orca_terminal() {    # is_idle_orca_terminal <pid>
    local pid="$1" ppid pc st
    ppid="$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
    case "$ppid" in ''|*[!0-9]*) return 1 ;; esac
    [ -r "/proc/$ppid/cmdline" ] || return 1
    pc="$(tr '\0' ' ' < "/proc/$ppid/cmdline" 2>/dev/null)"
    case "$pc" in
        *orca-ide*) ;;
        *) return 1 ;;
    esac
    # No child processes: anything waiting on it (a build, a test run,
    # a shell with children) is real work.
    for st in /proc/[0-9]*/status; do
        [ -r "$st" ] || continue
        [ "$(awk '/^PPid:/{print $2}' "$st" 2>/dev/null)" = "$pid" ] && return 1
    done
    return 0
}

# Branches step 2 frees -- the branch of every worktree it removed (or,
# in --report, would remove) and of every pruned one. Step 3 needs them:
# a branch that will be free by the time it runs must not be treated as
# still checked out just because the worktree that held it still stands.
freed_branches=()
remember_freed() {  # remember_freed <branch>
    [ -n "$1" ] || return 0
    local f
    for f in ${freed_branches[@]+"${freed_branches[@]}"}; do
        [ "$f" = "$1" ] && return 0
    done
    freed_branches+=("$1")
}

is_freed() {
    local b="$1" f
    for f in ${freed_branches[@]+"${freed_branches[@]}"}; do
        [ "$f" = "$b" ] && return 0
    done
    return 1
}

# --- the worktree inventory (porcelain: path, then optionally its branch) ---
wt_paths=()
wt_branches=()
_cur=""
_curbr=""
while IFS= read -r line; do
    case "$line" in
        worktree\ *)
            if [ -n "$_cur" ]; then
                wt_paths+=("$_cur")
                wt_branches+=("$_curbr")
            fi
            _cur="${line#worktree }"
            _curbr=""
            ;;
        branch\ refs/heads/*) _curbr="${line#branch refs/heads/}" ;;
    esac
done < <(git -C "$PROJECT" worktree list --porcelain 2>/dev/null)
if [ -n "$_cur" ]; then
    wt_paths+=("$_cur")
    wt_branches+=("$_curbr")
fi

if [ "${#wt_paths[@]}" -eq 0 ]; then
    echo "worktree-gc: cannot list worktrees in $PROJECT" >&2
    gc_log_add "worktree-gc: cannot list worktrees in $PROJECT"
    gc_log_write 2
    exit 2
fi
MAIN_PATH="${wt_paths[0]}"

base=""
if git -C "$PROJECT" show-ref --verify --quiet refs/heads/main; then
    base="main"
elif git -C "$PROJECT" show-ref --verify --quiet refs/heads/master; then
    base="master"
fi
base_label="${base:-main}"

# --- step 1: HEAD of the main worktree -------------------------------------
head_branch="$(git -C "$MAIN_PATH" symbolic-ref --short HEAD 2>/dev/null)" || head_branch=""
case "$head_branch" in
    main|master) ;;
    *)
        if [ -n "$head_branch" ]; then
            emit "STRANDED HEAD is on $head_branch, not $base_label -- the live version is $base_label; merge back or switch"
        else
            emit "STRANDED HEAD is detached, not on $base_label -- the live version is $base_label; merge back or switch"
        fi
        stranded=1
        ;;
esac

# While HEAD is anywhere but main/master the "live version" is ambiguous,
# so nothing below runs: a sweep that deleted branches around an
# unexpected HEAD could eat work nobody has judged yet.
if [ "$stranded" = "0" ]; then

# --- step 2: every worktree other than the main one ------------------------
n_wt="${#wt_paths[@]}"
i=0
while [ "$i" -lt "$n_wt" ]; do
    path="${wt_paths[i]}"
    branch="${wt_branches[i]}"
    i=$((i + 1))
    [ "$path" = "$MAIN_PATH" ] && continue

    if [ ! -d "$path" ]; then
        [ "$REPORT" = "1" ] || git -C "$PROJECT" worktree prune >/dev/null 2>&1
        remember_freed "$branch"
        emit "pruned $path (directory gone)"
        continue
    fi

    # A live process in there is not stale, whatever git thinks of its
    # contents -- scan /proc rather than trust anything the worktree itself
    # reports. Collect every occupant first: an idle Orca terminal does not
    # count, and neither does the orca-ide process it hangs from when that
    # process also sits in the worktree (Orca's own, closed by the rm).
    real_path="$(cd "$path" && pwd -P)"
    busy=0
    busy_pid=""
    busy_first=""
    idle_terminal=0
    occupants=" "
    for cwdlink in /proc/[0-9]*/cwd; do
        [ -e "$cwdlink" ] || continue
        target="$(readlink -f "$cwdlink" 2>/dev/null)" || continue
        case "$target" in
            "$real_path"|"$real_path"/*) ;;
            *) continue ;;
        esac
        proc_pid="${cwdlink#/proc/}"
        proc_pid="${proc_pid%/cwd}"
        occupants="$occupants$proc_pid "
    done
    if [ "$occupants" != " " ]; then
        for occ_pid in $occupants; do
            busy_first="$occ_pid"
            break
        done
        # The idle-terminal question only matters when Orca can actually
        # close one; when it is not reachable, plain `git worktree remove`
        # cannot, so every process still means busy. Asked once per run,
        # and only when a worktree has an occupant to judge.
        if [ -z "$reachable" ]; then
            if orca_reachable; then reachable=1; else reachable=0; fi
        fi
        if [ "$reachable" = "1" ]; then
            idle_pids=" "
            for occ_pid in $occupants; do
                if is_idle_orca_terminal "$occ_pid"; then
                    idle_pids="$idle_pids$occ_pid "
                fi
            done
            if [ "$idle_pids" != " " ]; then
                idle_terminal=1
                forgivable="$idle_pids"
                for e in $idle_pids; do
                    eppid="$(awk '/^PPid:/{print $2}' "/proc/$e/status" 2>/dev/null)"
                    case "$occupants" in
                        *" $eppid "*) forgivable="$forgivable$eppid " ;;
                    esac
                done
                for occ_pid in $occupants; do
                    case "$forgivable" in
                        *" $occ_pid "*) ;;
                        *) busy=1; busy_pid="$occ_pid"; break ;;
                    esac
                done
            else
                busy=1
                busy_pid="$busy_first"
            fi
        else
            busy=1
            busy_pid="$busy_first"
        fi
    fi
    if [ "$busy" = "1" ]; then
        emit "busy $path (a running process has it as its cwd)"
        # The log must explain WHY the worktree was kept: the pid, ppid and
        # cmdline of the first process that made it busy.
        if [ -n "$busy_pid" ]; then
            busy_ppid="$(awk '/^PPid:/{print $2}' "/proc/$busy_pid/status" 2>/dev/null)"
            busy_cmd="$(tr '\0' ' ' < "/proc/$busy_pid/cmdline" 2>/dev/null | tr -d '\n')"
            busy_cmd="${busy_cmd% }"
            gc_log_add "busy pid=$busy_pid ppid=${busy_ppid:-?} cmdline=$busy_cmd"
        fi
        kept_paths+=("$path")
        kept_branches+=("$branch")
        kept_reasons+=("busy")
        continue
    fi

    status_out="$(git -C "$path" status --porcelain --untracked-files=all 2>/dev/null)"
    if [ -n "$status_out" ]; then
        emit "FAIL: kept $path (uncommitted or untracked changes)"
        kept_paths+=("$path")
        kept_branches+=("$branch")
        kept_reasons+=("uncommitted changes")
        stranded=1
        continue
    fi

    # Clean -- but removable only when its branch, or a detached HEAD, is
    # contained in the base (claude-orca-mpt). A clean tree carrying commits
    # main does not have is a finished-but-unverified worker's home: keep it
    # and let the kept-worktree loop in step 3 name it STRANDED with
    # "kept: unmerged", the same shape a busy or dirty keep already gets.
    contained=1
    wt_head=""
    if [ -z "$base" ]; then
        contained=0
    elif [ -n "$branch" ]; then
        git -C "$PROJECT" merge-base --is-ancestor "$branch" "$base" 2>/dev/null || contained=0
    else
        wt_head="$(git -C "$path" rev-parse HEAD 2>/dev/null)" || wt_head=""
        contained=0
        if [ -n "$wt_head" ] && git -C "$PROJECT" merge-base --is-ancestor "$wt_head" "$base" 2>/dev/null; then
            contained=1
        fi
    fi
    if [ "$contained" != "1" ]; then
        kept_paths+=("$path")
        kept_branches+=("$branch")
        kept_reasons+=("unmerged")
        if [ -z "$base" ]; then
            emit "FAIL: kept $path (no $base_label branch to judge merged-ness)"
            stranded=1
        elif [ -z "$branch" ]; then
            n_det="$(git -C "$PROJECT" rev-list --count "$base..$wt_head" 2>/dev/null)" || n_det="?"
            emit "STRANDED detached HEAD at $path: $n_det commit(s) not in $base (worktree kept: unmerged)"
            stranded=1
        fi
        continue
    fi

    if [ "$REPORT" = "1" ]; then
        remember_freed "$branch"
        emit "removed $path"
        continue
    fi

    # Clean. Prefer Orca, because it drops the branch too when it can prove
    # the worktree merged -- but a reachable Orca that answers ok:false, or
    # that answers ok:true and leaves the directory in place, is a refusal,
    # not a removal, and must not be reported as one.
    removed=0
    reason=""
    if [ -z "$reachable" ]; then
        if orca_reachable; then reachable=1; else reachable=0; fi
    fi
    if [ "$reachable" = "1" ]; then
        rm_out="$(orca_call worktree rm --worktree "path:$path" --json 2>/dev/null)"
        rm_ok=0
        if command -v jq >/dev/null 2>&1; then
            [ "$(printf '%s' "$rm_out" | jq -r '.ok // false' 2>/dev/null)" = "true" ] && rm_ok=1
        else
            case "$rm_out" in
                *'"ok":true'*|*'"ok": true'*) rm_ok=1 ;;
            esac
        fi
        if [ "$rm_ok" = "1" ] && [ ! -d "$path" ]; then
            removed=1
        elif [ "$rm_ok" != "1" ]; then
            reason="orca-ide refused the rm"
        else
            reason="orca-ide reported ok but the directory is still there"
        fi
    fi

    if [ "$removed" != "1" ]; then
        # Unreachable, or Orca's rm did not actually take: fall back to
        # plain git. The tree is already confirmed clean on this path, so
        # --force (needed only if the first attempt leaves something behind)
        # throws nothing real away.
        git -C "$PROJECT" worktree remove "$path" >/dev/null 2>&1
        if [ -d "$path" ]; then
            git -C "$PROJECT" worktree remove --force "$path" >/dev/null 2>&1
        fi
        if [ ! -d "$path" ]; then
            removed=1
        elif [ -z "$reason" ]; then
            reason="git worktree remove left the directory in place"
        fi
    fi

    git -C "$PROJECT" worktree prune >/dev/null 2>&1

    if [ "$removed" = "1" ]; then
        removed_wt=$((removed_wt + 1))
        remember_freed "$branch"
        if [ "$idle_terminal" = "1" ]; then
            emit "removed $path (closed Orca's idle terminal)"
        else
            emit "removed $path"
        fi
    else
        emit "FAIL: could not remove $path ($reason)"
        stranded=1
    fi
done

if [ "$REPORT" = "0" ] && [ "$QUIET" = "0" ] && [ "$n_wt" -le 1 ]; then
    printf 'no worktree other than %s; nothing to sweep\n' "$MAIN_PATH"
    gc_log_add "no worktree other than $MAIN_PATH; nothing to sweep"
fi

# --- step 3: local branches ------------------------------------------------
# The checkout state is read here, after the sweep: the branches of the
# worktrees step 2 removed (and pruned) are free now and get judged; the
# branches of the worktrees it kept (busy, dirty) are still checked out
# and are skipped silently.
if [ -n "$base" ]; then
    checked=()
    while IFS= read -r line; do
        case "$line" in
            branch\ refs/heads/*)
                cb="${line#branch refs/heads/}"
                checked+=("$cb")
                ;;
        esac
    done < <(git -C "$PROJECT" worktree list --porcelain 2>/dev/null)

    is_checked_out() {
        local b="$1" c
        for c in ${checked[@]+"${checked[@]}"}; do
            [ "$c" = "$b" ] || continue
            is_freed "$b" && return 1
            return 0
        done
        return 1
    }

    while IFS= read -r b; do
        [ -z "$b" ] && continue
        case "$b" in
            main|master) continue ;;
        esac
        is_checked_out "$b" && continue
        if git -C "$PROJECT" merge-base --is-ancestor "$b" "$base" 2>/dev/null; then
            if [ "$REPORT" = "1" ]; then
                emit "deleted branch $b (merged)"
            elif git -C "$PROJECT" branch -d "$b" >/dev/null 2>&1; then
                deleted_br=$((deleted_br + 1))
                emit "deleted branch $b (merged)"
            else
                emit "FAIL: could not delete branch $b"
                stranded=1
            fi
        else
            n_commits="$(git -C "$PROJECT" rev-list --count "$base..$b" 2>/dev/null)" || n_commits="?"
            emit "STRANDED branch $b: $n_commits commit(s) not in $base -- merge it or \`git branch -D $b\` to drop the work"
            stranded=1
        fi
    done < <(git -C "$PROJECT" for-each-ref --format='%(refname:short)' refs/heads)

    # A branch a kept worktree still holds is skipped above -- but if it
    # carries commits main does not contain, the work behind it must stay
    # impossible to miss: name the branch, the count, and why it was kept.
    j=0
    n_kept="${#kept_paths[@]}"
    while [ "$j" -lt "$n_kept" ]; do
        kept_branch="${kept_branches[j]}"
        case "$kept_branch" in
            main|master|"") j=$((j + 1)); continue ;;
        esac
        if ! git -C "$PROJECT" merge-base --is-ancestor "$kept_branch" "$base" 2>/dev/null; then
            kept_commits="$(git -C "$PROJECT" rev-list --count "$base..$kept_branch" 2>/dev/null)" || kept_commits="?"
            emit "STRANDED branch $kept_branch: $kept_commits commit(s) not in $base (worktree ${kept_paths[j]} kept: ${kept_reasons[j]})"
            stranded=1
        fi
        j=$((j + 1))
    done
fi

# --- step 4: finished delegate job dirs ------------------------------------
delegate_root="$PROJECT/.claude-dev/delegate"
if [ -d "$delegate_root" ]; then
    for job_dir in "$delegate_root"/*/; do
        [ -d "$job_dir" ] || continue
        job="$(basename "$job_dir")"
        pid=""
        if [ -f "$job_dir/pid" ]; then
            pid="$(head -n 1 "$job_dir/pid" 2>/dev/null | tr -cd '0-9')"
        fi
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            continue
        fi
        [ -d "$job_dir/worktree" ] && continue
        if [ "$REPORT" = "1" ]; then
            emit "swept job $job (home, config)"
        elif [ -d "$job_dir/home" ] || [ -d "$job_dir/config" ]; then
            rm -rf "$job_dir/home" "$job_dir/config"
            swept_jobs=$((swept_jobs + 1))
            emit "swept job $job (home, config)"
        fi
    done
fi

fi  # not stranded

# --- summary and exit ------------------------------------------------------
if [ "$QUIET" = "1" ]; then
    if [ "$removed_wt" -ne 0 ] || [ "$deleted_br" -ne 0 ] || [ "$swept_jobs" -ne 0 ] || [ "$stranded" = "1" ]; then
        summary_line="$(printf 'worktree-gc: removed %s worktree(s), deleted %s branch(es), swept %s job dir(s)' \
            "$removed_wt" "$deleted_br" "$swept_jobs")"
        printf '%s\n' "$summary_line"
        gc_log_add "$summary_line"
    fi
fi

gc_exit=0
if [ "$stranded" = "1" ]; then
    gc_exit=1
fi
gc_log_write "$gc_exit"
exit "$gc_exit"
