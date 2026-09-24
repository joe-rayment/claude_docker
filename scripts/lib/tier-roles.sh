#!/usr/bin/env bash
#
# tier-roles.sh -- tier.json v2 helpers, shared by tier-set/prime/gate/
# reconcile (claude-orca-qa2.12; plan .claude/plans/orca-orchestration.md
# "Roles and backends"). Sourced, never executed. bash 3.2 clean.
#
# tier.json v2 keeps every v1 key exactly where it was and ADDS a .roles
# block carrying a backend + agent + model per role:
#
#   { "top": "fable",
#     "worker": "sonnet",                      <- v1 mirror of roles.worker.model
#     "recon":  "haiku",                       <- v1 mirror of roles.recon.model
#     "roles": {
#       "worker":  {"backend":"orca","agent":"opencode","model":"openrouter/qwen/qwen3-coder"},
#       "recon":   {"backend":"subagent","agent":"claude","model":"haiku"},
#       "checker": {"backend":"subagent","agent":"claude","model":"opus"} },
#     "pinned": false, "overdrive": false, "updated": "…Z" }
#
# A v1 file (no .roles) READS as v2 with backend "subagent", agent "claude"
# and the model taken from the v1 key -- that is what tier_role below does,
# so no caller ever needs to know which version it is looking at. A role may
# also carry "pinned": true, meaning "this role was bound explicitly; do not
# re-derive its model from the ladder" (tier-reconcile honours it).
#
#   backends: orca      -- a supervised Orca worker terminal (orca-dispatch)
#             subagent  -- the Claude Code Agent tool, in-process
#   agents:   claude | opencode | codex | gemini

# tier_role <state-file> <worker|recon|checker>
# Prints "<backend>\t<agent>\t<model>\t<pinned>\t<variant>" -- always exits 0; an
# absent/unreadable file yields the subagent+claude defaults with an empty
# model (checker: "inherit" -- a v1 file predates the derived checker rung,
# and "inherit" is what it meant; a v2 file written by tier-set carries the
# rung tier-derive --checker gives for the bound top, claude-orca-8a0.2).
tier_role() {
    local f="${1:-}" r="${2:-}"
    if [ -z "$f" ] || [ ! -f "$f" ] || ! command -v jq >/dev/null 2>&1; then
        case "$r" in
            checker) printf 'subagent\tclaude\tinherit\tfalse\t\n' ;;
            *)       printf 'subagent\tclaude\t\tfalse\t\n' ;;
        esac
        return 0
    fi
    jq -r --arg r "$r" '
        ( if $r == "worker" then (.worker // "")
          elif $r == "recon" then (.recon // "")
          else "inherit" end ) as $v1
        | ((.roles[$r]) // {})
        | [ (.backend // "subagent"),
            (.agent // "claude"),
            (.model // $v1),
            (if (.pinned // false) == true then "true" else "false" end),
            (.variant // "") ]
        | @tsv' "$f" 2>/dev/null || {
        case "$r" in
            checker) printf 'subagent\tclaude\tinherit\tfalse\t\n' ;;
            *)       printf 'subagent\tclaude\t\tfalse\t\n' ;;
        esac
    }
}

# tier_role_field <state-file> <role> <backend|agent|model|pinned|variant>
tier_role_field() {
    local line n
    line="$(tier_role "$1" "$2")"
    case "$3" in
        backend) n=1 ;;
        agent)   n=2 ;;
        model)   n=3 ;;
        pinned)  n=4 ;;
        variant) n=5 ;;
        *)       return 1 ;;
    esac
    printf '%s' "$line" | awk -F'\t' -v n="$n" '{printf "%s", $n}'
}

