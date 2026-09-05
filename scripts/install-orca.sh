#!/usr/bin/env bash
#
# install-orca.sh -- installs Orca, pinned, into
# <project>/.claude-dev/app/Orca.app from the GitHub release DMG (V1,
# claude-orca-qt9.1; see .claude/plans/orca-port.md S9.1). No cask, no
# /Applications copy: a central Orca is exactly the unsandboxed app this
# design exists to avoid, so the only Orca for this project is the one in
# the folder, which V2's launcher starts under a Seatbelt profile.
#
# Usage: install-orca.sh [<host dir>]        (default: this template's parent)
#        install-orca.sh --print-version     (installed version, or exit 1)
#
# CLAUDE_ORCA_SKIP_ORCA_DMG=1 skips the download+mount entirely (CI and
# Linux hosts, where hdiutil does not exist); claude-dev --doctor then
# reports the row as missing. Idempotent: a folder whose Orca.app already
# reports $ORCA_VERSION is left alone, download and all.

set -euo pipefail

ORCA_VERSION="1.4.197"
ORCA_RELEASE_URL="https://github.com/stablyai/orca/releases/download/v${ORCA_VERSION}"

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

MODE="install"
if [ "${1:-}" = "--print-version" ]; then
    MODE="print-version"
    shift
fi

HOST="${1:-$(host_dir)}"
APP_DIR="$HOST/app"
APP="$APP_DIR/Orca.app"
PLIST="$APP/Contents/Info.plist"

# CFBundleShortVersionString, from a binary plist (PlistBuddy, macOS) or an
# XML one (the awk fallback -- also what the Linux test fixtures produce).
installed_version() {
    [ -f "$PLIST" ] || return 1
    local v=""
    if [ -x /usr/libexec/PlistBuddy ]; then
        v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            "$PLIST" 2>/dev/null || true)"
    fi
    if [ -z "$v" ]; then
        v="$(awk '/<key>CFBundleShortVersionString<\/key>/ {
                      getline
                      sub(/.*<string>/, "")
                      sub(/<\/string>.*/, "")
                      gsub(/[[:space:]]/, "")
                      print
                      exit
                  }' "$PLIST" 2>/dev/null || true)"
    fi
    [ -n "$v" ] || return 1
    printf '%s\n' "$v"
}

if [ "$MODE" = "print-version" ]; then
    installed_version
    exit $?
fi

if [ "${CLAUDE_ORCA_SKIP_ORCA_DMG:-0}" = "1" ]; then
    echo "  skipped: Orca.app (CLAUDE_ORCA_SKIP_ORCA_DMG=1)"
    exit 0
fi

if [ "$(installed_version || true)" = "$ORCA_VERSION" ]; then
    echo "  Orca.app already at $ORCA_VERSION"
    exit 0
fi

case "$(uname -m)" in
    arm64|aarch64) DMG_NAME="orca-macos-arm64.dmg" ;;
    *)             DMG_NAME="orca-macos-x64.dmg" ;;
esac

TMP_DIR="$HOST/tmp"
STATE_DIR="$HOST/state"
mkdir -p "$TMP_DIR" "$STATE_DIR" "$APP_DIR"
DMG="$TMP_DIR/$DMG_NAME"
MOUNT="$TMP_DIR/orca-mount-$$"

cleanup() {
    if [ -d "$MOUNT" ]; then
        hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
        rm -rf "$MOUNT"
    fi
    rm -f "$DMG"
}
trap cleanup EXIT

echo "  downloading $DMG_NAME ($ORCA_VERSION)"
curl -fL --retry 3 -o "$DMG" "$ORCA_RELEASE_URL/$DMG_NAME"

# Recorded, not enforced: there is no published checksum to compare
# against, so this is the audit trail for what this folder actually
# installed (claude-dev --doctor prints the version beside it).
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$DMG" | awk '{print $1}' > "$STATE_DIR/orca.sha256"
else
    shasum -a 256 "$DMG" | awk '{print $1}' > "$STATE_DIR/orca.sha256"
fi

mkdir -p "$MOUNT"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
rm -rf "$APP"
cp -R "$MOUNT/Orca.app" "$APP_DIR/"
hdiutil detach "$MOUNT" >/dev/null
rm -rf "$MOUNT"

echo "  installed Orca.app $(installed_version || echo unknown) into $APP_DIR"
