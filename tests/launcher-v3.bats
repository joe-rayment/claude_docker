#!/usr/bin/env bats
#
# Acceptance contract for claude-orca-qa2.2 (v3 S2, the Mac half) --
# FROZEN from RED-AT onward.
#
# v3 replaces the Seatbelt install with one Linux VM per project: the Mac
# side only has to preflight Apple's `container` CLI, seed the folder, pull
# the pinned image, run the container with the project and the folder-local
# home mounted, and open the pairing URL the entrypoint publishes. Nothing
# here needs a Mac: `container`, `open`, `sw_vers` and `uname` are stubbed
# by tests/helpers/setup.bash, and the `container` stub stands in for the
# entrypoint by writing run/orca-web-url.txt when it is asked to `run`.
#
# See .claude/plans/container-v3.md S5 and scripts/container/entrypoint.sh
# (the env contract asserted in case 3: PROJECT_DIR, ORCA_PORT, HOST_UID,
# GH_TOKEN in, run/orca-web-url.txt and run/port out).

load helpers/setup

STUB_TOKEN="gho_stubfaketoken0123456789abcdef"

# The one line the `container` stub logged for the invocation whose argv
# starts with $1 (its log is one line per invocation, argv joined).
ctr_line() {
    grep "^$1" "$CONTAINER_STUB_LOG" | head -1
}

@test "bootstrap preflight requires macOS 26 on Apple silicon and the container CLI, starts the container service, and never installs brew, srt or a DMG" {
    export STUB_UNAME_S=Darwin
    export STUB_UNAME_M=arm64

    # Not a Mac at all.
    export STUB_UNAME_S=Linux
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"macOS 26"* ]]
    [ ! -e "$PROJECT_DIR/.claude-dev" ]
    export STUB_UNAME_S=Darwin

    # An Intel Mac: Apple's container CLI is Apple-silicon only.
    export STUB_UNAME_M=x86_64
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Apple silicon"* ]]
    [ ! -e "$PROJECT_DIR/.claude-dev" ]
    export STUB_UNAME_M=arm64

    # A Mac too old for `container`.
    export CLAUDE_ORCA_TEST_MACOS=15.5
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"macOS 26"* ]]
    [ ! -e "$PROJECT_DIR/.claude-dev" ]
    unset CLAUDE_ORCA_TEST_MACOS

    # No container CLI: the preflight installs Apple's signed .pkg for you
    # and carries on in the same run.
    export STUB_CONTAINER_SRC="$BATS_TEST_TMPDIR/container-stub"
    mv "$STUB_BIN/container" "$STUB_CONTAINER_SRC"
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    grep -q "^sudo installer -pkg " "$STUB_LOG"
    [ -x "$STUB_BIN/container" ]

    # And the whole preflight, passing: the service is started, the
    # template is cloned, and not one v2 install step runs.
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    grep -q "^system start" "$CONTAINER_STUB_LOG"
    grep "^system start" "$CONTAINER_STUB_LOG" | head -1 | grep -q -- "--enable-kernel-install"

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

@test "register seeds claude-orca.json, the home gitconfig and a port, logs in to ghcr and pulls the pinned image, falling back to container build when the pull fails" {
    git config --global user.name "Test User"
    git config --global user.email "test@example.com"

    mkdir -p "$PROJECT_DIR"
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

    grep -q "Test User" "$primary/.claude-dev/home/.gitconfig"
    grep -q "test@example.com" "$primary/.claude-dev/home/.gitconfig"

    # The registry login: username in argv, token on stdin and nowhere else.
    login="$(ctr_line "registry login")"
    [[ "$login" == *"ghcr.io"* ]]
    [[ "$login" == *"joe-rayment"* ]]
    [[ "$login" == *"--password-stdin"* ]]
    [[ "$login" != *"$STUB_TOKEN"* ]]
    [ "$(cat "$CONTAINER_STUB_STATE/registry-password")" = "$STUB_TOKEN" ]

    # The image ref is pinned by the template's own IMAGE_TAG file.
    [ -f "$REPO_ROOT/IMAGE_TAG" ]
    tag="$(cat "$primary/.claude-dev/template/IMAGE_TAG")"
    [ -n "$tag" ]
    grep -qF "image pull ghcr.io/joe-rayment/claude_orca:$tag" "$CONTAINER_STUB_LOG"
    ! grep -q "^build " "$CONTAINER_STUB_LOG"

    # A pull that fails falls back to building the image from the folder's
    # own template clone.
    export CLAUDE_ORCA_TEST_PULL_FAIL=1
    : > "$CONTAINER_STUB_LOG"
    mkdir -p "$BATS_TEST_TMPDIR/project2"
    second="$(abspath "$BATS_TEST_TMPDIR/project2")"
    run make_project_v3 "$second"
    [ "$status" -eq 0 ]

    grep -q "^image pull " "$CONTAINER_STUB_LOG"
    build="$(ctr_line "build ")"
    [[ "$build" == *"-t ghcr.io/joe-rayment/claude_orca:$tag"* ]]
    [[ "$build" == *"-f $second/.claude-dev/template/Dockerfile"* ]]
}

@test "open runs the container with the project and home mounted at the same paths, the port published on 127.0.0.1, PROJECT_DIR/ORCA_PORT/HOST_UID/GH_TOKEN in the environment, waits for run/orca-web-url.txt and opens it" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    port="$(cat "$primary/.claude-dev/run/port")"
    name="claude-orca-$(basename "$primary")"

    line="$(ctr_line "run ")"
    [[ "$line" == *" -d "* ]]
    [[ "$line" == *"--name $name"* ]]
    [[ "$line" == *"--volume $primary:$primary"* ]]
    [[ "$line" == *"--volume $primary/.claude-dev/home:/home/agent"* ]]
    [[ "$line" == *"-p 127.0.0.1:$port:$port"* ]]
    [[ "$line" == *"-e PROJECT_DIR=$primary"* ]]
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

@test "open on an existing container starts it when stopped and only opens the URL when running; stop, shell and logs call container with the project name" {
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
    [[ "$shell_line" == *"--workdir $primary"* ]]

    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev logs"
    [ "$status" -eq 0 ]
    grep -qx "logs -f $name" "$CONTAINER_STUB_LOG"
}

@test "doctor reports the container CLI, service, image, container state, port and web url and exits 2 on a finding; teardown stops and removes the container and the install" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null
    name="claude-orca-$(basename "$primary")"
    port="$(cat "$primary/.claude-dev/run/port")"

    run bash -c "cd '$primary' && ./claude-dev --doctor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"container CLI"* ]]
    [[ "$output" == *"container service"* ]]
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
