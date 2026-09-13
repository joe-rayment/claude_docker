#!/usr/bin/env bats
#
# Acceptance contract for claude-orca-qa2.2 (v3 S2, the Mac half) --
# FROZEN from RED-AT onward.
#
# v3 replaces the Seatbelt install with one Linux container per project: the
# Mac side only has to preflight `docker`, seed the folder, pull the pinned
# image, run the container with the project and the folder-local home
# mounted, and open the pairing URL the entrypoint publishes. Nothing here
# needs a Mac or a daemon: `docker`, `open`, `sw_vers` and `uname` are
# stubbed by tests/helpers/setup.bash, and the `docker` stub stands in for
# the entrypoint by writing run/orca-web-url.txt when it is asked to `run`.
#
# See .claude/plans/container-v3.md S5 and scripts/container/entrypoint.sh
# (the env contract asserted in case 3: PROJECT_DIR, ORCA_PORT, HOST_UID,
# GH_TOKEN in, run/orca-web-url.txt and run/port out).

load helpers/setup

STUB_TOKEN="gho_stubfaketoken0123456789abcdef"

# The one line the `docker` stub logged for the invocation whose argv
# starts with $1 (its log is one line per invocation, argv joined).
ctr_line() {
    grep "^$1" "$CONTAINER_STUB_LOG" | head -1
}

# A PATH with no docker on it at all. Removing the stub is not enough: this
# box ships a real /usr/bin/docker AND a real daemon, and the preflight case
# would then drive them for real. $ORIGINAL_PATH is shadowed into one
# directory of symlinks minus docker, and PATH becomes $STUB_BIN plus it --
# so brew, gh and the rest still answer with their stubs.
path_without_docker() {
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
    rm -f "$shadow/docker" "$STUB_BIN/docker"
    export PATH="$STUB_BIN:$shadow"
}

@test "bootstrap preflight requires macOS or Linux and the docker CLI, checks the daemon, and never installs brew, srt or a DMG" {
    export STUB_UNAME_S=Darwin
    export STUB_UNAME_M=arm64

    # An OS Docker does not run on at all.
    export STUB_UNAME_S=FreeBSD
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"macOS or Linux"* ]]
    [ ! -e "$PROJECT_DIR/.claude-dev" ]
    export STUB_UNAME_S=Darwin

    # An Intel Mac and an old macOS are both supported now -- Docker Desktop
    # runs on both, so the Apple-silicon and macOS-26 gates are gone.
    export STUB_UNAME_M=x86_64
    export CLAUDE_ORCA_TEST_MACOS=15.5
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    export STUB_UNAME_M=arm64
    unset CLAUDE_ORCA_TEST_MACOS

    # No docker CLI: the preflight installs the Homebrew cask for you and
    # carries on in the same run.
    export STUB_DOCKER_SRC="$BATS_TEST_TMPDIR/docker-stub"
    cp "$STUB_BIN/docker" "$STUB_DOCKER_SRC"
    path_without_docker
    ! command -v docker >/dev/null 2>&1
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    grep -q "^brew install --cask docker" "$STUB_LOG"
    [ -x "$STUB_BIN/docker" ]

    # And the whole preflight, passing: the daemon answered, the
    # template is cloned, and not one v2 install step runs. A clean log, so
    # the negatives below are about this run and not about the cask install
    # the previous one was asked to do.
    : > "$STUB_LOG"
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    grep -q "^info" "$CONTAINER_STUB_LOG"

    [ -d "$PROJECT_DIR/.claude-dev/template/.git" ]
    [ -L "$PROJECT_DIR/.claude-dev/bin/claude-dev" ]

    [ ! -e "$PROJECT_DIR/.claude-dev/srt" ]
    [ ! -e "$PROJECT_DIR/.claude-dev/app" ]
    ! grep -q "^brew " "$STUB_LOG"
    ! grep -q "hdiutil" "$STUB_LOG"
    ! grep -q "sandbox-runtime" "$STUB_LOG"
    [ ! -e "$HOME/.zprofile" ]
    [ ! -e "$HOME/.zshrc" ]
    [ ! -e "$HOME/.bash_profile" ]
}

# startup v4 (claude-orca-qa2.10): the Mac side reads its own global git
# config and passes the two values in as env; every file that used to be
# seeded here -- the home .gitconfig, the project .gitignore, attachments/,
# a restored beads snapshot -- is now written by the entrypoint inside the
# VM, where it can be exercised for real (tests/container-entrypoint.bats).
@test "register passes the Mac git identity as CLAUDE_ORCA_GIT_NAME and CLAUDE_ORCA_GIT_EMAIL and writes no gitconfig, gitignore, attachments or beads files itself" {
    git config --global user.name "Test User"
    git config --global user.email "test@example.com"

    mkdir -p "$PROJECT_DIR"
    printf 'node_modules/\n' > "$PROJECT_DIR/.gitignore"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    config="$primary/.claude-dev/claude-orca.json"
    [ -f "$config" ]
    run jq -e '.version == 3' "$config"
    [ "$status" -eq 0 ]

    port="$(jq -r '.port' "$config")"
    [[ "$port" =~ ^[0-9]+$ ]]
    [ "$port" -ge 6768 ]
    [ "$(cat "$primary/.claude-dev/run/port")" = "$port" ]

    # The identity crosses the boundary as env on the `docker run`; the
    # entrypoint is what writes /home/agent/.gitconfig from it.
    identity="$(ctr_line "run ")"
    [[ "$identity" == *"-e CLAUDE_ORCA_GIT_NAME=Test User"* ]]
    [[ "$identity" == *"-e CLAUDE_ORCA_GIT_EMAIL=test@example.com"* ]]
    [ ! -e "$primary/.claude-dev/home/.gitconfig" ]

    # Nothing else the container seeds for itself is written out here: the
    # user's own .gitignore is untouched, and there is no attachments/ and
    # no .beads/ on the Mac side.
    [ "$(cat "$primary/.gitignore")" = "node_modules/" ]
    [ ! -e "$primary/attachments" ]
    [ ! -e "$primary/.beads" ]

    # The image ref is pinned by the template's own IMAGE_TAG file, and
    # is built locally -- there is no registry left in this path to log
    # in to.
    [ -f "$REPO_ROOT/IMAGE_TAG" ]
    tag="$(cat "$primary/.claude-dev/template/IMAGE_TAG")"
    [ -n "$tag" ]
    grep -qF "build --tag claude-orca:$tag" "$CONTAINER_STUB_LOG"
    ! grep -q "^pull " "$CONTAINER_STUB_LOG"
}

