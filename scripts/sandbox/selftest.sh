#!/usr/bin/env bash
#
# selftest.sh -- the S3 probe runner. Invoked by `claude-orca-shell
# --selftest` INSIDE the sandbox (see claude-orca-shell and
# .claude/plans/orca-port.md S3) to prove the sandbox from the inside:
# seventeen probes, each a shell function returning 0 (expected behaviour
# observed -- PASS), 1 (violation -- FAIL) or 2 (not applicable on this
# host -- N/A), run in the fixed order below (the single source of truth
# for the probe table). Writes a results JSON and exits 0 iff no probe
# FAILed.
#
# Usage:
#   selftest.sh --json-out <file> [--dry-run] [--fake <file>]
#
# --dry-run prints the probe table (name + one-line description) and
# executes NOTHING -- no probe function is called, no JSON is written.
#
# --fake <file> (or $CLAUDE_ORCA_SELFTEST_FAKE, CLI wins if both given)
# replaces EXECUTION for any probe named in the file: lines of the form
# `probe-name=0`, `=1` or `=2` are used as that probe's result verbatim
# instead of running its real shell code -- this is what makes the runner
# testable on a Linux host that cannot run sandbox-exec/bwrap at all.
# Probes not mentioned in the file still run for real.
#
# $CLAUDE_ORCA_SELFTEST_TRACE=<file> (test-only hook, not a documented
# interface) -- if set, the runner appends each probe's name to this file
# right before resolving its outcome (fake lookup or real call), for
# EVERY mode except --dry-run. Used by tests/selftest.bats to prove
# --dry-run truly executes nothing, without depending on any real
# sandboxing semantics this host can't provide.
#
# Env this script reads (all optional -- probes that need one and don't
# find it report N/A or FAIL, never silently skip):
#   CLAUDE_ORCA_REAL_HOME  -- the unsandboxed home (write/read-denied probes)
#   CLAUDE_ORCA_ROOT       -- the primary checkout (project-writable, hooks audit)
#   CLAUDE_ORCA_SETTINGS   -- generated srt settings JSON (git-hooks-audit)
#   CLAUDE_ORCA_HOST       -- <project>/.claude-dev (srt-version-pinned);
#                             falls back to $CLAUDE_ORCA_ROOT/.claude-dev, the same
#                             default every other script in this repo uses.
#   CLAUDE_ORCA_LAYER      -- `orca` inside a terminal that the folder's own
#                             sandboxed Orca opened (exported by orca-launch).
#                             The last four probes -- layer 1, the Orca app
#                             itself -- are the only ones that can observe
#                             that layer, so they report N/A anywhere else
#                             rather than claiming a confinement nobody
#                             applied. V3 (claude-orca-qt9.3).
#
# Deliberately no `set -e`: most of these probes' PASS case is "the
# expected command fails" -- every fallible command below is the
# condition of an explicit if/case instead, so nothing here relies on -e
# to detect success/failure. bash 3.2 clean (see scripts/lint-bash32.sh).

set -u

PROBE_NAMES="write-outside-denied read-real-home-denied keychain-denied project-writable worktree-writable sibling-worktree-denied tmp-outside-denied network-blocked-domain network-allowed-domain orca-socket-unreachable sandbox-exec-present srt-version-pinned git-hooks-audit orca-profile-active home-redirected orca-data-in-folder host-files-write-denied"

usage() {
    cat <<'USAGE'
Usage: selftest.sh --json-out <file> [--dry-run] [--fake <file>]
USAGE
}

