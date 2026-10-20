#!/usr/bin/env bash
#
# config-sync -- syncs this repo's config/ into a project's sandboxed Claude
# config dir (S4, claude-orca-3sk.4; see .claude/plans/orca-port.md S3.6).
# Checksum-gated: a no-op when config/**'s content hasn't changed since the
# last sync into this project. Idempotent; never touches anything outside
# <project>/.claude-dev/home (or its own gate file under
# <project>/.claude-dev/run/).
#
# Usage: config-sync --project <primary> --host <HOST>
#
#   --project  the primary checkout. Its .claude-dev/home/.claude is the
#              sync target, and .claude-dev/run/config-hash the gate.
#   --host     the host dir (<project>/.claude-dev) whose template/config/ is the
#              SOURCE; hook commands in the synced settings.json get the
#              __HOST__ placeholder rewritten to this exact value, so every
#              hook command is an absolute path Claude Code can exec
#              directly -- never left for the agent to resolve via PATH.
#
# Populates (from $HOST/template/config/):
#   claude-settings.json  -> .claude/settings.json (__HOST__ rewritten, then
#                             settings.local.json merged in -- local wins)
#   claude-keybindings.json -> .claude/keybindings.json (merged under the
#                             person's own bindings -- theirs win)
#   claude-user-memory.md -> .claude/CLAUDE.md
#   testing-standard.md   -> .claude/TESTING.md (the rulebook's § Tests standard)
#   statusline.sh         -> .claude/statusline.sh (executable)
#   agents/*.md           -> .claude/agents/
#   claude-commands/*.md  -> .claude/commands/
#   skills/**             -> .claude/skills/ (template entries mirrored;
#                            entries nothing shipped -- an Orca/npx-installed
#                            skill link, Claude Code's own 'synced' dir --
#                            survive; previously-shipped entries are tracked
#                            in skills/.claude-orca-shipped, claude-orca-qxc)
#   workflows/*.js        -> .claude/workflows/
#   opencode/opencode.json -> .config/opencode/opencode.json (opencode's own
#                             provider config, outside .claude/)
#   opencode/plugin/context-meter.js -> .config/opencode/plugin/
#                             context-meter.js (claude-orca-7lz.2 -- the
#                             opencode-side context-budget meter; opencode
#                             auto-loads *.js under ~/.config/opencode/plugin/)
#   .zshrc                -> .zshrc
#
# settings.local.json itself is only ever READ, never rewritten or moved --
# it is the one sanctioned override channel and always wins on the next
# sync too, since it survives the checksum-gated settings.json rewrite.
#
# settings.json is exactly the rendered template (plus settings.local.json):
# nothing else is carried across the rewrite. A settings.json that still
# carries Orca's managed hook entries or statusLine chain (commands under
# /.orca/agent-hooks/, left by an Orca that ran before the Ghostty move,
# claude-orca-9bh.13) is re-rendered even when the template hash is
# unchanged, which is the migration that strips them from existing folders.
#
# Exit 0 whether or not a sync actually ran (a checksum match is not an
# error -- callers don't need to distinguish); exit 2 on bad input.

set -euo pipefail

# Resolve through a symlink chain (e.g. bin/config-sync ->
# ../scripts/config-sync.sh) to this script's real directory, so
# lib/paths.sh resolves whether this is invoked via the repo copy or the
# .claude-dev/template/bin/ symlink.
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

die() { echo "config-sync: $1" >&2; exit 2; }

project=""
host=""
while [ $# -gt 0 ]; do
    case "$1" in
        --project) project="$2"; shift 2 ;;
        --host)    host="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$project" ] || die "--project is required"
[ -n "$host" ]    || die "--host is required"
[ -d "$project" ] || die "--project is not a directory: $project"
[ -d "$host" ]    || die "--host is not a directory: $host"
project="$(cd "$project" && pwd -P)"
host="$(cd "$host" && pwd -P)"