@test "register passes the terminal palette to the container as CLAUDE_ORCA_TERMINAL_THEME -- Homebrew by default, claude-orca.json's terminalTheme when set" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    line="$(ctr_line "run ")"
    [[ "$line" == *"-e CLAUDE_ORCA_TERMINAL_THEME=Homebrew"* ]]

    name="claude-orca-$(basename "$primary")"
    json="$primary/.claude-dev/claude-orca.json"
    jq '.terminalTheme = "Snazzy"' "$json" > "$json.tmp" && mv "$json.tmp" "$json"
    rm -f "$CONTAINER_STUB_STATE/containers/$name"
    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev"
    [ "$status" -eq 0 ]

    line="$(ctr_line "run ")"
    [[ "$line" == *"-e CLAUDE_ORCA_TERMINAL_THEME=Snazzy"* ]]
}

@test "open runs the container with the project at /workspace/<name> and the home at /home/agent, the port published on 127.0.0.1, PROJECT_DIR/ORCA_PORT/HOST_UID/GH_TOKEN/BEADS_DIR in the environment, waits for run/orca-web-url.txt and opens it" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    port="$(cat "$primary/.claude-dev/run/port")"
    name="claude-orca-$(basename "$primary")"

    line="$(ctr_line "run ")"
    guest="/workspace/$(basename "$primary")"
    [[ "$line" == *" -d "* ]]
    [[ "$line" == *"--name $name"* ]]
    # The project is mounted at /workspace/<name>, NOT at its Mac path.
    # Mounted at its Mac path, the container spells out the owner's home
    # directory and their folder tree in every prompt and every `cd ..`,
    # and a real owner read that as the sandbox being broken (2026-09-07).
    # Nothing inside needs the two paths to agree: everything in the
    # container takes the path from PROJECT_DIR.
    [[ "$line" == *"--volume $primary:$guest"* ]]
    [[ "$line" != *"--volume $primary:$primary"* ]]
    [[ "$line" == *"--volume $primary/.claude-dev/home:/home/agent"* ]]
    [[ "$line" == *"-p 127.0.0.1:$port:$port"* ]]
    [[ "$line" == *"-e PROJECT_DIR=$guest"* ]]
    # The Mac path still rides along, for messages that name a file a
    # person has to open on the Mac.
    [[ "$line" == *"-e CLAUDE_ORCA_HOST_PROJECT_DIR=$primary"* ]]
    # bd walks UP from the cwd for .beads, so from anywhere but the
    # project it finds nothing -- which is exactly what "no beads database
    # found" meant on 2026-09-07. The folder's tracker is named outright.
    [[ "$line" == *"-e BEADS_DIR=$guest/.beads"* ]]
    [[ "$line" == *"-e CLAUDE_ORCA_ROOT=$guest"* ]]
    [[ "$line" == *"-e ORCA_PORT=$port"* ]]
    [[ "$line" == *"-e HOST_UID=$(id -u)"* ]]
    [[ "$line" == *"-e GH_TOKEN=$STUB_TOKEN"* ]]
    [[ "$line" == *"claude-orca:"* ]]

    # The entrypoint's side of the contract, faked by the stub: the URL
    # file appears and the launcher waits for it, then opens it.
    url="$(cat "$primary/.claude-dev/run/orca-web-url.txt")"
    [ "$url" = "http://127.0.0.1:$port/web-index.html#pairing=stub" ]
    [ "$(tail -1 "$OPEN_STUB_LOG")" = "$url" ]

    # And the three-line hand-off: the URL, how to reopen, how to get a
    # terminal inside the container.
    [[ "$output" == *"$url"* ]]
    [[ "$output" == *"./claude-dev shell"* ]]
}

@test "the container gets CLAUDE_ORCA_SETUP pointing at the folder's own template clone when it carries scripts/container/setup.sh, and none at all when it does not" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    guest="/workspace/$(basename "$primary")"
    line="$(ctr_line "run ")"
    # bootstrap.sh's clone is the real repo, so the folder's own template
    # has scripts/container/setup.sh from the first run -- pointing the
    # baked entrypoint's CLAUDE_ORCA_SETUP fallback at it is what delivers
    # a scripts/container/* fix with no image rebuild.
    [[ "$line" == *"-e CLAUDE_ORCA_SETUP=$guest/.claude-dev/template/scripts/container/setup.sh"* ]]

    # Take it away -- an older template clone, from before this file
    # existed -- and the launcher must not name a file that is not there;
    # the image's own baked default runs instead.
    rm -f "$primary/.claude-dev/template/scripts/container/setup.sh"
    name="claude-orca-$(basename "$primary")"
    rm -f "$CONTAINER_STUB_STATE/containers/$name"
    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev"
    [ "$status" -eq 0 ]

    line="$(ctr_line "run ")"
    [[ "$line" != *"CLAUDE_ORCA_SETUP"* ]]
}

