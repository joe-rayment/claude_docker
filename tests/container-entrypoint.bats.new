#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
#
# Guards:   the in-container entrypoint (scripts/container/entrypoint.sh)
#           boots a folder without Orca: it runs setup.sh, seeds, starts the
#           OpenRouter guard, supervises sshd as the long-running child, and
#           provisions the folder through provision.d. Whether the image
#           itself works is proven by running it (tests/mac-e2e.sh).
# Fails if: setup.sh stops being run before the privilege drop, a failing
#           setup.sh kills the boot, the guard's real key leaks into sshd's
#           environment, run/port stops being written, or the entrypoint
#           exits on its own instead of living as long as sshd is supervised.
# Run:      bats tests/container-entrypoint.bats
#
# This box cannot run containers (no mount namespaces), so the entrypoint
# is exercised NATIVELY here, with CLAUDE_ORCA_SSHD_BIN pointed at a stub
# sshd (a script that dumps its environment and sleeps) wherever a case
# needs to see what sshd would inherit. The entrypoint never exits by
# itself any more -- PID 1 waits on the sshd supervisor -- so every case
# starts it in the background and stops it with TERM, as `docker stop`
# does. tests/container-entrypoint-sshd.bats covers sshd itself, against a
# real OpenSSH.

load helpers/entrypoint-boot

@test "entrypoint runs setup.sh before dropping privileges and logs it to run/setup.log" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" before after
    make_project "$proj"
    : > "$TMP/setup.argv"
    write_setup_stub "$TMP/setup.sh"

    run_entrypoint_once HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_SETUP="$TMP/setup.sh" \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1

    # It got all the way to waiting on sshd, which is after the setup step,
    # and TERM took it down with the conventional 143.
    [[ "$output" == *"waiting on the sshd supervisor"* ]]
    [ "$ep_status" = "143" ]

    # First start: --check said the toolchain is not there, so the user
    # gets told why the VM is going to sit there for minutes.
    [[ "$output" == *"First start: installing the toolchain"* ]]

    # --check first, then the real run with no arguments.
    grep -qxF 'argv:--check' "$TMP/setup.argv"
    grep -qxF 'argv:' "$TMP/setup.argv"

    # tee'd, so the install output is both on the console and in the file
    # every failure message points at.
    [ -f "$proj/.claude-dev/run/setup.log" ]
    grep -qF 'stub setup: installing everything' "$proj/.claude-dev/run/setup.log"
    [[ "$output" == *"stub setup: installing everything"* ]]

    # Second start: --check passes now, so no notice -- but setup still runs.
    run_entrypoint_once HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_SETUP="$TMP/setup.sh" \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    [[ "$output" != *"First start:"* ]]

    # The skip knob keeps it out of the way entirely.
    before="$(wc -l < "$TMP/setup.argv" | tr -d '[:space:]')"
    run_entrypoint_once HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_SETUP="$TMP/setup.sh" CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    after="$(wc -l < "$TMP/setup.argv" | tr -d '[:space:]')"
    [ "$before" = "$after" ]
    [[ "$output" == *"skipping setup"* ]]

    # An absent setup script is a logged skip, not a crash (base image
    # without the template mounted yet).
    run_entrypoint_once HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_SETUP="$TMP/no-setup.sh" \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    [[ "$output" == *"skipping setup"* ]]
    [[ "$output" == *"$TMP/no-setup.sh"* ]]

    # A failing setup says where to look and carries on (claude-orca-dbu.6):
    # on the built-image path setup.sh is a verification pass, so its
    # failure means the image is wrong -- and killing the container there
    # removes the only thing that could report that. Nothing in the boot is
    # fatal now, so the run goes on to the steady state.
    run_entrypoint_once HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_SETUP="$TMP/setup.sh" CLAUDE_ORCA_STUB_SETUP_STATUS=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    [[ "$output" == *"setup.sh failed"* ]]
    [[ "$output" == *"$proj/.claude-dev/run/setup.log"* ]]
    [[ "$output" == *"waiting on the sshd supervisor"* ]]
}

# write_setup_stub's failing twin (claude-orca-dbu.6). --check passes, so
# there is no first-start notice to confuse the assertions; the real run
# prints a line (which still has to reach run/setup.log) and exits 1.
write_failing_setup_stub() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "--check" ]; then exit 0; fi
echo "stub setup: this image is not what it promised"
exit 1
STUB
    chmod +x "$path"
}

