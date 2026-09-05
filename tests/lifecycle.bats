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