probe_description() {
    case "$1" in
        write-outside-denied)    echo "touch under \$CLAUDE_ORCA_REAL_HOME fails" ;;
        read-real-home-denied)   echo "ls \$CLAUDE_ORCA_REAL_HOME/.ssh (or the home itself) fails" ;;
        keychain-denied)         echo "security find-generic-password -s 'Claude Code-credentials' fails" ;;
        project-writable)        echo "a temp file under \$CLAUDE_ORCA_ROOT can be created and removed" ;;
        worktree-writable)       echo "a temp file under the current worktree can be created and removed" ;;
        sibling-worktree-denied) echo "another git worktree (not primary, not current) is not writable" ;;
        tmp-outside-denied)      echo "touch under the real /tmp (/private/tmp on Darwin) fails" ;;
        network-blocked-domain)  echo "curl https://example.com fails" ;;
        network-allowed-domain)  echo "curl https://api.anthropic.com/ returns any HTTP status" ;;
        orca-socket-unreachable) echo "the Orca runtime is unreachable unless sandbox.json orca.cli is true" ;;
        sandbox-exec-present)    echo "sandbox-exec is on PATH (Darwin only; reports bwrap elsewhere)" ;;
        srt-version-pinned)      echo "installed srt package.json version equals the SRT_VERSION pin" ;;
        git-hooks-audit)         echo "git hooks reference only paths covered by the generated denyWrite list" ;;
        orca-profile-active)     echo "a write under \$CLAUDE_ORCA_REAL_HOME fails before srt (layer 1 alone)" ;;
        home-redirected)         echo "\$HOME resolves inside <project>/.claude-dev/home" ;;
        orca-data-in-folder)     echo "Orca's user data dir is the folder's, and the real one is untouched since launch" ;;
        host-files-write-denied) echo "touch ./claude-dev, Orca.app/Contents/MacOS/Orca and state/orca.sb all fail" ;;
        *)                       echo "" ;;
    esac
}

# --- shared helpers --------------------------------------------------------

# Reads the pinned srt version straight out of install-srt.sh's own
# SRT_VERSION="..." line -- the single source of truth (scripts/install-
# srt.sh), never duplicated as a literal version string in this file.
read_srt_pin() {
    local self_dir install_srt pin
    self_dir="$(cd "$(dirname "$0")" && pwd -P 2>/dev/null)"
    install_srt="$self_dir/../install-srt.sh"
    [ -f "$install_srt" ] || return 1
    pin="$(grep -E '^SRT_VERSION=' "$install_srt" 2>/dev/null | head -1 | sed -E 's/^SRT_VERSION="([^"]*)".*/\1/')"
    [ -n "$pin" ] || return 1
    printf '%s\n' "$pin"
}

# $1 = path to test for temp-file create+remove. Echoes a detail line,
# returns 0 (writable) or 1 (not writable / doesn't exist).
try_write_remove() {
    local dir="$1" f
    [ -d "$dir" ] || { echo "$dir does not exist"; return 1; }
    f="$dir/.claude-orca-selftest-$$"
    if ( umask 022; : > "$f" ) 2>/dev/null; then
        rm -f "$f" 2>/dev/null
        echo "created and removed a temp file under $dir"
        return 0
    fi
    echo "could not create a temp file under $dir"
    return 1
}

# --- probes -----------------------------------------------------------------

probe_write_outside_denied() {
    local real_home="${CLAUDE_ORCA_REAL_HOME:-}" f
    if [ -z "$real_home" ] || [ ! -d "$real_home" ]; then
        echo "CLAUDE_ORCA_REAL_HOME not set or not a directory -- cannot test"
        return 2
    fi
    f="$real_home/.claude-orca-selftest-$$"
    if ( : > "$f" ) 2>/dev/null; then
        rm -f "$f" 2>/dev/null
        echo "touch $f unexpectedly succeeded"
        return 1
    fi
    echo "touch under \$CLAUDE_ORCA_REAL_HOME ($real_home) denied, as expected"
    return 0
}

probe_read_real_home_denied() {
    local real_home="${CLAUDE_ORCA_REAL_HOME:-}" target
    if [ -z "$real_home" ] || [ ! -d "$real_home" ]; then
        echo "CLAUDE_ORCA_REAL_HOME not set or not a directory -- cannot test"
        return 2
    fi
    target="$real_home/.ssh"
    [ -d "$target" ] || target="$real_home"
    if ls "$target" >/dev/null 2>&1; then
        echo "ls $target unexpectedly succeeded"
        return 1
    fi
    echo "ls $target denied, as expected"
    return 0
}

probe_keychain_denied() {
    if ! command -v security >/dev/null 2>&1; then
        echo "no 'security' binary on this host -- not applicable"
        return 2
    fi
    if security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
        echo "security find-generic-password unexpectedly succeeded"
        return 1
    fi
    echo "Keychain access for Claude Code credentials denied, as expected"
    return 0
}

probe_project_writable() {
    local root="${CLAUDE_ORCA_ROOT:-}"
    if [ -z "$root" ]; then
        echo "CLAUDE_ORCA_ROOT not set -- cannot test"
        return 2
    fi
    try_write_remove "$root"
}

probe_worktree_writable() {
    try_write_remove "$PWD"
}

probe_sibling_worktree_denied() {
    local root="${CLAUDE_ORCA_ROOT:-}" cur primary line path sibling=""
    if [ -z "$root" ] || [ ! -d "$root" ]; then
        echo "CLAUDE_ORCA_ROOT not set or not a directory -- cannot test"
        return 2
    fi
    if ! command -v git >/dev/null 2>&1; then
        echo "git not available -- not applicable"
        return 2
    fi
    cur="$(pwd -P)"
    primary="$(cd "$root" && pwd -P)"

    while IFS= read -r line; do
        case "$line" in
            worktree\ *)
                path="${line#worktree }"
                [ -d "$path" ] || continue
                path="$(cd "$path" && pwd -P)"
                if [ "$path" != "$primary" ] && [ "$path" != "$cur" ]; then
                    sibling="$path"
                    break
                fi
                ;;
        esac
    done < <(cd "$primary" && git worktree list --porcelain 2>/dev/null)

    if [ -z "$sibling" ]; then
        echo "no sibling worktree found -- not applicable"
        return 2
    fi

    local f="$sibling/.claude-orca-selftest-$$"
    if ( : > "$f" ) 2>/dev/null; then
        rm -f "$f" 2>/dev/null
        echo "sibling worktree $sibling unexpectedly writable"
        return 1
    fi
    echo "sibling worktree $sibling not writable, as expected"
    return 0
}

probe_tmp_outside_denied() {
    local base f
    if [ "$(uname -s)" = "Darwin" ]; then
        base="/private/tmp"
    else
        base="/tmp"
    fi
    [ -d "$base" ] || { echo "$base does not exist -- not applicable"; return 2; }
    f="$base/.claude-orca-selftest-$$"
    if ( : > "$f" ) 2>/dev/null; then
        rm -f "$f" 2>/dev/null
        echo "$base unexpectedly writable"
        return 1
    fi
    echo "$base not writable, as expected"
    return 0
}

probe_network_blocked_domain() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "curl not available -- not applicable"
        return 2
    fi
    if curl -sS --max-time 8 https://example.com >/dev/null 2>&1; then
        echo "curl to example.com unexpectedly succeeded"
        return 1
    fi
    echo "curl to example.com denied, as expected"
    return 0
}

