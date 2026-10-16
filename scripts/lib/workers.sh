#!/usr/bin/env bash
#
# workers.sh -- shared helpers for the Orca-free headless workers
# (claude-orca-9bh.1; plan .claude/plans/ghostty.md "Workers and /tier,
# without Orca"). Sourced, never executed. bash 3.2 clean, because
# lint-bash32.sh scans all of scripts/.
#
# Two kinds of helper live here:
#
#   * the bead/spec helpers (orch_root, orch_dir, orch_bead_json,
#     orch_note_bead, orch_last_handoff, orch_spec, orch_mtime) -- the names
#     kept from the Orca era so every caller is unchanged;
#   * the small shared pieces dispatch / worker-run / workers need:
#     workers_dir, workers_max, workers_inbox_append, workers_job_set.
#
# A job lives at <root>/.claude-dev/run/workers/<job>/ (job.json, spec.md,
# later pid, log.jsonl, receipt.json). Slot lock files sit in
# <root>/.claude-dev/run/workers/slots/. The inbox is
# <root>/.claude-dev/run/orchestration/inbox.jsonl.
#
#   CLAUDE_ORCA_MAX_WORKERS   slot cap override (else .maxWorkers, else 3)

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
# One text, used twice: as the headless worker's spec and, when there is no
# runtime to dispatch into, as the Agent-tool prompt the orchestrator falls
# back to. It ends with the WORKER RULES block, which is the whole reason a
# worker on a foreign model behaves like one of ours.

# orch_last_handoff <notes> -- the last HANDOFF the relay
# appended to a bead's notes as "HANDOFF-AT <ts> dispatch=<id>" followed by
# the block. Prints the lines after the LAST such line, through the first
# following line that starts with "relay:" (included), or up to but not
# including the next line starting with "ORCA " (old relay notes) when there
# is no relay: line, or to the end of the notes otherwise. Exit 1, no output, when
# <notes> has no "HANDOFF-AT " line.
orch_last_handoff() {
    local notes="$1"
    printf '%s\n' "$notes" | awk '
        /^HANDOFF-AT / { last = NR }
        { line[NR] = $0 }
        END {
            if (!last) { exit 1 }
            for (i = last + 1; i <= NR; i++) {
                if (line[i] ~ /^ORCA /) { break }
                print line[i]
                if (line[i] ~ /^relay:/) { break }
            }
        }
    '
}

# orch_spec <bead-json> <bead-id> [mode]
#
# The WORKER RULES are the headless ones: no runtime calls; the worker reports
# in its FINAL message, and asks by ending that message with a line starting
# `QUESTION:`. The optional third argument is accepted (callers still pass
# "headless") and ignored -- there is only one set of rules.
orch_spec() {
    local bj="$1" id="$2" title desc ac notes handoff
    title="$(printf '%s' "$bj" | jq -r '.title // ""')"
    desc="$(printf '%s' "$bj" | jq -r '.description // ""')"
    ac="$(printf '%s' "$bj" | jq -r '.acceptance_criteria // ""')"
    notes="$(printf '%s' "$bj" | jq -r '.notes // ""')"

    printf 'BEAD %s -- %s\n\n' "$id" "$title"
    [ -n "$desc" ] && printf '%s\n\n' "$desc"
    if [ -n "$ac" ]; then
        printf 'ACCEPTANCE CONTRACT (pre-registered; the checker runs it verbatim)\n%s\n\n' "$ac"
    fi
    if printf '%s\n' "$notes" | grep -q -e '^HANDOFF-AT '; then
        handoff="$(orch_last_handoff "$notes")"
        if [ -n "$handoff" ]; then
            printf 'CONTINUE FROM HANDOFF\nA previous worker on this bead stopped at its context budget. Continue from\nits handoff below; do not redo what it lists as done.\n%s\n\n' \
                "$handoff"
        fi
    fi
    cat <<'RULES'
WORKER RULES
- You are a worker on this one slice. Do not delegate, do not spawn agents
  or sub-agents, do not start further workers.
- Work only in this worktree (your current directory) and commit there.
  Never touch another checkout of the repository.
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
- Report in your FINAL message, once, when the slice is done or you are
  blocked: what changed and where, and how you checked it (the exact
  command and what it printed). Nobody reads anything before that.
- If you are blocked on a decision that is not yours, stop and end your
  final message with one line starting `QUESTION:` followed by the
  question. The orchestrator answers and resumes you in this same session.
RULES
}

