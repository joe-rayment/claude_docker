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
#       --host <CLAUDE_ORCA_HOME> --sandbox-json <file> [--gh-token-present]
#
# --gh-token-present (S5, claude-orca-3sk.17): the caller found a GitHub
# token on the host (`gh auth token`) and will pass it into srt as
# GH_TOKEN, so emit the credentials block that makes srt mask it -- the
# sandboxed process sees a sentinel, and the host proxy substitutes the
# real value only on egress to github.com/api.github.com. Omitted when
# there is no token: an entry naming an unset variable buys nothing, and
# the settings must stay schema-valid either way. srt rejects credential
# masking without network.tlsTerminate (sentinel->real substitution must
# run over a connection whose upstream identity it verified), so the
# credentials block always brings an empty tlsTerminate -- srt then
# generates an ephemeral CA and points the sandboxed child's trust store
# at it. The alternative it offers, credentials.allowPlaintextInject,
# would put the real token on the cleartext path; not taken.
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
    cdn.playwright.dev
    playwright.download.prss.microsoft.com
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
gh_token_present=0

while [ $# -gt 0 ]; do
    case "$1" in
        --gh-token-present) gh_token_present=1; shift ;;
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

# S9 (claude-orca-3sk.20): the opt-in Orca CLI mode. `orca` talks to the
# running app over a Unix socket under the REAL home's Orca runtime dir --
# the same path the wrapper exports as ORCA_USER_DATA_PATH -- which the
# denyRead of $real_home otherwise closes. Reachability is a remote
# control for an UNSANDBOXED app (see config/orca-cli-addendum.md), so it
# is off unless sandbox.json says otherwise, and a non-boolean value is
# rejected rather than coerced: fail closed, like every other extra here.
if ! jq -e '(.orca.cli // false) | type == "boolean"' "$sandbox_json" >/dev/null 2>&1; then
    die "orca.cli must be a boolean"
fi
orca_cli="$(jq -r '.orca.cli // false' "$sandbox_json")"
ORCA_RUNTIME_DIR="$real_home/Library/Application Support/orca"

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

# S9: the socket allowance and the read allowance are one decision -- srt
# needs both (connect(2) plus a readable path to it), and neither is
# useful alone. Appended last so the base allowRead list keeps its order.
allow_unix_sockets=()
if [ "$orca_cli" = "true" ]; then
    allow_unix_sockets=("$ORCA_RUNTIME_DIR")
    allow_read+=("$ORCA_RUNTIME_DIR")
fi

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
allow_unix_sockets_json="$(to_json_array ${allow_unix_sockets[@]+"${allow_unix_sockets[@]}"})"

# S5: masked GH_TOKEN, or nothing at all. injectHosts names two hosts that
# are always in DEFAULT_DOMAINS -- srt rejects an injectHosts entry that is
# not reachable via allowedDomains.
if [ "$gh_token_present" -eq 1 ]; then
    credentials_json='{"envVars":[{"name":"GH_TOKEN","mode":"mask","injectHosts":["github.com","api.github.com"]}]}'
else
    credentials_json='null'
fi

jq -n \
    --argjson credentials "$credentials_json" \
    --argjson allowWrite "$allow_write_json" \
    --argjson denyWrite "$deny_write_json" \
    --argjson allowRead "$allow_read_json" \
    --argjson denyRead "$deny_read_json" \
    --argjson allowedDomains "$allowed_domains_json" \
    --argjson allowUnixSockets "$allow_unix_sockets_json" \
    '{
        network: {
            allowedDomains: $allowedDomains,
            deniedDomains: [],
            strictAllowlist: true,
            allowLocalBinding: true,
            allowUnixSockets: $allowUnixSockets
        },
        filesystem: {
            denyRead: $denyRead,
            allowRead: $allowRead,
            allowWrite: $allowWrite,
            denyWrite: $denyWrite
        },
        credentials: $credentials,
        enableWeakerNetworkIsolation: true,
        allowAppleEvents: false,
        allowPty: true
    }
    | if .credentials == null
      then del(.credentials)
      else .network.tlsTerminate = {}
      end'