# --- one caller at a time (claude-orca-dbu.4) --------------------------
#
# Two callers can land on the same settings.json at the same moment: the
# provision.d step on a folder's start, and the host side's resync over
# `docker exec` right after the URL is published (plus a /config-resync
# typed in a terminal). The settings.json rewrite below is a
# render-then-merge over one file, so an interleaved pair can leave a
# half-written one.
#
# flock is util-linux's and is not on a stock Mac, where this script also
# runs -- so it is taken when it is there and skipped when it is not,
# which is no worse than the behaviour this replaces.
LOCK_FILE="$project/.claude-dev/run/config-sync.lock"
if command -v flock >/dev/null 2>&1; then
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    if { exec 9>"$LOCK_FILE"; } 2>/dev/null; then
        flock 9 || true
    fi
fi

TEMPLATE_CONFIG="$host/template/config"
[ -d "$TEMPLATE_CONFIG" ] || die "template config not found: $TEMPLATE_CONFIG"

CONFIG_DIR="$project/.claude-dev/home/.claude"
LOCAL_SETTINGS="$CONFIG_DIR/settings.local.json"

# An Orca that ran here before the Ghostty move wrote its managed hook
# entries (and a statusLine chain) into this settings.json; they all point
# at a script under this path. Finding it on disk means the folder still
# needs the clean re-render below even if the template hash has not moved.
LEGACY_HOOK_MARK="/.orca/agent-hooks/"

# --- checksum gate -----------------------------------------------------

# Sorted sha1 of every file's relative path AND its content, PLUS the
# --host value and the project's own settings.local.json -- a rename with
# byte-identical content still counts as a change (unlike a content-only
# hash), and so does a host change with byte-identical config: __HOST__ is
# baked into every hook command in the synced settings.json, so a project
# re-registered (or re-entered) under a different host dir must re-render
# even when config/** itself is untouched, never silently keep serving the
# previous host's paths. settings.local.json is included for the same
# reason: it is merged into the OUTPUT settings.json below, so appearing,
# changing or disappearing must invalidate the gate even though it lives
# outside $TEMPLATE_CONFIG entirely and never itself changes config/**.
config_checksum() {
    ( cd "$TEMPLATE_CONFIG" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s\n' "${f#./}"
        sha1sum "$f" | cut -d' ' -f1
    done
    printf 'host:%s\n' "$host"
    if [ -f "$LOCAL_SETTINGS" ]; then
        printf 'local-settings:%s\n' "$(sha1sum "$LOCAL_SETTINGS" | cut -d' ' -f1)"
    else
        printf 'local-settings:(absent)\n'
    fi ) | sha1sum | cut -d' ' -f1
}

# V2d (claude-orca-qt9.9): the gate lives in .claude-dev/run, beside
# everything else written from inside a sandbox. This script runs INSIDE
# layer 1 (the wrapper calls it on every launch, and layer 1 write-denies
# the folder's host-owned tree), so a gate parked there could never be
# updated on a Mac -- every launch would re-sync the whole config dir.
# run/ is agent-writable, which costs nothing here: the hash only decides
# whether to re-sync, so forging it can at most force a sync or skip one,
# and an agent that wants either can already get it by editing the config
# dir this script syncs into.
HASH_FILE="$project/.claude-dev/run/config-hash"
NEW_HASH="$(config_checksum)"
OLD_HASH=""
[ -f "$HASH_FILE" ] && OLD_HASH="$(cat "$HASH_FILE" 2>/dev/null)"

if [ "$NEW_HASH" = "$OLD_HASH" ]; then
    # Unchanged template: normally nothing to do. But a settings.json that
    # still carries Orca's hook entries is stale whatever the hash says.
    if [ -f "$CONFIG_DIR/settings.json" ] \
        && grep -qF -- "$LEGACY_HOOK_MARK" "$CONFIG_DIR/settings.json" 2>/dev/null; then
        :
    else
        exit 0
    fi
fi

# --- populate ------------------------------------------------------------

mkdir -p "$CONFIG_DIR"

# The statusLine chain file an earlier version kept beside settings.json
# (our half of the Orca-composed command); nothing reads it now.
rm -f "$CONFIG_DIR"/.orca-statusline-*