probe_network_allowed_domain() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "curl not available -- not applicable"
        return 2
    fi
    local code
    code="$(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' https://api.anthropic.com/ 2>/dev/null)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then
        echo "curl to api.anthropic.com returned HTTP $code"
        return 0
    fi
    echo "curl to api.anthropic.com did not return an HTTP status (got '${code:-<empty>}')"
    return 1
}

# Echoes "true"/"false" and returns 0 when $1 (the output of `orca status
# --json`) carries a runtime-reachability boolean; returns 1, echoing
# nothing, when it does not. The printed shape is NOT a pinned contract --
# v1.4.197 nests it as .runtime.reachable -- so this searches every object
# for a `reachable` key rather than trusting one path.
orca_status_reachable() {
    local value
    command -v jq >/dev/null 2>&1 || return 1
    value="$(printf '%s' "$1" | jq -r '
        [.. | objects | select(has("reachable")) | .reachable]
        | first
        | if type == "boolean" then tostring else empty end' 2>/dev/null)"
    case "$value" in
        true|false) printf '%s\n' "$value"; return 0 ;;
    esac
    return 1
}

# What this actually enforces is that the Orca runtime is NOT reachable
# from in here unless sandbox.json opted in -- not that the `orca` binary
# fails. The real CLI (v1.4.197) always exits 0 under --json and reports
# reachability in the JSON, so exit status alone says nothing: only plain
# `orca status` encodes it, and that is the fallback below.
probe_orca_socket_unreachable() {
    if ! command -v orca >/dev/null 2>&1; then
        echo "orca not on PATH -- not applicable"
        return 2
    fi
    local root="${CLAUDE_ORCA_ROOT:-}" cli_enabled="false" reachable source
    if [ -n "$root" ] && [ -f "$root/.claude-dev/sandbox.json" ] && command -v jq >/dev/null 2>&1; then
        cli_enabled="$(jq -r '.orca.cli // false' "$root/.claude-dev/sandbox.json" 2>/dev/null)"
    fi

    if reachable="$(orca_status_reachable "$(orca status --json 2>/dev/null)")"; then
        source="per 'orca status --json'"
    else
        if orca status >/dev/null 2>&1; then
            reachable="true"
        else
            reachable="false"
        fi
        source="per the plain 'orca status' exit code (status JSON carried no reachability)"
    fi

    if [ "$cli_enabled" = "true" ]; then
        if [ "$reachable" = "true" ]; then
            echo "Orca runtime reachable $source (orca.cli=true, expected)"
            return 0
        fi
        echo "Orca runtime unreachable $source, but orca.cli=true -- launch this folder's Orca.app, then re-run: claude-dev --doctor"
        return 2
    fi
    if [ "$reachable" = "true" ]; then
        echo "SANDBOX LEAK: Orca runtime reachable $source although orca.cli=false -- the unix-socket deny is not in effect"
        return 1
    fi
    echo "Orca runtime unreachable $source, as expected (orca.cli=false)"
    return 0
}

