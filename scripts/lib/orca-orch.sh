#!/usr/bin/env bash
#
# orca-orch.sh -- shared helpers for the orchestrator's Orca tools
# (claude-orca-qa2.13; plan .claude/plans/orca-orchestration.md "The
# orchestrator's tools"). Sourced, never executed. bash 3.2 clean, because
# lint-bash32.sh scans all of scripts/.
#
# The Orca CLI answers with one envelope: {"id":…,"ok":true|false,
# "result":{…}} or {"ok":false,"error":{"code":…,"message":…}}. Everything
# here goes through orca_call/orca_field so no caller has to know that, and
# so a runtime that is simply not up reads as "unreachable" rather than as
# a crash.
#
#   ORCA_CLI_BIN / CLAUDE_ORCA_ORCA_CLI   override the CLI (tests, VMs)
#   ORCA_USER_DATA_PATH                   which runtime to talk to
#
# Run state lives at <root>/.claude-dev/run/orchestration/:
#   run.json                    {run_id, coordinator_handle, created}
#   dispatch/<dispatch_id>.json {bead, run_id, task_id, dispatch_id, agent,
#                                model, backend, terminal, worktree}
# run/ holds results, state/ holds authority (CLAUDE.md) -- these are
# results: the Mac side never reads them.

# --- the CLI -------------------------------------------------------------

orca_cli() {
    local c
    c="${ORCA_CLI_BIN:-${CLAUDE_ORCA_ORCA_CLI:-}}"
    if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
    if command -v orca-ide >/dev/null 2>&1; then printf 'orca-ide'; return 0; fi
    if command -v orca >/dev/null 2>&1; then printf 'orca'; return 0; fi
    if [ -x /opt/orca/resources/bin/orca-ide ]; then
        printf '/opt/orca/resources/bin/orca-ide'; return 0
    fi
    return 1
}

# orca_call <args...> -- runs the CLI, prints its raw JSON on stdout.
# Returns 0 when the envelope says ok, 1 otherwise (the CLI's own exit code
# is deliberately ignored: worker-start exits 1 for a non-ready worker that
# nevertheless produced a Dispatch, and the caller decides what that means).
#
# </dev/null and 3>&- are not decoration: the first CLI call in a session
# spawns Orca's DETACHED daemon, which inherits whatever descriptors it was
# handed and outlives the command by design. Handed a pipe -- a shell
# pipeline, a bats run, `orca-dispatch … | jq` -- it holds the write end
# open forever and the reader never sees EOF. Every invocation here gets a
# closed stdin and no inherited fd 3 so nothing downstream can hang on it.
orca_call() {
    local cli out
    cli="$(orca_cli)" || return 1
    out="$("$cli" "$@" 2>/dev/null </dev/null 3>&-)"
    [ -n "$out" ] || return 1
    printf '%s' "$out"
    printf '%s' "$out" | jq -e '.ok == true' >/dev/null 2>&1
}

# orca_field <json> <jq-filter> -- prints "" for null/absent.
orca_field() {
    printf '%s' "$1" | jq -r "($2) // \"\"" 2>/dev/null
}

orca_error() {
    printf '%s' "$1" | jq -r '.error.message // .error.code // "unknown error"' 2>/dev/null
}

# orca_reachable -- is a runtime up? `status --json` is cheap and never
# blocks; both the current (.result.runtime) and the flat legacy shape count.
orca_reachable() {
    local cli out
    command -v jq >/dev/null 2>&1 || return 1
    cli="$(orca_cli)" || return 1
    if command -v timeout >/dev/null 2>&1; then
        out="$(timeout 10 "$cli" status --json 2>/dev/null </dev/null 3>&-)" || return 1
    else
        out="$("$cli" status --json 2>/dev/null </dev/null 3>&-)" || return 1
    fi
    [ -n "$out" ] || return 1
    printf '%s' "$out" |
        jq -e '((.result.runtime.reachable // .runtime.reachable) == true)' \
        >/dev/null 2>&1
}

# --- where we are --------------------------------------------------------

# orch_root -- CLAUDE_ORCA_ROOT, else the bootstrapped project, else the
# git toplevel. Exit 1, no output, if none of them resolve.
orch_root() {
    if [ -n "${CLAUDE_ORCA_ROOT:-}" ] && [ -d "$CLAUDE_ORCA_ROOT" ]; then
        printf '%s' "$CLAUDE_ORCA_ROOT"; return 0
    fi
    local r
    if command -v claude_orca_root >/dev/null 2>&1; then
        r="$(claude_orca_root 2>/dev/null)" || r=""
        if [ -n "$r" ]; then printf '%s' "$r"; return 0; fi
    fi
    r="$(git rev-parse --show-toplevel 2>/dev/null)" || r=""
    [ -n "$r" ] || return 1
    printf '%s' "$r"
}