# settings.json: hook commands carry a __HOST__ placeholder in the repo copy
# (config/claude-settings.json), rewritten here to this project's actual
# host dir.
sed "s#__HOST__#$host#g" "$TEMPLATE_CONFIG/claude-settings.json" > "$CONFIG_DIR/settings.json"

# keybindings.json: the template's chords (ctrl+q toggles the Activity
# sidebar) merged under the person's own -- a chord they bound themselves,
# in any context, wins, and every binding of theirs survives the sync.
if [ -f "$TEMPLATE_CONFIG/claude-keybindings.json" ]; then
    kb="$CONFIG_DIR/keybindings.json"
    if [ -f "$kb" ] && jq -e . "$kb" >/dev/null 2>&1; then
        kb_tmp=$(mktemp "$kb.XXXXXX")
        if jq -s 'def bymap: reduce (.bindings // [])[] as $b ({}; .[$b.context] += $b.bindings);
                  (.[0] | bymap) as $t | (.[1] | bymap) as $u
                  | .[1] + {"$schema": .[0]["$schema"],
                            bindings: [($t * $u) | to_entries[] | {context: .key, bindings: .value}]}' \
                "$TEMPLATE_CONFIG/claude-keybindings.json" "$kb" > "$kb_tmp" 2>/dev/null; then
            mv "$kb_tmp" "$kb"
        else
            rm -f "$kb_tmp"
        fi
    else
        cp "$TEMPLATE_CONFIG/claude-keybindings.json" "$kb"
    fi
fi

cp "$TEMPLATE_CONFIG/claude-user-memory.md" "$CONFIG_DIR/CLAUDE.md"
if [ -f "$TEMPLATE_CONFIG/testing-standard.md" ]; then
    cp "$TEMPLATE_CONFIG/testing-standard.md" "$CONFIG_DIR/TESTING.md"
fi
cp "$TEMPLATE_CONFIG/statusline.sh" "$CONFIG_DIR/statusline.sh"
chmod +x "$CONFIG_DIR/statusline.sh"

# agents/commands/workflows are fully mirrored (removed-in-template files
# are removed here too), never hand-edited in the project --
# settings.local.json is the one sanctioned local-override channel.
rm -rf "$CONFIG_DIR/agents" "$CONFIG_DIR/commands" "$CONFIG_DIR/workflows"
mkdir -p "$CONFIG_DIR/agents" "$CONFIG_DIR/commands" "$CONFIG_DIR/workflows"
if [ -d "$TEMPLATE_CONFIG/agents" ]; then
    cp "$TEMPLATE_CONFIG"/agents/*.md "$CONFIG_DIR/agents/" 2>/dev/null || true
fi
if [ -d "$TEMPLATE_CONFIG/claude-commands" ]; then
    cp "$TEMPLATE_CONFIG"/claude-commands/*.md "$CONFIG_DIR/commands/" 2>/dev/null || true
fi
if [ -d "$TEMPLATE_CONFIG/workflows" ]; then
    cp "$TEMPLATE_CONFIG"/workflows/*.js "$CONFIG_DIR/workflows/" 2>/dev/null || true
fi

# skills is NOT fully mirrored (claude-orca-qxc): the entries this template
# ships are mirrored, but entries anything else put there survive -- the
# home-scope orchestration link provision.d/75-orca-skills creates and
# Claude Code's own 'synced' directory are not this script's to remove,
# and Orca's Settings > Orchestration panel reads exactly that link. What
# the previous sync shipped is recorded in skills/.claude-orca-shipped
# (one name per line, rewritten after every copy), so a skill the template
# dropped since the last sync is still removed; a first run with no
# manifest removes only what the template ships now. agents/commands/
# workflows stay wholesale because nothing else writes there; skills/ is
# where foreign installers write.
shipped_manifest="$CONFIG_DIR/skills/.claude-orca-shipped"
if [ -f "$shipped_manifest" ]; then
    while IFS= read -r skill_name; do
        case "$skill_name" in ""|.|..|*/*|.*) continue ;; esac
        rm -rf "$CONFIG_DIR/skills/$skill_name"
    done < "$shipped_manifest"