probe_sandbox_exec_present() {
    if [ "$(uname -s)" = "Darwin" ]; then
        if command -v sandbox-exec >/dev/null 2>&1; then
            echo "sandbox-exec present on PATH"
            return 0
        fi
        echo "sandbox-exec NOT found on PATH"
        return 1
    fi
    if command -v bwrap >/dev/null 2>&1; then
        echo "not Darwin -- bwrap present on PATH (informational)"
    else
        echo "not Darwin -- bwrap not found on PATH (informational)"
    fi
    return 2
}

probe_srt_version_pinned() {
    local pin host pkg installed
    pin="$(read_srt_pin)" || { echo "could not read SRT_VERSION pin from install-srt.sh"; return 2; }
    host="${CLAUDE_ORCA_HOST:-${CLAUDE_ORCA_ROOT:-}/.claude-dev}"
    pkg="$host/srt/node_modules/@anthropic-ai/sandbox-runtime/package.json"
    if [ ! -f "$pkg" ]; then
        echo "srt package.json not found at $pkg (pin is $pin)"
        return 2
    fi
    installed="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$pkg" | head -1 | sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/')"
    if [ "$installed" = "$pin" ]; then
        echo "installed srt version $installed matches pin $pin"
        return 0
    fi
    echo "installed srt version '$installed' does not match pin '$pin'"
    return 1
}