# tier_role_label <backend> <agent> <model>
# "orca:opencode:openrouter/qwen/qwen3-coder" -- the agent segment is shown
# only when it is not the default (claude), so a plain Anthropic binding
# reads as "subagent:sonnet".
tier_role_label() {
    local b="${1:-subagent}" a="${2:-claude}" m="${3:-}" v="${4:-}"
    [ -n "$m" ] || m="<unbound>"
    if [ "$a" = "claude" ]; then
        printf '%s:%s' "$b" "$m"
    else
        printf '%s:%s:%s' "$b" "$a" "$m"
    fi
    # A reasoning-effort variant (roles.<role>.variant, claude-orca-1w8)
    # reads as "@high" on the end -- the same spelling /tier accepts.
    [ -n "$v" ] && printf '@%s' "$v"
    return 0
}

# The default worker vendor when this folder has an OpenRouter key
# (claude-orca-qa2.20; plan .claude/plans/orca-orchestration.md "Default
# stack and data residency"): Fable orchestrates, the most capable GLM
# executes. The provider that actually serves it is not decided here -- the
# in-VM guard forces config/provider-policy.json's allowlist onto every
# request, which is what keeps a Chinese model on US/Canadian/European
# hardware.
#
# Both defaults (and every OpenRouter route in config/delegate-routes.json
# that has one) are OpenRouter's "~<vendor>/<family>-latest" aliases, the
# OpenRouter twin of Claude Code's fable/opus/sonnet: OpenRouter redirects
# each request to the family's newest model, so a release needs no edit here
# and no re-bind -- the day luna still meant gpt-5.6-luna after gpt-6-luna
# shipped is the day these stopped naming versions.
TIER_OPENROUTER_DEFAULT_MODEL="openrouter/~z-ai/glm-latest"

# The RECON rung's OpenRouter default (claude-orca-8a0.2). Recon is fan-out
# lookup work -- find the callers, list the usages, summarise the directory --
# where latency and price matter and depth does not, so the flash-class sibling
# of the worker GLM is the right seat for it. `/tier recon openrouter` (the
# bare spec, no model named) binds exactly this.
TIER_OPENROUTER_RECON_MODEL="openrouter/~z-ai/glm-flash-latest"

# tier_openrouter_role_default <worker|recon|checker> -- the OpenRouter model
# a bare `openrouter` spec binds for that role: the flash rung for recon, the
# full-size GLM for anything else.
tier_openrouter_role_default() {
    case "${1:-}" in
        recon) printf '%s\n' "$TIER_OPENROUTER_RECON_MODEL" ;;
        *)     printf '%s\n' "$TIER_OPENROUTER_DEFAULT_MODEL" ;;
    esac
}

# tier_openrouter_key_file -- where this folder's OpenRouter key lives:
# .claude-dev/home/.openrouter.key, the file `claude-dev key openrouter`
# writes (scripts/launcher.sh). TIER_OPENROUTER_KEY_FILE overrides it
# (tests). Falls back to $CLAUDE_ORCA_HOME/$HOME when the project cannot be
# resolved -- inside the VM $HOME *is* .claude-dev/home.
tier_openrouter_key_file() {
    local p=""
    if [ -n "${TIER_OPENROUTER_KEY_FILE:-}" ]; then
        printf '%s\n' "$TIER_OPENROUTER_KEY_FILE"
        return 0
    fi
    if command -v project_dir >/dev/null 2>&1; then
        p="$(project_dir 2>/dev/null)" || p=""
    fi
    if [ -n "$p" ]; then
        printf '%s\n' "$p/.claude-dev/home/.openrouter.key"
    else
        printf '%s\n' "${CLAUDE_ORCA_HOME:-$HOME}/.openrouter.key"
    fi
}

# tier_openrouter_key_present -- does this folder have an OpenRouter key at
# all? The env var (what agent terminals carry -- the GUARD TOKEN, in the
# wired-up VM) or a non-empty key file. Never prints, never leaks the value.
tier_openrouter_key_present() {
    [ -n "${OPENROUTER_API_KEY:-}" ] && return 0
    local f
    f="$(tier_openrouter_key_file)"
    [ -n "$f" ] && [ -s "$f" ]
}

