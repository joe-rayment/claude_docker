#!/usr/bin/env bash
#
# gen-orca-profile.sh -- pure function: (project, real home, sandbox.json)
# -> the Seatbelt (SBPL) profile that confines LAYER 1, the Orca app
# itself, to the project folder (.claude/plans/orca-port.md §9.1). No
# side effects: never writes a file, never mkdirs, never touches the
# network -- orca-launch is what redirects stdout into
# <project>/.claude-dev/state/orca.sb before each launch.
#
# Usage:
#   gen-orca-profile.sh --project <dir> --real-home <dir> \
#       [--app <Orca.app>] [--sandbox-json <file>]
#
# The order below is the only one that works: SBPL is LAST-MATCH-WINS, so
# a rule can only be qualified by a rule beneath it.
#
#   (allow default)                 a GUI app needs the whole mediated-
#                                   service surface (WindowServer,
#                                   cfprefsd, the Keychain that keeps
#                                   Orca logged in). This profile
#                                   confines the FILE SYSTEM; layer 2
#                                   (srt, per shell) narrows the agents'
#                                   network and writes.
#   deny read+write /Users /Volumes every user's files, every disk
#   deny read+write <real home>     only when it sits outside both
#   deny write /                    nothing anywhere is writable ...
#   allow read+write <project>      ... except this folder: the app's
#                                   whole world (HOME and TMPDIR point
#                                   inside it, so Orca's own state -- its
#                                   user data dir, its dot-directory and
#                                   the Claude config dir -- lands here)
#   allow read <app> /private/var/folders /private/tmp /dev
#   allow write /private/var/folders /dev
#   [orca.profileExceptions block, if sandbox.json has one]
#   deny write <host-owned paths>   LAST, so nothing above re-opens one
#
# Exit 0 with the profile on stdout; exit 2 with a one-line reason on
# stderr for any malformed or out-of-scope input -- an invalid exception
# fails the launch closed, never silently dropped or silently widened.

set -euo pipefail

# Resolve through .claude-dev/bin/<name> symlinks to this file's real
# directory, so the shared host-owned list is found however we were
# invoked.
_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
    _link="$(readlink "$_self")"
    case "$_link" in
        /*) _self="$_link" ;;
        *)  _self="$(cd "$(dirname "$_self")" && pwd)/$_link" ;;
    esac
done
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"
# shellcheck source=scripts/sandbox/host-owned-paths.sh
. "$SCRIPT_DIR/host-owned-paths.sh"

die() {
    echo "gen-orca-profile: $1" >&2
    exit 2
}

resolve_dir() {
    if [ ! -d "$2" ]; then
        die "$1 is not a directory: $2"
    fi
    (cd "$2" && pwd -P)
}

# An SBPL string literal. srt escapes paths with JSON.stringify
# (macos-sandbox-utils.ts:1173) and SBPL reads the same double-quoted,
# backslash-escaped form, so jq -Rs is exactly right here.
sbpl_str() {
    printf '%s' "$1" | jq -Rs .
}

# rule <operation> <path>  ->  (<operation> (subpath "<path>"))
rule() {
    printf '(%s (subpath %s))\n' "$1" "$(sbpl_str "$2")"
}

# --- argument parsing -------------------------------------------------

project=""
real_home=""
app=""
sandbox_json=""

while [ $# -gt 0 ]; do
    case "$1" in
        --project)      project="$2"; shift 2 ;;
        --real-home)    real_home="$2"; shift 2 ;;
        --app)          app="$2"; shift 2 ;;
        --sandbox-json) sandbox_json="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$project" ]   || die "--project is required"
[ -n "$real_home" ] || die "--real-home is required"

project="$(resolve_dir --project "$project")"
real_home="$(resolve_dir --real-home "$real_home")"
[ -n "$app" ] || app="$project/.claude-dev/app/Orca.app"
case "$app" in
    /*) ;;
    *) die "--app must be an absolute path: $app" ;;
esac
[ -n "$sandbox_json" ] || sandbox_json="$project/.claude-dev/sandbox.json"

# --- sandbox.json exceptions (untrusted data) --------------------------

# The documented escape hatch for the one thing the Mac probes may find
# (V3): an Electron appData that does not follow $HOME. Two arrays of
# ABSOLUTE paths, nothing else understood, nothing else accepted.
exceptions_read=""
exceptions_write=""

if [ -f "$sandbox_json" ]; then
    jq -e . "$sandbox_json" >/dev/null 2>&1 \
        || die "sandbox.json is not valid JSON: $sandbox_json"
    exc="$(jq -c '.orca.profileExceptions // {}' "$sandbox_json" 2>/dev/null)" \
        || die "sandbox.json: unable to read orca.profileExceptions"
    jq -e 'type == "object"' <<<"$exc" >/dev/null 2>&1 \
        || die "orca.profileExceptions must be an object"
    jq -e '(keys - ["allowRead", "allowWrite"]) | length == 0' <<<"$exc" >/dev/null 2>&1 \
        || die "orca.profileExceptions: only allowRead and allowWrite are understood"
    for key in allowRead allowWrite; do
        jq -e --arg k "$key" \
            '((.[$k] // []) | type == "array") and ((.[$k] // []) | all(.[]; type == "string"))' \
            <<<"$exc" >/dev/null 2>&1 \
            || die "orca.profileExceptions.$key must be an array of strings"
        while IFS= read -r entry; do
            [ -z "$entry" ] && continue
            case "$entry" in
                /*) ;;
                *) die "orca.profileExceptions.$key is not an absolute path: $entry" ;;
            esac
            case "$entry" in
                *"/../"*|*/..) die "orca.profileExceptions.$key contains a traversal: $entry" ;;
            esac
            if [ "$key" = "allowRead" ]; then
                exceptions_read="$exceptions_read$entry