# Structural check (is the hooks dir itself covered by denyWrite) plus a
# best-effort content scan for literal references, under any hook file,
# to an absolute path under $primary/$worktree that ISN'T covered --
# such a reference is a supply-chain escape: hooks run unsandboxed on the
# host, so anything they source/exec that the sandboxed agent can still
# write to is agent-controlled code that runs outside the sandbox on the
# next host-side git operation. Resolves core.hooksPath first (bd wires
# hooks there, not only .git/hooks/ -- see the S3 addendum).
probe_git_hooks_audit() {
    local root="${CLAUDE_ORCA_ROOT:-}"
    if [ -z "$root" ] || [ ! -d "$root" ]; then
        echo "CLAUDE_ORCA_ROOT not set or not a directory -- cannot test"
        return 2
    fi
    if ! command -v git >/dev/null 2>&1; then
        echo "git not available -- not applicable"
        return 2
    fi

    local settings_file="${CLAUDE_ORCA_SETTINGS:-}"
    if [ -z "$settings_file" ] || [ ! -f "$settings_file" ]; then
        echo "CLAUDE_ORCA_SETTINGS not set or file missing -- cannot verify denyWrite coverage"
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "jq not available -- cannot parse $settings_file"
        return 1
    fi
    local deny_write_json
    deny_write_json="$(jq -c '.filesystem.denyWrite // []' "$settings_file" 2>/dev/null)"
    if [ -z "$deny_write_json" ]; then
        echo "could not parse filesystem.denyWrite from $settings_file"
        return 1
    fi

    local primary worktree hooks_path hooks_dir
    primary="$(cd "$root" && pwd -P)"
    worktree="$(pwd -P)"

    hooks_path="$(cd "$primary" && git config core.hooksPath 2>/dev/null)"
    if [ -n "$hooks_path" ]; then
        case "$hooks_path" in
            /*) hooks_dir="$hooks_path" ;;
            *)  hooks_dir="$primary/$hooks_path" ;;
        esac
    else
        hooks_dir="$(cd "$primary" && git rev-parse --git-path hooks 2>/dev/null)"
        case "$hooks_dir" in
            /*|"") ;;
            *) hooks_dir="$primary/$hooks_dir" ;;
        esac
    fi

    if [ -z "$hooks_dir" ] || [ ! -d "$hooks_dir" ]; then
        echo "no git hooks directory found (core.hooksPath unset, .git/hooks absent) -- nothing to audit"
        return 0
    fi
    hooks_dir="$(cd "$hooks_dir" && pwd -P)"

    if ! _selftest_path_covered "$hooks_dir" "$deny_write_json"; then
        echo "git hooks directory $hooks_dir (core.hooksPath) is not covered by the generated denyWrite list"
        return 1
    fi

    local violations="" f base ref
    for f in "$hooks_dir"/*; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        case "$base" in
            *.sample) continue ;;
        esac
        for ref in $(grep -o -E "($primary|$worktree)(/[A-Za-z0-9._/-]*)?" "$f" 2>/dev/null | sort -u); do
            if ! _selftest_path_covered "$ref" "$deny_write_json"; then
                violations="$violations $base:$ref"
            fi
        done
    done

    if [ -n "$violations" ]; then
        echo "hooks dir $hooks_dir is covered, but uncovered path references found:$violations"
        return 1
    fi
    echo "hooks dir $hooks_dir (from ${hooks_path:-.git/hooks}) covered by denyWrite; no uncovered path references found"
    return 0
}

# $1 = path, $2 = denyWrite JSON array. True iff $1 equals or is nested
# under one of the array's entries.
_selftest_path_covered() {
    local p="$1" entry
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        case "$p" in
            "$entry"|"$entry"/*) return 0 ;;
        esac
    done < <(jq -r '.[]' <<<"$2" 2>/dev/null)
    return 1
}

# --- layer 1: the Orca app itself (V3, claude-orca-qt9.3) -------------------
#
# The thirteen probes above are about layer 2 -- the srt sandbox each
# shell re-execs into. The four below are about LAYER 1: the Seatbelt
# profile orca-launch hands sandbox-exec before Orca ever starts. Only a
# terminal that this folder's own Orca opened is inside it, and there is
# no way to fake that from anywhere else -- so each of them reports N/A
# (never PASS) unless $CLAUDE_ORCA_LAYER says so. A probe that cannot
# see what it checks must not claim the check passed.

# The one gate, and the one message that tells a reader how to make these
# four mean something.
orca_layer_na() {
    echo "not inside an Orca terminal (CLAUDE_ORCA_LAYER=orca) -- run the self-test from a terminal this folder's Orca opened"
}

# Seconds since the epoch for $1, or nothing (GNU stat, then BSD/macOS).
file_mtime() {
    stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || true
}

probe_orca_profile_active() {
    local real_home="${CLAUDE_ORCA_REAL_HOME:-}" f
    [ "${CLAUDE_ORCA_LAYER:-}" = "orca" ] || { orca_layer_na; return 2; }
    if [ -z "$real_home" ] || [ ! -d "$real_home" ]; then
        echo "CLAUDE_ORCA_REAL_HOME not set or not a directory -- cannot test"
        return 2
    fi
    # Deliberately the same write as write-outside-denied, minus srt: in
    # an Orca terminal that has not re-execed yet, only layer 1 can be
    # what denies it.
    f="$real_home/.claude-orca-selftest-layer1-$$"
    if ( : > "$f" ) 2>/dev/null; then
        rm -f "$f" 2>/dev/null
        echo "layer 1 is NOT confining this app: $f was created without srt in the way"
        return 1
    fi
    echo "layer 1 active: a write under \$CLAUDE_ORCA_REAL_HOME ($real_home) is denied before srt"
    return 0
}

probe_home_redirected() {
    local root="${CLAUDE_ORCA_ROOT:-}" expect cur
    [ "${CLAUDE_ORCA_LAYER:-}" = "orca" ] || { orca_layer_na; return 2; }
    if [ -z "$root" ]; then
        echo "CLAUDE_ORCA_ROOT not set -- cannot tell which folder this should be"
        return 2
    fi
    expect="$root/.claude-dev/home"
    if [ ! -d "$expect" ]; then
        echo "$expect does not exist -- HOME cannot be pointing inside the folder"
        return 1
    fi
    expect="$(cd "$expect" && pwd -P)"
    cur="$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)" || cur=""
    case "$cur" in
        "$expect"|"$expect"/*)
            echo "HOME=$cur is inside the folder ($expect)"
            return 0
            ;;
    esac
    echo "HOME=${cur:-${HOME:-<unset>}} is outside $expect -- the app is writing someone else's home"
    return 1
}

probe_orca_data_in_folder() {
    local root="${CLAUDE_ORCA_ROOT:-}" real_home="${CLAUDE_ORCA_REAL_HOME:-}"
    local folder_data real_data profile launched touched
    [ "${CLAUDE_ORCA_LAYER:-}" = "orca" ] || { orca_layer_na; return 2; }
    if [ -z "$root" ]; then
        echo "CLAUDE_ORCA_ROOT not set -- cannot tell which folder this should be"
        return 2
    fi
    folder_data="${ORCA_USER_DATA_PATH:-$root/.claude-dev/home/Library/Application Support/orca}"
    if [ ! -d "$folder_data" ]; then
        echo "$folder_data does not exist -- Orca is not running in this folder yet"
        return 2
    fi
    real_data="$real_home/Library/Application Support/orca"
    if [ -z "$real_home" ] || [ ! -d "$real_data" ]; then
        echo "Orca's data is in the folder ($folder_data); the real home has none"
        return 0
    fi
    # "Since launch" is measured against the profile, which orca-launch
    # regenerates immediately before exec'ing sandbox-exec.
    profile="$root/.claude-dev/state/orca.sb"
    launched="$(file_mtime "$profile")"
    touched="$(file_mtime "$real_data")"
    if [ -n "$launched" ] && [ -n "$touched" ] && [ "$touched" -gt "$launched" ]; then
        echo "the real home's Orca data ($real_data) was written since this launch"
        return 1
    fi
    echo "Orca's data is in the folder ($folder_data); $real_data untouched since launch"
    return 0
}

probe_host_files_write_denied() {
    local root="${CLAUDE_ORCA_ROOT:-}" p tested=0 escaped=""
    [ "${CLAUDE_ORCA_LAYER:-}" = "orca" ] || { orca_layer_na; return 2; }
    if [ -z "$root" ]; then
        echo "CLAUDE_ORCA_ROOT not set -- cannot tell which folder this should be"
        return 2
    fi
    # The three the host executes on the next launch: the stub, the
    # bundle Finder starts, and the profile that confines what it starts.
    for p in "$root/claude-dev" \
             "$root/Orca.app/Contents/MacOS/Orca" \
             "$root/.claude-dev/state/orca.sb"; do
        [ -e "$p" ] || continue
        tested=$((tested + 1))
        if touch "$p" 2>/dev/null; then
            escaped="$escaped $p"
        fi
    done
    if [ "$tested" -eq 0 ]; then
        echo "none of the host-owned files exist in $root yet -- nothing to test"
        return 2
    fi
    if [ -n "$escaped" ]; then
        echo "host-owned files are WRITABLE from in here:$escaped"
        return 1
    fi
    echo "touch denied on all $tested host-owned files (./claude-dev, the Orca.app binary, state/orca.sb)"
    return 0
}

# --- dispatch ---------------------------------------------------------------

probe_run() {
    case "$1" in
        write-outside-denied)    probe_write_outside_denied ;;
        read-real-home-denied)   probe_read_real_home_denied ;;
        keychain-denied)         probe_keychain_denied ;;
        project-writable)        probe_project_writable ;;
        worktree-writable)       probe_worktree_writable ;;
        sibling-worktree-denied) probe_sibling_worktree_denied ;;
        tmp-outside-denied)      probe_tmp_outside_denied ;;
        network-blocked-domain)  probe_network_blocked_domain ;;
        network-allowed-domain)  probe_network_allowed_domain ;;
        orca-socket-unreachable) probe_orca_socket_unreachable ;;
        sandbox-exec-present)    probe_sandbox_exec_present ;;
        srt-version-pinned)      probe_srt_version_pinned ;;
        git-hooks-audit)         probe_git_hooks_audit ;;
        orca-profile-active)     probe_orca_profile_active ;;
        home-redirected)         probe_home_redirected ;;
        orca-data-in-folder)     probe_orca_data_in_folder ;;
        host-files-write-denied) probe_host_files_write_denied ;;
        *) echo "unknown probe: $1"; return 1 ;;
    esac
}

# $1 = probe name. Echoes the fake status (0/1/2) and returns 0 if the
# fake file has an entry for it; returns 1 (nothing echoed) otherwise --
# including when there is no fake file at all -- so the caller falls back
# to a real probe_run.
fake_lookup() {
    local fake_file="$1" name="$2" line
    [ -n "$fake_file" ] && [ -f "$fake_file" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            "$name="*)
                printf '%s\n' "${line#*=}"
                return 0
                ;;
        esac
    done < "$fake_file"
    return 1
}

# --- main --------------------------------------------------------------

JSON_OUT=""
DRY_RUN=0
FAKE_FILE="${CLAUDE_ORCA_SELFTEST_FAKE:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --json-out) JSON_OUT="${2:-}"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --fake)     FAKE_FILE="${2:-}"; shift 2 ;;
        --help|-h)  usage; exit 0 ;;
        *) echo "selftest.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ "$DRY_RUN" -eq 1 ]; then
    printf '%-28s %s\n' "NAME" "DESCRIPTION"
    for name in $PROBE_NAMES; do
        printf '%-28s %s\n' "$name" "$(probe_description "$name")"
    done
    exit 0
fi

if [ -z "$JSON_OUT" ]; then
    echo "selftest.sh: --json-out is required" >&2
    exit 2
fi

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
srt_pin="$(read_srt_pin || true)"
platform="$(uname -s)"
root="${CLAUDE_ORCA_ROOT:-}"
worktree="$(pwd -P 2>/dev/null || pwd)"

pass_count=0
fail_count=0
na_count=0
probe_entries=""

for name in $PROBE_NAMES; do
    if [ -n "${CLAUDE_ORCA_SELFTEST_TRACE:-}" ]; then
        printf '%s\n' "$name" >> "$CLAUDE_ORCA_SELFTEST_TRACE"
    fi

    fake_status=""
    if fake_status="$(fake_lookup "$FAKE_FILE" "$name")"; then
        case "$fake_status" in
            0) status=0; detail="faked: PASS" ;;
            1) status=1; detail="faked: FAIL" ;;
            2) status=2; detail="faked: N/A" ;;
            *) status=1; detail="faked: invalid code '$fake_status', treated as FAIL" ;;
        esac
    else
        detail="$(probe_run "$name")"
        status=$?
    fi

    case "$status" in
        0) label="PASS"; pass_count=$((pass_count + 1)) ;;
        2) label="N/A";  na_count=$((na_count + 1)) ;;
        *) label="FAIL"; fail_count=$((fail_count + 1)) ;;
    esac

    entry="$(jq -n --arg n "$name" --arg s "$label" --arg d "$detail" '{name:$n, status:$s, detail:$d}')"
    probe_entries="$probe_entries$entry
"
    printf '  [%-4s] %s -- %s\n' "$label" "$name" "$detail"
done

probes_json="$(printf '%s' "$probe_entries" | jq -s -c .)"

jq -n \
    --arg ts "$timestamp" \
    --arg srt "$srt_pin" \
    --arg platform "$platform" \
    --arg root "$root" \
    --arg worktree "$worktree" \
    --argjson probes "$probes_json" \
    --argjson pass "$pass_count" \
    --argjson fail "$fail_count" \
    --argjson na "$na_count" \
    '{
        timestamp: $ts,
        srt_version: $srt,
        platform: $platform,
        root: $root,
        worktree: $worktree,
        probes: $probes,
        summary: {pass: $pass, fail: $fail, na: $na}
    }' > "$JSON_OUT"

printf 'Summary: %d PASS, %d FAIL, %d N/A\n' "$pass_count" "$fail_count" "$na_count"

if [ "$fail_count" -gt 0 ]; then
    exit 1
fi
exit 0