@test "open on an existing container starts it when stopped and only opens the URL when running; stop, shell and logs call docker with the project name" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null
    name="claude-orca-$(basename "$primary")"
    url="$(cat "$primary/.claude-dev/run/orca-web-url.txt")"

    # Already running: no second container, no start, just the URL.
    : > "$CONTAINER_STUB_LOG"
    : > "$OPEN_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]
    ! grep -q "^run " "$CONTAINER_STUB_LOG"
    ! grep -q "^start " "$CONTAINER_STUB_LOG"
    [ "$(tail -1 "$OPEN_STUB_LOG")" = "$url" ]

    # Stopped: started, never recreated.
    printf 'stopped\n' > "$CONTAINER_STUB_STATE/containers/$name"
    : > "$CONTAINER_STUB_LOG"
    : > "$OPEN_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]
    grep -qx "start $name" "$CONTAINER_STUB_LOG"
    ! grep -q "^run " "$CONTAINER_STUB_LOG"
    [ "$(tail -1 "$OPEN_STUB_LOG")" = "$url" ]

    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev stop"
    [ "$status" -eq 0 ]
    grep -qx "stop $name" "$CONTAINER_STUB_LOG"

    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev shell"
    [ "$status" -eq 0 ]
    shell_line="$(ctr_line "exec ")"
    [[ "$shell_line" == *"$name"* ]]
    [[ "$shell_line" == *"zsh"* ]]
    [[ "$shell_line" == *"--workdir /workspace/$(basename "$primary")"* ]]

    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev logs"
    [ "$status" -eq 0 ]
    grep -qx "logs -f $name" "$CONTAINER_STUB_LOG"
}

@test "doctor reports the docker CLI, daemon, image, container state, port and web url and exits 2 on a finding; teardown stops and removes the container and the install" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null
    name="claude-orca-$(basename "$primary")"
    port="$(cat "$primary/.claude-dev/run/port")"

    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"docker CLI"* ]]
    [[ "$output" == *"docker daemon"* ]]
    [[ "$output" == *"image"* ]]
    [[ "$output" == *"claude-orca:"* ]]
    [[ "$output" == *"$name"* ]]
    [[ "$output" == *"running"* ]]
    [[ "$output" == *"port"* ]]
    [[ "$output" == *"$port"* ]]
    [[ "$output" == *"web url"* ]]

    # One finding -- the image is gone -- and the doctor exits 2.
    rm -f "$CONTAINER_STUB_STATE/image"
    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [ "$status" -eq 2 ]
    [[ "$output" == *"missing"* ]]

    # Teardown: the container goes, the install goes, and so does any v2
    # shell-rc block left over from an upgraded folder.
    printf '%s\n' '# >>> claude_orca >>>' 'eval "$(claude-orca-shell)"' '# <<< claude_orca <<<' \
        > "$HOME/.zshrc"
    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev --teardown"
    [ "$status" -eq 0 ]
    grep -qx "stop $name" "$CONTAINER_STUB_LOG"
    grep -qx "rm $name" "$CONTAINER_STUB_LOG"
    [ ! -e "$primary/.claude-dev" ]
    [ ! -e "$primary/claude-dev" ]
    ! grep -q "claude_orca" "$HOME/.zshrc"
}

# S5 (claude-orca-dbu.5): a folder can be diagnosed from either side. The
# steps write their status inside the container; the doctor on the Mac asks
# the container for them rather than parsing the files itself, so a folder
# whose provisioning half failed cannot look healthy from here.
@test "doctor grows one row per provision step, fetched from the container, and exits 2 on a failed step" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null

    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"10-toolchain-verify"* ]]
    [[ "$output" == *"20-config-sync"* ]]

    # One failed step is a finding, named, with the line that says why.
    export CLAUDE_ORCA_TEST_PROVISION_FAIL=1
    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [ "$status" -eq 2 ]
    [[ "$output" == *"FAIL"* ]]
    [[ "$output" == *"20-config-sync"* ]]
    [[ "$output" == *"cp: cannot create the settings file"* ]]
}


# --- desktop Orca, S1 (claude-orca-8uo.2) --------------------------------
#
# A desktop Orca on the Mac attaches to the container's runtime with the
# pairing URL `orca serve` minted. A folder can have it two ways, and the
# launcher must take either: run/orca-pairing-url.txt, which the entrypoint
# writes from serve's own `Pairing URL:` line, or -- for every folder still
# on an image built before that change -- the `#pairing=` fragment of
# run/orca-web-url.txt, which carries the same URL percent-encoded. A
# change that can only arrive in a rebuilt image reaches nobody, so the
# second path is not a fallback, it is the one that always works.

# The launcher is a command-dispatching script, so a unit case lifts the
# one function out of it with sed, the way tests/toolchain-cache.bats
# drives try_build. A missing function fails loudly rather than looking
# like the "no URL" return it is being asked about.
run_pairing_url_of() {
    local fns
    fns="$(sed -n '/^pairing_url_of()/,/^}$/p' "$REPO_ROOT/scripts/launcher.sh")"
    if [ -z "$fns" ]; then
        echo "pairing_url_of is not defined in scripts/launcher.sh" >&2
        return 99
    fi
    bash -c "set -uo pipefail
$fns
pairing_url_of \"\$@\"" _ "$@"
}

pairing_fixture() {
    local dir="$1"
    mkdir -p "$dir/.claude-dev/run"
    rm -f "$dir/.claude-dev/run/orca-pairing-url.txt" \
          "$dir/.claude-dev/run/orca-web-url.txt"
}

@test "pairing_url_of prefers run/orca-pairing-url.txt" {
    local dir="$BATS_TEST_TMPDIR/pair1"
    pairing_fixture "$dir"

    # Both files present and disagreeing: the entrypoint's own file wins,
    # because it is serve's verbatim line rather than something derived.
    printf '%s\n' 'orca://pair?code=FROMTHEFILE' \
        > "$dir/.claude-dev/run/orca-pairing-url.txt"
    printf '%s\n' \
        'http://127.0.0.1:5173/web-index.html#pairing=orca%3A%2F%2Fpair%3Fcode%3DFROMTHEFRAGMENT' \
        > "$dir/.claude-dev/run/orca-web-url.txt"

    run run_pairing_url_of "$dir"
    [ "$status" -eq 0 ]
    [ "$output" = "orca://pair?code=FROMTHEFILE" ]

    # A pairing file that is not a pairing URL at all (a truncated write, a
    # stale placeholder) is not trusted: the fragment still answers.
    printf '%s\n' 'not a url' > "$dir/.claude-dev/run/orca-pairing-url.txt"
    run run_pairing_url_of "$dir"
    [ "$status" -eq 0 ]
    [ "$output" = "orca://pair?code=FROMTHEFRAGMENT" ]
}

