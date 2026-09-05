#!/usr/bin/env bats
#
# S12 acceptance contract (claude-orca-3sk.23), rebased onto the v2
# per-folder layout by V1 (claude-orca-qt9.1). Covers the lifecycle
# commands: claude-dev --update, --teardown, --uninstall, and the
# beads-snapshot restore that a later registration performs. In v2 the
# install IS the folder, so teardown deletes it whole (launcher included)
# and the snapshots live beside it, in <project>/.claude-dev-snapshots/.
# Everything runs against the local git fixture template and a fixture
# $HOME built by helpers/setup.bash -- never the real shell rc files.

load helpers/setup

# Adds a second commit to the fixture template repo that moves the pinned
# srt version, so a successful `--update` is observable twice over: the
# clone's HEAD advances, and re-running the (pulled) install-srt.sh asks
# npm for the NEW pin rather than the one bootstrap installed.
bump_template_pin() {
    local new_pin="$1"
    sed -i.bak "s/^SRT_VERSION=\"[^\"]*\"/SRT_VERSION=\"$new_pin\"/" \
        "$TEMPLATE_SRC/scripts/install-srt.sh"
    rm -f "$TEMPLATE_SRC/scripts/install-srt.sh.bak"
    git -C "$TEMPLATE_SRC" -c user.email=test@example.com -c user.name=test \
        commit --quiet -am "bump srt pin to $new_pin"
}

@test "--update pulls the template via stubbed git, re-runs the srt pin and config sync, and re-runs the self-test" {
    make_project "$PROJECT_DIR"
    local before after
    before="$(git -C "$ORCA_HOST/template" rev-parse HEAD)"

    bump_template_pin "0.0.76"
    rm -f "$PROJECT_DIR/.claude-dev/run/selftest.json"
    : > "$STUB_LOG"

    cd "$PROJECT_DIR"
    run "$ORCA_HOST/bin/claude-dev" --update
    [ "$status" -eq 0 ]

    # The pull happened: the clone advanced to the fixture repo's new HEAD.
    after="$(git -C "$ORCA_HOST/template" rev-parse HEAD)"
    [ "$after" != "$before" ]
    [ "$after" = "$(git -C "$TEMPLATE_SRC" rev-parse HEAD)" ]

    # install-srt re-ran FROM THE PULLED TEMPLATE -- it asked npm for the
    # moved pin, not the one bootstrap had installed.
    grep -q "sandbox-runtime@0.0.76" "$STUB_LOG"

    # config sync ran for the current project.
    [ -f "$PROJECT_DIR/.claude-dev/home/.claude/settings.json" ]

    # the self-test re-ran and wrote fresh results.
    [ -f "$PROJECT_DIR/.claude-dev/run/selftest.json" ]

    # ... and it reported what changed.
    [[ "$output" == *"${before:0:7}"* ]]
    [[ "$output" == *"${after:0:7}"* ]]
}

@test "--teardown writes the beads snapshot under <project>/.claude-dev-snapshots/<timestamp>/ then removes .claude-dev, the ./claude-dev stub and the seeded gitignore lines only" {
    mkdir -p "$PROJECT_DIR"
    printf 'node_modules/\n' > "$PROJECT_DIR/.gitignore"
    make_project "$PROJECT_DIR"

    mkdir -p "$PROJECT_DIR/.beads"
    printf '{"id":"x-1"}\n' > "$PROJECT_DIR/.beads/issues.jsonl"
    printf '{"prefix":"x"}\n' > "$PROJECT_DIR/.beads/metadata.json"

    cd "$PROJECT_DIR"
    run "$ORCA_HOST/bin/claude-dev" --teardown
    [ "$status" -eq 0 ]

    # Exactly one timestamped snapshot, carrying both beads files verbatim.
    local state_root snap
    state_root="$PROJECT_DIR/.claude-dev-snapshots"
    [ -d "$state_root" ]
    [ "$(ls -1 "$state_root" | wc -l | tr -d ' ')" = "1" ]
    snap="$state_root/$(ls -1 "$state_root")"
    [[ "$(basename "$snap")" =~ ^[0-9]{8}-[0-9]{6}$ ]]
    [ "$(cat "$snap/issues.jsonl")" = '{"id":"x-1"}' ]
    [ "$(cat "$snap/metadata.json")" = '{"prefix":"x"}' ]

    # Removed: .claude-dev, the root stub and the seeded gitignore block
    # -- nothing else.
    [ ! -d "$PROJECT_DIR/.claude-dev" ]
    [ ! -e "$PROJECT_DIR/claude-dev" ]
    [ "$(cat "$PROJECT_DIR/.gitignore")" = "node_modules/" ]
    [ -f "$PROJECT_DIR/.beads/issues.jsonl" ]
    [ -d "$PROJECT_DIR/attachments" ]
}