orch_dir()      { printf '%s/.claude-dev/run/orchestration' "$1"; }
orch_run_file() { printf '%s/.claude-dev/run/orchestration/run.json' "$1"; }
orch_disp_file() {
    printf '%s/.claude-dev/run/orchestration/dispatch/%s.json' "$1" "$2"
}

# orch_handle [<--from value>] -- the coordinator terminal handle: the
# explicit one, else ORCA_TERMINAL_HANDLE, else ORCA_PANE_KEY (an agent
# terminal exports it). Empty output means "let the CLI resolve itself",
# which is what happens inside a live Orca terminal.
orch_handle() {
    if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
    if [ -n "${ORCA_TERMINAL_HANDLE:-}" ]; then
        printf '%s' "$ORCA_TERMINAL_HANDLE"; return 0
    fi
    if [ -n "${ORCA_PANE_KEY:-}" ]; then printf '%s' "$ORCA_PANE_KEY"; return 0; fi
    printf ''
}

# --- the bead ------------------------------------------------------------

# orch_bead_json <root> <bead-id> -- the bead as one JSON object.
orch_bead_json() {
    local root="$1" id="$2" out
    command -v bd >/dev/null 2>&1 || return 1
    out="$(cd "$root" 2>/dev/null && bd show "$id" --json 2>/dev/null)" || return 1
    [ -n "$out" ] || return 1
    printf '%s' "$out" |
        jq -e -c 'if type == "array" then .[0] else . end' 2>/dev/null
}

# orch_note_bead <root> <bead-id> <text> -- best effort; never fatal.
orch_note_bead() {
    local root="$1" id="$2" text="$3"
    command -v bd >/dev/null 2>&1 || return 0
    ( cd "$root" 2>/dev/null && bd update "$id" --append-notes "$text" ) \
        >/dev/null 2>&1 || return 0
}

# --- the Task spec -------------------------------------------------------
#
# One text, used twice: as the Orca Task spec and, when there is no runtime
# to dispatch into, as the Agent-tool prompt the orchestrator falls back to.
# It ends with the WORKER RULES block, which is the whole reason a worker
# on a foreign model behaves like one of ours.

# orch_spec <bead-json> <bead-id>
orch_spec() {
    local bj="$1" id="$2" title desc ac
    title="$(printf '%s' "$bj" | jq -r '.title // ""')"
    desc="$(printf '%s' "$bj" | jq -r '.description // ""')"
    ac="$(printf '%s' "$bj" | jq -r '.acceptance_criteria // ""')"

    printf 'BEAD %s -- %s\n\n' "$id" "$title"
    [ -n "$desc" ] && printf '%s\n\n' "$desc"
    if [ -n "$ac" ]; then
        printf 'ACCEPTANCE CONTRACT (pre-registered; the checker runs it verbatim)\n%s\n\n' "$ac"
    fi
    cat <<'RULES'
WORKER RULES
- You are a worker on this one slice. Do not delegate, do not spawn agents
  or sub-agents, do not start further Orca workers.
- You do not close the bead and you never write a VERIFIED line on it: that
  record belongs to the orchestrator, after an independent checker has run.
- Verify by running the real thing, never a stand-in. Install whatever that
  needs. Report the command you ran and the output you saw.
- When the bead carries an acceptance contract: write the test first, run
  it, observe it fail, commit the test ALONE with a pathspec-limited
  `git commit -- <test file>`, and note RED-AT: <sha> on the bead with
  `bd update <bead> --append-notes`. Then implement, run the contract's
  CHECK verbatim, commit the implementation, note GREEN-AT: <sha>. The
  FROZEN files are frozen from the RED commit onward -- never edit one to
  make an implementation pass.
- Ask before guessing past a decision that is not yours:
  `orca-ide orchestration ask --question "<question>" --json` blocks until
  the orchestrator answers.
- Report exactly once, when the slice is done or you are blocked (the ids
  are in the dispatch preamble above; --outcome is succeeded or failed):
  `orca-ide orchestration send --type worker_done --subject "<bead> done"
   --body "<what changed, where, how you checked it>"
   --task-id <task id> --dispatch-id <dispatch id>
   --outcome succeeded --files-modified <comma,separated,paths> --json`
RULES
}

# orch_fallback <spec> <model> -- the Agent-tool spec printed when nothing
# was dispatched into Orca (unreachable runtime, or --backend subagent).
orch_fallback() {
    printf 'SUBAGENT FALLBACK: spawn Agent(subagent_type=executor, model=%s) with this prompt:\n\n' "${2:-inherit}"
    printf '%s\n' "$1"
}