@test "pairing_url_of decodes the #pairing= fragment of run/orca-web-url.txt" {
    local dir="$BATS_TEST_TMPDIR/pair2"
    pairing_fixture "$dir"

    # A real fragment: the whole URL percent-encoded, base64url payload and
    # its `=` padding included (%3D), which is what makes a plain `tr` or a
    # `${x//%2F//}` pass wrong and a proper decode necessary.
    printf '%s\n' \
        'http://127.0.0.1:5173/web-index.html#pairing=orca%3A%2F%2Fpair%3Fcode%3DeyJ2IjoyLCJzY29wZSI6InJ1bnRpbWUifQ%3D%3D' \
        > "$dir/.claude-dev/run/orca-web-url.txt"

    run run_pairing_url_of "$dir"
    [ "$status" -eq 0 ]
    [ "$output" = 'orca://pair?code=eyJ2IjoyLCJzY29wZSI6InJ1bnRpbWUifQ==' ]
}

@test "pairing_url_of fails with empty output when neither file yields an orca://pair URL" {
    local dir="$BATS_TEST_TMPDIR/pair3"

    # Nothing published yet.
    pairing_fixture "$dir"
    run run_pairing_url_of "$dir"
    [ "$status" -eq 1 ]
    [ -z "$output" ]

    # A web URL with no fragment at all.
    printf '%s\n' 'http://127.0.0.1:5173/web-index.html' \
        > "$dir/.claude-dev/run/orca-web-url.txt"
    run run_pairing_url_of "$dir"
    [ "$status" -eq 1 ]
    [ -z "$output" ]

    # A fragment that decodes to something that is not a pairing URL.
    printf '%s\n' \
        'http://127.0.0.1:5173/web-index.html#pairing=http%3A%2F%2Fexample.invalid' \
        > "$dir/.claude-dev/run/orca-web-url.txt"
    run run_pairing_url_of "$dir"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# --- desktop Orca, S2 (claude-orca-8uo.3) --------------------------------
#
# Which of the two UIs a folder runs is a property OF THE FOLDER, decided
# once at register and written into claude-orca.json as `ui`: desktop when
# the Mac has an Orca.app and nothing said otherwise, web in every other
# case. It is a decision, not a probe, so a re-register never revisits it
# -- a folder that was set to web stays web even after the user installs
# the app, and a desktop folder survives the app being moved. The doctor
# reports what it can see of the app either way, and never turns a missing
# desktop Orca into a failing exit code: Orca Web is a complete answer.

# The uname stub answers only what a test pins, and make_project_v3 pins
# Darwin for the bootstrap call alone -- so a case that drives the launcher
# AFTER the install (the doctor) has to pin it for itself.
as_mac() {
    export STUB_UNAME_S=Darwin
    export STUB_UNAME_M=arm64
}

@test "register writes ui desktop when the app is found" {
    as_mac
    make_project_v3 "$PROJECT_DIR" >/dev/null

    [ "$(jq -r '.ui' "$PROJECT_DIR/.claude-dev/claude-orca.json")" = "desktop" ]

    # The same folder re-registered is still desktop: the key is written
    # once and read forever after.
    run bash -c "cd '$PROJECT_DIR' && ./claude-dev register"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.ui' "$PROJECT_DIR/.claude-dev/claude-orca.json")" = "desktop" ]
}

@test "register leaves an existing ui key alone" {
    as_mac
    make_project_v3 "$PROJECT_DIR" >/dev/null
    config="$PROJECT_DIR/.claude-dev/claude-orca.json"

    # The counterfactual first, so "left alone" is not a property of a
    # register that never writes the key at all: a config with no ui key
    # (a folder carried over from before this template had one) gets the
    # probe's answer written into it.
    jq 'del(.ui)' "$config" > "$config.t" && mv "$config.t" "$config"
    run bash -c "cd '$PROJECT_DIR' && ./claude-dev register"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.ui' "$config")" = "desktop" ]

    # A folder deliberately pinned to Orca Web, on a Mac that has the app:
    # the probe would say desktop, and the folder's own answer wins.
    jq '.ui = "web"' "$config" > "$config.t" && mv "$config.t" "$config"
    run bash -c "cd '$PROJECT_DIR' && ./claude-dev register"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.ui' "$config")" = "web" ]

    # And the other way: a desktop folder whose app has gone stays desktop
    # rather than being quietly demoted behind the user's back.
    jq '.ui = "desktop"' "$config" > "$config.t" && mv "$config.t" "$config"
    run bash -c "cd '$PROJECT_DIR' \
        && CLAUDE_ORCA_APP='$BATS_TEST_TMPDIR/no-such-Orca.app' ./claude-dev register"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.ui' "$config")" = "desktop" ]
}

@test "doctor prints the orca app row with its version" {
    as_mac
    make_project_v3 "$PROJECT_DIR" >/dev/null

    run bash -c "cd '$PROJECT_DIR' && ./claude-dev --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"orca app"* ]]
    [[ "$output" == *"$CLAUDE_ORCA_APP (1.4.197)"* ]]
    [[ "$output" == *"orca cli"* ]]
    [[ "$output" == *"$CLAUDE_ORCA_APP/Contents/Resources/bin/orca"* ]]
}

@test "doctor prints the orca app row missing when there is no app" {
    as_mac
    # A folder that registered as web, on a Mac with no Orca.app: both rows
    # still print, and neither is a finding -- Orca Web needs no app.
    export CLAUDE_ORCA_UI=web
    make_project_v3 "$PROJECT_DIR" >/dev/null
    [ "$(jq -r '.ui' "$PROJECT_DIR/.claude-dev/claude-orca.json")" = "web" ]

    export CLAUDE_ORCA_APP="$BATS_TEST_TMPDIR/no-such-Orca.app"
    run bash -c "cd '$PROJECT_DIR' && ./claude-dev --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" =~ orca[[:space:]]app[[:space:]]+missing ]]
}