@test "--uninstall removes the rc snippet from both rc files and deletes this folder's .claude-dev" {
    seed_pre_existing_rc_line 'eval "$(/opt/homebrew/bin/brew shellenv)"'
    make_project "$PROJECT_DIR"

    grep -qF "# >>> claude_orca >>>" "$HOME/.zshrc"
    grep -qF "# >>> claude_orca >>>" "$HOME/.bash_profile"

    cd "$PROJECT_DIR"
    run "$ORCA_HOST/bin/claude-dev" --uninstall
    [ "$status" -eq 0 ]

    # rc files back to exactly their pre-existing content.
    local rc
    for rc in .zprofile .zshrc .bash_profile; do
        [ "$(cat "$HOME/$rc")" = 'eval "$(/opt/homebrew/bin/brew shellenv)"' ]
    done

    # the folder's install is gone, and the path was printed on the way.
    [ ! -e "$ORCA_HOST" ]
    [[ "$output" == *"$ORCA_HOST"* ]]

    # teardown ran for the registered project on the way out.
    [ ! -d "$PROJECT_DIR/.claude-dev" ]
}

@test "registration after teardown restores the newest snapshot when issues.jsonl is absent" {
    make_project "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR/.beads"
    printf '{"id":"older"}\n' > "$PROJECT_DIR/.beads/issues.jsonl"
    printf '{"prefix":"older"}\n' > "$PROJECT_DIR/.beads/metadata.json"

    cd "$PROJECT_DIR"
    run "$ORCA_HOST/bin/claude-dev" --teardown
    [ "$status" -eq 0 ]

    # A second, NEWER snapshot (timestamps are second-granular). V1: a
    # teardown takes the launcher with it, so coming back means re-running
    # the bootstrap -- which ends in `register`, restoring as it goes.
    sleep 1
    make_project "$PROJECT_DIR"
    printf '{"id":"newest"}\n' > "$PROJECT_DIR/.beads/issues.jsonl"
    printf '{"prefix":"newest"}\n' > "$PROJECT_DIR/.beads/metadata.json"
    run "$ORCA_HOST/bin/claude-dev" --teardown
    [ "$status" -eq 0 ]
    [ "$(ls -1 "$PROJECT_DIR/.claude-dev-snapshots" | wc -l | tr -d ' ')" = "2" ]

    rm -f "$PROJECT_DIR/.beads/issues.jsonl" "$PROJECT_DIR/.beads/metadata.json"

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"snapshot"* ]]
    [ "$(cat "$PROJECT_DIR/.beads/issues.jsonl")" = '{"id":"newest"}' ]
    [ "$(cat "$PROJECT_DIR/.beads/metadata.json")" = '{"prefix":"newest"}' ]
}

# --- V5 (claude-orca-qt9.5): the v2 lifecycle ----------------------------

