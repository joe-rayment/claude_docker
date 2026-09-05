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
#       --host <project>/.claude-dev --sandbox-json <file> [--gh-token-present] \
#       [--openrouter-key-present] [--openai-key-present] [--gemini-key-present]
#
# The three provider-key flags (S8, claude-orca-3sk.19) are the delegation
# equivalent of --gh-token-present: the caller found OPENROUTER_API_KEY /
# OPENAI_API_KEY / GEMINI_API_KEY in the host environment and will pass it
# in, so mask it and open its API host. See "credential masks" below.
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

# V2 (claude-orca-qt9.2): the host-executed paths inside a project come
# from ONE shared list, so this (layer 2, the agents) and the Orca-layer
# Seatbelt profile can never drift apart. Resolved through any symlink
# chain, so it is found however this script was invoked.
_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
    _link="$(readlink "$_self")"
    case "$_link" in
        /*) _self="$_link" ;;
        *)  _self="$(cd "$(dirname "$_self")" && pwd)/$_link" ;;
    esac
done
# shellcheck source=scripts/sandbox/host-owned-paths.sh
. "$(cd "$(dirname "$_self")" && pwd)/host-owned-paths.sh"

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
openrouter_key_present=0
openai_key_present=0
gemini_key_present=0

while [ $# -gt 0 ]; do
    case "$1" in
        --gh-token-present) gh_token_present=1; shift ;;
        --openrouter-key-present) openrouter_key_present=1; shift ;;
        --openai-key-present) openai_key_present=1; shift ;;
        --gemini-key-present) gemini_key_present=1; shift ;;
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
    allow_read=("$primary" "$host" "$real_home/.local/bin" "$real_home/.local/share/claude" "$real_home/.orca/agent-hooks")
else
    allow_write=("$worktree" "$primary/.git" "$primary/.beads" "$primary/.claude-dev/home" "$primary/.claude-dev/tmp")
    allow_read=("$primary" "$worktree" "$host" "$real_home/.local/bin" "$real_home/.local/share/claude" "$real_home/.orca/agent-hooks")
fi

# Everything the host executes or trusts inside the folder, on top of
# srt's own mandatory deny list -- the shared list (host-owned-paths.sh),
# never a copy of it. A linked worktree adds its own copy of the same
# paths: Orca runs its setup files from whichever checkout it opened.
deny_write=()
add_host_owned() {
    local hop
    while IFS= read -r hop; do
        [ -z "$hop" ] && continue
        deny_write=(${deny_write[@]+"${deny_write[@]}"} "$hop")
    done < <(host_owned_paths "$1")
}
add_host_owned "$primary"
if [ "$primary" != "$worktree" ]; then
    add_host_owned "$worktree"
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

# --- credential masks ------------------------------------------------------

# S5 (GH_TOKEN) and S8 (claude-orca-3sk.19, the delegation provider keys):
# a secret the caller found on the host becomes an srt credentials mask --
# the sandboxed process sees a sentinel and the host proxy substitutes the
# real value only on egress to that secret's own inject hosts. Each inject
# host also joins allowedDomains, because srt rejects an injectHosts entry
# the allowlist cannot reach; the two GitHub hosts are already there, so
# the settings a project without any provider key gets are unchanged.
cred_json='[]'

# add_credential <env-var-name> <inject-host> [inject-host]
add_credential() {
    local name="$1" host1="$2" host2="${3:-}"
    local h existing dup hosts_json
    for h in "$host1" "$host2"; do
        if [ -z "$h" ]; then
            continue
        fi
        dup=0
        for existing in "${allowed_domains[@]}"; do
            if [ "$existing" = "$h" ]; then
                dup=1
                break
            fi
        done
        if [ "$dup" -eq 0 ]; then
            allowed_domains+=("$h")
        fi
    done
    if [ -n "$host2" ]; then
        hosts_json="$(printf '%s\n%s\n' "$host1" "$host2" | jq -R . | jq -s -c .)"
    else
        hosts_json="$(printf '%s\n' "$host1" | jq -R . | jq -s -c .)"
    fi
    cred_json="$(jq -c --arg n "$name" --argjson h "$hosts_json" \
        '. + [{name: $n, mode: "mask", injectHosts: $h}]' <<<"$cred_json")"
    return 0
}

if [ "$gh_token_present" -eq 1 ]; then
    add_credential GH_TOKEN github.com api.github.com
fi
if [ "$openrouter_key_present" -eq 1 ]; then
    add_credential OPENROUTER_API_KEY openrouter.ai
fi
if [ "$openai_key_present" -eq 1 ]; then
    add_credential OPENAI_API_KEY api.openai.com
fi
if [ "$gemini_key_present" -eq 1 ]; then
    add_credential GEMINI_API_KEY generativelanguage.googleapis.com
fi

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

# Masked secrets, or nothing at all: an entry naming an unset variable
# buys nothing, and the settings must stay schema-valid either way.
if [ "$cred_json" = "[]" ]; then
    credentials_json='null'
else
    credentials_json="$(jq -c -n --argjson e "$cred_json" '{envVars: $e}')"
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
