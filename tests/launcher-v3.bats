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

    # The registry login: username in argv, token on stdin and nowhere else.
    login="$(ctr_line "login ")"
    [[ "$login" == *"ghcr.io"* ]]
    [[ "$login" == *"joe-rayment"* ]]
    [[ "$login" == *"--password-stdin"* ]]
    [[ "$login" != *"$STUB_TOKEN"* ]]
    [ "$(cat "$CONTAINER_STUB_STATE/registry-password")" = "$STUB_TOKEN" ]

    # The image ref is pinned by the template's own IMAGE_TAG file.
    [ -f "$REPO_ROOT/IMAGE_TAG" ]
    tag="$(cat "$primary/.claude-dev/template/IMAGE_TAG")"
    [ -n "$tag" ]
    grep -qF "pull ghcr.io/joe-rayment/claude_orca:$tag" "$CONTAINER_STUB_LOG"
    ! grep -q "^build " "$CONTAINER_STUB_LOG"
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
    [[ "$line" == *"ghcr.io/joe-rayment/claude_orca:"* ]]

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
    [[ "$output" == *"ghcr.io/joe-rayment/claude_orca:"* ]]
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