# --- desktop Orca, S3 (claude-orca-8uo.4) --------------------------------
#
# With `ui = desktop` the hand-off stops being a browser tab. The launcher
# launches the Mac's own Orca.app, waits for its runtime to answer, saves
# this folder's container as a named environment through the app's own
# CLI, and prints the pane to pick it in. Three facts from the probe (bead
# claude-orca-8uo.1) shape all of it: `orca status --json` exits 0 whether
# the runtime is reachable or not, so the boolean in the JSON is the only
# signal; a second `environment add` under a name that already exists is
# refused outright, so the stale one goes first; and no `orca://` protocol
# handler is registered, so the app is launched by bundle (`open -a`) and
# paired through the CLI.
#
# The CLI is stubbed at the path orca_cli() resolves -- the app bundle's
# own Contents/Resources/bin/orca -- and logs its argv, one line per call.

DESKTOP_PAIR_URL='orca://pair?code=eyJ2IjoyLCJzY29wZSI6InJ1bnRpbWUifQ=='
DESKTOP_PAIR_FRAGMENT='orca%3A%2F%2Fpair%3Fcode%3DeyJ2IjoyLCJzY29wZSI6InJ1bnRpbWUifQ%3D%3D'

# A registered folder with its container up, on a Mac whose Orca.app has a
# CLI that answers, and a pairing offer published the way an image that
# carries S1 publishes it. Prints the project path; leaves both logs empty
# so a case asserts about its own `./claude-dev open` and not about the
# register that set the folder up.
desktop_fixture() {
    local primary
    as_mac
    write_stub_orca "$CLAUDE_ORCA_APP/Contents/Resources/bin/orca"
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null
    printf '%s\n' "$DESKTOP_PAIR_URL" \
        > "$primary/.claude-dev/run/orca-pairing-url.txt"
    : > "$ORCA_STUB_LOG"
    : > "$OPEN_STUB_LOG"
    printf '%s\n' "$primary"
}

# --- one installed Orca.app, never a second one (claude-orca-tgr) --------
#
# claude-orca-qhq's answer to Orca.app opening LOCAL workspaces (agents run
# on the Mac, no container) was a private per-folder profile -- but that
# opens a SECOND instance of the app, which is worse: there must be
# exactly one Orca, the installed one, no exception. So this enforces the
# invariant on THAT app instead: the launcher removes this folder from its
# own project list before handing over the runtime (only ever safe while
# the app is not running), and self-heals -- quit, strip, relaunch, once --
# when the app was already up and already held it.

@test "open with ui desktop launches the single installed app without -n, --args or a private profile" {
    local primary
    primary="$(desktop_fixture)"
    # The default: the app is not running yet, so this run is the one
    # that launches it -- plain `open -a <bundle>`, nothing else.

    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    grep -qxF -- "-a $CLAUDE_ORCA_APP" "$OPEN_STUB_LOG"
    [ "$(wc -l < "$OPEN_STUB_LOG")" -eq 1 ]
    [ ! -e "$primary/.claude-dev/state/orca-profile" ]

    grep -qF "Remote Hosts" <<< "$output"
}

@test "open with ui desktop strips this folder's local project from orca-data.json while the app is not running, leaving other repos and keys intact" {
    local primary
    primary="$(desktop_fixture)"
    # The app is not running (the default) -- an earlier session, or the
    # app's own "+ Add project", already left this folder AND another
    # project in its persisted store, alongside a key of the app's own
    # that has nothing to do with any of this.
    mkdir -p "$ORCA_STUB_DATA_DIR"
    printf '{"repos":[{"path":"%s"},{"path":"/Users/joe/some-other-project"}],"windowState":{"x":100}}\n' \
        "$primary" > "$ORCA_STUB_DATA_DIR/orca-data.json"

    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    [ "$(jq --arg d "$primary" '.repos | map(select(.path == $d)) | length' "$ORCA_STUB_DATA_DIR/orca-data.json")" = "0" ]
    [ "$(jq -r '.repos[] | select(.path == "/Users/joe/some-other-project") | .path' "$ORCA_STUB_DATA_DIR/orca-data.json")" = "/Users/joe/some-other-project" ]
    [ "$(jq -r '.windowState.x' "$ORCA_STUB_DATA_DIR/orca-data.json")" = "100" ]
}

# --- self-heal when the app already holds this folder locally ------------
#
# The strip above only runs while the app is not running -- orca-data.json
# is the app's own on-disk state. When the app was already up (or the
# strip raced its own "+ Add project"), the only way left to remove this
# folder from it is to quit the one installed Orca, strip, and relaunch it,
# once; a leak that survives that gets no second try -- the folder falls
# back to Orca Web instead, so it stays sandboxed either way.

