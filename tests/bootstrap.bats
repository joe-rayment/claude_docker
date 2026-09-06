#!/usr/bin/env bats
#
# S1 acceptance contract (claude-orca-3sk.1), rebased onto the v2
# per-folder layout by V1 (claude-orca-qt9.1) and re-pointed at the v3
# container install by claude-orca-qa2.2: bootstrap.sh no longer runs brew
# bundle, installs sandbox-runtime or Claude Code, mounts an Orca DMG or
# writes a shell-rc hook, and registration seeds claude-orca.json rather
# than sandbox.json -- so every assertion that named one of those now
# names its v3 replacement. Exercises bootstrap.sh + scripts/launcher.sh
# against a local git fixture (built from the working tree by
# helpers/setup.bash) with container/open/sw_vers/uname/gh stubbed on
# PATH -- no Mac and no network required. The layout itself is pinned by
# tests/layout.bats.

load helpers/setup

# Every case runs as if on an Apple-silicon Mac; the stub answers only
# what a test pins, so this is the one line that makes the preflight pass.
mac_env() {
    export STUB_UNAME_S=Darwin
    export STUB_UNAME_M=arm64
}

@test "bootstrap refuses without gh auth" {
    mac_env
    export STUB_GH_UNAUTH=1
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"gh"* ]]
    [ ! -d "$ORCA_HOST" ]
}

# v3 (claude-orca-qa2.2): Apple's `container` is macOS 26 + Apple silicon
# only, and there is no fallback runtime -- so an unsupported Mac is
# refused in the preflight, before the first mkdir.
@test "preflight refuses an unsupported Mac before cloning anything" {
    mac_env

    export STUB_UNAME_M=x86_64
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Apple silicon"* ]]
    [ ! -e "$ORCA_HOST" ]
    export STUB_UNAME_M=arm64

    export CLAUDE_ORCA_TEST_MACOS=15.7
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"macOS 26"* ]]
    [[ "$output" == *"15.7"* ]]
    [ ! -e "$ORCA_HOST" ]
}

# The one dependency a bootstrap cannot install for you: the .pkg needs an
# admin password, so it is instructed and the run stops there.
@test "preflight refuses a missing container CLI before cloning anything" {
    mac_env
    mv "$STUB_BIN/container" "$BATS_TEST_TMPDIR/container-stub"

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"github.com/apple/container/releases"* ]]
    [[ "$output" == *"installer"* ]]
    [[ "$output" == *"re-run this same command"* ]]

    [ ! -e "$ORCA_HOST/template" ]
    [ ! -d "$ORCA_HOST" ]
}

# Past the preflight, a step that dies mid-install says which one, so the
# fix-and-re-run loop has somewhere to start.
@test "a failing step is named by the error trap" {
    mac_env
    export CLAUDE_ORCA_TEMPLATE_URL="$BATS_TEST_TMPDIR/no-such-template.git"

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Bootstrap failed during: Installing the claude_orca template"* ]]
    [[ "$output" == *"idempotent and picks up where it left off"* ]]
}

