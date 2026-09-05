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
#   allow file-read-metadata        one (literal) each for /Users, the
#     /Users, <real home>, and      real home and every directory between
#     every ancestor of <project>   the project and the root: opening
#                                   anything in the folder stat()s every
#                                   parent on the way to it, and those
#                                   parents are inside the tree just
#                                   denied. Metadata only, never a
#                                   subpath, so nothing inside them is
#                                   readable.
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
# What LAYER 1 -- this profile: the Orca app, and every terminal it opens
# -- may WRITE (V2d, claude-orca-qt9.9): <project>, /private/var/folders
# (the per-user temp dir), /dev, and nothing else; minus the host-owned
# paths denied last, .claude-dev/state and .claude-dev/sandbox.json among
# them. The wrapper runs HERE, which settles where each launch's srt
# settings file goes: not under .claude-dev/state (write-denied, so the
# launch would fail on the write), and not under .claude-dev/run or
# .claude-dev/tmp (writable here, but writable to layer 2 as well, and
# that file is what defines layer 2) -- a private per-launch directory
# under the per-user temp dir instead. See claude-orca-shell.
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

# The Keychain is unreachable from this folder unless the project asks
# for it: default false, `true` opts back in, anything else is refused
# rather than coerced (a truthy string must never read as "yes").
keychain="false"

if [ -f "$sandbox_json" ]; then
    jq -e . "$sandbox_json" >/dev/null 2>&1 \
        || die "sandbox.json is not valid JSON: $sandbox_json"

    keychain_type="$(jq -r '
        if (type == "object") and ((.orca? | type) == "object") and (.orca | has("keychain"))
        then (.orca.keychain | type)
        else "absent"
        end' "$sandbox_json" 2>/dev/null)" \
        || die "sandbox.json: unable to read orca.keychain"
    case "$keychain_type" in
        absent)  keychain="false" ;;
        boolean) keychain="$(jq -r '.orca.keychain' "$sandbox_json")" ;;
        *) die "orca.keychain must be a boolean, got $keychain_type" ;;
    esac
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
echo "; 1c. Path resolution through what was just denied. Reaching anything"
echo ";     in the folder means stat()ing every directory on the way to it,"
echo ";     and on a Mac that path runs through /Users (and through the real"
echo ";     home, when the folder lives under it): without this the folder"
echo ";     is unreachable by its own absolute path. (literal ...) is the"
echo ";     directory ENTRY only -- never a subpath -- so nothing INSIDE"
echo ";     these directories becomes readable, and file-read-metadata is"
echo ";     not file-read*: names and stat(2), never contents."
meta_paths="/Users
$real_home"
_meta_walk="$(dirname "$project")"
while [ "$_meta_walk" != "/" ] && [ -n "$_meta_walk" ]; do
    meta_paths="$meta_paths
$_meta_walk"
    _meta_walk="$(dirname "$_meta_walk")"
done
printf '(allow file-read-metadata'
_meta_seen=""
while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    case "$_meta_seen" in
        *"|$entry|"*) continue ;;
    esac
    _meta_seen="$_meta_seen|$entry|"
    printf ' (literal %s)' "$(sbpl_str "$entry")"
done <<META
$meta_paths
META
printf ')\n'

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

# --- services, appended after the filesystem rules ----------------------

echo ""
if [ "$keychain" = "true" ]; then
    echo "; Keychain services: reachable, by request (sandbox.json orca.keychain)."
else
    echo ";; -- services --"
    echo "; (allow default) above leaves every Mach service reachable, so this"
    echo "; block is what closes the Keychain to everything in this folder:"
    echo "; securityd's classic Mach service and its XPC endpoint, CryptoTokenKit,"
    echo "; and the authorization prompt. Set orca.keychain to true in"
    echo "; .claude-dev/sandbox.json to opt back in -- that hands the folder the"
    echo "; user's own stored credentials, so it is off by default."
    echo ";"
    echo "; Provenance: com.apple.SecurityServer and com.apple.securityd.xpc are"
    echo "; the two names srt's own generator allows (macos-sandbox-utils.ts:1012"
    echo "; and :888). com.apple.ctkd and com.apple.security.agent appear in"
    echo "; neither srt nor anything runnable here: this container is Linux, so"
    echo "; their effect is UNVERIFIED and the Mac probes (V3) are what confirm"
    echo "; it. Denying a service name that does not exist costs nothing."
    echo ";"
    echo "; Never denied, deliberately, and never named below: com.apple.trustd"
    echo "; and com.apple.trustd.agent (TLS verification -- srt:895),"
    echo "; com.apple.pasteboard.1 (copy and paste has to keep working),"
    echo "; WindowServer and CoreDisplay (there is no window without them),"
    echo "; cfprefsd (preferences), com.apple.fonts and com.apple.FontObjectsServer"
    echo "; (srt:878-879), com.apple.coreservices.launchservicesd (srt:889)."
    echo "; All of them stay reachable through (allow default)."
    for svc in com.apple.SecurityServer com.apple.securityd.xpc \
               com.apple.ctkd com.apple.security.agent; do
        printf '(deny mach-lookup (global-name %s))\n' "$(sbpl_str "$svc")"
    done
    echo ";; -- end services --"
fi
