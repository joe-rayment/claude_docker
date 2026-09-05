#!/usr/bin/env bash
#
# tier-set -- /tier backend (S4, claude-orca-3sk.4). Binds the model tier by
# writing .claude-dev/run/tier.json {top, worker, recon, pinned, overdrive,
# updated} and .model in <config dir>/settings.local.json -- NEVER
# agents/*.md: srt write-denies .claude/agents under cwd (see
# .claude/plans/orca-port.md S3.1, S3.6), so the binding lives in hook-read
# state instead of frontmatter (the superseded design:
# attachments/claude_docker/scripts/tier-set.sh rewrote executor.md/scout.md
# directly). tier-gate (PreToolUse[Agent]) reads tier.json to inject the
# worker/recon model into executor/scout spawns that omit one;
# tier-prime/tier-reconcile also read/write it.
#
# Usage:
#   tier-set                           # no args -> show (same as `show`)
#   tier-set show
#   tier-set <top>                     # worker/recon auto-derived (capped)
#   tier-set <top> <worker> [<recon>]  # explicit pin
#   tier-set overdrive                 # lift the worker cap on the bound top
#
# Ladder and derivation: scripts/tier-derive.sh (ported unchanged from the
# old template) is the single source of truth; this script never repeats it.
#
# TIER_STATE_FILE / TIER_SETTINGS_LOCAL override the paths (test suite).
# TIER_DERIVE overrides the tier-derive lookup (default: alongside this
# script, i.e. the sibling scripts/tier-derive.sh, or tier-derive on PATH).
#
# Deliberately dropped from the old design, out of S4's scope: probing
# candidates against a live `claude -p` round trip (unsuitable for hermetic
# tests, and not asked for here), and the `cost` subcommand (cost-mirror is
# S7). Also dropped: tier-set itself purging legacy ANTHROPIC_DEFAULT_*/
# CLAUDE_CODE_SUBAGENT_MODEL vars -- that is tier-reconcile's job now (see
# its header), so it isn't duplicated here.

set -u

# Resolve through a symlink chain (e.g. bin/tier-set -> ../scripts/tier-set.sh)
# to this script's real directory, so lib/paths.sh resolves whether this is
# invoked via the repo copy or the .claude-dev/template/bin/ symlink.
_resolve_script_path() {
    local src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        local link dir
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(cd "$(dirname "$src")" && pwd)"; src="$dir/$link" ;;
        esac
    done
    echo "$src"
}
SCRIPT_DIR="$(cd "$(dirname "$(_resolve_script_path)")" && pwd)"
# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"

DERIVE="${TIER_DERIVE:-}"
if [ -z "$DERIVE" ]; then
    DERIVE=$(command -v tier-derive 2>/dev/null) || DERIVE="$SCRIPT_DIR/tier-derive.sh"
fi

STATE_FILE="${TIER_STATE_FILE:-}"
[ -n "$STATE_FILE" ] || STATE_FILE="$(tier_state_file 2>/dev/null)" || STATE_FILE=""

LOCAL_SETTINGS="${TIER_SETTINGS_LOCAL:-}"
[ -n "$LOCAL_SETTINGS" ] || LOCAL_SETTINGS="$(claude_config_dir)/settings.local.json"

alias_id() {  # alias -> concrete id; unknown strings pass through (full ids)
    case "$1" in
        fable)  echo claude-fable-5 ;;
        opus)   echo claude-opus-5 ;;
        sonnet) echo claude-sonnet-5 ;;
        haiku)  echo claude-haiku-4-5-20251001 ;;
        *)      echo "$1" ;;
    esac
}

# Only safe id characters -- the same injection guard the old design used
# before writing a model id into a file; jq itself is injection-safe, but a
# typo/empty value here is still a useful UX error before we bind anything.
valid_id() {
    case "$1" in
        ''|*[!a-zA-Z0-9._\[\]-]*) return 1 ;;
        *) return 0 ;;
    esac
}

state_field() {  # state_field <field> -- '' if the file/field is absent
    [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ] || { echo ""; return 0; }
    jq -r ".$1 // empty" "$STATE_FILE" 2>/dev/null
}

# write_state <top> <worker> <recon> <pinned:true|false> <overdrive:true|false>
write_state() {
    [ -n "$STATE_FILE" ] || { echo "tier-set: cannot determine the project's tier state file (not inside a bootstrapped project; set CLAUDE_ORCA_ROOT or TIER_STATE_FILE) -- nothing bound" >&2; return 1; }
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
    local tmp
    tmp=$(mktemp "$STATE_FILE.XXXXXX") || return 1
    if jq -n --arg t "$1" --arg w "$2" --arg c "$3" --argjson p "$4" --argjson o "$5" \
          --arg u "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '{top: $t, worker: $w, recon: $c, pinned: $p, overdrive: $o, updated: $u}' \
          > "$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$STATE_FILE"
    else
        rm -f "$tmp"
        echo "tier-set: failed to write $STATE_FILE" >&2
        return 1
    fi
}

