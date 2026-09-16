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
orch_epic_file() {
    printf '%s/.claude-dev/run/orchestration/epics/%s.json' "$1" "$2"
}
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

# --- one Run per coordinator ---------------------------------------------

# orch_ensure_run <root> <handle> -- the Run id on stdout, human notes on
# stderr; exit 1 if the runtime would not give us one.
#
# run.json is the coordinator's memory of its Run. It is reused whenever
# the runtime still knows that Run AND it belongs to this coordinator, so
# orca-dispatch and orca-run land in the same Run and orca-wait has one
# mailbox to watch. `run-use` is the reachability test: a Run from a dead
# runtime fails it and we make a new one.
orch_ensure_run() {
    local root="$1" handle="$2"
    local odir run_file prev_run prev_coord out run_id coord
    local from_args
    odir="$(orch_dir "$root")"
    run_file="$(orch_run_file "$root")"
    mkdir -p "$odir/dispatch" || { printf 'cannot write %s\n' "$odir" >&2; return 1; }

    from_args=()
    [ -n "$handle" ] && from_args=(--from "$handle")

    if [ -f "$run_file" ]; then
        prev_run="$(jq -r '.run_id // ""' "$run_file" 2>/dev/null)"
        prev_coord="$(jq -r '.coordinator_handle // ""' "$run_file" 2>/dev/null)"
        if [ -n "$prev_run" ] &&
           { [ -z "$handle" ] || [ "$prev_coord" = "$handle" ]; }; then
            if out="$(orca_call orchestration run-use --id "$prev_run" \
                        ${from_args[@]+"${from_args[@]}"} --json)"; then
                printf 'reusing Run %s for this coordinator\n' "$prev_run" >&2
                printf '%s' "$prev_run"
                return 0
            fi
            printf 'Run %s is gone (%s); creating a new one\n' \
                "$prev_run" "$(orca_error "$out")" >&2
        fi
    fi

    out="$(orca_call orchestration run-create \
        --objective "claude-orca orchestrator: $root" \
        ${from_args[@]+"${from_args[@]}"} --json)" || {
        printf 'run-create failed: %s\n' "$(orca_error "$out")" >&2
        return 1
    }
    run_id="$(orca_field "$out" '.result.run.id')"
    [ -n "$run_id" ] || { printf 'run-create returned no run id\n' >&2; return 1; }
    coord="$(orca_field "$out" '.result.run.coordinator_handle')"
    [ -n "$coord" ] || coord="$handle"
    jq -n --arg r "$run_id" --arg c "$coord" \
        --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{run_id: $r, coordinator_handle: $c, created: $t}' >"$run_file"
    printf 'created Run %s\n' "$run_id" >&2
    printf '%s' "$run_id"
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
- Stay visible: after every commit, and at least every 5 minutes of work,
  send one heartbeat --
  `orca-ide orchestration send --type heartbeat --subject alive
   --task-id <task id> --dispatch-id <dispatch id> --json`
  A worker that goes quiet for longer than the orchestrator's stall window
  (a commit, a file change or a heartbeat all count as being alive) is
  nudged once through its terminal and then replaced.
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

# --- opencode's command line ----------------------------------------------
#
# Orca locks its user-data-dir when --serve starts, and seed-orca-state.sh
# (which is what writes agentDefaultEnv.opencode) runs before that -- so a
# guard started mid-session, after auth, is invisible to Orca's own env for
# a dispatched worker. orca_opencode_command works around that by composing
# the terminal command itself: when a guard token exists at dispatch time,
# it writes a private env file next to it and has the command source that
# file before exec'ing opencode, so the token is never on the command line
# (visible in `ps`) and never in Orca's own state.
#
# OPENROUTER_BASE_URL is exported for codex's benefit; opencode itself does
# NOT read it -- config/opencode/opencode.json hardcodes provider.openrouter
# .options.baseURL to http://127.0.0.1:4141/api/v1, so changing
# CLAUDE_ORCA_GUARD_PORT alone does not move where opencode talks to.

# orca_opencode_command <model> <run_dir> [<variant>] -- the command string
# for `terminal create --command`, on stdout. Pure given its arguments plus
# CLAUDE_ORCA_GUARD_PORT: no Orca calls.
#
# A role's reasoning-effort variant (tier.json roles.<role>.variant,
# claude-orca-1w8) has no CLI flag on the opencode TUI -- verified in this
# container on opencode 1.18.25 (2026-09-16): only a config file naming
# provider.openrouter.models.<vendor/model>.options.reasoning.effort turns
# reasoning tokens on. So whenever a variant is given OR a guard token
# exists, a per-launch config is written under <run_dir>/opencode-launch/
# and OPENCODE_CONFIG is added to the same env file the guard token rides
# in -- no variant and no token stays the original bare command, no files.
orca_opencode_command() {
    local model="$1" run_dir="$2" variant="${3:-}"
    local token_file token="" port env_file slug cfg_dir cfg vendor_model
    local base_url="" api_key_json="null"

    token_file="$run_dir/openrouter-guard.token"
    if [ -s "$token_file" ]; then
        token="$(cat "$token_file" 2>/dev/null)"
    fi

    if [ -z "$token" ] && [ -z "$variant" ]; then
        printf 'opencode --model %s' "$model"
        return 0
    fi

    port="${CLAUDE_ORCA_GUARD_PORT:-4141}"
    env_file="$run_dir/openrouter-guard.env"
    vendor_model="${model#openrouter/}"

    slug="$(printf '%s' "$model" | tr '/:' '-')"
    [ -n "$variant" ] && slug="${slug}-${variant}"
    cfg_dir="$run_dir/opencode-launch"
    mkdir -p "$cfg_dir"
    cfg="$cfg_dir/$slug.json"

    if [ -n "$token" ]; then
        base_url="http://127.0.0.1:${port}/api/v1"
        api_key_json='{"apiKey":"{env:OPENROUTER_API_KEY}","baseURL":"'"$base_url"'"}'
    fi

    ( umask 077 && jq -n \
        --argjson options "$api_key_json" \
        --arg vm "$vendor_model" --arg eff "$variant" --argjson havemodels "$([ -n "$variant" ] && echo true || echo false)" \
        '{"$schema": "https://opencode.ai/config.json",
          provider: { openrouter: (
            { }
            + (if $options != null then { options: $options } else {} end)
            + (if $havemodels then { models: { ($vm): { options: { reasoning: { effort: $eff } } } } } else {} end)
          ) } }' >"$cfg" )
    chmod 600 "$cfg"

    {
        if [ -n "$token" ]; then
            printf "OPENROUTER_API_KEY='%s'\n" "$token"
            printf "OPENROUTER_BASE_URL='http://127.0.0.1:%s/api/v1'\n" "$port"
        fi
        printf "OPENCODE_CONFIG='%s'\n" "$cfg"
    } > "$env_file"
    chmod 600 "$env_file"

    printf "set -a; . '%s'; set +a; opencode --model %s" "$env_file" "$model"
}

# --- small portability helpers -------------------------------------------

# orch_mtime <path> -- the file's mtime in epoch seconds. GNU stat first,
# BSD stat second; empty output when neither answers.
orch_mtime() {
    stat -c %Y "$1" 2>/dev/null && return 0
    stat -f %m "$1" 2>/dev/null && return 0
    printf ''
}
