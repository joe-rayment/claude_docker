#!/usr/bin/env bats
#
# S1 acceptance contract (claude-orca-3sk.1) -- FROZEN from RED-AT onward.
# Exercises bootstrap.sh + scripts/launcher.sh against a local git fixture
# (built from the working tree by helpers/setup.bash) with brew/npm/gh/node
# stubbed on PATH -- no Docker, no network, no real macOS tooling required.

load helpers/setup

@test "bootstrap refuses without gh auth" {
    export STUB_GH_UNAUTH=1
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"gh"* ]]
    [ ! -d "$CLAUDE_ORCA_HOME" ]
}

@test "bootstrap installs host side under ~/.claude-orca (bin, template clone, srt pinned to 0.0.75 via stubbed npm)" {
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    [ -L "$CLAUDE_ORCA_HOME/bin/claude-dev" ]
    [ "$(readlink "$CLAUDE_ORCA_HOME/bin/claude-dev")" = "$CLAUDE_ORCA_HOME/template/scripts/launcher.sh" ]

    [ -d "$CLAUDE_ORCA_HOME/template/.git" ]
    [ -f "$CLAUDE_ORCA_HOME/template/bootstrap.sh" ]

    run cat "$CLAUDE_ORCA_HOME/srt/node_modules/@anthropic-ai/sandbox-runtime/package.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"version":"0.0.75"'* ]]

    grep -q -- "--prefix $CLAUDE_ORCA_HOME/srt install" "$STUB_LOG"
    grep -q "sandbox-runtime@0.0.75" "$STUB_LOG"
}

@test "brew bundle invoked with the Brewfile via stubbed brew" {
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    grep -qF "brew bundle --file $CLAUDE_ORCA_HOME/template/Brewfile" "$STUB_LOG"
}

@test "registration creates .claude-dev/{home,tmp,state} and sandbox.json defaults" {
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    [ -d "$PROJECT_DIR/.claude-dev/home" ]
    [ -d "$PROJECT_DIR/.claude-dev/tmp" ]
    [ -d "$PROJECT_DIR/.claude-dev/state" ]
    [ -f "$PROJECT_DIR/.claude-dev/sandbox.json" ]

    run jq -e '.version == 1
        and .network.extraAllowedDomains == []
        and .filesystem.extraAllowWrite == []
        and .orca.cli == false' "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]
}

@test "gitignore seeded idempotently with .claude-dev/, .mcp.json, attachments/, .claude/logs/" {
    echo "node_modules/" > "$PROJECT_DIR/.gitignore"

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    grep -qxF "node_modules/" "$PROJECT_DIR/.gitignore"
    grep -qxF ".claude-dev/" "$PROJECT_DIR/.gitignore"
    grep -qxF ".mcp.json" "$PROJECT_DIR/.gitignore"
    grep -qxF "attachments/" "$PROJECT_DIR/.gitignore"
    grep -qxF ".claude/logs/" "$PROJECT_DIR/.gitignore"
    [ "$(grep -c '# claude_orca' "$PROJECT_DIR/.gitignore")" -eq 1 ]

    local before after
    before="$(wc -l < "$PROJECT_DIR/.gitignore")"

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    after="$(wc -l < "$PROJECT_DIR/.gitignore")"
    [ "$before" -eq "$after" ]
    [ "$(grep -c '# claude_orca' "$PROJECT_DIR/.gitignore")" -eq 1 ]
    [ "$(grep -cxF '.claude-dev/' "$PROJECT_DIR/.gitignore")" -eq 1 ]
}

@test "no ./claude-dev file is written into the project" {
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    [ ! -e "$PROJECT_DIR/claude-dev" ]
    [ -x "$CLAUDE_ORCA_HOME/bin/claude-dev" ]

    # No executable lands anywhere in the project EXCEPT inside .claude-dev/
    # itself, where config-sync (S7, claude-orca-3sk.7) intentionally makes
    # the synced statusline.sh executable as part of the config dir, and
    # Orca.app/Contents/MacOS/Orca, the generated launcher bundle's entry
    # point (V2, claude-orca-qt9.2). Both are host-owned: write-denied
    # inside both sandboxes (scripts/sandbox/host-owned-paths.sh).
    run find "$PROJECT_DIR" -type f -perm -u+x \
        -not -path "$PROJECT_DIR/.claude-dev/*" \
        -not -path "$PROJECT_DIR/Orca.app/*"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "register populates .claude-dev/home/.claude from the template config" {
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    dest="$PROJECT_DIR/.claude-dev/home/.claude"
    [ -f "$dest/settings.json" ]
    run jq -e . "$dest/settings.json"
    [ "$status" -eq 0 ]
    [ -f "$dest/CLAUDE.md" ]
    [ -x "$dest/statusline.sh" ]
    [ -f "$PROJECT_DIR/.claude-dev/state/config-hash" ]

    # __HOST__ is always rewritten to a real, absolute host path -- never
    # left as a literal placeholder for Claude Code to choke on.
    run cat "$dest/settings.json"
    [[ "$output" != *"__HOST__"* ]]
}

@test "second run is a no-op" {
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    local host_sum1 project_sum1 host_sum2 project_sum2
    host_sum1="$(tree_checksum "$CLAUDE_ORCA_HOME")"
    project_sum1="$(tree_checksum "$PROJECT_DIR")"

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    host_sum2="$(tree_checksum "$CLAUDE_ORCA_HOME")"
    project_sum2="$(tree_checksum "$PROJECT_DIR")"

    [ "$host_sum1" = "$host_sum2" ]
    [ "$project_sum1" = "$project_sum2" ]
}

@test "CLAUDE_ORCA_SKIP_BREW=1 succeeds with brew entirely absent from PATH" {
    rm -f "$STUB_BIN/brew"
    export CLAUDE_ORCA_SKIP_BREW=1
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    ! grep -q '^brew ' "$STUB_LOG"
}

# S3 addition (claude-orca-3sk.15): registration now runs the sandbox
# self-test as its last step and refuses to hand off to Orca on failure
# -- see tests/selftest.bats for the self-test's own contract.
@test "registration exits 2 and omits the Orca hand-off line when the sandbox self-test fails" {
    cat > "$CLAUDE_ORCA_SELFTEST_FAKE" <<'FAKE'
write-outside-denied=1
read-real-home-denied=0
keychain-denied=0
project-writable=0
worktree-writable=0
sibling-worktree-denied=0
tmp-outside-denied=0
network-blocked-domain=0
network-allowed-domain=0
orca-socket-unreachable=0
sandbox-exec-present=0
srt-version-pinned=0
git-hooks-audit=0
FAKE

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Refusing to hand off to Orca"* ]]
    [[ "$output" != *"Next: open this folder in Orca"* ]]
    [[ "$output" == *"write-outside-denied"* ]]

    run jq -e '.summary.fail == 1' "$PROJECT_DIR/.claude-dev/state/selftest.json"
    [ "$status" -eq 0 ]
}
