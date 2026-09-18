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
#   3. Deletes every local branch other than main/master and the
#      branches still checked out in some worktree that main contains
#      (`git branch -d`). A branch main does NOT contain is reported
#      "STRANDED branch ... N commit(s) not in main" and is never
#      deleted -- work you could lose must be impossible to miss.
#   4. Sweeps home/ and config/ (the npm cache and opencode node_modules)
#      out of delegate job dirs whose pid is dead (or absent) and whose
#      worktree/ is already gone: receipts, logs, the branch name and the
#      env stay; a live job is untouched.
#
# Usage: worktree-gc [--report] [--quiet] [--project <dir>]
#   --report        print what would happen, delete nothing
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
PROJECT=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --report)    REPORT=1 ;;
        --quiet)     QUIET=1 ;;
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

removed_wt=0
deleted_br=0
swept_jobs=0
stranded=0

# emit <line> -- --report prints exactly the lines a deleting run would
# print, each prefixed "would "; --quiet prints only the STRANDED/FAIL
# lines (the summary line at the end carries the counts); otherwise print
# the line as-is.
emit() {
    local line="$1"
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
    # reports.
    real_path="$(cd "$path" && pwd -P)"
    busy=0
    for cwdlink in /proc/[0-9]*/cwd; do
        [ -e "$cwdlink" ] || continue
        target="$(readlink -f "$cwdlink" 2>/dev/null)" || continue
        case "$target" in
            "$real_path"|"$real_path"/*) busy=1; break ;;
        esac
    done
    if [ "$busy" = "1" ]; then
        emit "busy $path (a running process has it as its cwd)"
        continue
    fi

    status_out="$(git -C "$path" status --porcelain --untracked-files=all 2>/dev/null)"
    if [ -n "$status_out" ]; then
        emit "FAIL: kept $path (uncommitted or untracked changes)"
        stranded=1
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
        emit "removed $path"
    else
        emit "FAIL: could not remove $path ($reason)"
        stranded=1
    fi
done

if [ "$REPORT" = "0" ] && [ "$QUIET" = "0" ] && [ "$n_wt" -le 1 ]; then
    printf 'no worktree other than %s; nothing to sweep\n' "$MAIN_PATH"
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
        printf 'worktree-gc: removed %s worktree(s), deleted %s branch(es), swept %s job dir(s)\n' \
            "$removed_wt" "$deleted_br" "$swept_jobs"
    fi
fi

[ "$stranded" = "1" ] && exit 1
exit 0