# Moves one pin in the fixture template and commits, so `--update` has
# something to pull: install-srt.sh/SRT_VERSION,
# install-claude.sh/CLAUDE_CODE_VERSION, install-orca.sh/ORCA_VERSION.
# Asserts the substitution actually landed -- a silently-unmatched sed
# would otherwise turn the pin assertions below into no-ops.
bump_template_var() {
    local file="$1" var="$2" value="$3"
    sed -i.bak "s/^${var}=\"[^\"]*\"/${var}=\"$value\"/" \
        "$TEMPLATE_SRC/scripts/$file"
    rm -f "$TEMPLATE_SRC/scripts/$file.bak"
    grep -qF "${var}=\"$value\"" "$TEMPLATE_SRC/scripts/$file"
    git -C "$TEMPLATE_SRC" -c user.email=test@example.com -c user.name=test \
        commit --quiet -am "bump $var to $value"
}

@test "--update pulls the in-folder template, re-runs the srt and Claude Code pins, re-downloads the Orca DMG only when the pin moved, re-syncs and re-runs the self-test" {
    make_project "$PROJECT_DIR"
    cd "$PROJECT_DIR"

    # Nothing moved: the pinned installs are all no-ops. In particular the
    # Orca DMG -- a ~150MB download -- is NOT fetched again.
    : > "$STUB_LOG"
    run "$ORCA_HOST/bin/claude-dev" --update
    [ "$status" -eq 0 ]
    run grep -c 'orca-macos' "$STUB_LOG"
    [ "$output" = "0" ]
    run grep -c '^npm ' "$STUB_LOG"
    [ "$output" = "0" ]

    # A folder bootstrapped before orca-launch existed carries no link for
    # it; pulling the template that added one must wire it up, or `open`
    # and the double-click bundle stay broken until a re-bootstrap.
    rm -f "$ORCA_HOST/bin/orca-launch"

    local before after
    before="$(git -C "$ORCA_HOST/template" rev-parse HEAD)"
    bump_template_var install-srt.sh    SRT_VERSION         "0.0.99"
    bump_template_var install-claude.sh CLAUDE_CODE_VERSION "9.9.9"
    bump_template_var install-orca.sh   ORCA_VERSION        "1.9.9"
    export STUB_ORCA_DMG_VERSION="1.9.9"

    rm -f "$PROJECT_DIR/.claude-dev/run/selftest.json"
    : > "$STUB_LOG"
    run "$ORCA_HOST/bin/claude-dev" --update
    [ "$status" -eq 0 ]

    # The pull landed, and was reported as a range.
    after="$(git -C "$ORCA_HOST/template" rev-parse HEAD)"
    [ "$after" != "$before" ]
    [ "$after" = "$(git -C "$TEMPLATE_SRC" rev-parse HEAD)" ]
    [[ "$output" == *"${before:0:7}"* ]]
    [[ "$output" == *"${after:0:7}"* ]]

    # Both npm pins were re-run FROM THE PULLED TEMPLATE ...
    grep -qF "sandbox-runtime@0.0.99" "$STUB_LOG"
    grep -qF "claude-code@9.9.9" "$STUB_LOG"

    # ... and this time the DMG was fetched, because the pin moved.
    grep -qF "releases/download/v1.9.9/orca-macos-" "$STUB_LOG"
    grep -qF "1.9.9" "$ORCA_HOST/app/Orca.app/Contents/Info.plist"

    # The folder's bin/ matches the pulled template again.
    [ -L "$ORCA_HOST/bin/orca-launch" ]
    [ -x "$ORCA_HOST/bin/orca-launch" ]

    # Config re-synced, self-test re-run.
    [ -f "$PROJECT_DIR/.claude-dev/home/.claude/settings.json" ]
    [ -f "$PROJECT_DIR/.claude-dev/run/selftest.json" ]
}

