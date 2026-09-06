#!/usr/bin/env bash
#
# tier-roles.sh -- tier.json v2 helpers, shared by tier-set/prime/gate/
# reconcile (claude-orca-qa2.12; plan .claude/plans/orca-orchestration.md
# "Roles and backends"). Sourced, never executed. bash 3.2 clean.
#
# tier.json v2 keeps every v1 key exactly where it was and ADDS a .roles
# block carrying a backend + agent + model per role:
#
#   { "top": "claude-fable-5",
#     "worker": "claude-sonnet-5",              <- v1 mirror of roles.worker.model
#     "recon":  "claude-haiku-4-5-20251001",    <- v1 mirror of roles.recon.model
#     "roles": {
#       "worker":  {"backend":"orca","agent":"opencode","model":"openrouter/qwen/qwen3-coder"},
#       "recon":   {"backend":"subagent","agent":"claude","model":"claude-haiku-4-5-20251001"},
#       "checker": {"backend":"subagent","agent":"claude","model":"inherit"} },
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
# Prints "<backend>\t<agent>\t<model>\t<pinned>" -- always exits 0; an
# absent/unreadable file yields the subagent+claude defaults with an empty
# model (checker: "inherit").
tier_role() {
    local f="${1:-}" r="${2:-}"
    if [ -z "$f" ] || [ ! -f "$f" ] || ! command -v jq >/dev/null 2>&1; then
        case "$r" in
            checker) printf 'subagent\tclaude\tinherit\tfalse\n' ;;
            *)       printf 'subagent\tclaude\t\tfalse\n' ;;
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
            (if (.pinned // false) == true then "true" else "false" end) ]
        | @tsv' "$f" 2>/dev/null || {
        case "$r" in
            checker) printf 'subagent\tclaude\tinherit\tfalse\n' ;;
            *)       printf 'subagent\tclaude\t\tfalse\n' ;;
        esac
    }
}

# tier_role_field <state-file> <role> <backend|agent|model|pinned>
tier_role_field() {
    local line n
    line="$(tier_role "$1" "$2")"
    case "$3" in
        backend) n=1 ;;
        agent)   n=2 ;;
        model)   n=3 ;;
        pinned)  n=4 ;;
        *)       return 1 ;;
    esac
    printf '%s' "$line" | awk -F'\t' -v n="$n" '{printf "%s", $n}'
}

# tier_role_label <backend> <agent> <model>
# "orca:opencode:openrouter/qwen/qwen3-coder" -- the agent segment is shown
# only when it is not the default (claude), so a plain Anthropic binding
# reads as "subagent:claude-sonnet-5".
tier_role_label() {
    local b="${1:-subagent}" a="${2:-claude}" m="${3:-}"
    [ -n "$m" ] || m="<unbound>"
    if [ "$a" = "claude" ]; then
        printf '%s:%s' "$b" "$m"
    else
        printf '%s:%s:%s' "$b" "$a" "$m"
    fi
}

# The default worker vendor when this folder has an OpenRouter key
# (claude-orca-qa2.20; plan .claude/plans/orca-orchestration.md "Default
# stack and data residency"): Fable orchestrates, the most capable GLM
# executes. The provider that actually serves it is not decided here -- the
# in-VM guard forces config/provider-policy.json's allowlist onto every
# request, which is what keeps the traffic out of China.
TIER_OPENROUTER_DEFAULT_MODEL="openrouter/z-ai/glm-5.3"

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
