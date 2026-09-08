#!/usr/bin/env bash
#
# verify-folder.sh -- "is this folder actually set up the way the template
# promises?", asked from inside the container and answered row by row.
#
# The template seeds a lot on a folder's first start: the rulebook and the
# agent definitions into the folder's Claude config, hooks that must keep
# Orca's own entries, a git identity, the Claude first-run keys, Orca's
# worktree base and theme, the beads database. Every one of those was
# written by code that logged a line and moved on, and nothing ever read
# them back -- so "the basic things I asked to exist in this template seem
# to be fundamentally missing" was a reasonable thing for the owner to
# conclude on 2026-09-07, and there was no command that could have said
# otherwise. This is that command's other half; `claude-dev verify` runs
# it and adds the rows only the Mac can answer.
#
# Output is one row per check, tab separated, for the launcher to format:
#
#   ok<TAB><name><TAB><detail>
#   FAIL<TAB><name><TAB><what is wrong>
#   n/a<TAB><name><TAB><why it does not apply>
#
# Exit 0 when nothing FAILed, 1 otherwise. Reads only: it installs
# nothing, starts nothing and writes nothing outside /tmp.

set -uo pipefail

PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_ORCA_ROOT:-}}"
AGENT_HOME="${HOME:-/home/agent}"
TEMPLATE_ROOT="/opt/claude-orca"
[ -d "$TEMPLATE_ROOT" ] || TEMPLATE_ROOT="$PROJECT_DIR/.claude-dev/template"

FAILED=0
row()  { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}"; [ "$1" = "FAIL" ] && FAILED=1; return 0; }
ok()   { row ok   "$1" "${2:-}"; }
bad()  { row FAIL "$1" "${2:-}"; }
skip() { row n/a  "$1" "${2:-}"; }

[ -n "$PROJECT_DIR" ] || { bad "project" "neither PROJECT_DIR nor CLAUDE_ORCA_ROOT is set"; exit 1; }

# --- the boundary, as a person sees it ----------------------------------

case "$PROJECT_DIR" in
    /workspace/*) ok "mount point" "$PROJECT_DIR" ;;
    *)            bad "mount point" "the project is at $PROJECT_DIR, not /workspace/<name>" ;;
esac

if [ -e /Users ]; then
    bad "host paths" "/Users exists inside the container"
else
    beside="$(ls -A "$(dirname "$PROJECT_DIR")" 2>/dev/null | grep -c .)"
    if [ "$beside" = "1" ]; then
        ok "host paths" "one folder beside it, no /Users"
    else
        bad "host paths" "$beside entries beside the project, expected 1"
    fi
fi

# --- the tracker --------------------------------------------------------

if ! command -v bd >/dev/null 2>&1; then
    bad "beads" "bd is not on PATH"
elif [ ! -d "$PROJECT_DIR/.beads" ]; then
    bad "beads" "no $PROJECT_DIR/.beads"
else
    prefix="$(cd "$PROJECT_DIR" && bd where 2>/dev/null | sed -n 's/^ *prefix: *//p' | head -1)"
    if [ -n "$prefix" ]; then
        ok "beads" "initialized, prefix $prefix"
    else
        bad "beads" "bd where answered nothing in $PROJECT_DIR"
    fi
fi

# bd walks UP from the cwd for .beads, so without BEADS_DIR it works in the
# project and nowhere else -- which is what "no beads database found" meant
# after a `cd ..` on 2026-09-07.
if [ -z "${BEADS_DIR:-}" ]; then
    bad "beads anywhere" "BEADS_DIR is not set; bd only works inside the project"
elif ( cd / && bd status >/dev/null 2>&1 ); then
    ok "beads anywhere" "BEADS_DIR=$BEADS_DIR"
else
    bad "beads anywhere" "BEADS_DIR=$BEADS_DIR but 'cd / && bd status' failed"
fi

# --- the toolchain the image promised -----------------------------------

setup="$TEMPLATE_ROOT/scripts/container/setup.sh"
if [ ! -x "$setup" ]; then
    bad "toolchain" "no setup.sh at $setup"
else
    out="$("$setup" --check 2>&1)"
    notok="$(printf '%s\n' "$out" | grep -v '^\[check\] ok' | grep . )"
    if [ -z "$notok" ]; then
        ok "toolchain" "every pin present"
    elif [ "$(printf '%s\n' "$notok" | grep -c .)" = "1" ] \
         && printf '%s' "$notok" | grep -q 'agent user: want uid'; then
        # The entrypoint remaps `agent` to the Mac's uid, so this row is
        # always "wrong" in a running container and always fine.
        ok "toolchain" "every pin present (the agent uid is remapped to the Mac's)"
    else
        bad "toolchain" "$(printf '%s' "$notok" | head -2 | tr '\n' ';')"
    fi
fi

# --- the config the template ships --------------------------------------

rulebook="$AGENT_HOME/.claude/CLAUDE.md"
shipped="$TEMPLATE_ROOT/config/claude-user-memory.md"
if [ ! -f "$rulebook" ]; then
    bad "rulebook" "no $rulebook"