@test "--teardown snapshots beads to the documented location then removes .claude-dev, Orca.app, ./claude-dev and only the seeded gitignore lines" {
    mkdir -p "$PROJECT_DIR"
    printf 'node_modules/\n*.log\n' > "$PROJECT_DIR/.gitignore"
    make_project "$PROJECT_DIR"

    mkdir -p "$PROJECT_DIR/.beads"
    printf '{"id":"x-1"}\n' > "$PROJECT_DIR/.beads/issues.jsonl"
    printf '{"prefix":"x"}\n' > "$PROJECT_DIR/.beads/metadata.json"
    printf 'mine\n' > "$PROJECT_DIR/keep.txt"

    # register wrote the double-clickable launcher bundle: teardown owns it
    # too, and it is identified by the bundle id, never by its name.
    grep -qF "dev.onorca.sandboxed." "$PROJECT_DIR/Orca.app/Contents/Info.plist"

    cd "$PROJECT_DIR"
    run "$ORCA_HOST/bin/claude-dev" --teardown
    [ "$status" -eq 0 ]

    # The snapshot goes exactly where TEARDOWN_RECOVERY.md says it goes --
    # beside the folder, never in a central location.
    grep -qF '<project>/.claude-dev-snapshots/<timestamp>/' \
        "$REPO_ROOT/knowledge-base/TEARDOWN_RECOVERY.md"

    local root snap
    root="$PROJECT_DIR/.claude-dev-snapshots"
    [ "$(ls -1 "$root" | wc -l | tr -d ' ')" = "1" ]
    snap="$root/$(ls -1 "$root")"
    [[ "$(basename "$snap")" =~ ^[0-9]{8}-[0-9]{6}$ ]]
    [ "$(cat "$snap/issues.jsonl")" = '{"id":"x-1"}' ]
    [ "$(cat "$snap/metadata.json")" = '{"prefix":"x"}' ]
    [[ "$output" == *"$snap"* ]]

    # Gone: the install, the stub, the bundle. Kept: everything else,
    # including the user's own gitignore lines, byte for byte.
    [ ! -d "$PROJECT_DIR/.claude-dev" ]
    [ ! -e "$PROJECT_DIR/claude-dev" ]
    [ ! -e "$PROJECT_DIR/Orca.app" ]
    [ "$(cat "$PROJECT_DIR/.gitignore")" = "$(printf 'node_modules/\n*.log')" ]
    [ "$(cat "$PROJECT_DIR/keep.txt")" = "mine" ]
    [ -f "$PROJECT_DIR/.beads/issues.jsonl" ]
    [ -d "$PROJECT_DIR/attachments" ]
}

@test "--uninstall removes the rc block from all rc files and a v1 ~/.claude-orca when present, after printing the paths" {
    seed_pre_existing_rc_line 'eval "$(/opt/homebrew/bin/brew shellenv)"'
    make_project "$PROJECT_DIR"

    # A machine bootstrapped before v2 still carries the central install.
    local v1="$HOME/.claude-orca"
    mkdir -p "$v1/template" "$v1/bin"
    printf 'stale\n' > "$v1/bin/claude-dev"

    local rc
    for rc in .zprofile .zshrc .bash_profile; do
        grep -qF "# >>> claude_orca >>>" "$HOME/$rc"
    done

    cd "$PROJECT_DIR"
    run "$ORCA_HOST/bin/claude-dev" --uninstall
    [ "$status" -eq 0 ]

    # Every rc file back to exactly its pre-existing content.
    for rc in .zprofile .zshrc .bash_profile; do
        [ "$(cat "$HOME/$rc")" = 'eval "$(/opt/homebrew/bin/brew shellenv)"' ]
    done

    # Both roots named on the way out ...
    [[ "$output" == *"$ORCA_HOST"* ]]
    [[ "$output" == *"$v1"* ]]

    # ... and both actually removed.
    [ ! -e "$ORCA_HOST" ]
    [ ! -e "$v1" ]
    [ ! -d "$PROJECT_DIR/.claude-dev" ]
}
