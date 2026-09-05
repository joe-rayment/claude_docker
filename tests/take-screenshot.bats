#!/usr/bin/env bats
#
# S10 (claude-orca-3sk.21) -- scripts/take-screenshot.sh, the sandbox's only
# remaining "give Claude eyes" tool: Playwright headless chromium against a
# URL. The Docker template's `term` (termshot) and `display` (Xvfb) modes are
# gone -- there is no display server inside Seatbelt -- so they must fail
# loudly with a usage message rather than silently do nothing.
#
# Everything runs against stubs (helpers/setup.bash): a recording `node` that
# writes its argv and environment to disk and fakes the PNG, plus a fake
# playwright package directory. No browser is launched here; whether chromium
# actually starts under a nested seatbelt profile is a Mac-only question the
# script's header documents a fallback for.

load helpers/setup

TAKE_SCREENSHOT() {
    bash "$REPO_ROOT/scripts/take-screenshot.sh" "$@"
}

# A project root + project-local Claude config dir, without paying for a full
# bootstrap: take-screenshot only reads them through scripts/lib/paths.sh.
setup_screenshot_env() {
    export CLAUDE_ORCA_ROOT="$BATS_TEST_TMPDIR/proj"
    export CLAUDE_CONFIG_DIR="$CLAUDE_ORCA_ROOT/.claude-dev/home/.claude"
    mkdir -p "$CLAUDE_CONFIG_DIR"

    export CLAUDE_ORCA_PLAYWRIGHT_HOME="$BATS_TEST_TMPDIR/pw-home"
    mkdir -p "$CLAUDE_ORCA_PLAYWRIGHT_HOME"

    export STUB_ARGV="$BATS_TEST_TMPDIR/node.argv"
    export STUB_NODE_ENV="$BATS_TEST_TMPDIR/node.env"
    write_stub_node_recording "$BATS_TEST_TMPDIR/stubs/node"
}

@test "url mode invokes stubbed playwright with PLAYWRIGHT_BROWSERS_PATH inside .claude-dev/home/.cache and --no-sandbox, writing attachments/<name>.png" {
    setup_screenshot_env
    fake_playwright_package "$CLAUDE_ORCA_PLAYWRIGHT_HOME"

    run TAKE_SCREENSHOT url "http://localhost:3000/dashboard" --name shot
    [ "$status" -eq 0 ]

    expected_png="$CLAUDE_ORCA_ROOT/attachments/shot.png"
    [ -f "$expected_png" ]
    [[ "$output" == *"$expected_png"* ]]

    # chromium launched with the sandbox disabled (Seatbelt already confines
    # the process; chromium's own sandbox cannot nest inside it).
    grep -qx -- "--no-sandbox" "$STUB_ARGV"

    # Browsers live under the project-local config home, never the real ~.
    browsers="$(grep '^PLAYWRIGHT_BROWSERS_PATH=' "$STUB_NODE_ENV" | head -1)"
    browsers="${browsers#PLAYWRIGHT_BROWSERS_PATH=}"
    [ -n "$browsers" ]
    [[ "$browsers" == *"/.claude-dev/home/.cache/"* ]]
    [[ "$browsers" == *"ms-playwright"* ]]

    # The URL and the output path are what node was actually handed.
    grep -qx -- "http://localhost:3000/dashboard" "$STUB_ARGV"
    grep -qxF -- "$expected_png" "$STUB_ARGV"
}

@test "term and display modes exit 2 with a usage message" {
    setup_screenshot_env
    fake_playwright_package "$CLAUDE_ORCA_PLAYWRIGHT_HOME"

    run TAKE_SCREENSHOT term "pytest tests/"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage"* ]]
    [[ "$output" == *"url"* ]]

    run TAKE_SCREENSHOT display
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage"* ]]

    run TAKE_SCREENSHOT
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage"* ]]

    # Neither removed mode may have reached node.
    [ ! -s "$STUB_ARGV" ]
}

@test "missing playwright produces a one-line install hint and exit 3" {
    setup_screenshot_env
    # No fake_playwright_package: nothing resolvable anywhere.

    run TAKE_SCREENSHOT url "http://localhost:3000/"
    [ "$status" -eq 3 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == *"npm i -g playwright@1.61.1"* ]]
    [[ "$output" == *"npx playwright install chromium"* ]]
}
