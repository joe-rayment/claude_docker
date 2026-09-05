#!/usr/bin/env bats
#
# V2b acceptance contract (claude-orca-qt9.6) -- FROZEN from RED-AT
# onward. The services block of the Orca-layer Seatbelt profile: the Mac
# Keychain is unreachable from the whole folder by default, and the
# services the app cannot live without (TLS, the clipboard, the window
# server, preferences, fonts, LaunchServices) are never denied.
#
# Linux cannot exercise Seatbelt, so these cases assert the generated
# text -- which is also the only artifact the Mac probes (V3) will read.

load helpers/setup

GEN_PROFILE() {
    "$REPO_ROOT/scripts/sandbox/gen-orca-profile.sh" "$@"
}

# Minimal fixture: a project dir and the sandbox.json the generator
# reads. $1 is the JSON value of .orca (or "" for a file without one).
make_keychain_project() {
    local orca_json="${1:-}"
    mkdir -p "$PROJECT_DIR/.claude-dev/app/Orca.app"
    if [ -n "$orca_json" ]; then
        jq -nc --argjson o "$orca_json" \
            '{version: 1, network: {extraAllowedDomains: []}, filesystem: {extraAllowWrite: []}, orca: $o}' \
            > "$PROJECT_DIR/.claude-dev/sandbox.json"
    else
        printf '%s\n' '{"version":1,"network":{"extraAllowedDomains":[]},"filesystem":{"extraAllowWrite":[]}}' \
            > "$PROJECT_DIR/.claude-dev/sandbox.json"
    fi
}

@test "by default the Keychain services are denied in a marked services block after the filesystem rules" {
    make_keychain_project '{"cli":false}'
    p="$(abspath "$PROJECT_DIR")"
    rh="$(make_real_home)"

    run GEN_PROFILE --project "$p" --real-home "$rh"
    [ "$status" -eq 0 ]
    prof="$BATS_TEST_TMPDIR/orca.sb"
    printf '%s\n' "$output" > "$prof"

    marker="$(grep -nF ';; -- services --' "$prof" | head -1 | cut -d: -f1)"
    [ -n "$marker" ]

    # Appended after the filesystem rules: every file rule is above it.
    last_file_rule="$(grep -nE '^\((allow|deny) file-' "$prof" | tail -1 | cut -d: -f1)"
    [ -n "$last_file_rule" ]
    [ "$marker" -gt "$last_file_rule" ]

    # securityd's classic Mach service and its XPC endpoint, both named
    # by srt's own generator, plus CryptoTokenKit.
    for svc in com.apple.SecurityServer com.apple.securityd.xpc com.apple.ctkd; do
        ln="$(grep -nF "(deny mach-lookup (global-name \"$svc\"))" "$prof" | head -1 | cut -d: -f1)"
        [ -n "$ln" ]
        [ "$ln" -gt "$marker" ]
    done

    # An explicit deny only bites after (allow default), which stays.
    [ -n "$(grep -nF '(allow default)' "$prof" | head -1 | cut -d: -f1)" ]
}

@test "orca.keychain true removes the services block; a non-boolean fails closed" {
    p="$(abspath "$PROJECT_DIR")"
    rh="$(make_real_home)"

    make_keychain_project '{"keychain":true}'
    run GEN_PROFILE --project "$p" --real-home "$rh"
    [ "$status" -eq 0 ]
    ! grep -qF ';; -- services --' <<<"$output"
    ! grep -qF 'deny mach-lookup' <<<"$output"
    # ... and the filesystem confinement is untouched by the opt-in.
    grep -qF "(allow file-write* (subpath \"$p\"))" <<<"$output"

    # Explicit false is the same as absent: denied.
    make_keychain_project '{"keychain":false}'
    run GEN_PROFILE --project "$p" --real-home "$rh"
    [ "$status" -eq 0 ]
    grep -qF ';; -- services --' <<<"$output"
    grep -qF '(deny mach-lookup (global-name "com.apple.SecurityServer"))' <<<"$output"

    # Anything that is not a boolean fails closed: no profile at all.
    for bad in '{"keychain":"true"}' '{"keychain":1}' '{"keychain":null}' '{"keychain":[]}'; do
        make_keychain_project "$bad"
        run GEN_PROFILE --project "$p" --real-home "$rh"
        [ "$status" -eq 2 ]
        ! grep -q '(version 1)' <<<"$output"
    done
}

@test "the profile never denies TLS, the clipboard, or the window, preferences, font and LaunchServices interfaces" {
    make_keychain_project '{"cli":false}'
    p="$(abspath "$PROJECT_DIR")"
    rh="$(make_real_home)"

    run GEN_PROFILE --project "$p" --real-home "$rh"
    [ "$status" -eq 0 ]

    denies="$(grep -F 'deny mach-lookup' <<<"$output" || true)"
    [ -n "$denies" ]
    for keep in com.apple.trustd com.apple.pasteboard WindowServer CoreDisplay \
                com.apple.fonts com.apple.FontObjectsServer cfprefsd \
                com.apple.coreservices.launchservicesd; do
        ! grep -qF "$keep" <<<"$denies"
    done
}