@test "open with ui desktop quits, strips and relaunches the app when it is running and holds this folder locally" {
    local primary
    primary="$(desktop_fixture)"
    export ORCA_STUB_APP_RUNNING=true
    mkdir -p "$ORCA_STUB_DATA_DIR"
    printf '{"repos":[{"path":"%s"},{"path":"/Users/joe/some-other-project"}]}\n' \
        "$primary" > "$ORCA_STUB_DATA_DIR/orca-data.json"
    # The precondition the quit is now gated on: the store the launcher
    # would rewrite has to name this folder, and while the app is running
    # the way it finds that store is the app's own open files.
    export ORCA_STUB_LSOF_DIR="$ORCA_STUB_DATA_DIR"

    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    # Quit by name, through the GUI scripting bridge -- the only way with
    # no `orca://` protocol handler -- then a single relaunch, not a
    # second instance.
    grep -qF "tell application \"$(basename "$CLAUDE_ORCA_APP" .app)\" to quit" "$OSASCRIPT_STUB_LOG"
    # ... and guarded on the app already running: an unguarded `quit`
    # LAUNCHES the app when it is not running (AppleScript semantics).
    grep -qF "is running" "$OSASCRIPT_STUB_LOG"
    [ "$(wc -l < "$OSASCRIPT_STUB_LOG")" -eq 1 ]
    [ "$(grep -c -- "-a $CLAUDE_ORCA_APP" "$OPEN_STUB_LOG")" -eq 1 ]

    # ... and the relaunch reads back a store this folder is gone from,
    # while the other project the app also held is untouched.
    [ "$(jq --arg d "$primary" '.repos | map(select(.path == $d)) | length' "$ORCA_STUB_DATA_DIR/orca-data.json")" = "0" ]
    [ "$(jq -r '.repos[] | select(.path == "/Users/joe/some-other-project") | .path' "$ORCA_STUB_DATA_DIR/orca-data.json")" = "/Users/joe/some-other-project" ]

    # The hand-off finished: an environment was saved and the app is shown
    # attached, not sent to the browser.
    [ -s "$primary/.claude-dev/run/orca-environment.json" ]
    grep -qF "Remote Hosts" <<< "$output"
}

@test "open with ui desktop falls back to Orca Web when the app still holds this folder locally after the relaunch" {
    local primary url
    primary="$(desktop_fixture)"
    export ORCA_STUB_APP_RUNNING=true
    # No ORCA_STUB_DATA_DIR fixture: a plain answer that stays the same no
    # matter what gets stripped, standing in for an app that keeps
    # re-adding this folder mid-relaunch -- exactly the leak a single
    # self-heal cannot fix.
    export ORCA_STUB_LOCAL_REPOS="$primary"
    # The store the launcher rewrites is a DIFFERENT file from the one the
    # CLI stub answers out of, so the strip lands (the quit's precondition
    # is met and orca-data.json really does stop naming the folder) and
    # the app goes on claiming it anyway.
    export ORCA_USER_DATA_PATH="$BATS_TEST_TMPDIR/mac-orca-data"
    mkdir -p "$ORCA_USER_DATA_PATH"
    printf '{"repos":[{"path":"%s"}]}\n' "$primary" \
        > "$ORCA_USER_DATA_PATH/orca-data.json"

    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    # One quit, one relaunch -- "self-heal ONCE", not a retry loop.
    [ "$(wc -l < "$OSASCRIPT_STUB_LOG")" -eq 1 ]
    [ "$(grep -c -- "-a $CLAUDE_ORCA_APP" "$OPEN_STUB_LOG")" -eq 1 ]

    # It gave up on the app and opened the browser instead -- the folder
    # stays sandboxed either way -- and saved no environment.
    url="$(head -1 "$primary/.claude-dev/run/orca-web-url.txt")"
    [ "$(tail -1 "$OPEN_STUB_LOG")" = "$url" ]
    grep -qF "Orca Web" <<< "$output"
    [ ! -e "$primary/.claude-dev/run/orca-environment.json" ]
}

# --- the quit is a last resort, and it is earned ------------------------
#
# Quitting the user's Orca is the most destructive thing this launcher
# does (their open windows, their running agents), and the hand-off used
# to do it on nothing more than `repo list` saying "local" -- then strip a
# file that may never have named the folder, relaunch, find it still
# local, and fall back to the browser anyway. Two checks make it earned:
# the store the strip rewrites has to name the folder BEFORE anything is
# quit, and the strip has to have landed before the app is launched.

@test "open with ui desktop never quits the app when orca-data.json does not name this folder" {
    local primary url data
    primary="$(desktop_fixture)"
    export ORCA_STUB_APP_RUNNING=true
    # The app says this folder is a local project of its own...
    export ORCA_STUB_LOCAL_REPOS="$primary"
    # ... and the store the launcher would rewrite to fix that does not
    # mention it, so no rewrite it could do would change the answer.
    data="$BATS_TEST_TMPDIR/mac-orca-data"
    mkdir -p "$data"
    export ORCA_USER_DATA_PATH="$data"
    printf '{"repos":[{"path":"/Users/joe/some-other-project"}]}\n' \
        > "$data/orca-data.json"

    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    # Not one quit: the app keeps whatever the user had open.
    ! grep -qF "to quit" "$OSASCRIPT_STUB_LOG"
    # It says which file it read and what to do by hand instead.
    grep -qF "$data/orca-data.json" <<< "$output"
    grep -qF "does not name it" <<< "$output"
    grep -qF "Remove" <<< "$output"

    # ... and the folder still ends up sandboxed, in the browser.
    url="$(head -1 "$primary/.claude-dev/run/orca-web-url.txt")"
    [ "$(tail -1 "$OPEN_STUB_LOG")" = "$url" ]
    grep -qF "opening Orca Web instead" <<< "$output"
    [ ! -e "$primary/.claude-dev/run/orca-environment.json" ]
}

@test "open with ui desktop never launches the app when the strip could not land" {
    local primary url data
    if [ "$(id -u)" -eq 0 ]; then
        skip "a read-only directory does not stop root from writing in it"
    fi
    primary="$(desktop_fixture)"
    # The app is not running (the default) and its store holds this
    # folder -- but the store cannot be rewritten, so the rename+mv the
    # strip ends with fails and the folder is still listed afterwards.
    data="$BATS_TEST_TMPDIR/mac-orca-data"
    mkdir -p "$data"
    export ORCA_USER_DATA_PATH="$data"
    printf '{"repos":[{"path":"%s"}]}\n' "$primary" > "$data/orca-data.json"
    chmod 555 "$data"

    run bash -c "cd '$primary' && ./claude-dev open"
    chmod 755 "$data"
    [ "$status" -eq 0 ]

    grep -qF "still lists" <<< "$output"
    grep -qF "opening Orca Web instead" <<< "$output"

    # The whole point: no app was started. A launch here would open the
    # one thing this run cannot take back -- a local, unsandboxed
    # workspace on this folder.
    ! grep -q -- "-a $CLAUDE_ORCA_APP" "$OPEN_STUB_LOG"
    url="$(head -1 "$primary/.claude-dev/run/orca-web-url.txt")"
    [ "$(tail -1 "$OPEN_STUB_LOG")" = "$url" ]
    [ ! -e "$primary/.claude-dev/run/orca-environment.json" ]
}

