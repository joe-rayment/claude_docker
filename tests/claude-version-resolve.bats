#!/usr/bin/env bats
#
# claude-orca-7a0 acceptance contract -- FROZEN from RED-AT. `claude-dev
# --update` has to install the newest Claude Code, not a hand-set literal;
# resolution happens OUTSIDE the docker build (a RUN layer would cache the
# answer forever) via scripts/resolve-claude-version.sh, which prints
# exactly one version string, never empty, and always exits 0 -- a network
# blip must not fail a build, so it falls back to the pinned floor.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RESOLVER="$REPO_ROOT/scripts/resolve-claude-version.sh"
LAUNCHER="$REPO_ROOT/scripts/launcher.sh"
LINT="$REPO_ROOT/scripts/lint-bash32.sh"

setup() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/bin"
}

teardown() {
    rm -rf "$TMP"
}

# fake_curl <body> <exit> -- stands in for the releases endpoint.
fake_curl() {
    local body="$1" rc="${2:-0}"
    cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
touch "$TMP/curl-was-called"
printf '%s' '$body'
exit $rc
EOF
    chmod +x "$TMP/bin/curl"
}

@test "1: stubbed 200 body with no trailing newline prints exactly that version" {
    fake_curl '2.1.271' 0
    run env PATH="$TMP/bin:$PATH" CLAUDE_ORCA_CLAUDE_RELEASES_BASE="http://dummy.invalid" \
        bash "$RESOLVER"
    [ "$status" -eq 0 ]
    [ "$output" = "2.1.271" ]
}

@test "2: stubbed 200 body with a trailing newline prints exactly that version, no stray whitespace" {
    fake_curl $'2.1.271\n' 0
    run env PATH="$TMP/bin:$PATH" CLAUDE_ORCA_CLAUDE_RELEASES_BASE="http://dummy.invalid" \
        bash "$RESOLVER"
    [ "$status" -eq 0 ]
    [ "$output" = "2.1.271" ]
}

@test "3: stubbed curl exit 22 falls back to the pinned literal, exit 0" {
    fake_curl '' 22
    run env PATH="$TMP/bin:$PATH" CLAUDE_ORCA_CLAUDE_RELEASES_BASE="http://dummy.invalid" \
        bash "$RESOLVER"
    [ "$status" -eq 0 ]
    [ "$output" = "2.1.271" ]
}

@test "4: stubbed HTML error page falls back to the pinned literal, exit 0" {
    fake_curl '<html><body>502 Bad Gateway</body></html>' 0
    run env PATH="$TMP/bin:$PATH" CLAUDE_ORCA_CLAUDE_RELEASES_BASE="http://dummy.invalid" \
        bash "$RESOLVER"
    [ "$status" -eq 0 ]
    [ "$output" = "2.1.271" ]
}

@test "5: CLAUDE_ORCA_CLAUDE_VERSION set skips the network call entirely" {
    fake_curl '9.9.8' 0
    run env PATH="$TMP/bin:$PATH" CLAUDE_ORCA_CLAUDE_RELEASES_BASE="http://dummy.invalid" \
        CLAUDE_ORCA_CLAUDE_VERSION="9.9.9" \
        bash "$RESOLVER"
    [ "$status" -eq 0 ]
    [ "$output" = "9.9.9" ]
    [ ! -f "$TMP/curl-was-called" ]
}

@test "6: resolver output is never empty" {
    fake_curl '' 0
    run env PATH="$TMP/bin:$PATH" CLAUDE_ORCA_CLAUDE_RELEASES_BASE="http://dummy.invalid" \
        bash "$RESOLVER"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "7: lint-bash32.sh is clean on the resolver and launcher.sh" {
    run bash "$LINT" "$RESOLVER" "$LAUNCHER"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "launcher.sh's try_build passes CLAUDE_CODE_VERSION as a build-arg and keeps --tag first" {
    run grep -qE -- '--build-arg "CLAUDE_CODE_VERSION=' "$LAUNCHER"
    [ "$status" -eq 0 ]
    run grep -qE -- 'ctr build --tag "\$ref"' "$LAUNCHER"
    [ "$status" -eq 0 ]
}