fi
if [ -d "$TEMPLATE_CONFIG/skills" ]; then
    for skill_name in "$TEMPLATE_CONFIG"/skills/*; do
        [ -e "$skill_name" ] || continue
        rm -rf "$CONFIG_DIR/skills/$(basename "$skill_name")"
    done
fi
mkdir -p "$CONFIG_DIR/skills"
if [ -d "$TEMPLATE_CONFIG/skills" ]; then
    cp -R "$TEMPLATE_CONFIG"/skills/. "$CONFIG_DIR/skills/" 2>/dev/null || true
fi
: > "$shipped_manifest"
if [ -d "$TEMPLATE_CONFIG/skills" ]; then
    for skill_name in "$TEMPLATE_CONFIG"/skills/*; do
        [ -e "$skill_name" ] || continue
        printf '%s\n' "$(basename "$skill_name")" >> "$shipped_manifest"
    done
fi

if [ -f "$TEMPLATE_CONFIG/.zshrc" ]; then
    cp "$TEMPLATE_CONFIG/.zshrc" "$project/.claude-dev/home/.zshrc"
fi

# opencode's provider config (claude-orca-qa2.11): an Orca worker terminal
# running a non-Anthropic model is `opencode --model openrouter/<model>`,
# and opencode reads its providers from a file rather than argv. It lives
# outside .claude/ because it is not Claude Code's -- ~/.config/opencode is
# where opencode looks, and where seed-orca-state.sh points OPENCODE_CONFIG.
# Template-owned like everything else here: no key in the file, just the
# {env:OPENROUTER_API_KEY} reference the VM's environment satisfies.
if [ -f "$TEMPLATE_CONFIG/opencode/opencode.json" ]; then
    mkdir -p "$project/.claude-dev/home/.config/opencode"
    cp "$TEMPLATE_CONFIG/opencode/opencode.json" \
        "$project/.claude-dev/home/.config/opencode/opencode.json"
fi

# The opencode-side context-budget meter (claude-orca-7lz.2): opencode
# auto-loads any *.js under ~/.config/opencode/plugin/, no config entry
# needed. Template-owned and checksum-gated like everything else here.
if [ -f "$TEMPLATE_CONFIG/opencode/plugin/context-meter.js" ]; then
    mkdir -p "$project/.claude-dev/home/.config/opencode/plugin"
    cp "$TEMPLATE_CONFIG/opencode/plugin/context-meter.js" \
        "$project/.claude-dev/home/.config/opencode/plugin/context-meter.js"
fi

# --- settings.local.json overlay: preserved on disk, and merged IN (local
# wins) -- same deep-merge entrypoint.sh used, permission arrays unioned
# rather than replaced so a local allowlist extends the base one instead of
# wiping it.
if [ -f "$LOCAL_SETTINGS" ] && jq -e . "$LOCAL_SETTINGS" >/dev/null 2>&1; then
    merged="$(jq -s '
        .[0] as $base | .[1] as $local | ($base * $local)
        | if ($base.permissions.allow or $local.permissions.allow)
          then .permissions.allow = ((($base.permissions.allow // []) + ($local.permissions.allow // [])) | unique) else . end
        | if ($base.permissions.deny or $local.permissions.deny)
          then .permissions.deny = ((($base.permissions.deny // []) + ($local.permissions.deny // [])) | unique) else . end
        | if ($base.permissions.ask or $local.permissions.ask)
          then .permissions.ask = ((($base.permissions.ask // []) + ($local.permissions.ask // [])) | unique) else . end
    ' "$CONFIG_DIR/settings.json" "$LOCAL_SETTINGS" 2>/dev/null)"
    if [ -n "$merged" ] && printf '%s' "$merged" | jq -e . >/dev/null 2>&1; then
        printf '%s\n' "$merged" > "$CONFIG_DIR/settings.json"
    fi
fi

mkdir -p "$(dirname "$HASH_FILE")"
printf '%s\n' "$NEW_HASH" > "$HASH_FILE"
exit 0
