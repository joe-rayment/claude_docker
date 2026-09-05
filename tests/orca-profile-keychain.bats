#!/usr/bin/env bats
#
# V2b acceptance contract (claude-orca-qt9.8) -- FROZEN from RED-AT
# onward. The services block of the Orca-layer Seatbelt profile: the Mac
# Keychain is unreachable from the whole folder by default, the opt-in
# changes nothing else, an invalid value fails closed, and the doctor
# says which mode the folder is in.
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

set_orca_keychain() {
    local dir="$1" value="$2" tmp="$BATS_TEST_TMPDIR/sandbox.json.tmp"
    jq --argjson v "$value" '.orca.keychain = $v' \
        "$dir/.claude-dev/sandbox.json" > "$tmp"
    mv "$tmp" "$dir/.claude-dev/sandbox.json"
}

# The profile's rules, without comments or blank lines.
rules_only() {
    grep -v '^;' <<<"$1" | grep -v '^[[:space:]]*$'
}

@test "the generated Orca profile denies the Keychain mach services by name in a marked services block and never denies trustd, pasteboard, WindowServer or font services" {
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

    # By name: securityd's classic Mach service and its XPC endpoint (the
    # two srt's own generator allows), CryptoTokenKit, the auth prompt.
    for svc in com.apple.SecurityServer com.apple.securityd.xpc \
               com.apple.ctkd com.apple.security.agent; do
        ln="$(grep -nF "(deny mach-lookup (global-name \"$svc\"))" "$prof" | head -1 | cut -d: -f1)"
        [ -n "$ln" ]
        [ "$ln" -gt "$marker" ]
    done

    # An explicit deny only bites after (allow default), which stays.
    grep -qxF '(allow default)' "$prof"

    # What the app cannot live without is never denied, and never named.
    denies="$(grep -F 'deny mach-lookup' "$prof")"
    [ -n "$denies" ]
    for keep in com.apple.trustd com.apple.pasteboard WindowServer CoreDisplay \
                com.apple.fonts com.apple.FontObjectsServer cfprefsd \
                com.apple.coreservices.launchservicesd; do
        ! grep -qF "$keep" <<<"$denies"
    done
}

@test "orca.keychain true removes the denial block and nothing else changes in the profile" {
    p="$(abspath "$PROJECT_DIR")"
    rh="$(make_real_home)"

    make_keychain_project '{"keychain":false}'
    run GEN_PROFILE --project "$p" --real-home "$rh"
    [ "$status" -eq 0 ]
    denied_rules="$(rules_only "$output")"
    grep -qF ';; -- services --' <<<"$output"

    make_keychain_project '{"keychain":true}'
    run GEN_PROFILE --project "$p" --real-home "$rh"
    [ "$status" -eq 0 ]
    shared_rules="$(rules_only "$output")"

    # The block is gone ...
    ! grep -qF ';; -- services --' <<<"$output"
    ! grep -q 'mach-lookup' <<<"$shared_rules"
    # ... and it is the ONLY thing that changed: strike the mach-lookup
    # denials from the default profile and the two are identical.
    [ "$(grep -v '^(deny mach-lookup' <<<"$denied_rules")" = "$shared_rules" ]
    # Sanity: the filesystem confinement is still in there.
    grep -qF "(allow file-write* (subpath \"$p\"))" <<<"$shared_rules"
}

@test "an invalid orca.keychain value fails closed (exit 2)" {
    p="$(abspath "$PROJECT_DIR")"
    rh="$(make_real_home)"

    for bad in '{"keychain":"true"}' '{"keychain":1}' '{"keychain":null}' \
               '{"keychain":[]}' '{"keychain":{}}'; do
        make_keychain_project "$bad"
        run GEN_PROFILE --project "$p" --real-home "$rh"
        [ "$status" -eq 2 ]
        ! grep -q '(version 1)' <<<"$output"
        ! grep -q 'mach-lookup' <<<"$output"
    done
}

@test "doctor prints the keychain line matching the mode" {
    make_project "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    doctor="$CLAUDE_ORCA_HOME/bin/claude-dev"

    # Default: the folder keeps its own credentials.
    run bash -c "cd '$primary' && '$doctor' --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"keychain: denied (folder-local credentials)"* ]]
    [[ "$output" != *"shared with macOS"* ]]

    # Opted in: say so, in the same row.
    set_orca_keychain "$PROJECT_DIR" true
    run bash -c "cd '$primary' && '$doctor' --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"keychain: shared with macOS (orca.keychain=true)"* ]]
    [[ "$output" != *"folder-local credentials"* ]]

    # It is the CWD project's mode: outside one there is no such row.
    outside="$BATS_TEST_TMPDIR/outside"
    mkdir -p "$outside"
    run bash -c "cd '$outside' && '$doctor' --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" != *"keychain:"* ]]
}
