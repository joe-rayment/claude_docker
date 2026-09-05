#!/usr/bin/env bash
#
# gen-settings.sh -- pure function: (primary, worktree, real-home, host,
# sandbox.json) -> srt settings JSON on stdout. No side effects: never
# writes files, never mkdirs, never touches the network. sandbox.json is
# read as validated DATA ONLY (see .claude/plans/orca-port.md S3.1) -- an
# invalid extra domain or write path fails closed (exit 2), it is never
# silently dropped or silently widened.
#
# Usage:
#   gen-settings.sh --primary <dir> --worktree <dir> --real-home <dir> \
#       --host <CLAUDE_ORCA_HOME> --sandbox-json <file>
#
# Exit 0 with the JSON on stdout; exit 2 with a one-line reason on stderr
# for any malformed or out-of-scope input.

set -euo pipefail

DEFAULT_DOMAINS=(
    api.anthropic.com
    claude.ai
    console.anthropic.com
    platform.claude.com
    statsig.anthropic.com
    "*.sentry.io"
    github.com
    api.github.com
    "*.githubusercontent.com"
    registry.npmjs.org
    pypi.org
    files.pythonhosted.org
)

# Host-only pattern (no protocol/path/port), lowercase, wildcard only as a
# single leading "*." with at least two labels after it -- matches the
# srt zod schema's own domainPatternSchema (sandbox-config.ts).
DOMAIN_RE='^(\*\.)?[a-z0-9-]+(\.[a-z0-9-]+)+$'

die() {
    echo "gen-settings: $1" >&2
    exit 2
}

resolve_dir() {
    if [ ! -d "$2" ]; then
        die "$1 is not a directory: $2"
    fi
    (cd "$2" && pwd -P)
}

# --- argument parsing -------------------------------------------------

primary=""
worktree=""
real_home=""
host=""
sandbox_json=""

while [ $# -gt 0 ]; do
    case "$1" in
        --primary)      primary="$2"; shift 2 ;;
        --worktree)     worktree="$2"; shift 2 ;;
        --real-home)    real_home="$2"; shift 2 ;;
        --host)         host="$2"; shift 2 ;;
        --sandbox-json) sandbox_json="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$primary" ]      || die "--primary is required"
[ -n "$worktree" ]     || die "--worktree is required"
[ -n "$real_home" ]    || die "--real-home is required"
[ -n "$host" ]         || die "--host is required"
[ -n "$sandbox_json" ] || die "--sandbox-json is required"

primary="$(resolve_dir --primary "$primary")"
worktree="$(resolve_dir --worktree "$worktree")"
real_home="$(resolve_dir --real-home "$real_home")"
host="$(resolve_dir --host "$host")"

if [ ! -f "$sandbox_json" ]; then
    die "sandbox.json not found: $sandbox_json"
fi
if ! jq -e . "$sandbox_json" >/dev/null 2>&1; then
    die "sandbox.json is not valid JSON: $sandbox_json"
fi

# --- validate sandbox.json extras (untrusted data) ---------------------

extra_domains_json="$(jq -c '.network.extraAllowedDomains // []' "$sandbox_json" 2>/dev/null)" \
    || die "sandbox.json: unable to read network.extraAllowedDomains"
if ! jq -e 'type == "array" and all(.[]; type == "string")' <<<"$extra_domains_json" >/dev/null 2>&1; then
    die "network.extraAllowedDomains must be an array of strings"
fi

while IFS= read -r domain; do
    if [ -z "$domain" ]; then
        continue
    fi
    if ! [[ "$domain" =~ $DOMAIN_RE ]]; then
        die "invalid domain pattern in network.extraAllowedDomains: $domain"
    fi
done < <(jq -r '.[]' <<<"$extra_domains_json")

extra_write_json="$(jq -c '.filesystem.extraAllowWrite // []' "$sandbox_json" 2>/dev/null)" \
    || die "sandbox.json: unable to read filesystem.extraAllowWrite"
if ! jq -e 'type == "array" and all(.[]; type == "string")' <<<"$extra_write_json" >/dev/null 2>&1; then
    die "filesystem.extraAllowWrite must be an array of strings"
fi

