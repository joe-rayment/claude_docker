#!/usr/bin/env bash
#
# verify-folder.sh -- "is this folder actually set up the way the template
# promises?", asked from inside the container and answered row by row.
#
# The template seeds a lot on a folder's first start: the rulebook and the
# agent definitions into the folder's Claude config, the template's hooks,
# a git identity, the Claude first-run keys, the beads database. Every
# one of those was
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
# TEMPLATE_ROOT is the same name provision-run.sh and the entrypoint use;
# set it to point this at a checkout. Unset, the image's /opt/claude-orca
# wins when it exists, else the folder's own template clone.
TEMPLATE_ROOT="${TEMPLATE_ROOT:-/opt/claude-orca}"
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
    ok "agents" "six definitions in the agent home's .claude/agents"
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
    if [ "${ours:-0}" -gt 0 ]; then
        ok "hooks" "$ours from the template"
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

# --- the outside world --------------------------------------------------

if curl -fsS -o /dev/null --max-time 20 https://api.github.com/ 2>/dev/null; then
    ok "network" "api.github.com answers"
else
    bad "network" "cannot reach api.github.com; check the folder's dns setting"
fi

# --- OpenRouter: opencode's own synced config decides, not process env --
#
# OPENROUTER_API_KEY/OPENROUTER_BASE_URL are set in the environment of
# the sessions the entrypoint starts, never inside the fresh `docker exec`
# this script actually runs under (claude-dev verify). Gating this row on
# them read n/a in every real run, guard running or not. config-sync
# copies opencode.json into every folder unconditionally, so its baseURL
# is the signal this script can actually see (claude-orca-8tx).

opencode_cfg="$AGENT_HOME/.config/opencode/opencode.json"
guard_url=""
if command -v jq >/dev/null 2>&1 && [ -f "$opencode_cfg" ]; then
    guard_url="$(jq -r '.provider.openrouter.options.baseURL // empty' "$opencode_cfg" 2>/dev/null)"
fi

# Any HTTP status at all means something listens: the live guard answers
# 401 to a request without its token, and the probe must not carry that
# token (it is not needed and never printed). Only "no connection" -- curl
# reports http_code 000 on a refused connection or a timeout -- is down
# (claude-orca-0v6).
guard_code=""
if [ -n "$guard_url" ]; then
    guard_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${guard_url%/api/v1}/" 2>/dev/null)"
fi

if [ -z "$guard_url" ]; then
    skip "openrouter guard" "opencode is not configured to use one"
elif [ -n "$guard_code" ] && [ "$guard_code" != "000" ]; then
    ok "openrouter guard" "listening on $guard_url; agents hold its token, not the key"
else
    bad "openrouter guard" "opencode.json names the guard at $guard_url but nothing answers there -- run 'opencode auth login openrouter' then restart the container (the guard token is fixed when the container starts), or set a key at $AGENT_HOME/.openrouter.key (mode 600) and restart, or run './claude-dev key openrouter' on the Mac (same file)"
fi

exit "$FAILED"