@test "a failing setup.sh does not stop the entrypoint: sshd is still supervised and run/port is still written" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" port
    make_project "$proj"
    mkdir -p "$TMP/home"
    write_failing_setup_stub "$TMP/setup.sh"
    port="$(free_port)"

    export HOME="$TMP/home"
    export PROJECT_DIR="$proj"
    export CLAUDE_ORCA_SSHD_PORT="$port"
    export CLAUDE_ORCA_RUNTIME_DIR="$RT"
    export CLAUDE_ORCA_SETUP="$TMP/setup.sh"
    export CLAUDE_ORCA_SKIP_BEADS=1
    export CLAUDE_ORCA_SKIP_PROVISION=1
    export CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1

    start_entrypoint_bg

    # run/port is written right after the sshd supervisor starts, so it
    # appearing proves the boot went past the failed setup.
    if ! wait_for_file "$proj/.claude-dev/run/port" 40; then
        echo "--- entrypoint stdout ---" >&2
        cat "$TMP/entrypoint.out" >&2 || true
        false
    fi
    [ "$(tr -d '[:space:]' < "$proj/.claude-dev/run/port")" = "$port" ]

    # sshd has no keys in this fixture, so the supervisor says so in its
    # log and keeps retrying; it is running, which is the point.
    wait_for_file "$proj/.claude-dev/run/sshd.log" 20
    grep -qF 'no ssh keys in state/ssh yet' "$proj/.claude-dev/run/sshd.log"

    # The failure was not silent: it is on the console, in setup.log, and
    # in the status file -- and the boot went on anyway.
    grep -qF 'setup.sh failed' "$TMP/entrypoint.out"
    grep -qF 'stub setup: this image is not what it promised' \
        "$proj/.claude-dev/run/setup.log"
    [ "$(cat "$proj/.claude-dev/run/provision/setup.status" | tr -d '[:space:]')" = "1" ]
}

@test "a failing setup.sh leaves a non-zero run/provision/setup.status and a warning, not a die" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project"
    make_project "$proj"
    write_failing_setup_stub "$TMP/setup.sh"

    run_entrypoint_once HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_SETUP="$TMP/setup.sh" \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1

    # Warned, named the log, and carried on to waiting on sshd.
    [[ "$output" == *"setup.sh failed"* ]]
    [[ "$output" == *"$proj/.claude-dev/run/setup.log"* ]]
    [[ "$output" == *"waiting on the sshd supervisor"* ]]

    run cat "$proj/.claude-dev/run/provision/setup.status"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | tr -d '[:space:]')" = "1" ]
}

@test "a succeeding setup.sh leaves run/provision/setup.status 0" {
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project"
    make_project "$proj"
    : > "$TMP/setup.argv"
    write_setup_stub "$TMP/setup.sh"

    run_entrypoint_once HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_SETUP="$TMP/setup.sh" \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    [[ "$output" == *"setup done"* ]]
    [[ "$output" != *"setup.sh failed"* ]]

    # 0 is written too, so "ran fine" and "never ran" are distinguishable.
    run cat "$proj/.claude-dev/run/provision/setup.status"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | tr -d '[:space:]')" = "0" ]
}

@test "Dockerfile, setup.sh and smoke.sh exist, and the image runs the entrypoint" {
    # Guards:   the image's moving parts are all in the repo: the Dockerfile
    #           that builds it, setup.sh that installs it, smoke.sh that
    #           checks it, and the entrypoint it starts under tini.
    # Fails if: the Dockerfile stops naming scripts/container/entrypoint.sh,
    #           or one of the four files is deleted or loses its exec bit.
    # Run:      bats -f 'the image runs the entrypoint' tests/container-entrypoint.bats
    [ -f "$DOCKERFILE" ]
    [ -x "$SETUP" ]
    [ -x "$SMOKE" ]
    [ -x "$ENTRYPOINT" ]

    # The image runs the entrypoint under tini.
    run grep -q 'scripts/container/entrypoint.sh' "$DOCKERFILE"
    [ "$status" -eq 0 ]
}