# --- small portability helpers -------------------------------------------

# orch_mtime <path> -- the file's mtime in epoch seconds. GNU stat first,
# BSD stat second; empty output when neither answers.
orch_mtime() {
    stat -c %Y "$1" 2>/dev/null && return 0
    stat -f %m "$1" 2>/dev/null && return 0
    printf ''
}

# --- jobs, slots and the inbox -------------------------------------------

# workers_dir <root> -- where the jobs (and the slots/ lock dir) live.
workers_dir() { printf '%s/.claude-dev/run/workers' "$1"; }

# workers_max <root> -- the slot cap: CLAUDE_ORCA_MAX_WORKERS, else
# .maxWorkers in <root>/.claude-dev/claude-orca.json (read as data, through
# jq), else 3. A value that is not a whole number >= 1 is skipped, not
# trusted -- zero slots would queue every job forever.
workers_max() {
    local root="$1" n cfg
    n="${CLAUDE_ORCA_MAX_WORKERS:-}"
    case "$n" in ''|*[!0-9]*|0) n="" ;; esac
    if [ -z "$n" ]; then
        cfg="$root/.claude-dev/claude-orca.json"
        if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
            n="$(jq -r '.maxWorkers // empty' "$cfg" 2>/dev/null)" || n=""
        fi
        case "$n" in ''|*[!0-9]*|0) n="" ;; esac
    fi
    printf '%s' "${n:-3}"
}

# workers_inbox_append <root> <json-line> -- append ONE line to
# <root>/.claude-dev/run/orchestration/inbox.jsonl under flock on
# inbox.lock, so lines from parallel runs never interleave. Returns 1 when
# the inbox cannot be written.
workers_inbox_append() {
    local root="$1" line="$2" d
    d="$(orch_dir "$root")"
    mkdir -p "$d" 2>/dev/null || return 1
    line="$(printf '%s' "$line" | tr '\n' ' ')"
    (
        if command -v flock >/dev/null 2>&1; then
            flock 9 || exit 1
        fi
        printf '%s\n' "$line" >>"$d/inbox.jsonl"
    ) 9>"$d/inbox.lock"
}

# workers_job_set <jobdir> <key> <json-value> -- set one key of job.json,
# atomically (jq into a tmp file in the same dir, then mv; flock on
# job.lock so the runner and `workers stop` cannot lose each other's
# update). <json-value> is JSON: 42, true, or '"running"' for a string.
# Returns 1 when job.json is absent or the value is not valid JSON.
workers_job_set() {
    local jd="$1" key="$2" val="$3" f
    f="$jd/job.json"
    [ -f "$f" ] || return 1
    (
        if command -v flock >/dev/null 2>&1; then
            flock 9 || exit 1
        fi
        tmp="$(mktemp "$jd/.job.json.XXXXXX")" || exit 1
        if jq --arg k "$key" --argjson v "$val" '.[$k] = $v' "$f" >"$tmp" 2>/dev/null; then
            mv "$tmp" "$f"
        else
            rm -f "$tmp"
            exit 1
        fi
    ) 9>"$jd/job.lock"
}

# --- opencode's launch env ------------------------------------------------
#
# A headless opencode worker needs the guard token (OPENROUTER_API_KEY) and
# its per-launch config (OPENCODE_CONFIG) without either being on a command
# line, where `ps` would show them. workers_opencode_command composes a
# private env file under the run dir (mode 600) and prints a shell
# fragment that sources it before exec'ing opencode; worker-run sources the
# file itself and ignores the printed string.
#
# OPENROUTER_BASE_URL is exported for codex's benefit; opencode itself does
# NOT read it -- config/opencode/opencode.json hardcodes provider.openrouter
# .options.baseURL to http://127.0.0.1:4141/api/v1, so changing
# CLAUDE_ORCA_GUARD_PORT alone does not move where opencode talks to.

# workers_opencode_command <model> <run_dir> [<variant>] -- writes
# <run_dir>/openrouter-guard.env and prints the sourcing command on stdout.
# Pure given its arguments plus CLAUDE_ORCA_GUARD_PORT.
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
# worker-run reads it by that name.
if ! command -v opencode_launch_config >/dev/null 2>&1; then
    # shellcheck source=opencode-launch.sh
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/opencode-launch.sh"
fi

workers_opencode_command() {
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