# tier_orca_reachable -- is an Orca runtime up? `orca-ide status --json`
# (falling back to `orca`), 2s cap, parsed as .runtime.reachable. Nothing is
# cached: the answer is only ever used at bind time. No CLI on PATH, no
# `timeout`-able run, or any error at all => not reachable (=> the subagent
# backend, which always works).
#   TIER_ORCA_PROBE_DISABLE=1  skip the probe entirely (always unreachable)
#   TIER_ORCA_PROBE_CMD=<cmd>  probe command override (tests)
tier_orca_reachable() {
    local cmd out
    [ "${TIER_ORCA_PROBE_DISABLE:-}" = "1" ] && return 1
    command -v jq >/dev/null 2>&1 || return 1
    cmd="${TIER_ORCA_PROBE_CMD:-}"
    if [ -z "$cmd" ]; then
        if command -v orca-ide >/dev/null 2>&1; then
            cmd="orca-ide"
        elif command -v orca >/dev/null 2>&1; then
            cmd="orca"
        else
            return 1
        fi
    fi
    if command -v timeout >/dev/null 2>&1; then
        out=$(timeout 2 $cmd status --json 2>/dev/null) || return 1
    else
        out=$($cmd status --json 2>/dev/null) || return 1
    fi
    [ -n "$out" ] || return 1
    # Orca 1.4.197 wraps every CLI answer in {"ok":…,"result":{…}}, so the
    # status payload lives at .result.runtime; the flat shape is accepted
    # too, for an older CLI (or a TIER_ORCA_PROBE_CMD stub) that emits it.
    printf '%s' "$out" |
        jq -e '((.result.runtime.reachable // .runtime.reachable) == true)' \
        >/dev/null 2>&1
}

# tier_openrouter_guard_token_file -- <root>/.claude-dev/run/
# openrouter-guard.token, written by entrypoint.sh at boot and by
# scripts/openrouter-auth.sh mid-session when it starts a guard. Resolved
# the same way the rest of this file resolves a root: run_dir() when
# paths.sh is sourced alongside this file (the normal case -- tier-set.sh
# sources both), else CLAUDE_ORCA_ROOT directly (a caller -- e.g. the test
# suite -- that sources only tier-roles.sh). Exit 1, no output, if neither
# resolves.
tier_openrouter_guard_token_file() {
    local r
    if command -v run_dir >/dev/null 2>&1; then
        r="$(run_dir 2>/dev/null)" || r=""
        if [ -n "$r" ]; then
            printf '%s/openrouter-guard.token\n' "$r"
            return 0
        fi
    fi
    [ -n "${CLAUDE_ORCA_ROOT:-}" ] || return 1
    printf '%s/.claude-dev/run/openrouter-guard.token\n' "$CLAUDE_ORCA_ROOT"
}

# tier_openrouter_ready -- can an OpenRouter worker actually run right now?
# True (0) when OPENROUTER_API_KEY is already set (an agent terminal
# launched with the credential), or when the guard's token file is
# non-empty AND something answers on its port. A token file with no
# listener behind it is NOT readiness -- the guard that minted it may have
# died, or the file is stale -- which is what distinguishes this from
# tier_openrouter_key_present above: that one only checks the key file the
# Mac side writes and knows nothing about whether a guard is actually up.
# False (1) otherwise.
#   CLAUDE_ORCA_GUARD_PORT   the guard's loopback port (default 4141 -- the
#                            same knob entrypoint.sh's guard startup and
#                            orca-orch.sh's orca_opencode_command use)
tier_openrouter_ready() {
    [ -n "${OPENROUTER_API_KEY:-}" ] && return 0
    local f port
    f="$(tier_openrouter_guard_token_file 2>/dev/null)" || return 1
    [ -n "$f" ] && [ -s "$f" ] || return 1
    port="${CLAUDE_ORCA_GUARD_PORT:-4141}"
    ( exec 3<>"/dev/tcp/127.0.0.1/$port" ) 2>/dev/null
}