@test "entrypoint seeds .gitignore, attachments/ and the home gitconfig from CLAUDE_ORCA_GIT_NAME and CLAUDE_ORCA_GIT_EMAIL" {
    # Guards:   a fresh folder gets its .gitignore entries (once each), the
    #           attachments/ directory and a home gitconfig carrying the Mac's
    #           git identity -- and never overwrites a gitconfig that exists.
    # Fails if: a start appends the .gitignore block twice, the identity
    #           stops reaching ~/.gitconfig, an existing gitconfig is
    #           replaced, or an empty [user] stanza is written without env.
    # Run:      bats -f 'seeds .gitignore, attachments' tests/container-entrypoint.bats
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" home pattern
    make_project "$proj"
    stage_template_tree "$proj" 40-git-identity 50-seed-project
    home="$proj/.claude-dev/home"

    # Twice, because the seed has to be idempotent: a folder is registered
    # again on every start.
    local i
    for i in 1 2; do
        run_entrypoint_once HOME="$home" PROJECT_DIR="$proj" \
            CLAUDE_ORCA_SKIP_PROVISION=0 CLAUDE_ORCA_PROVISION_TIMEOUT=30 \
            CLAUDE_ORCA_SKIP_SETUP=1 \
            CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
            CLAUDE_ORCA_GIT_NAME="Ada Lovelace" \
            CLAUDE_ORCA_GIT_EMAIL="ada@example.com"
        [ "$ep_status" = "143" ]
        [[ "$output" == *"waiting on the sshd supervisor"* ]]
    done

    # The same entries and marker seed_gitignore writes on the Mac, each
    # exactly once.
    [ -f "$proj/.gitignore" ]
    run grep -c '^# claude_orca$' "$proj/.gitignore"
    [ "$output" = "1" ]
    for pattern in '.claude-dev/' '.claude-dev-snapshots/' '/claude-dev' \
                   'Orca.app/' '.mcp.json' 'attachments/' '.claude/logs/'; do
        run grep -c -xF "$pattern" "$proj/.gitignore"
        [ "$output" = "1" ]
    done

    # Where take-screenshot drops images.
    [ -d "$proj/attachments" ]

    # A fresh .claude-dev/home has no git identity at all, so every commit
    # inside the container would fail. The Mac passes its own as env.
    [ -f "$home/.gitconfig" ]
    run cat "$home/.gitconfig"
    [[ "$output" == *"name = Ada Lovelace"* ]]
    [[ "$output" == *"email = ada@example.com"* ]]

    # Never over an existing one: whatever the agent set up in there wins.
    run_entrypoint_once HOME="$home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_SKIP_PROVISION=0 CLAUDE_ORCA_PROVISION_TIMEOUT=30 \
            CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1 \
        CLAUDE_ORCA_GIT_NAME="Someone Else" \
        CLAUDE_ORCA_GIT_EMAIL="else@example.com"
    run cat "$home/.gitconfig"
    [[ "$output" == *"Ada Lovelace"* ]]
    [[ "$output" != *"Someone Else"* ]]

    # Nothing to copy: no env, no file (and no empty [user] stanza).
    local proj2="$TMP/project2" home2
    make_project "$proj2"
    stage_template_tree "$proj2" 40-git-identity 50-seed-project
    home2="$proj2/.claude-dev/home"
    # unset: a claude-orca container exports the identity into every
    # shell, and this leg is about the folder that ships none.
    unset CLAUDE_ORCA_GIT_NAME CLAUDE_ORCA_GIT_EMAIL
    run_entrypoint_once HOME="$home2" PROJECT_DIR="$proj2" \
        CLAUDE_ORCA_SKIP_PROVISION=0 CLAUDE_ORCA_PROVISION_TIMEOUT=30 \
            CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    [ ! -f "$home2/.gitconfig" ]
    [ -d "$proj2/attachments" ]
}

# --- first-run friction (claude-orca-qa2.17) ------------------------------
#
# A Claude Code worker in a fresh .claude-dev/home sat on the trust dialog
# forever (the 2026-09-06 live demo on this box). The Orca-CLI half of that
# pair of cases is gone with Orca; the trust seed stays.

