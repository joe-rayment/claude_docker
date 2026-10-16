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
#   runs/<handle>.json          per-coordinator Run record
#                               {run_id, coordinator_handle, created}
#                               (claude-orca-fyv: two coordinators in one
#                               folder each get their own record; the legacy
#                               run.json below stays a mirror of the newest
#                               one so pre-fix readers keep working)
#   run.json                    legacy/empty-handle Run record, same shape
#   dispatch/<dispatch_id>.json {bead, run_id, task_id, dispatch_id, agent,
#                                model, backend, terminal, worktree}
# run/ holds results, state/ holds authority (CLAUDE.md) -- these are
# results: the Mac side never reads them.

# The Orca-free half (root/bead/spec helpers) -- sibling of this file.
# shellcheck source=workers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workers.sh"

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
#
# orch_root, orch_dir, orch_bead_json, orch_note_bead, orch_last_handoff,
# orch_spec and orch_mtime live in workers.sh now (claude-orca-9bh.1: the
# Orca-free workers need them without any of the Orca machinery here); the
# source line at the top of this file keeps every caller of them unchanged.

orch_epic_file() {
    printf '%s/.claude-dev/run/orchestration/epics/%s.json' "$1" "$2"
}
# orch_run_file <root> [<handle>] -- which file names a coordinator's Run
# record. With a non-empty handle, the per-coordinator file
# runs/<handle>.json (claude-orca-fyv: one shared run.json let a second
# coordinator's orca-dispatch overwrite the first one's Run under its
# feet); with an empty handle, the legacy run.json. A handle holding / or
# .. would name a file outside runs/ and is refused: exit 1, no output.
orch_run_file() {
    local root="$1" handle="${2:-}"
    case "$handle" in
        */*|*..*) return 1 ;;
    esac
    if [ -n "$handle" ]; then
        printf '%s/.claude-dev/run/orchestration/runs/%s.json' "$root" "$handle"
        return 0
    fi
    printf '%s/.claude-dev/run/orchestration/run.json' "$root"
}

# orch_run_state_file <root> <handle> -- which run record this coordinator
# READS: the keyed file when its handle has one, the legacy run.json
# otherwise (a pre-fix folder, or an empty handle, keep working;
# claude-orca-fyv). A bad handle is refused.
orch_run_state_file() {
    local root="$1" handle="$2" keyed
    if [ -n "$handle" ]; then
        keyed="$(orch_run_file "$root" "$handle")" || return 1
        if [ -f "$keyed" ]; then
            printf '%s' "$keyed"
            return 0
        fi
    fi
    orch_run_file "$root"
}
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
# The coordinator's Run record (the keyed file, run.json when the handle is
# empty) is its memory of its Run. It is reused whenever the runtime still
# knows that Run AND it belongs to this coordinator, so orca-dispatch and
# orca-run land in the same Run and orca-wait has one mailbox to watch.
# `run-use` is the reachability test: a Run from a dead runtime fails it
# and we make a new one. Two coordinators never share a record again --
# each handle reads and writes only its own keyed file (claude-orca-fyv).
orch_ensure_run() {
    local root="$1" handle="$2"
    local odir run_file legacy_file prev_run prev_coord out run_id coord
    local state from_args
    odir="$(orch_dir "$root")"
    run_file="$(orch_run_file "$root" "$handle")" || {
        printf 'refusing coordinator handle with / or ..: %s\n' "$handle" >&2
        return 1
    }
    legacy_file="$(orch_run_file "$root")"
    mkdir -p "$odir/dispatch" "$odir/runs" || {
        printf 'cannot write %s\n' "$odir" >&2
        return 1
    }

    from_args=()
    [ -n "$handle" ] && from_args=(--from "$handle")

    # A folder dispatched before the fix kept its Run in the legacy file
    # alone: adopt it when it belongs to this coordinator, so the upgrade
    # does not strand a reachable Run. Another coordinator's run is never
    # adopted -- that shared slot was the whole bug.
    if [ -n "$handle" ] && [ "$run_file" != "$legacy_file" ] &&
       [ ! -f "$run_file" ] && [ -f "$legacy_file" ]; then
        prev_coord="$(jq -r '.coordinator_handle // ""' "$legacy_file" 2>/dev/null)"
        if [ "$prev_coord" = "$handle" ]; then
            cp -f "$legacy_file" "$run_file" 2>/dev/null || true
            printf 'adopted the pre-keying Run from %s\n' "$legacy_file" >&2
        fi
    fi

    if [ -f "$run_file" ]; then
        prev_run="$(jq -r '.run_id // ""' "$run_file" 2>/dev/null)"
        prev_coord="$(jq -r '.coordinator_handle // ""' "$run_file" 2>/dev/null)"
        if [ -n "$prev_run" ] &&
           { [ -z "$handle" ] || [ "$prev_coord" = "$handle" ]; }; then
            if out="$(orca_call orchestration run-use --id "$prev_run" \
                        ${from_args[@]+"${from_args[@]}"} --json)"; then
                printf 'reusing Run %s for this coordinator\n' "$prev_run" >&2
                if [ -n "$handle" ] && [ "$run_file" != "$legacy_file" ]; then
                    # the legacy file stays a mirror of the newest keyed
                    # record, for readers that have not learned about runs/
                    cp -f "$run_file" "$legacy_file" 2>/dev/null || true
                fi
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
    state="$(jq -n --arg r "$run_id" --arg c "$coord" \
        --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{run_id: $r, coordinator_handle: $c, created: $t}')"
    printf '%s\n' "$state" >"$run_file"
    if [ -n "$handle" ] && [ "$run_file" != "$legacy_file" ]; then
        cp -f "$run_file" "$legacy_file" 2>/dev/null || true
    fi
    printf 'created Run %s\n' "$run_id" >&2
    printf '%s' "$run_id"
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
# reasoning tokens on. A per-launch config is ALWAYS written now under
# <run_dir>/opencode-launch/, with OPENCODE_CONFIG added to the same env
# file the guard token rides in, even with no variant and no token
# (claude-orca-gh9): opencode's own "ask" default on external_directory and
# doom_loop stalls a dispatched worker forever since nobody is at the
# keyboard to answer the TUI's permission prompt, so the config also carries
# a blanket-allow permission block unless
# CLAUDE_ORCA_OPENCODE_PERMISSIONS=ask opts back into opencode's
# interactive defaults (the config is still written either way).
#
# The config itself is composed by the ONE writer shared with recon
# (scripts/lib/opencode-launch.sh, claude-orca-c3p.2), which sits next to
# this file and is sourced the way the other libs resolve siblings. An
# openai/ model takes the openai provider branch: no guard token is read,
# and the env file carries ONLY the OPENCODE_CONFIG line -- opencode's own
# ChatGPT login supplies the credential, so the token lines would be dead
# weight (and the OPENROUTER_API_KEY a lie about who serves the request).
# The env file keeps the openrouter-guard.env name either way: headless
# dispatch passes it to orca-worker-run by name.
if ! command -v opencode_launch_config >/dev/null 2>&1; then
    # shellcheck source=opencode-launch.sh
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/opencode-launch.sh"
fi

orca_opencode_command() {
    local model="$1" run_dir="$2" variant="${3:-}"
    local token_file token="" port env_file slug cfg_dir cfg
    local base_url="" perm

    port="${CLAUDE_ORCA_GUARD_PORT:-4141}"
    env_file="$run_dir/openrouter-guard.env"

    perm="allow"
    [ "${CLAUDE_ORCA_OPENCODE_PERMISSIONS:-allow}" = "ask" ] && perm="ask"

    slug="$(printf '%s' "$model" | tr '/:' '-')"
    [ -n "$variant" ] && slug="${slug}-${variant}"
    cfg_dir="$run_dir/opencode-launch"
    mkdir -p "$cfg_dir"
    cfg="$cfg_dir/$slug.json"

    case "$model" in
        openai/*)
            opencode_launch_config "$model" "$variant" "$perm" "$cfg"
            printf "OPENCODE_CONFIG='%s'\n" "$cfg" > "$env_file"
            ;;
        *)
            # OpenRouter (and anything else): today's env file, unchanged.
            token_file="$run_dir/openrouter-guard.token"
            if [ -s "$token_file" ]; then
                token="$(cat "$token_file" 2>/dev/null)"
            fi
            [ -n "$token" ] && base_url="http://127.0.0.1:${port}/api/v1"
            opencode_launch_config "$model" "$variant" "$perm" "$cfg" "$base_url"
            {
                if [ -n "$token" ]; then
                    printf "OPENROUTER_API_KEY='%s'\n" "$token"
                    printf "OPENROUTER_BASE_URL='http://127.0.0.1:%s/api/v1'\n" "$port"
                fi
                printf "OPENCODE_CONFIG='%s'\n" "$cfg"
            } > "$env_file"
            ;;
    esac
    chmod 600 "$env_file"

    printf "set -a; . '%s'; set +a; opencode --model %s" "$env_file" "$model"
}