extra_write_paths=()
while IFS= read -r p; do
    if [ -z "$p" ]; then
        continue
    fi
    if [ ! -d "$p" ]; then
        die "filesystem.extraAllowWrite entry does not exist or is not a directory: $p"
    fi
    resolved="$(cd "$p" && pwd -P)"
    case "$resolved" in
        "$primary"|"$primary"/*) ;;
        "$worktree"|"$worktree"/*) ;;
        *) die "filesystem.extraAllowWrite entry resolves outside the folder: $p" ;;
    esac
    extra_write_paths+=("$resolved")
done < <(jq -r '.[]' <<<"$extra_write_json")

# --- scope derivation ----------------------------------------------------

if [ "$primary" = "$worktree" ]; then
    allow_write=("$primary" "$primary/.claude-dev/home" "$primary/.claude-dev/tmp")
    deny_write=("$primary/orca.yaml" "$primary/.worktreeinclude" "$primary/.envrc" "$primary/.beads/hooks")
    allow_read=("$primary" "$host" "$real_home/.local/bin" "$real_home/.local/share/claude" "$real_home/.orca/agent-hooks")
else
    allow_write=("$worktree" "$primary/.git" "$primary/.beads" "$primary/.claude-dev/home" "$primary/.claude-dev/tmp")
    deny_write=(
        "$primary/orca.yaml" "$primary/.worktreeinclude" "$primary/.envrc" "$primary/.beads/hooks"
        "$worktree/orca.yaml" "$worktree/.worktreeinclude" "$worktree/.envrc"
    )
    allow_read=("$primary" "$worktree" "$host" "$real_home/.local/bin" "$real_home/.local/share/claude" "$real_home/.orca/agent-hooks")
fi

# Bash 3.2 (macOS /bin/bash) throws "unbound variable" under `set -u` when
# "${arr[@]}" expands an array that has zero elements -- even just to
# reference it, not only to assign it. extra_write_paths is exactly that
# case when sandbox.json's filesystem.extraAllowWrite is []. The
# `${arr[@]+"${arr[@]}"}` idiom sidesteps it: the `+` test only substitutes
# its alternate value when the parameter is considered set, so an unset or
# zero-element array expands to nothing instead of raising, while a
# non-empty array is unaffected -- verified against a real bash-3.2.57
# build in tests/shell-entry.bats.
allow_write+=(${extra_write_paths[@]+"${extra_write_paths[@]}"})

allowed_domains=("${DEFAULT_DOMAINS[@]}")
while IFS= read -r d; do
    if [ -z "$d" ]; then
        continue
    fi
    dup=0
    for existing in "${allowed_domains[@]}"; do
        if [ "$existing" = "$d" ]; then
            dup=1
            break
        fi
    done
    if [ "$dup" -eq 0 ]; then
        allowed_domains+=("$d")
    fi
done < <(jq -r '.[]' <<<"$extra_domains_json")

# --- JSON emission ---------------------------------------------------------

# Bash-array -> compact JSON array, via jq -R/-s. printf with ZERO args
# still runs its format string once (emitting one blank line) rather than
# zero times, so the empty case is special-cased instead of relying on
# `"${arr[@]}"` expanding to nothing.
to_json_array() {
    if [ "$#" -eq 0 ]; then
        echo "[]"
    else
        printf '%s\n' "$@" | jq -R . | jq -s -c .
    fi
}

allow_write_json="$(to_json_array "${allow_write[@]}")"
deny_write_json="$(to_json_array "${deny_write[@]}")"
allow_read_json="$(to_json_array "${allow_read[@]}")"
deny_read_json="$(to_json_array "$real_home")"
allowed_domains_json="$(to_json_array "${allowed_domains[@]}")"

jq -n \
    --argjson allowWrite "$allow_write_json" \
    --argjson denyWrite "$deny_write_json" \
    --argjson allowRead "$allow_read_json" \
    --argjson denyRead "$deny_read_json" \
    --argjson allowedDomains "$allowed_domains_json" \
    '{
        network: {
            allowedDomains: $allowedDomains,
            deniedDomains: [],
            strictAllowlist: true,
            allowLocalBinding: true,
            allowUnixSockets: []
        },
        filesystem: {
            denyRead: $denyRead,
            allowRead: $allowRead,
            allowWrite: $allowWrite,
            denyWrite: $denyWrite
        },
        enableWeakerNetworkIsolation: true,
        allowAppleEvents: false,
        allowPty: true
    }'