# merge_model <id> -- .model = <id> into settings.local.json, everything
# else in the file untouched (created fresh as {} if absent).
merge_model() {
    mkdir -p "$(dirname "$LOCAL_SETTINGS")" 2>/dev/null
    local base tmp
    base='{}'
    if [ -f "$LOCAL_SETTINGS" ] && jq -e . "$LOCAL_SETTINGS" >/dev/null 2>&1; then
        base="$(cat "$LOCAL_SETTINGS")"
    fi
    tmp=$(mktemp "$LOCAL_SETTINGS.XXXXXX") || return 1
    if printf '%s' "$base" | jq --arg m "$1" '.model = $m' > "$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$LOCAL_SETTINGS"
    else
        rm -f "$tmp"
        echo "tier-set: failed to update $LOCAL_SETTINGS" >&2
        return 1
    fi
}

# --- show ------------------------------------------------------------------

show_state() {
    local top worker recon pinned overdrive
    top="$(state_field top)"; worker="$(state_field worker)"; recon="$(state_field recon)"
    pinned="$(state_field pinned)"; overdrive="$(state_field overdrive)"

    if [ -z "$top" ] && [ -z "$worker" ] && [ -z "$recon" ]; then
        echo "no tier bound yet -- run /tier <top> (e.g. /tier opus) to bind one"
    else
        echo "orchestrator (top)   = $top"
        echo "worker / executor    = $worker"
        echo "recon / scout        = $recon"
        [ "$pinned" = "true" ] && echo "explicit pin: ON — worker/recon were set manually (tier-set <top> <worker> [<recon>]); a plain /tier <top> clears it."
        [ "$overdrive" = "true" ] && echo "overdrive: ON — the worker cap is LIFTED (executor runs the top model); a plain /tier <top> clears it."
    fi
    echo "1-arg /tier auto-derives worker/recon: worker = one rung down capped at sonnet-class, recon = one below the worker (fable>opus>sonnet>haiku, floored)."
    echo "2/3-arg /tier <top> <worker> [<recon>] pins those bindings explicitly; /tier overdrive lifts the worker cap on the bound top."
    echo "verifier & oracle inherit the orchestrator's model; /model is the primary in-session lever for the derived default."
}

if [ $# -eq 0 ] || [ "${1:-}" = "show" ]; then
    show_state
    exit 0
fi

# --- overdrive ---------------------------------------------------------------

if [ $# -eq 1 ] && [ "$1" = "overdrive" ]; then
    [ -x "$DERIVE" ] || { echo "tier-set: tier-derive not found or not executable ($DERIVE) -- cannot derive the trio; nothing bound" >&2; exit 1; }
    top="$(state_field top)"
    if [ -z "$top" ]; then
        echo "tier-set: no top bound yet -- overdrive lifts an existing top; run /tier <top> first; nothing bound" >&2
        exit 1
    fi
    if ! trio=$("$DERIVE" --overdrive "$top" 2>/dev/null); then
        echo "tier-set: top '$top' is off-ladder -- not liftable; bindings left untouched, nothing bound" >&2
        exit 1
    fi
    set -f; set -- $trio; set +f
    W=$2; C=$3   # $1 (the resolved top) is discarded: it is not re-bound
    write_state "$top" "$W" "$C" false true || exit 1
    echo "tier bound (overdrive — worker cap LIFTED)  top=$top  →  worker=$W  recon=$C  — a plain /tier <top> clears overdrive"
    echo "→ the lifted worker binding applies to NEW subagent spawns immediately (tier-gate reads tier.json at spawn time)."
    exit 0
fi

# --- 1-arg (auto-derive) or 2/3-arg (explicit pin) --------------------------

if [ $# -eq 1 ]; then
    resolved="$(alias_id "$1")"
    valid_id "$resolved" || { echo "tier-set: unknown subcommand or model id: '$1'" >&2; exit 1; }
    [ -x "$DERIVE" ] || { echo "tier-set: tier-derive not found or not executable ($DERIVE) -- cannot derive the trio; nothing bound" >&2; exit 1; }
    R=$resolved
    if trio=$("$DERIVE" "$R" 2>/dev/null); then
        set -f; set -- $trio; set +f
        R=$1; W=$2; C=$3
    else
        W=$R; C=$R
        echo "tier: top '$R' is off-ladder — worker/recon set to the same model (not derivable)" >&2
    fi
    write_state "$R" "$W" "$C" false false || exit 1
    merge_model "$R" || exit 1
    echo "tier bound  top=$R  →  worker=$W  recon=$C  (worker/recon derived from the top)"
    echo "→ run  /model $R  to move THIS session's model now — new sessions pick everything up automatically."
    exit 0
fi

R="$(alias_id "$1")"; W="$(alias_id "$2")"
valid_id "$R" || { echo "tier-set: unknown or unsafe top model id: '$1' -- nothing bound" >&2; exit 1; }
valid_id "$W" || { echo "tier-set: unknown or unsafe worker model id: '$2' -- nothing bound" >&2; exit 1; }
if [ $# -ge 3 ]; then
    C="$(alias_id "$3")"
    valid_id "$C" || { echo "tier-set: unknown or unsafe recon model id: '$3' -- nothing bound" >&2; exit 1; }
    [ $# -gt 3 ] && echo "tier: extra args ignored (dropped: ${*:4})" >&2
else
    C=$W   # 2-arg form: a 2-level config — recon shares the worker model
fi

write_state "$R" "$W" "$C" true false || exit 1
merge_model "$R" || exit 1
echo "tier bound (explicit, pinned)  top=$R  worker=$W  recon=$C  — a plain /tier <top> clears the pin"
echo "→ run  /model $R  to move THIS session's model now — new sessions pick everything up automatically."
exit 0
