#!/usr/bin/env bash
#
# openai-auth -- the in-tab OpenAI sign-in helper (claude-orca-c3p.4).
# Meant to run inside a focused Orca terminal opened by `tier-set auth
# openai`, but works fine invoked directly.
#
# What it does, in order: prints what is about to happen; skips the login
# when this folder is already signed in (unless --force); runs
# `opencode auth login --provider openai --method "ChatGPT Pro/Plus
# (headless)"` -- opencode shows a device link and one-time code, the
# browser part is the user's -- and refuses to claim success unless
# opencode exited 0 AND the auth store now reads as signed in; then lists
# what the subscription serves (`opencode models openai`) and names the
# next step (binding a role). Exit 0 only on a signed-in folder; a failed
# login writes nothing and exits 1.
#
# The credential is opencode's own business: it lives in opencode's auth
# store and is never printed, catted, or echoed by this script -- not the
# access token, not the refresh token, not the auth file.
#
# Env knobs (all optional):
#   OPENAI_AUTH_OPENCODE_BIN  the opencode binary to use (default: opencode)
#   TIER_OPENAI_AUTH_FILE     passes through to tier_openai_ready (tests)
#
# Usage: openai-auth.sh [--force]

set -euo pipefail

# Resolve through a symlink chain (e.g. bin/openai-auth -> ../scripts/openai-auth.sh)
# to this script's real directory, so lib/ resolves whether this is
# invoked via the repo copy or the .claude-dev/template/bin/ symlink --
# the same resolution scripts/recon.sh does.
_resolve_script_path() {
    local src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        local link dir
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(case "$src" in (*/*) cd "${src%/*}/" ;; esac && pwd)"; src="$dir/$link" ;;
        esac
    done
    echo "$src"
}
SCRIPT_DIR="$(_s="$(_resolve_script_path)"; case "$_s" in (*/*) cd "${_s%/*}/" ;; esac && pwd)"

# shellcheck source=lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"
# shellcheck source=lib/tier-roles.sh
. "$SCRIPT_DIR/lib/tier-roles.sh"

FORCE=""
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        *) printf 'openai-auth: usage: openai-auth.sh [--force]\n' >&2; exit 64 ;;
    esac
done

OC="${OPENAI_AUTH_OPENCODE_BIN:-opencode}"

echo "Sign in to OpenAI with your ChatGPT subscription (Plus, Pro, Business ...)."
echo "opencode shows a link and a one-time code: open the link in your browser, sign in, enter the code -- this tab finishes by itself."

if [ -z "$FORCE" ] && tier_openai_ready; then
    echo "Already signed in to OpenAI in this folder."
else
    rc=0
    "$OC" auth login --provider openai --method "ChatGPT Pro/Plus (headless)" || rc=$?
    if [ "$rc" -ne 0 ] || ! tier_openai_ready; then
        printf 'OpenAI sign-in did not complete (opencode exited %s) -- nothing changed; /tier auth openai tries again.\n' "$rc" >&2
        exit 1
    fi
fi

echo "Models your subscription serves:"
models_out=""
models_out="$("$OC" models openai 2>/dev/null)" || models_out=""
[ -n "$models_out" ] && printf '%s\n' "$models_out" | sed 's/^/  /'

echo "Next: bind a role, e.g.  /tier opus openai:terra openai:luna@high   (or /tier worker openai:terra)"
exit 0
