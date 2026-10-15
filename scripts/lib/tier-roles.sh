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
#       "worker":  {"backend":"headless","agent":"opencode","model":"openrouter/qwen/qwen3-coder"},
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
#   backends: headless  -- a detached process `dispatch <bead>` starts:
#                          `claude -p` or `opencode run`, per the agent
#             subagent  -- the Claude Code Agent tool, in-process
#   agents:   claude | opencode | codex | gemini
#
# MIGRATION ON READ (claude-orca-9bh.2): a tier.json written before Orca was
# dropped may carry backend "orca". tier_role maps it where it is read --
# orca + claude -> subagent; orca + any other agent -> headless; any other
# unknown backend -> subagent -- and tier-reconcile's rewrite filter applies
# the same mapping, so the next reconcile stores the new word. Writers never
# write "orca" again.

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
        | (.agent // "claude") as $ag
        | (.backend // "subagent") as $bk
        | [ (if $bk == "headless" then "headless"
             elif $bk == "orca" and $ag != "claude" then "headless"
             else "subagent" end),
            $ag,
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
# "headless:opencode:openrouter/qwen/qwen3-coder" -- the agent segment is shown
# only when it is not the default (claude), so a plain Anthropic binding
# reads as "subagent:sonnet".
# tier_claude_effort <effort> [settings] -- one effort word on Claude's own
# scale. /tier takes the union of every agent's words (none minimal low
# medium high xhigh max) so a phrase never has to know which agent it lands
# on; Claude has no "minimal", so it reads as the nearest step, "low". The
# settings file's effortLevel stops at xhigh ("max" is per-session in
# Claude Code), so `settings` caps it there. Empty in, empty out.
tier_claude_effort() {
    case "$1" in
        none|"") return 0 ;;
        minimal) printf 'low' ;;
        max)     if [ "${2:-}" = "settings" ]; then printf 'xhigh'; else printf 'max'; fi ;;
        *)       printf '%s' "$1" ;;
    esac
}

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

# --- OpenAI direct (claude-orca-c3p.2) -------------------------------------
#
# The second opencode provider beside OpenRouter: the user's own ChatGPT
# subscription, signed in with opencode's own login (`/tier auth openai`
# -> scripts/openai-auth.sh, opencode's headless device flow). Tokens land
# in opencode's auth store and opencode refreshes them itself, so -- unlike
# OpenRouter -- no guard proxy and no key file: the credential never leaves
# opencode. Models are spelled openai/<id> (or the openai/~<family>-latest
# alias, resolved AT LAUNCH to the newest id the subscription serves, the
# same way OpenRouter's ~-latest aliases work server-side).

# The default worker/recon models for a bare `openai` bind, in the same
# ~<family>-latest alias form (epic claude-orca-c3p DESIGN 2): the newest
# balanced GPT Terra executes, the newest efficient GPT Luna recons.
TIER_OPENAI_WORKER_MODEL="openai/~gpt-terra-latest"
TIER_OPENAI_RECON_MODEL="openai/~gpt-luna-latest"

# tier_openai_role_default <worker|recon|checker> -- the OpenAI model a
# bare `openai` spec binds for that role.
tier_openai_role_default() {
    case "${1:-}" in
        recon) printf '%s\n' "$TIER_OPENAI_RECON_MODEL" ;;
        *)     printf '%s\n' "$TIER_OPENAI_WORKER_MODEL" ;;
    esac
}

# tier_openai_auth_file -- where opencode's own credential store lives:
# ${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json, the file
# `opencode auth login --provider openai` writes. TIER_OPENAI_AUTH_FILE
# overrides it (tests). Never checks that the file exists.
tier_openai_auth_file() {
    if [ -n "${TIER_OPENAI_AUTH_FILE:-}" ]; then
        printf '%s\n' "$TIER_OPENAI_AUTH_FILE"
        return 0
    fi
    printf '%s/opencode/auth.json\n' "${XDG_DATA_HOME:-$HOME/.local/share}"
}

