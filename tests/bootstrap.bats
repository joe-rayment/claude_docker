#!/usr/bin/env bats
#
# S1 acceptance contract (claude-orca-3sk.1), rebased onto the v2
# per-folder layout by V1 (claude-orca-qt9.1): $ORCA_HOST is now
# <project>/.claude-dev, not a central install. Exercises bootstrap.sh +
# scripts/launcher.sh against a local git fixture (built from the working
# tree by helpers/setup.bash) with brew/npm/gh/node/curl/hdiutil stubbed on
# PATH -- no network and no real macOS tooling required. The layout itself
# is pinned by tests/layout.bats.

load helpers/setup

@test "bootstrap refuses without gh auth" {
    export STUB_GH_UNAUTH=1
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"gh"* ]]
    [ ! -d "$ORCA_HOST" ]
}

@test "bootstrap installs everything under <project>/.claude-dev (bin, template clone, srt pinned to 0.0.75 via stubbed npm)" {
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    [ -L "$ORCA_HOST/bin/claude-dev" ]
    [ "$(readlink "$ORCA_HOST/bin/claude-dev")" = "../template/scripts/launcher.sh" ]
    [ -x "$ORCA_HOST/bin/claude-dev" ]

    [ -d "$ORCA_HOST/template/.git" ]
    [ -f "$ORCA_HOST/template/bootstrap.sh" ]

    run cat "$ORCA_HOST/srt/node_modules/@anthropic-ai/sandbox-runtime/package.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"version":"0.0.75"'* ]]

    grep -q -- "--prefix $ORCA_HOST/srt install" "$STUB_LOG"
    grep -q "sandbox-runtime@0.0.75" "$STUB_LOG"
}

@test "brew bundle invoked with the Brewfile via stubbed brew" {
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    grep -qF "brew bundle --file $ORCA_HOST/template/Brewfile" "$STUB_LOG"
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

@test "gitignore seeded idempotently with .claude-dev/, /claude-dev, Orca.app/, .mcp.json, attachments/, .claude/logs/" {
    echo "node_modules/" > "$PROJECT_DIR/.gitignore"

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
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

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    after="$(wc -l < "$PROJECT_DIR/.gitignore")"
    [ "$before" -eq "$after" ]
    [ "$(grep -c '# claude_orca' "$PROJECT_DIR/.gitignore")" -eq 1 ]
    [ "$(grep -cxF '.claude-dev/' "$PROJECT_DIR/.gitignore")" -eq 1 ]
}

# V1 (claude-orca-qt9.1) inverts S1's rule: the v2 project root DOES get
# one executable, the ./claude-dev stub that execs the in-folder launcher
# (trust boundary v2 -- both Seatbelt profiles write-deny it). It is still
# the ONLY one outside .claude-dev/.
@test "the only executable outside .claude-dev is the ./claude-dev stub" {
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    [ -x "$PROJECT_DIR/claude-dev" ]
    [ -x "$ORCA_HOST/bin/claude-dev" ]

    # config-sync (S7, claude-orca-3sk.7) intentionally makes the synced
    # statusline.sh executable inside .claude-dev/, which is excluded here;
    # so is Orca.app/Contents/MacOS/Orca, the generated launcher bundle's
    # entry point (V2, claude-orca-qt9.2). Both are host-owned: write-denied
    # inside both sandboxes (scripts/sandbox/host-owned-paths.sh).
    run find "$PROJECT_DIR" -type f -perm -u+x \
        -not -path "$PROJECT_DIR/.claude-dev/*" \
        -not -path "$PROJECT_DIR/Orca.app/*"
    [ "$status" -eq 0 ]
    [ "$output" = "$PROJECT_DIR/claude-dev" ]
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

    local project_sum1 project_sum2
    project_sum1="$(tree_checksum "$PROJECT_DIR")"

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    project_sum2="$(tree_checksum "$PROJECT_DIR")"

    # One checksum now covers both sides: the host install lives inside
    # the project folder.
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
