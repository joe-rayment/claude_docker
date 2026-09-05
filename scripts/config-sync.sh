#!/usr/bin/env bash
#
# config-sync -- syncs this repo's config/ into a project's sandboxed Claude
# config dir (S4, claude-orca-3sk.4; see .claude/plans/orca-port.md S3.6).
# Checksum-gated: a no-op when config/**'s content hasn't changed since the
# last sync into this project. Idempotent; never touches anything outside
# <project>/.claude-dev/home (or its own gate file under
# <project>/.claude-dev/state/).
#
# Usage: config-sync --project <primary> --host <HOST>
#
#   --project  the primary checkout. Its .claude-dev/home/.claude is the
#              sync target, and .claude-dev/state/config-hash the gate.
#   --host     the host dir (~/.claude-orca) whose template/config/ is the
#              SOURCE; hook commands in the synced settings.json get the
#              __HOST__ placeholder rewritten to this exact value, so every
#              hook command is an absolute path Claude Code can exec
#              directly -- never left for the agent to resolve via PATH.
#
# Populates (from $HOST/template/config/):
#   claude-settings.json  -> .claude/settings.json (__HOST__ rewritten, then
#                             settings.local.json merged in -- local wins)
#   claude-user-memory.md -> .claude/CLAUDE.md
#   statusline.sh         -> .claude/statusline.sh (executable)
#   agents/*.md           -> .claude/agents/
#   claude-commands/*.md  -> .claude/commands/
#   skills/**             -> .claude/skills/
#   .zshrc                -> .zshrc
#
# settings.local.json itself is only ever READ, never rewritten or moved --
# it is the one sanctioned override channel and always wins on the next
# sync too, since it survives the checksum-gated settings.json rewrite.
#
# Exit 0 whether or not a sync actually ran (a checksum match is not an
# error -- callers don't need to distinguish); exit 2 on bad input.

set -euo pipefail

# Resolve through a symlink chain (e.g. bin/config-sync ->
# ../scripts/config-sync.sh) to this script's real directory, so
# lib/paths.sh resolves whether this is invoked via the repo copy or the
# ~/.claude-orca/template/bin/ symlink.
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

TEMPLATE_CONFIG="$host/template/config"
[ -d "$TEMPLATE_CONFIG" ] || die "template config not found: $TEMPLATE_CONFIG"

# --- checksum gate -----------------------------------------------------

# Sorted sha1 of every file's relative path AND its content -- a rename
# with byte-identical content still counts as a change, unlike a
# content-only hash.
config_checksum() {
    ( cd "$TEMPLATE_CONFIG" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s\n' "${f#./}"
        sha1sum "$f" | cut -d' ' -f1
    done ) | sha1sum | cut -d' ' -f1
}

HASH_FILE="$project/.claude-dev/state/config-hash"
NEW_HASH="$(config_checksum)"
OLD_HASH=""
[ -f "$HASH_FILE" ] && OLD_HASH="$(cat "$HASH_FILE" 2>/dev/null)"

if [ "$NEW_HASH" = "$OLD_HASH" ]; then
    exit 0
fi

# --- populate ------------------------------------------------------------

CONFIG_DIR="$project/.claude-dev/home/.claude"
mkdir -p "$CONFIG_DIR"

# settings.json: hook commands carry a __HOST__ placeholder in the repo copy
# (config/claude-settings.json), rewritten here to this project's actual
# host dir.
sed "s#__HOST__#$host#g" "$TEMPLATE_CONFIG/claude-settings.json" > "$CONFIG_DIR/settings.json"

cp "$TEMPLATE_CONFIG/claude-user-memory.md" "$CONFIG_DIR/CLAUDE.md"
cp "$TEMPLATE_CONFIG/statusline.sh" "$CONFIG_DIR/statusline.sh"
chmod +x "$CONFIG_DIR/statusline.sh"

# agents/commands/skills are fully mirrored (removed-in-template files are
# removed here too), never hand-edited in the project -- settings.local.json
# is the one sanctioned local-override channel.
rm -rf "$CONFIG_DIR/agents" "$CONFIG_DIR/commands" "$CONFIG_DIR/skills"
mkdir -p "$CONFIG_DIR/agents" "$CONFIG_DIR/commands" "$CONFIG_DIR/skills"
if [ -d "$TEMPLATE_CONFIG/agents" ]; then
    cp "$TEMPLATE_CONFIG"/agents/*.md "$CONFIG_DIR/agents/" 2>/dev/null || true
fi
if [ -d "$TEMPLATE_CONFIG/claude-commands" ]; then
    cp "$TEMPLATE_CONFIG"/claude-commands/*.md "$CONFIG_DIR/commands/" 2>/dev/null || true
fi
if [ -d "$TEMPLATE_CONFIG/skills" ]; then
    cp -R "$TEMPLATE_CONFIG"/skills/. "$CONFIG_DIR/skills/" 2>/dev/null || true
fi

if [ -f "$TEMPLATE_CONFIG/.zshrc" ]; then
    cp "$TEMPLATE_CONFIG/.zshrc" "$project/.claude-dev/home/.zshrc"
fi

# --- settings.local.json overlay: preserved on disk, and merged IN (local
# wins) -- same deep-merge entrypoint.sh used, permission arrays unioned
# rather than replaced so a local allowlist extends the base one instead of
# wiping it.
LOCAL_SETTINGS="$CONFIG_DIR/settings.local.json"
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