# v3 installs nothing on the Mac, so gh is instructed rather than brewed in
# ($ORIGINAL_PATH is shadowed into a directory of symlinks minus gh,
# because this container ships a real /usr/bin/gh that removing the stub
# would otherwise expose).
@test "missing gh is instructed, never installed" {
    mac_env
    rm -f "$STUB_BIN/gh"

    local shadow="$BATS_TEST_TMPDIR/shadow" d oifs
    mkdir -p "$shadow"
    oifs="$IFS"; IFS=:
    for d in $ORIGINAL_PATH; do
        IFS="$oifs"
        [ -d "$d" ] || continue
        ln -s "$d"/* "$shadow/" 2>/dev/null || true
        IFS=:
    done
    IFS="$oifs"
    rm -f "$shadow/gh"
    export PATH="$STUB_BIN:$shadow"
    ! command -v gh >/dev/null 2>&1

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"gh is required"* ]]
    ! grep -q "^brew " "$STUB_LOG"
    [ ! -d "$ORCA_HOST" ]
}

@test "bootstrap installs the template clone and bin under <project>/.claude-dev, and nothing else" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    [ -L "$ORCA_HOST/bin/claude-dev" ]
    [ "$(readlink "$ORCA_HOST/bin/claude-dev")" = "../template/scripts/launcher.sh" ]
    [ -x "$ORCA_HOST/bin/claude-dev" ]

    [ -d "$ORCA_HOST/template/.git" ]
    [ -f "$ORCA_HOST/template/bootstrap.sh" ]
    [ -f "$ORCA_HOST/template/IMAGE_TAG" ]

    # The v2 installs are gone: no sandbox-runtime, no in-folder Claude
    # Code, no Orca.app from a DMG -- all three live in the image now.
    [ ! -e "$ORCA_HOST/srt" ]
    [ ! -e "$ORCA_HOST/claude" ]
    [ ! -e "$ORCA_HOST/app" ]
    [ ! -e "$PROJECT_DIR/Orca.app" ]
    ! grep -q "sandbox-runtime" "$STUB_LOG"
}

@test "the container service is started and brew is never called" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    grep -qx "system start" "$CONTAINER_STUB_LOG"
    ! grep -q "^brew " "$STUB_LOG"
    ! grep -q "hdiutil" "$STUB_LOG"
}

@test "registration creates .claude-dev/{home,run,state} and claude-orca.json defaults" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    [ -d "$PROJECT_DIR/.claude-dev/home" ]
    [ -d "$PROJECT_DIR/.claude-dev/run" ]
    [ -d "$PROJECT_DIR/.claude-dev/state" ]
    [ -f "$PROJECT_DIR/.claude-dev/claude-orca.json" ]
    [ ! -e "$PROJECT_DIR/.claude-dev/sandbox.json" ]

    run jq -e '.version == 3
        and (.port | type) == "number"
        and .cpus == null
        and .memory == null
        and .extraMounts == []' "$PROJECT_DIR/.claude-dev/claude-orca.json"
    [ "$status" -eq 0 ]
}

# The port is chosen once and reused forever: the same number has to be
# free on both sides, because the pairing code the browser is handed
# advertises ws://127.0.0.1:<port>.
@test "register chooses a port once and records it in run/port and claude-orca.json" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    port="$(jq -r '.port' "$PROJECT_DIR/.claude-dev/claude-orca.json")"
    [[ "$port" =~ ^[0-9]+$ ]]
    [ "$port" -ge 6768 ]
    [ "$(cat "$PROJECT_DIR/.claude-dev/run/port")" = "$port" ]

    run bash -c "cd '$PROJECT_DIR' && '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.port' "$PROJECT_DIR/.claude-dev/claude-orca.json")" = "$port" ]
}

@test "register never overwrites an existing claude-orca.json" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    config="$PROJECT_DIR/.claude-dev/claude-orca.json"
    printf '%s\n' '{"version":3,"port":6999,"cpus":4,"memory":"8g","extraMounts":["/opt/data"]}' > "$config"

    run bash -c "cd '$PROJECT_DIR' && '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 0 ]

    run jq -e '.port == 6999 and .cpus == 4 and .memory == "8g"
        and .extraMounts == ["/opt/data"]' "$config"
    [ "$status" -eq 0 ]
}

# "Run one command, start working" ends with a browser open on Orca, so
# the last thing the install prints is the URL and the two commands that
# get the user back to it.
@test "registration ends with the URL, the reopen command and the shell command" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    url="$(cat "$PROJECT_DIR/.claude-dev/run/orca-web-url.txt")"
    [[ "$output" == *"$url"* ]]
    [[ "$output" == *"./claude-dev"* ]]
    [[ "$output" == *"./claude-dev shell"* ]]
    [ "$(tail -1 "$OPEN_STUB_LOG")" = "$url" ]
}

@test "gitignore seeded idempotently with .claude-dev/, /claude-dev, Orca.app/, .mcp.json, attachments/, .claude/logs/" {
    echo "node_modules/" > "$PROJECT_DIR/.gitignore"

    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    grep -qxF "node_modules/" "$PROJECT_DIR/.gitignore"
    grep -qxF ".claude-dev/" "$PROJECT_DIR/.gitignore"
    grep -qxF "/claude-dev" "$PROJECT_DIR/.gitignore"
    grep -qxF "Orca.app/" "$PROJECT_DIR/.gitignore"
    grep -qxF ".mcp.json" "$PROJECT_DIR/.gitignore"
    grep -qxF "attachments/" "$PROJECT_DIR/.gitignore"
    grep -qxF ".claude/logs/" "$PROJECT_DIR/.gitignore"
    [ "$(grep -c '# claude_orca' "$PROJECT_DIR/.gitignore")" -eq 1 ]

    local before after
    before="$(wc -l < "$PROJECT_DIR/.gitignore")"

    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    after="$(wc -l < "$PROJECT_DIR/.gitignore")"
    [ "$before" -eq "$after" ]
    [ "$(grep -c '# claude_orca' "$PROJECT_DIR/.gitignore")" -eq 1 ]
    [ "$(grep -cxF '.claude-dev/' "$PROJECT_DIR/.gitignore")" -eq 1 ]
}

# V1 (claude-orca-qt9.1) inverts S1's rule: the project root DOES get one
# executable, the ./claude-dev stub that execs the in-folder launcher. It
# is still the ONLY one outside .claude-dev/ -- and in v3 there is no
# generated Orca.app beside it any more.
@test "the only executable outside .claude-dev is the ./claude-dev stub" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    [ -x "$PROJECT_DIR/claude-dev" ]
    [ -x "$ORCA_HOST/bin/claude-dev" ]

    # git's own sample hooks are executable and are not ours.
    run find "$PROJECT_DIR" -type f -perm -u+x \
        -not -path "$PROJECT_DIR/.claude-dev/*" \
        -not -path "$PROJECT_DIR/.git/*"
    [ "$status" -eq 0 ]
    [ "$output" = "$PROJECT_DIR/claude-dev" ]
}

# v3 (claude-orca-qa2.2): the Claude config dir is synced INSIDE the VM by
# scripts/container/entrypoint.sh, into the same folder-local home the Mac
# mounts -- so registration seeds the git identity and leaves .claude to
# the container.
@test "register seeds the home gitconfig and leaves .claude to the entrypoint" {
    git config --global user.name "Test User"
    git config --global user.email "test@example.com"

    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    gc="$PROJECT_DIR/.claude-dev/home/.gitconfig"
    [ -f "$gc" ]
    grep -q "Test User" "$gc"
    grep -q "test@example.com" "$gc"

    [ ! -e "$PROJECT_DIR/.claude-dev/home/.claude/settings.json" ]
}

@test "second run is a no-op" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    local project_sum1 project_sum2
    project_sum1="$(tree_checksum "$PROJECT_DIR")"

    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    project_sum2="$(tree_checksum "$PROJECT_DIR")"

    # One checksum covers both sides: the host install lives inside the
    # project folder.
    [ "$project_sum1" = "$project_sum2" ]
}

@test "bootstrap succeeds with brew, npm and hdiutil absent from PATH" {
    rm -f "$STUB_BIN/brew" "$STUB_BIN/npm" "$STUB_BIN/hdiutil"

    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    [ -d "$ORCA_HOST/template/.git" ]
    [ -s "$PROJECT_DIR/.claude-dev/run/orca-web-url.txt" ]
}

# v3 (claude-orca-qa2.2): the sandbox self-test and the shell-rc hook both
# belonged to Seatbelt. The VM boundary replaces them, so registration
# must run neither -- nothing on the Mac confines anything any more.
@test "registration runs no sandbox self-test and installs no shell hook" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    [[ "$output" != *"self-test"* ]]
    [[ "$output" != *"Refusing to hand off"* ]]
    [ ! -e "$PROJECT_DIR/.claude-dev/run/selftest.json" ]
    [ ! -e "$PROJECT_DIR/.claude-dev/state/orca.sb" ]
    [ ! -e "$HOME/.zprofile" ]
    [ ! -e "$HOME/.zshrc" ]
    [ ! -e "$HOME/.bash_profile" ]
}