@test "open with ui desktop falls back to Orca Web without a quit when the launched app re-adds this folder" {
    local primary url data
    primary="$(desktop_fixture)"
    # The app is not running, the store names this folder, and the strip
    # lands (the file really does stop naming it) -- and the app claims it
    # again the moment it starts. The old flow answered that with a quit
    # of the app it had just launched, which is how "./claude-dev opens
    # Orca and it quits again" happened.
    data="$BATS_TEST_TMPDIR/mac-orca-data"
    mkdir -p "$data"
    export ORCA_USER_DATA_PATH="$data"
    printf '{"repos":[{"path":"%s"}]}\n' "$primary" > "$data/orca-data.json"
    export ORCA_STUB_LOCAL_REPOS="$primary"

    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    # The strip did land, on the file the launcher was pointed at.
    [ "$(jq --arg d "$primary" '.repos | map(select(.path == $d)) | length' "$data/orca-data.json")" = "0" ]
    # The app was launched exactly once and never quit.
    [ "$(grep -c -- "-a $CLAUDE_ORCA_APP" "$OPEN_STUB_LOG")" -eq 1 ]
    [ ! -s "$OSASCRIPT_STUB_LOG" ]

    grep -qF "re-added this folder as a LOCAL project" <<< "$output"
    url="$(head -1 "$primary/.claude-dev/run/orca-web-url.txt")"
    [ "$(tail -1 "$OPEN_STUB_LOG")" = "$url" ]
    [ ! -e "$primary/.claude-dev/run/orca-environment.json" ]
}

@test "desktop cli calls carry no ORCA_USER_DATA_PATH override" {
    local primary
    primary="$(desktop_fixture)"

    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    [ -s "$ORCA_STUB_ENVPATH_LOG" ]
    # Every call this hand-off made carried none at all.
    ! grep -q . "$ORCA_STUB_ENVPATH_LOG"
}

@test "open with ui desktop adds the environment with the decoded pairing URL and records its id" {
    local primary name envfile
    primary="$(desktop_fixture)"
    name="remote-$(basename "$primary")"

    # The fragment path, not the file: a folder whose image predates
    # run/orca-pairing-url.txt still has the offer, percent-encoded in the
    # web URL Orca published. What reaches `environment add` is the
    # decoded URL, base64url padding and all.
    rm -f "$primary/.claude-dev/run/orca-pairing-url.txt"
    printf 'http://127.0.0.1:6768/web-index.html#pairing=%s\n' "$DESKTOP_PAIR_FRAGMENT" \
        > "$primary/.claude-dev/run/orca-web-url.txt"
    : > "$ORCA_STUB_LOG"

    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    grep -qxF \
        "environment add --name $name --pairing-code $DESKTOP_PAIR_URL --json" \
        "$ORCA_STUB_LOG"

    # The id the app gave back is a Mac-side result, so it lands in run/.
    envfile="$primary/.claude-dev/run/orca-environment.json"
    [ -s "$envfile" ]
    [ "$(jq -r '.id' "$envfile")" = "68b6f2e5-1111-2222-3333-444455556666" ]
    [ "$(jq -r '.name' "$envfile")" = "$name" ]
}

@test "open with ui desktop removes an existing environment of the same name before adding" {
    local primary name rm_line add_line
    primary="$(desktop_fixture)"
    name="remote-$(basename "$primary")"

    # A folder opened once before: the app already has an environment of
    # this name, saved against the PREVIOUS container's pairing offer. A
    # recreated container mints a new one, and a second add under the same
    # name is refused ("A server named ... already exists."), so the stale
    # environment goes first.
    printf '%s\n' "$name" > "$ORCA_STUB_STATE/environments"
    : > "$ORCA_STUB_LOG"

    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    rm_line="$(grep -n "^environment rm --environment $name --json$" "$ORCA_STUB_LOG" | head -1 | cut -d: -f1)"
    add_line="$(grep -n "^environment add --name $name " "$ORCA_STUB_LOG" | head -1 | cut -d: -f1)"
    [ -n "$rm_line" ]
    [ -n "$add_line" ]
    [ "$rm_line" -lt "$add_line" ]

    # ... and the add went through rather than being refused.
    [ -s "$primary/.claude-dev/run/orca-environment.json" ]
}

@test "open with ui desktop also removes the environment saved under the old container name before adding" {
    local primary legacy_name rm_line add_line
    primary="$(desktop_fixture)"
    # The name this folder was saved under before the badge rename. A
    # folder opened once under it still has that environment in the app,
    # pointed at a container offer that no longer exists -- leaving it
    # there is a second, dead entry under the same project.
    legacy_name="claude-orca-$(basename "$primary")"
    printf '%s\n' "$legacy_name" > "$ORCA_STUB_STATE/environments"
    : > "$ORCA_STUB_LOG"

    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    rm_line="$(grep -n "^environment rm --environment $legacy_name --json$" "$ORCA_STUB_LOG" | head -1 | cut -d: -f1)"
    add_line="$(grep -n "^environment add --name remote-$(basename "$primary") " "$ORCA_STUB_LOG" | head -1 | cut -d: -f1)"
    [ -n "$rm_line" ]
    [ -n "$add_line" ]
    [ "$rm_line" -lt "$add_line" ]

    # The old name is gone from the app, and only the new one is saved.
    ! grep -qxF "$legacy_name" "$ORCA_STUB_STATE/environments"
    grep -qxF "remote-$(basename "$primary")" "$ORCA_STUB_STATE/environments"
}

