#!/usr/bin/env bash
# pin-currency.sh — reports drift between the Dockerfile's pinned tool
# versions and each tool's latest upstream release (beads_claude_docker-xq9).
# Nothing else in this repo tracks pin staleness; this exists so a bump
# decision starts from a table instead of a manual hunt through the
# Dockerfile against a dozen release pages.
#
# Usage:
#   pin-currency.sh extract    tool<TAB>current rows only — no network
#   pin-currency.sh            extract + query upstream latest + print an
#                               aligned drift table (tool/pinned/latest/status)
#
# Pure bash + curl + jq, deliberately dependency-free beyond that, so the
# HOST launcher (running outside the container, on whatever the user's
# machine has) can invoke it too, not just the container's own copy.
#
# Deliberately no `set -e`/`set -u`: this is a report tool, never a gate, and
# must reach `exit 0` even when a network call fails, jq is missing, or a
# future Dockerfile edit changes a pin's line shape out from under one
# extraction pattern. Every fetch/extract failure degrades that one row to
# "unknown" via `${var:-unknown}`-style defaults and the loop moves on —
# `set -e`/`set -u` would instead abort the whole report on the first miss.
#
# Network seam (tests / offline use): set PIN_CURRENCY_FETCH_CMD to the
# command used to fetch a URL, with the URL appended as the final argument
# and the response body printed to stdout. Defaults to `curl -fsSL -m 10`,
# which is resolved on PATH at call time — so staging a fake `curl` earlier
# on PATH intercepts fetches exactly like setting PIN_CURRENCY_FETCH_CMD
# explicitly, no extra plumbing needed (kb/GUARD_VERIFICATION.md's
# fake-binary-on-PATH technique).

DOCKERFILE="${PIN_CURRENCY_DOCKERFILE:-}"
if [ -z "$DOCKERFILE" ]; then
    DOCKERFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Dockerfile"
fi
FETCH_CMD="${PIN_CURRENCY_FETCH_CMD:-curl -fsSL -m 10}"

# Tool inventory, in Dockerfile order. Adding a newly-pinned tool means one
# new case arm in each of the two functions below, plus the name here.
TOOLS="base-image node helix graphifyy bats-core bd dolt playwright-cli playwright-mcp intellishell termshot pnpm yarn"

# grep -oP pattern (applied to the whole Dockerfile, first match wins) that
# captures just the pinned version/digest for this tool.
extract_pattern() {
    case "$1" in
        base-image)     echo '^FROM\s+\S+@sha256:\K[0-9a-f]+' ;;
        node)           echo 'deb\.nodesource\.com/setup_\K[0-9]+(?=\.x)' ;;
        helix)          echo 'HELIX_VERSION=\K[0-9.]+' ;;
        graphifyy)      echo 'graphifyy==\K[0-9.]+' ;;
        bats-core)      echo '\-\-branch v\K[0-9.]+' ;;
        bd)             echo 'BD_VERSION=\K[0-9.]+' ;;
        dolt)           echo 'dolthub/dolt/releases/download/v\K[0-9.]+' ;;
        playwright-cli) echo '\-g playwright@\K[0-9.]+' ;;
        playwright-mcp) echo '@playwright/mcp@\K[0-9.]+' ;;
        intellishell)   echo 'intelli-shell/v\K[0-9.]+' ;;
        termshot)       echo 'termshot@v\K[0-9.]+' ;;
        pnpm)           echo '\-g pnpm@\K[0-9.]+' ;;
        yarn)           echo 'yarn@\K[0-9.]+' ;;
    esac
}

# Where to look up "latest": manual (never queried — base-image digests are
# a deliberate human call, not a version to chase), github:<owner>/<repo>
# (GitHub releases API), or npm:<package> (npm registry).
upstream_source() {
    case "$1" in
        base-image)     echo 'manual' ;;
        node)           echo 'github:nodejs/node' ;;
        helix)          echo 'github:helix-editor/helix' ;;
        graphifyy)      echo 'github:Graphify-Labs/graphify' ;;
        bats-core)      echo 'github:bats-core/bats-core' ;;
        bd)             echo 'github:gastownhall/beads' ;;
        dolt)           echo 'github:dolthub/dolt' ;;
        playwright-cli) echo 'npm:playwright' ;;
        playwright-mcp) echo 'npm:@playwright/mcp' ;;
        intellishell)   echo 'github:lasantosr/intelli-shell' ;;
        termshot)       echo 'github:homeport/termshot' ;;
        pnpm)           echo 'npm:pnpm' ;;
        yarn)           echo 'npm:yarn' ;;
    esac
}

current_of() {
    local pattern
    pattern="$(extract_pattern "$1")"
    [ -n "$pattern" ] || { echo unknown; return; }
    local v
    v="$(grep -oP -- "$pattern" "$DOCKERFILE" 2>/dev/null | head -1)"
    echo "${v:-unknown}"
}

fetch() {
    # $1 = URL. Body to stdout; empty output on any failure — callers treat
    # empty as "unknown", never as a reason to stop.
    $FETCH_CMD "$1" 2>/dev/null
}

latest_of() {
    local src body v
    src="$(upstream_source "$1")"
    case "$src" in
        manual)
            echo 'manual-check'
            ;;
        github:*)
            body="$(fetch "https://api.github.com/repos/${src#github:}/releases/latest")"
            v=""
            [ -n "$body" ] && v="$(printf '%s' "$body" | jq -r '.tag_name // empty' 2>/dev/null)"
            v="${v#v}"
            echo "${v:-unknown}"
            ;;
        npm:*)
            body="$(fetch "https://registry.npmjs.org/${src#npm:}/latest")"
            v=""
            [ -n "$body" ] && v="$(printf '%s' "$body" | jq -r '.version // empty' 2>/dev/null)"
            echo "${v:-unknown}"
            ;;
        *)
            echo unknown
            ;;
    esac
}

status_of() {
    local current="$1" latest="$2"
    if [ "$latest" = "manual-check" ]; then
        echo "manual-check"
    elif [ "$current" = "unknown" ] || [ "$latest" = "unknown" ]; then
        echo "unknown"
    elif [ "$current" = "$latest" ]; then
        echo "OK"
    else
        echo "DRIFT"
    fi
}

if [ "${1:-}" = "extract" ]; then
    for t in $TOOLS; do
        printf '%s\t%s\n' "$t" "$(current_of "$t")"
    done
else
    printf '%-16s %-14s %-14s %s\n' "TOOL" "PINNED" "LATEST" "STATUS"
    for t in $TOOLS; do
        cur="$(current_of "$t")"
        lat="$(latest_of "$t")"
        printf '%-16s %-14s %-14s %s\n' "$t" "$cur" "$lat" "$(status_of "$cur" "$lat")"
    done
fi

exit 0
