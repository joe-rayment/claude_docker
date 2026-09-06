#!/usr/bin/env bash
#
# tier-prime -- SessionStart hook. Prints the tier trio from
# .claude-dev/run/tier.json (S4, claude-orca-3sk.4, replaces the old
# frontmatter-reading version -- see .claude/plans/orca-port.md S3.6 and
# scripts/tier-set.sh's header). MUST fail open: never non-zero, never
# blocking; a missing tier.json (or missing jq) prints an <unbound>
# fallback line instead of erroring.
#
# TIER_PRIME_STATE_FILE overrides the tier.json path (test suite).

set -u

# Resolve through a symlink chain (e.g. bin/tier-prime -> ../scripts/tier-prime.sh)
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
# shellcheck source=lib/tier-roles.sh
. "$SCRIPT_DIR/lib/tier-roles.sh"

STATE_FILE="${TIER_PRIME_STATE_FILE:-}"
[ -n "$STATE_FILE" ] || STATE_FILE="$(tier_state_file 2>/dev/null)" || STATE_FILE=""

top=""; worker=""; recon=""; pinned="false"; overdrive="false"
bound=0
backends=""
if [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
    bound=1
    top=$(jq -r '.top // empty' "$STATE_FILE" 2>/dev/null)
    worker=$(jq -r '.worker // empty' "$STATE_FILE" 2>/dev/null)
    recon=$(jq -r '.recon // empty' "$STATE_FILE" 2>/dev/null)
    pinned=$(jq -r '.pinned // false' "$STATE_FILE" 2>/dev/null)
    overdrive=$(jq -r '.overdrive // false' "$STATE_FILE" 2>/dev/null)

    # v2 (claude-orca-qa2.12): the backend per role, read through the v1
    # fallback in lib/tier-roles.sh -- a v1 tier.json reads as subagent.
    bk_worker=subagent; lb_worker=""; bk_recon=subagent; lb_recon=""
    for _r in worker recon checker; do
        _line="$(tier_role "$STATE_FILE" "$_r")"
        _b="$(printf '%s' "$_line" | awk -F'\t' '{printf "%s", $1}')"
        _a="$(printf '%s' "$_line" | awk -F'\t' '{printf "%s", $2}')"
        _m="$(printf '%s' "$_line" | awk -F'\t' '{printf "%s", $3}')"
        _label="$(tier_role_label "$_b" "$_a" "$_m")"
        backends="$backends $_r=$_label"
        case "$_r" in
            worker) bk_worker="$_b"; lb_worker="$_label" ;;
            recon)  bk_recon="$_b";  lb_recon="$_label" ;;
        esac
    done
fi

flags=""
[ "$overdrive" = "true" ] && flags="$flags OVERDRIVE"
[ "$pinned" = "true" ] && flags="$flags PIN"

# --short (UserPromptSubmit, per-prompt): worker+recon only, one line, no
# orchestrator/protocol line -- that per-prompt line used to be built by
# grepping agent frontmatter (executor.md/scout.md `model:`); it now reads
# the same tier.json this whole script reads, so it can never drift from
# what tier-gate will actually inject.
if [ "${1:-}" = "--short" ]; then
    # A role on the orca backend is shown backend-qualified, because *where*
    # it runs changes how the orchestrator dispatches it; a plain subagent
    # role keeps the bare model id this line has always carried.
    w_disp="${worker:-<unbound>}"; r_disp="${recon:-<unbound>}"
    [ "${bk_worker:-subagent}" = "orca" ] && [ -n "${lb_worker:-}" ] && w_disp="$lb_worker"
    [ "${bk_recon:-subagent}" = "orca" ] && [ -n "${lb_recon:-}" ] && r_disp="$lb_recon"
    line="[tier] worker=$w_disp recon=$r_disp"
    if [ -n "$flags" ]; then
        line="$line (${flags# })"
    fi
    echo "$line"
    exit 0
fi

line="[tier] orchestrator=${top:-<unbound>} worker=${worker:-<unbound>} recon=${recon:-<unbound>}"
if [ -n "$flags" ]; then
    line="$line (${flags# })"
fi
echo "$line"
# The backend line is separate from the model line above on purpose: the
# model line is what every existing reader (and tests/tier-hooks.bats)
# parses, so backends are ADDED beside it rather than folded into it.
[ "$bound" -eq 1 ] && [ -n "$backends" ] && echo "[tier] backends:${backends} — an orca-backed role is dispatched with orca-dispatch, a subagent-backed one with the Agent tool"
echo "protocol: $(claude_config_dir)/CLAUDE.md § Delegation · § Lanes"
exit 0