@test "open with ui desktop copies the pairing URL to the clipboard when environment add fails" {
    local primary name
    export ORCA_STUB_ADD_FAIL=1
    primary="$(desktop_fixture)"
    name="remote-$(basename "$primary")"

    run bash -c "cd '$primary' && ./claude-dev open"
    # The container is up and the app is running either way: a hand-off
    # the CLI could not finish is something to tell the user how to
    # finish by hand, not a failed open.
    [ "$status" -eq 0 ]

    [ "$(cat "$PBCOPY_STUB_LOG")" = "$DESKTOP_PAIR_URL" ]
    grep -qF "clipboard" <<< "$output"
    grep -qF "Remote Hosts" <<< "$output"

    # Nothing was saved, so nothing claims it was.
    [ ! -e "$primary/.claude-dev/run/orca-environment.json" ]
}

@test "open with ui web opens the URL in the browser and never calls orca" {
    local primary url config
    primary="$(desktop_fixture)"
    config="$primary/.claude-dev/claude-orca.json"

    # The same Mac, the same app, the same pairing offer -- and a folder
    # that says it is a browser folder. Today's open runs untouched.
    jq '.ui = "web"' "$config" > "$config.t" && mv "$config.t" "$config"
    : > "$ORCA_STUB_LOG"
    : > "$OPEN_STUB_LOG"

    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    url="$(head -1 "$primary/.claude-dev/run/orca-web-url.txt")"
    [ "$(tail -1 "$OPEN_STUB_LOG")" = "$url" ]
    [ ! -s "$ORCA_STUB_LOG" ]
    grep -qF "open in a browser" <<< "$output"
}

@test "teardown removes the environment and leaves no profile dir behind" {
    local primary name legacy
    primary="$(desktop_fixture)"
    name="remote-$(basename "$primary")"
    # A profile left behind by claude-orca-qhq (4a1882c), before that
    # decision was reversed.
    legacy="$primary/.claude-dev/state/orca-profile"
    mkdir -p "$legacy"
    printf 'stale\n' > "$legacy/orca-data.json"

    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]
    [ -s "$primary/.claude-dev/run/orca-environment.json" ]
    # The hand-off's own migration cleanup already took it at open time.
    [ ! -e "$legacy" ]

    # A fresh log, so the rm asserted below is teardown's own and not the
    # remove-first the open above did.
    : > "$ORCA_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev --teardown"
    [ "$status" -eq 0 ]

    grep -qxF "environment rm --environment $name --json" "$ORCA_STUB_LOG"
    # ... and the app no longer offers a runtime that does not exist.
    ! grep -qxF "$name" "$ORCA_STUB_STATE/environments"
    [ ! -e "$legacy" ]
}

@test "verify reads local repos from orca-data.json when the app is not running" {
    local primary
    as_mac
    write_stub_orca "$CLAUDE_ORCA_APP/Contents/Resources/bin/orca"
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null

    # The app is not running (the stub's default) -- the only way left to
    # ask is the store it persists, not a CLI call.
    mkdir -p "$ORCA_STUB_DATA_DIR"
    printf '{"repos":[]}\n' > "$ORCA_STUB_DATA_DIR/orca-data.json"
    run bash -c "cd '$primary' && ./claude-dev verify"
    [ "$status" -eq 0 ]
    grep -qF "orca-data.json" <<< "$output"
    grep -qF "does not track" <<< "$output"

    printf '{"repos":[{"path":"%s"}]}\n' "$primary" > "$ORCA_STUB_DATA_DIR/orca-data.json"
    run bash -c "cd '$primary' && ./claude-dev verify"
    [ "$status" -eq 2 ]
    grep -qF "FAIL" <<< "$output"
    grep -qF "orca-data.json" <<< "$output"
    grep -qF "LOCAL repo" <<< "$output"
}

# --- desktop Orca, S4 (claude-orca-8uo.5) --------------------------------
#
# The image is built at the app's Orca version and carries it in its tag,
# so the two normally agree by construction. They come apart in one real
# way: the user upgrades Orca.app and this folder has not rebuilt yet --
# the ref it now wants does not exist and the image on this machine is the
# old one. Orca refuses a protocol mismatch outright, so the doctor says
# so. A warning and not a finding: the folder still opens (on Orca Web if
# nothing else), and one ./claude-dev --update fixes it.
@test "doctor flags an app/image version mismatch" {
    as_mac
    export CLAUDE_ORCA_APP="$(make_fake_orca_app "$BATS_TEST_TMPDIR/Applications/Orca9.app" 9.9.9)"
    make_project_v3 "$PROJECT_DIR" >/dev/null

    # What this machine actually holds under our repo: an image built at
    # the older version, which is what the tag says.
    printf '%s\n' "claude-orca latest-orca1.4.197 sha256:aaaaaaaaaaaa" \
        > "$CONTAINER_STUB_STATE/images-list"

    run bash -c "cd '$PROJECT_DIR' && ./claude-dev --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"orca versions"* ]]
    [[ "$output" == *"9.9.9"* ]]
    [[ "$output" == *"1.4.197"* ]]
    [[ "$output" =~ \[warn[[:space:]]*\][[:space:]]+orca[[:space:]]versions ]]
    [[ "$output" == *"--update"* ]]

    # The same folder once the rebuild has happened: one row, agreeing,
    # and no warning -- so the row above is about the versions and not
    # about having an app at all.
    printf '%s\n' "claude-orca latest-orca9.9.9 sha256:bbbbbbbbbbbb" \
        > "$CONTAINER_STUB_STATE/images-list"
    run bash -c "cd '$PROJECT_DIR' && ./claude-dev --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"orca versions"* ]]
    [[ "$output" =~ \[ok[[:space:]]*\][[:space:]]+orca[[:space:]]versions ]]
    [[ ! "$output" =~ \[warn[[:space:]]*\][[:space:]]+orca[[:space:]]versions ]]
}