@test "entrypoint seeds the Claude Code trust and bypass-permissions keys without overwriting existing ones" {
    # Guards:   a fresh home gets the folder-trust, onboarding and
    #           skip-permissions-prompt keys so a worker never stalls on a
    #           dialog -- while any value, or non-JSON file, already there wins.
    # Fails if: the seed stops writing a key, replaces a value the agent set,
    #           disturbs other keys in the file, or rewrites a non-JSON file.
    # Run:      bats -f 'trust and bypass-permissions keys' tests/container-entrypoint.bats
    [ -x "$ENTRYPOINT" ]
    command -v jq >/dev/null 2>&1

    local proj="$TMP/project" home cj sj
    make_project "$proj"
    stage_template_tree "$proj" 30-claude-first-run
    home="$proj/.claude-dev/home"
    cj="$home/.claude.json"
    sj="$home/.claude/settings.json"

    run_entrypoint_once HOME="$home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_SKIP_PROVISION=0 CLAUDE_ORCA_PROVISION_TIMEOUT=30 \
            CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    [ "$ep_status" = "143" ]
    [[ "$output" == *"waiting on the sshd supervisor"* ]]

    # The folder-trust dialog and the first-run wizard.
    [ -f "$cj" ]
    run jq -r --arg p "$proj" '.projects[$p].hasTrustDialogAccepted' "$cj"
    [ "$output" = "true" ]
    run jq -r '.hasCompletedOnboarding' "$cj"
    [ "$output" = "true" ]

    # The disclaimer --dangerously-skip-permissions raises once per install.
    [ -f "$sj" ]
    run jq -r '.skipDangerousModePermissionPrompt' "$sj"
    [ "$output" = "true" ]

    # A value already on disk always wins, and nothing else in the file is
    # disturbed: these are the agent's own config files.
    jq -n --arg p "$proj" '{
        hasCompletedOnboarding: false,
        oauthAccount: {emailAddress: "someone@example.com"},
        projects: {($p): {hasTrustDialogAccepted: false, allowedTools: ["Bash"]}}
    }' > "$cj"
    jq -n '{skipDangerousModePermissionPrompt: false, model: "opus"}' > "$sj"

    run_entrypoint_once HOME="$home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_SKIP_PROVISION=0 CLAUDE_ORCA_PROVISION_TIMEOUT=30 \
            CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    run jq -r --arg p "$proj" '[.hasCompletedOnboarding,
        .projects[$p].hasTrustDialogAccepted,
        .projects[$p].allowedTools[0],
        .oauthAccount.emailAddress] | join(",")' "$cj"
    [ "$output" = "false,false,Bash,someone@example.com" ]
    run jq -r '[.skipDangerousModePermissionPrompt, .model] | join(",")' "$sj"
    [ "$output" = "false,opus" ]

    # A config file that is not JSON is left exactly as it was found --
    # never replaced, because that file is the agent's login.
    printf 'not json at all\n' > "$cj"
    run_entrypoint_once HOME="$home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_SKIP_PROVISION=0 CLAUDE_ORCA_PROVISION_TIMEOUT=30 \
            CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    run cat "$cj"
    [ "$output" = "not json at all" ]
}

@test "entrypoint restores the newest beads snapshot before bd init when the project has no beads" {
    # Guards:   a folder with no .beads gets the NEWEST snapshot from
    #           .claude-dev-snapshots restored; live beads are never
    #           overwritten; no snapshots is a silent no-op.
    # Fails if: the oldest snapshot is restored, a project that already has
    #           beads is overwritten, or an empty snapshot dir creates .beads.
    # Run:      bats -f 'newest beads snapshot' tests/container-entrypoint.bats
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" snaps
    make_project "$proj"
    stage_template_tree "$proj" 50-seed-project
    snaps="$proj/.claude-dev-snapshots"
    mkdir -p "$snaps/20200101-000000" "$snaps/20240101-000000"
    echo '{"id":"old"}' > "$snaps/20200101-000000/issues.jsonl"
    echo '{"id":"newest"}' > "$snaps/20240101-000000/issues.jsonl"
    echo '{"prefix":"newest"}' > "$snaps/20240101-000000/metadata.json"
    [ ! -e "$proj/.beads" ]

    run_entrypoint_once HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_SKIP_PROVISION=0 CLAUDE_ORCA_PROVISION_TIMEOUT=30 \
            CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    [ "$ep_status" = "143" ]
    [[ "$output" == *"waiting on the sshd supervisor"* ]]

    # The newest snapshot, not the first one listed.
    [ -f "$proj/.beads/issues.jsonl" ]
    run cat "$proj/.beads/issues.jsonl"
    [ "$output" = '{"id":"newest"}' ]
    run cat "$proj/.beads/metadata.json"
    [ "$output" = '{"prefix":"newest"}' ]

    # A project that already carries beads keeps them: an older snapshot
    # must never overwrite live data.
    echo '{"id":"live"}' > "$proj/.beads/issues.jsonl"
    run_entrypoint_once HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_SKIP_PROVISION=0 CLAUDE_ORCA_PROVISION_TIMEOUT=30 \
            CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    run cat "$proj/.beads/issues.jsonl"
    [ "$output" = '{"id":"live"}' ]

    # No snapshots at all is a silent no-op, not a failure.
    local proj2="$TMP/project2"
    make_project "$proj2"
    stage_template_tree "$proj2" 50-seed-project
    run_entrypoint_once HOME="$proj2/.claude-dev/home" PROJECT_DIR="$proj2" \
        CLAUDE_ORCA_SKIP_PROVISION=0 CLAUDE_ORCA_PROVISION_TIMEOUT=30 \
            CLAUDE_ORCA_SKIP_SETUP=1 \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    [[ "$output" == *"waiting on the sshd supervisor"* ]]
    [ ! -e "$proj2/.beads" ]
}

