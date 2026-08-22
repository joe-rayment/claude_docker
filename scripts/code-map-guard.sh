#!/bin/sh
# code-map-guard — staged as /usr/local/bin/graphify, i.e. the ONLY `graphify`
# on PATH in this container.
#
# Why a wrapper at all: the upstream graphify CLI mixes two very different
# jobs. Graph work (extract, query, explain, …) is exactly what we want. But
# ~20 per-platform installers (`install`, `claude install`, `hook install`,
# `cursor install`, …) rewrite ASSISTANT CONFIG — CLAUDE.md sections, ~/.claude
# hooks and skills, .cursor rules. In this container that config is generated
# and checksum-synced from the image (config/ -> /etc/claude-dev/configs), so
# anything writing it out-of-band gets silently reverted at the next session
# start, or worse, sticks around as unexplained drift. The wrapper therefore
# runs deny-by-default: an ALLOWLIST of graph subcommands execs the real
# engine, and everything else — including subcommands upstream adds later —
# exits 2 with a pointer at `code-map`, the project's own front end.
#
# Engine resolution, in order:
#   1. $HOME/.local/lib/code-map/bin/graphify   the upgrade path: `code-map
#                                               upgrade` installs a newer
#                                               engine here, shadowing the
#                                               image's pinned one
#   2. $CODE_MAP_IMAGE_PREFIX/bin/graphify      the image's pinned engine
#                                               (default /opt/code-map, kept
#                                               OFF PATH on purpose so this
#                                               wrapper is the only entry
#                                               point). The env var exists so
#                                               tests can redirect it.
#
# NOTE: never resolve the engine through PATH (`command -v graphify`) — this
# script IS graphify on PATH, so that would exec itself forever.
#
# Exit: 0/engine's own status when allowed · 2 blocked · 3 no engine found

set -eu

IMAGE_PREFIX=${CODE_MAP_IMAGE_PREFIX:-/opt/code-map}
OVERRIDE_ENGINE="$HOME/.local/lib/code-map/bin/graphify"
IMAGE_ENGINE="$IMAGE_PREFIX/bin/graphify"

# Block first, resolve second: the deny decision must not depend on which
# engine happens to be installed, and a blocked call must never reach one.
cmd=${1-}

case "$cmd" in
    # graph work — the whole point of shipping the engine
    extract|update|cluster-only|query|explain|path|affected|tree|god-nodes|\
diagnose|label|watch|merge-graphs|merge-driver|export|benchmark|version|help)
        ;;
    # no args / bare flags: let the engine print its own help and version
    ''|--version|--help)
        ;;
    *)
        # name the second token too, so `claude install` doesn't report as
        # bare `claude`
        cat >&2 <<EOF
graphify ${cmd}${2:+ $2} is blocked in this container: it writes assistant config
(CLAUDE.md sections, ~/.claude hooks and skills, per-platform rules), which is
generated from the image here and would be reverted or left as drift.

Use \`code-map\` instead — see knowledge-base/CODE_MAP.md. Engine upgrades go
through \`code-map upgrade\`.
EOF
        exit 2
        ;;
esac

if [ -x "$OVERRIDE_ENGINE" ]; then
    engine=$OVERRIDE_ENGINE
elif [ -x "$IMAGE_ENGINE" ]; then
    engine=$IMAGE_ENGINE
else
    cat >&2 <<EOF
graphify engine not found. Looked for:
  $OVERRIDE_ENGINE
  $IMAGE_ENGINE

Run \`code-map doctor\` to diagnose (the engine ships in the image; a missing
one usually means the image predates the code-map feature).
EOF
    exit 3
fi

exec "$engine" "$@"