"
            else
                exceptions_write="$exceptions_write$entry
"
            fi
        done < <(jq -r --arg k "$key" '(.[$k] // [])[]' <<<"$exc")
    done
fi

# --- emission ----------------------------------------------------------

echo "(version 1)"
echo "; Generated by gen-orca-profile.sh, regenerated on every launch by"
echo "; .claude-dev/bin/orca-launch. Host-owned: write-denied in both layers."
echo "; Project: $project"
echo ""
echo "; A GUI app needs its mediated services (WindowServer, cfprefsd, the"
echo "; Keychain that keeps Orca signed in): those are not file access, and"
echo "; the app cannot run without them. What this profile confines is the"
echo "; file system."
echo "(allow default)"

echo ""
echo "; 1. Every account, every mounted disk: not this app's business."
rule 'deny file-read*'  /Users
rule 'deny file-read*'  /Volumes
rule 'deny file-write*' /Users
rule 'deny file-write*' /Volumes

case "$real_home" in
    /Users/*|/Volumes/*) ;;
    *)
        echo ""
        echo "; 1b. The real home sits outside those roots on this machine."
        rule 'deny file-read*'  "$real_home"
        rule 'deny file-write*' "$real_home"
        ;;
esac

echo ""
echo "; 2. Nothing anywhere on this machine is writable ..."
rule 'deny file-write*' /

echo ""
echo "; 3. ... except this folder, which is the whole world the app sees."
echo ";    HOME and TMPDIR point inside it, so Orca's own state lands here."
rule 'allow file-read*'  "$project"
rule 'allow file-write*' "$project"

echo ""
echo "; 4. Reads the app needs outside the folder: its own bundle, the"
echo ";    per-user temp/cache tree, the shared temp dir, device nodes."
rule 'allow file-read*' "$app"
rule 'allow file-read*' /private/var/folders
rule 'allow file-read*' /private/tmp
rule 'allow file-read*' /dev

echo ""
echo "; 5. The only two writable places outside the folder."
rule 'allow file-write*' /private/var/folders
rule 'allow file-write*' /dev

if [ -n "$exceptions_read" ] || [ -n "$exceptions_write" ]; then
    echo ""
    echo "; --- BEGIN sandbox.json orca.profileExceptions ---"
    echo "; Opened by hand in .claude-dev/sandbox.json. The documented use is"
    echo "; the appData fallback: if Electron's appData does not follow HOME,"
    echo "; Orca's real user-data dir goes here and nothing else does."
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        rule 'allow file-read*' "$entry"
    done <<<"$exceptions_read"
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        printf '(allow file-read* file-write* (subpath %s))\n' "$(sbpl_str "$entry")"
    done <<<"$exceptions_write"
    echo "; --- END sandbox.json orca.profileExceptions ---"
fi

echo ""
echo "; 6. The host-owned paths inside the folder, denied LAST: SBPL is"
echo ";    last-match-wins, so no rule above can re-open one -- not even an"
echo ";    exception. Same list the agents' srt settings deny; see"
echo ";    host-owned-paths.sh."
while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    rule 'deny file-write*' "$entry"
done < <(host_owned_paths "$project")