# --- where the template comes from (claude-orca-qa2.9) ---------------------

@test "entrypoint resolves the template from /opt/claude-orca or the mounted .claude-dev/template" {
    # Guards:   setup.sh and the other template-shaped files come from ONE
    #           root: the folder's own clone when it carries an executable
    #           setup.sh, else the baked /opt/claude-orca, else the clone bare
    #           -- and the setup.sh at that root is the one that really runs.
    # Fails if: the root rule changes, the logged "template root" / "setup:"
    #           paths disagree with it, the folder's setup.sh is not run
    #           (argv/run/setup.log stay empty), or the image-branch test in
    #           entrypoint.sh disappears.
    # Run:      bats -f 'resolves the template from' tests/container-entrypoint.bats
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project" expect_root
    make_project "$proj"

    # The prebuilt image carries the template at /opt/claude-orca; a base
    # image has only the folder's own mounted clone. The entrypoint's rule
    # (entrypoint.sh, "where the template is"): the folder's template wins
    # when it carries an executable setup.sh, then the baked copy, then
    # the folder clone bare. expect_root follows that same rule, so the
    # case holds on a base image, on the baked image, and on a project
    # that has pulled its own template clone -- whichever this box is.
    if [ -x "$proj/.claude-dev/template/scripts/container/setup.sh" ]; then
        expect_root="$proj/.claude-dev/template"
    elif [ -d /opt/claude-orca ]; then
        expect_root="/opt/claude-orca"
    else
        expect_root="$proj/.claude-dev/template"
    fi

    run_entrypoint_once HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_SKIP_SETUP=1 CLAUDE_ORCA_SKIP_BEADS=1 \
        CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    [ "$ep_status" = "143" ]
    [[ "$output" == *"template root: $expect_root"* ]]
    [[ "$output" == *"setup: $expect_root/scripts/container/setup.sh"* ]]

    # ...and that default is the script that actually runs. The folder's
    # stub outranks a baked /opt/claude-orca, so this leg holds on every box.
    : > "$TMP/setup.argv"
    write_setup_stub "$proj/.claude-dev/template/scripts/container/setup.sh"
    run_entrypoint_once HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_SKIP_BEADS=1 CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    [ "$ep_status" = "143" ]
    [[ "$output" == *"setup: $proj/.claude-dev/template/scripts/container/setup.sh"* ]]
    grep -qxF 'argv:' "$TMP/setup.argv"
    grep -qF 'stub setup: installing everything' \
        "$proj/.claude-dev/run/setup.log"

    # The image branch, which a folder with its own template never reaches,
    # is pinned here.
    run grep -qF '[ -d /opt/claude-orca ]' "$ENTRYPOINT"
    [ "$status" -eq 0 ]
}

@test "entrypoint prefers the folder's own template when it carries an executable setup.sh, even over a baked /opt/claude-orca" {
    # Guards:   a folder that has pulled its own scripts/container/* (what
    #           --update leaves behind) runs those, not the stale copy baked
    #           into the image months earlier.
    # Fails if: the baked /opt/claude-orca wins the tiebreak over a folder
    #           template with an executable setup.sh, or a folder template
    #           WITHOUT one starts to win.
    # Run:      bats -f 'prefers the folder' tests/container-entrypoint.bats
    [ -x "$ENTRYPOINT" ]

    local proj="$TMP/project"
    make_project "$proj"

    # No setup.sh in the folder's clone yet: whichever root this box would
    # have picked before (see the test above) still wins.
    if [ -d /opt/claude-orca ]; then
        run_entrypoint_once HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
            CLAUDE_ORCA_SKIP_SETUP=1 CLAUDE_ORCA_SKIP_BEADS=1 \
            CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
        [[ "$output" == *"template root: /opt/claude-orca"* ]]
    fi

    # An executable setup.sh in the folder's own clone -- what `--update`
    # leaves behind -- outranks the baked copy even when /opt/claude-orca
    # is still there, so a scripts/container/* fix reaches a folder on the
    # next recreate with no image rebuild.
    write_setup_stub "$proj/.claude-dev/template/scripts/container/setup.sh"
    run_entrypoint_once HOME="$proj/.claude-dev/home" PROJECT_DIR="$proj" \
        CLAUDE_ORCA_SKIP_SETUP=1 CLAUDE_ORCA_SKIP_BEADS=1 \
        CLAUDE_ORCA_ENTRYPOINT_NO_PRIVDROP=1
    [[ "$output" == *"template root: $proj/.claude-dev/template"* ]]
}