elif [ ! -f "$shipped" ]; then
    skip "rulebook" "$rulebook exists; no shipped copy to compare against"
elif cmp -s "$rulebook" "$shipped"; then
    ok "rulebook" "$rulebook matches the template"
else
    bad "rulebook" "$rulebook differs from $shipped (config-sync did not run?)"
fi

missing=""
for a in bead-auditor executor oracle professor scout verifier; do
    [ -f "$AGENT_HOME/.claude/agents/$a.md" ] || missing="$missing $a"
done
if [ -z "$missing" ]; then
    ok "agents" "six definitions in ~/.claude/agents"
else
    bad "agents" "missing:$missing"
fi

missing=""
for c in tier code-map; do
    [ -f "$AGENT_HOME/.claude/commands/$c.md" ] || missing="$missing /$c"
done
if [ -z "$missing" ]; then
    ok "commands" "/tier and /code-map"
else
    bad "commands" "missing:$missing"
fi

settings="$AGENT_HOME/.claude/settings.json"
if [ ! -f "$settings" ]; then
    bad "hooks" "no $settings"
elif ! jq -e . "$settings" >/dev/null 2>&1; then
    bad "hooks" "$settings is not valid JSON"
else
    ours="$(jq -r '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // ""]
                   | map(select(test("claude-orca-host|/template/bin/"))) | length' "$settings")"
    orcas="$(jq -r '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // ""]
                    | map(select(test("orca/agent-hooks"))) | length' "$settings")"
    if [ "${ours:-0}" -gt 0 ] && [ "${orcas:-0}" -gt 0 ]; then
        ok "hooks" "$ours from the template, $orcas from Orca, both kept"
    elif [ "${ours:-0}" -gt 0 ]; then
        bad "hooks" "$ours template hooks but none of Orca's own (config-sync overwrote them)"
    else
        bad "hooks" "no template hooks in $settings"
    fi
fi

gc="$AGENT_HOME/.gitconfig"
if [ -f "$gc" ] && grep -q 'email' "$gc" 2>/dev/null; then
    ok "git identity" "$(git config --file "$gc" user.name 2>/dev/null) <$(git config --file "$gc" user.email 2>/dev/null)>"
else
    bad "git identity" "no user.name/user.email in $gc; commits inside will fail"
fi

cj="$AGENT_HOME/.claude.json"
if [ ! -f "$cj" ]; then
    bad "claude first run" "no $cj"
elif [ "$(jq -r --arg p "$PROJECT_DIR" '(.hasCompletedOnboarding == true) and ((.projects[$p].hasTrustDialogAccepted) == true)' "$cj" 2>/dev/null)" = "true" ]; then
    ok "claude first run" "onboarding and folder trust seeded"
else
    bad "claude first run" "onboarding or trust for $PROJECT_DIR not seeded; a worker will stop at a dialog"
fi

# --- Orca's own state ---------------------------------------------------

udd="${ORCA_USER_DATA_DIR:-$AGENT_HOME/.config/orca}"
odata="$(ls "$udd"/profiles/*/orca-data.json 2>/dev/null | head -1)"
if [ -z "$odata" ]; then
    bad "orca state" "no orca-data.json under $udd"
else
    wt="$(jq -r '.repos[0].worktreeBasePath // empty' "$odata" 2>/dev/null)"
    theme="$(jq -r '.settings.theme // empty' "$odata" 2>/dev/null)"
    case "$wt" in
        "$PROJECT_DIR"/*) ok "orca state" "theme ${theme:-unset}, worktrees in $wt" ;;
        "")               bad "orca state" "no worktreeBasePath in $odata" ;;
        *)                bad "orca state" "worktrees at $wt, outside the project" ;;
    esac
fi

cli="${ORCA_CLI:-/opt/orca/resources/bin/orca-ide}"
if [ ! -x "$cli" ]; then
    skip "orca repo" "no Orca CLI at $cli"
elif ORCA_USER_DATA_PATH="$udd" timeout 30 "$cli" repo list --json 2>/dev/null \
        | grep -qF "$PROJECT_DIR"; then
    ok "orca repo" "the project is registered with the running Orca"
else
    bad "orca repo" "$PROJECT_DIR is not in 'orca repo list' (open it in the sidebar once)"
fi

# --- the outside world --------------------------------------------------

if curl -fsS -o /dev/null --max-time 20 https://api.github.com/ 2>/dev/null; then
    ok "network" "api.github.com answers"
else
    bad "network" "cannot reach api.github.com; check the folder's dns setting"
fi

# --- OpenRouter, only when the folder has a key -------------------------

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
    skip "openrouter guard" "no key in this folder (./claude-dev key openrouter)"
elif [ -n "${OPENROUTER_BASE_URL:-}" ] \
     && curl -fsS -o /dev/null --max-time 5 "${OPENROUTER_BASE_URL%/api/v1}/" 2>/dev/null; then
    ok "openrouter guard" "listening on $OPENROUTER_BASE_URL; agents hold its token, not the key"
else
    bad "openrouter guard" "a key is set but the guard is not answering on ${OPENROUTER_BASE_URL:-<unset>}"
fi

exit "$FAILED"