# tier_openai_ready -- is this folder signed in to OpenAI through
# opencode? True (0) when the auth store is readable JSON carrying either
# an oauth login with a non-empty refresh token (the ChatGPT sign-in;
# opencode rotates the access token itself) or an api login with a
# non-empty key. Never prints (stdout or stderr); jq missing or any
# doubt -> 1, i.e. signed out.
tier_openai_ready() {
    local f
    command -v jq >/dev/null 2>&1 || return 1
    f="$(tier_openai_auth_file)"
    [ -n "$f" ] && [ -f "$f" ] || return 1
    jq -e '(.openai.type == "oauth"
              and (.openai.refresh | type == "string" and length > 0))
           or (.openai.type == "api"
              and (.openai.key | type == "string" and length > 0))' \
        "$f" >/dev/null 2>&1
}

# tier_openai_catalogue -- what the subscription serves, as a JSON array of
# {id, family, release_date} (strings; missing -> ""). Sources, first that
# yields a non-empty array:
#   a) $TIER_OPENAI_MODELS_FILE  that file's JSON array, verbatim (tests)
#   b) when tier_openai_ready: `${TIER_OPENCODE_BIN:-opencode} models openai
#      --verbose` -- model header lines ("openai/<id>") dropped, the JSON
#      objects that follow them mapped to the array shape
#   c) ${TIER_OPENCODE_MODELS_CACHE:-$HOME/.cache/opencode/models.json} --
#      .openai.models of opencode's own cache
# Nothing usable: print nothing, exit 1.
tier_openai_catalogue() {
    local norm='map({id: (.id // ""), family: (.family // ""), release_date: (.release_date // "")})'
    local out=""

    # a) the test fixture, when set.
    if [ -n "${TIER_OPENAI_MODELS_FILE:-}" ] \
        && [ -f "${TIER_OPENAI_MODELS_FILE:-}" ]; then
        out="$(jq -e -c "$norm" "$TIER_OPENAI_MODELS_FILE" 2>/dev/null)" || out=""
        [ -n "$out" ] && [ "$out" != "[]" ] && { printf '%s\n' "$out"; return 0; }
    fi

    # b) the live listing, only when this folder is actually signed in.
    if tier_openai_ready; then
        out="$("${TIER_OPENCODE_BIN:-opencode}" models openai --verbose 2>/dev/null |
            grep -v '^openai/' |
            jq -s -c "$norm" 2>/dev/null)" || out=""
        [ -n "$out" ] && [ "$out" != "[]" ] && { printf '%s\n' "$out"; return 0; }
    fi

    # c) opencode's own models cache.
    local cache
    cache="${TIER_OPENCODE_MODELS_CACHE:-$HOME/.cache/opencode/models.json}"
    if [ -f "$cache" ]; then
        out="$(jq -e -c '.openai.models | to_entries
            | map({id: .key, family: (.value.family // ""),
                   release_date: (.value.release_date // "")})' \
            "$cache" 2>/dev/null)" || out=""
        [ -n "$out" ] && [ "$out" != "[]" ] && { printf '%s\n' "$out"; return 0; }
    fi

    return 1
}

# tier_openai_resolve <model> -- the model to launch, on stdout.
#   openai/~<fam>-latest -> openai/<id>, the newest catalogue entry whose
#     .family == <fam>: highest release_date, then the SHORTEST id
#     (gpt-5.6-luna beats gpt-5.6-luna-fast), then the lexically larger id.
#     No entry for <fam> (or no catalogue at all): one stderr line naming
#     the family and `opencode models openai`, exit 1.
#   anything else (openai/<id>, openrouter/..., other) -> printed unchanged,
#     exit 0; the catalogue is never consulted.
tier_openai_resolve() {
    local model="${1:-}" fam best
    case "$model" in
        openai/~*) fam="${model#openai/~}" ;;
        *) printf '%s\n' "$model"; return 0 ;;
    esac
    fam="${fam%-latest}"
    best="$(tier_openai_catalogue 2>/dev/null | jq -r --arg fam "$fam" '
        [ .[] | select(.family == $fam) ]
        | if length == 0 then empty
          else ( map(.release_date) | max ) as $d
          | [ .[] | select(.release_date == $d) ]
          | sort_by(.id | length)
          | group_by(.id | length)
          | .[0]
          | sort_by(.id)
          | .[-1]
          | "openai/\(.id)"
          end' 2>/dev/null)" || best=""
    if [ -z "$best" ]; then
        printf 'no OpenAI model serves family "%s" in this folder -- run `opencode models openai`\n' \
            "$fam" >&2
        return 1
    fi
    printf '%s\n' "$best"
}
