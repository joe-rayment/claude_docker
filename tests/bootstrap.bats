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

# V6: bootstrap.sh preflights every precondition BEFORE the first
# mkdir/clone/install, so a fixable problem costs nothing and leaves
# nothing behind. Registration's rc-install (rc_install_one in
# scripts/launcher.sh) is the last thing that runs, and a root-owned or
# read-only rc file used to fail there -- after the clone and every
# install.
#
# Read-only is not the same as unrecoverable: deleting a file needs write
# permission on its directory, never on the file, so a readable one is
# rebuilt in place with no sudo (rc_reclaim, duplicated in bootstrap.sh
# because the template carrying the launcher's copy is not cloned yet).
@test "preflight reclaims an unwritable-but-readable rc file and carries on" {
    if [ "$(id -u)" -eq 0 ]; then
        skip "root can write anything, so -w never reports the problem"
    fi

    printf '%s\n' 'export EDITOR=vi' > "$HOME/.bash_profile"
    chmod 444 "$HOME/.bash_profile"

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Reclaimed"* ]]
    [[ "$output" == *".bash_profile"* ]]

    [ -w "$HOME/.bash_profile" ]
    grep -qxF 'export EDITOR=vi' "$HOME/.bash_profile"
    [ "$(grep -c '# >>> claude_orca >>>' "$HOME/.bash_profile")" -eq 1 ]
    [ -d "$ORCA_HOST/template" ]
}

@test "preflight refuses an unreadable rc file before cloning anything" {
    if [ "$(id -u)" -eq 0 ]; then
        skip "root can read and write anything, so the refusal never fires"
    fi

    : > "$HOME/.bash_profile"
    chmod 000 "$HOME/.bash_profile"

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *".bash_profile"* ]]
    [[ "$output" == *"chown"* ]]
    [[ "$output" == *"re-run this same command"* ]]

    [ ! -e "$ORCA_HOST/template" ]
    [ ! -d "$ORCA_HOST" ]
}

# Past the preflight, a step that dies mid-install says which one, so the
# fix-and-re-run loop has somewhere to start.
@test "a failing step is named by the error trap" {
    cat > "$STUB_BIN/brew" <<'STUB'
#!/usr/bin/env bash
echo "brew $*" >> "$STUB_LOG"
[ "$1" = "bundle" ] && exit 1
exit 0
STUB
    chmod +x "$STUB_BIN/brew"

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Bootstrap failed during: brew bundle"* ]]
    [[ "$output" == *"idempotent and picks up where it left off"* ]]
}

# gh is the one missing dependency bootstrap fixes for you rather than
# printing instructions for. $ORIGINAL_PATH is shadowed into a directory of
# symlinks minus gh, because this container ships a real /usr/bin/gh that
# removing the stub would otherwise expose.
@test "missing gh with brew present auto-installs gh" {
    export STUB_BIN
    export STUB_GH_SRC="$BATS_TEST_TMPDIR/gh-src"
    write_stub_gh "$STUB_GH_SRC"
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

    cat > "$STUB_BIN/brew" <<'STUB'
#!/usr/bin/env bash
echo "brew $*" >> "$STUB_LOG"
if [ "$1" = "install" ] && [ "$2" = "gh" ]; then
    cp "$STUB_GH_SRC" "$STUB_BIN/gh"
    chmod +x "$STUB_BIN/gh"
    exit 0
fi
if [ "$1" = "list" ] && [ "$2" = "--cask" ] && [ "$3" = "orca" ]; then
    [ "${STUB_ORCA_INSTALLED:-}" = "1" ] && exit 0
    exit 1
fi
exit 0
STUB
    chmod +x "$STUB_BIN/brew"

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" != *"gh is required"* ]]
    grep -qF "brew install gh" "$STUB_LOG"
    [ -x "$STUB_BIN/gh" ]
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

    # orca.cli was seeded false through V5; V6 (claude-orca-riu.3) makes it
    # true for new folders -- pinned in its own case below.
    run jq -e '.version == 1
        and .network.extraAllowedDomains == []
        and .filesystem.extraAllowWrite == []
        and .orca.cli == true' "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]
}

# V6 (claude-orca-riu.3): native Orca orchestration is the default for a
# NEWLY registered folder -- the user coordinates multi-provider agents
# through the host Orca app, so the socket allowance is seeded ON rather
# than discovered later. gen-settings.sh still fails closed on a file with
# no orca key (tests/orca-cli-mode.bats): this is the seed, not the parser.
@test "register seeds sandbox.json with orca.cli true by default" {
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    run jq -e '.version == 1
        and .network.extraAllowedDomains == []
        and .filesystem.extraAllowWrite == []
        and .orca.cli == true' "$PROJECT_DIR/.claude-dev/sandbox.json"
    [ "$status" -eq 0 ]

    # With the mode on, the orca-socket probe reports N/A when the app is
    # simply not running (claude-orca-riu.2). That must never brick a first
    # registration: N/A is tallied apart from FAIL, and only FAIL refuses.
    fake="$BATS_TEST_TMPDIR/fake-socket-na.txt"
    sed 's/^orca-socket-unreachable=0$/orca-socket-unreachable=2/' \
        "$CLAUDE_ORCA_SELFTEST_FAKE" > "$fake"
    grep -qx 'orca-socket-unreachable=2' "$fake"
    export CLAUDE_ORCA_SELFTEST_FAKE="$fake"

    run bash -c "cd '$PROJECT_DIR' && '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Refusing to hand off"* ]]

    run jq -e '.summary.fail == 0 and .summary.na >= 1
        and ([.probes[] | select(.name == "orca-socket-unreachable") | .status]
             == ["N/A"])' "$PROJECT_DIR/.claude-dev/run/selftest.json"
    [ "$status" -eq 0 ]
}

# The other half of the same decision: an existing sandbox.json is the
# user's file. Register seeds defaults only when there is no file at all,
# so neither an explicit opt-out nor a hand-written file with no orca key
# is ever rewritten into the new default.
@test "register never overwrites an existing sandbox.json orca.cli choice" {
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    sandbox_json="$PROJECT_DIR/.claude-dev/sandbox.json"

    # No orca key at all: left byte for byte, and gen-settings.sh's
    # fail-closed default (absent == false) still governs it.
    printf '%s\n' '{"version":1,"network":{"extraAllowedDomains":["example.com"]},"filesystem":{"extraAllowWrite":[]}}' > "$sandbox_json"
    before="$(cat "$sandbox_json")"

    run bash -c "cd '$PROJECT_DIR' && '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 0 ]
    [ "$(cat "$sandbox_json")" = "$before" ]
    run jq -e '.orca == null' "$sandbox_json"
    [ "$status" -eq 0 ]

    # An explicit opt-out survives a re-register too.
    printf '%s\n' '{"version":1,"network":{"extraAllowedDomains":[]},"filesystem":{"extraAllowWrite":[]},"orca":{"cli":false}}' > "$sandbox_json"
    before="$(cat "$sandbox_json")"

    run bash -c "cd '$PROJECT_DIR' && '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 0 ]
    [ "$(cat "$sandbox_json")" = "$before" ]
    run jq -e '.orca.cli == false' "$sandbox_json"
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
    [ -f "$PROJECT_DIR/.claude-dev/run/config-hash" ]

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

    run jq -e '.summary.fail == 1' "$PROJECT_DIR/.claude-dev/run/selftest.json"
    [ "$status" -eq 0 ]
}
