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
# the entrypoint by writing run/sshd.ready when it is asked to `run`.
#
# See .claude/plans/container-v3.md S5 and scripts/container/entrypoint.sh
# (the env contract asserted in case 3: PROJECT_DIR, CLAUDE_ORCA_SSHD_PORT,
# HOST_UID, GH_TOKEN in, run/sshd.ready and run/port out).

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

@test "open runs the container with the project at /workspace/<name> and the home at /home/agent, the port published on 127.0.0.1, PROJECT_DIR/CLAUDE_ORCA_SSHD_PORT/HOST_UID/GH_TOKEN/BEADS_DIR in the environment and no ORCA_PORT, waits for run/sshd.ready and opens no URL" {
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
    # The published port is sshd's; nothing else listens on a second one.
    [[ "$line" == *"-e CLAUDE_ORCA_SSHD_PORT=$port"* ]]
    [[ "$line" != *"ORCA_PORT="* ]]
    [[ "$line" == *"-e HOST_UID=$(id -u)"* ]]
    [[ "$line" == *"-e GH_TOKEN=$STUB_TOKEN"* ]]
    [[ "$line" == *"claude-orca:"* ]]

    # The entrypoint's side of the contract, faked by the stub: run/sshd.ready
    # appears and the launcher waits for it. Nothing opens a URL any more:
    # the pane is an ssh session, so the open stub is never called.
    [ -s "$primary/.claude-dev/run/sshd.ready" ]
    [ ! -s "$OPEN_STUB_LOG" ]

    # And the hand-off: sshd came up, and (no terminal under bats) how to
    # get the pane.
    [[ "$output" == *"sshd is up"* ]]
    [[ "$output" == *"ready: run ./claude-dev pane in a terminal"* ]]
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

@test "open on an existing container starts it when stopped and only waits for sshd when running; stop, shell and logs call docker with the project name" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null
    name="claude-orca-$(basename "$primary")"

    # Already running: no second container, no start, just sshd answering.
    : > "$CONTAINER_STUB_LOG"
    : > "$OPEN_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]
    ! grep -q "^run " "$CONTAINER_STUB_LOG"
    ! grep -q "^start " "$CONTAINER_STUB_LOG"
    [[ "$output" == *"sshd is up"* ]]
    [ ! -s "$OPEN_STUB_LOG" ]

    # Stopped: started, never recreated.
    printf 'stopped\n' > "$CONTAINER_STUB_STATE/containers/$name"
    : > "$CONTAINER_STUB_LOG"
    : > "$OPEN_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]
    grep -qx "start $name" "$CONTAINER_STUB_LOG"
    ! grep -q "^run " "$CONTAINER_STUB_LOG"
    [[ "$output" == *"sshd is up"* ]]
    [ ! -s "$OPEN_STUB_LOG" ]

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

@test "doctor reports the docker CLI, daemon, image, container state, port and sshd and exits 2 on a finding; teardown stops and removes the container and the install" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    make_project_v3 "$primary" >/dev/null
    name="claude-orca-$(basename "$primary")"
    port="$(cat "$primary/.claude-dev/run/port")"
    stub_sshd_up "$primary"

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
    [[ "$output" == *"sshd"* ]]

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
    stub_sshd_up "$primary"

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

# --- the old Orca "ui" key ----------------------------------------------
#
# Folders registered while Orca was the UI carry `"ui": "desktop"|"web"` in
# claude-orca.json. Nothing reads it any more; register must neither pick a
# new one nor rewrite (or drop) the one an old folder has.
# Guards:   register writes no ui key and leaves an old folder's ui key untouched
# Fails if: register picks or rewrites a ui key (the old desktop/web decision)
# Run:      bats -f 'register ignores an existing ui key' tests/launcher-v3.bats
@test "register ignores an existing ui key and writes none of its own" {
    make_project_v3 "$PROJECT_DIR" >/dev/null
    config="$PROJECT_DIR/.claude-dev/claude-orca.json"

    # A fresh register writes no ui key at all.
    [ "$(jq 'has("ui")' "$config")" = "false" ]

    # An old folder's key is left exactly as it was found, whatever it says.
    jq '.ui = "desktop"' "$config" > "$config.t" && mv "$config.t" "$config"
    run bash -c "cd '$PROJECT_DIR' && ./claude-dev register"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.ui' "$config")" = "desktop" ]
}

# A container by the right name is not proof it is this folder's. A real
# Mac, 2026-09-13: bootstrapping a second folder moved an older
# generation's .claude-dev aside, that generation had used the same
# container name, and `open` adopted what it found -- "Container
# claude-orca-stocks is already running", Orca up in 0s, and a project in
# the app's sidebar that was empty, no shell and no agents, because the app
# was paired to a runtime holding another folder's mounts. Adoption is
# conditional now: image, project mount, home mount and published port.
#
# The `docker` stub records what each container was run from and answers
# `inspect` out of it; DOCKER_STUB_PRESET_CONTAINER fakes one this folder
# never created.
@test "open recreates a running container that was built from a different image" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    name="claude-orca-$(basename "$primary")"
    port="$(cat "$primary/.claude-dev/run/port")"

    # Same folder, same port -- only the image is a stranger's, which is
    # what an older generation of the template leaves behind.
    rm -f "$CONTAINER_STUB_STATE/preset-applied"
    export DOCKER_STUB_PRESET_CONTAINER="$name:claude-orca:old:$primary:$port"
    : > "$CONTAINER_STUB_LOG"
    : > "$OPEN_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    [[ "$output" == *"is not this folder's"* ]]
    [[ "$output" == *"image:"* ]]
    [[ "$output" == *"claude-orca:old"* ]]
    [[ "$output" != *"already running"* ]]

    # Stopped, removed, and only then a container of this folder's own.
    stop_at="$(grep -n "^stop $name\$" "$CONTAINER_STUB_LOG" | head -1 | cut -d: -f1)"
    rm_at="$(grep -n "^rm " "$CONTAINER_STUB_LOG" | head -1 | cut -d: -f1)"
    run_at="$(grep -n "^run .*--name $name" "$CONTAINER_STUB_LOG" | head -1 | cut -d: -f1)"
    [ -n "$stop_at" ]
    [ -n "$rm_at" ]
    [ -n "$run_at" ]
    [ "$stop_at" -lt "$rm_at" ]
    [ "$rm_at" -lt "$run_at" ]

    # A recreate removes the container only. The scratch volumes are keyed
    # by the same container name on purpose and survive it; only --teardown
    # (and --update's one-time cleanup of the old Orca state volume) rm one.
    ! grep -q "^volume rm" "$CONTAINER_STUB_LOG"

    # ...and the open still ends where it always does: sshd answers on the
    # new container and the terminal is told how to get a pane. No URL.
    [[ "$output" == *"sshd is up"* ]]
    [[ "$output" == *"ready: run ./claude-dev pane in a terminal"* ]]
    [ ! -s "$OPEN_STUB_LOG" ]
}

@test "open recreates a running container whose project mount is another folder" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    name="claude-orca-$(basename "$primary")"
    port="$(cat "$primary/.claude-dev/run/port")"
    # This folder's own image, so the image comparison passes and the
    # mount is what the mismatch is about.
    image="$(cat "$CONTAINER_STUB_STATE/image")"

    rm -f "$CONTAINER_STUB_STATE/preset-applied"
    export DOCKER_STUB_PRESET_CONTAINER="$name:$image:/some/other/dir:$port"
    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    [[ "$output" == *"is not this folder's"* ]]
    [[ "$output" == *"mount:"* ]]
    [[ "$output" != *"image:"* ]]
    [[ "$output" != *"already running"* ]]

    rm_at="$(grep -n "^rm " "$CONTAINER_STUB_LOG" | head -1 | cut -d: -f1)"
    run_at="$(grep -n "^run .*--name $name" "$CONTAINER_STUB_LOG" | head -1 | cut -d: -f1)"
    [ -n "$rm_at" ]
    [ -n "$run_at" ]
    [ "$rm_at" -lt "$run_at" ]

    # And the new one mounts THIS folder.
    line="$(ctr_line "run ")"
    [[ "$line" == *"--volume $primary:/workspace/$(basename "$primary")"* ]]
}

@test "open reuses a running container that matches" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    name="claude-orca-$(basename "$primary")"

    : > "$CONTAINER_STUB_LOG"
    : > "$OPEN_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Container $name is already running."* ]]
    [[ "$output" != *"is not this folder's"* ]]
    ! grep -q "^run " "$CONTAINER_STUB_LOG"
    ! grep -q "^stop " "$CONTAINER_STUB_LOG"
    ! grep -q "^rm " "$CONTAINER_STUB_LOG"
    [[ "$output" == *"sshd is up"* ]]
    [ ! -s "$OPEN_STUB_LOG" ]
}

# Guards: container_matches reads this folder's published port from
# .HostConfig.PortBindings, which docker keeps while a container is
# stopped -- .NetworkSettings.Ports is emptied the moment it stops (moby's
# releaseNetwork, daemon/container_operations.go:951) -- so a stopped
# container of this folder's own is started, not recreated.
# Fails if: the port is read from .NetworkSettings.Ports again; the stub
# then answers "port: none" for the stopped container, exactly what real
# docker answers, and open recreates the container instead of starting it.
# Run: bats tests/launcher-v3.bats
@test "open starts a stopped container of this folder's own instead of recreating it" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    name="claude-orca-$(basename "$primary")"

    # The container this folder created, now stopped -- what real docker
    # reports for it, and the state under which .NetworkSettings.Ports is
    # empty and .HostConfig.PortBindings still carries the port.
    printf 'exited\n' > "$CONTAINER_STUB_STATE/containers/$name"
    : > "$CONTAINER_STUB_LOG"
    : > "$OPEN_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]

    [[ "$output" == *"==> Starting $name (was exited)"* ]]
    [[ "$output" != *"recreating"* ]]
    [[ "$output" != *"is not this folder's"* ]]
    [[ "$output" != *"port: none"* ]]
    grep -qx "start $name" "$CONTAINER_STUB_LOG"
    ! grep -q "^run " "$CONTAINER_STUB_LOG"
    ! grep -q "^rm " "$CONTAINER_STUB_LOG"
    ! grep -q "^stop " "$CONTAINER_STUB_LOG"
    [[ "$output" == *"sshd is up"* ]]
    [ ! -s "$OPEN_STUB_LOG" ]
}

# Guards: Docker Desktop spells a Mac bind mount's .Mounts[].Source in its
# own VM's namespace -- the folder the launcher mounts as
# /Users/joe/Documents/Harness test is answered by `docker inspect` as
# /host_mnt/Users/joe/Documents/Harness test (real Mac, 2026-10-03) -- so a
# Source compared exactly as docker reported it never matches and every
# open recreates the container. container_matches must strip that ONE
# /host_mnt prefix before comparing, including when the folder's path
# contains a space, where a "find the substring anywhere" fix goes wrong.
# Fails if: the Source is compared as reported (the first open below
# recreates a container of this folder's own); or the strip is not
# anchored -- a Source naming a different folder under /host_mnt would then
# be adopted as this folder's own.
# Run: bats tests/launcher-v3.bats
@test "open reuses a running container whose mounts docker reported under /host_mnt, and still recreates a stranger's" {
    mkdir -p "$PROJECT_DIR/Harness test"
    primary="$(abspath "$PROJECT_DIR/Harness test")"
    export CONTAINER_STUB_SOURCE_PREFIX=/host_mnt
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    name="claude-orca-$(basename "$primary" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')"

    # The knob really is what put the prefix in the stub's answer.
    grep -qF "mount=/host_mnt$primary:" "$CONTAINER_STUB_STATE/containers/$name.meta"
    grep -qF "mount=/host_mnt$primary/.claude-dev/home:/home/agent" \
        "$CONTAINER_STUB_STATE/containers/$name.meta"

    # Running container of this folder's own, Sources spelled Docker
    # Desktop's way: reused -- never "recreating", never "not this
    # folder's", and sshd (already answering) is all the open waits for.
    : > "$CONTAINER_STUB_LOG"
    : > "$OPEN_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Container $name is already running."* ]]
    [[ "$output" != *"recreating"* ]]
    [[ "$output" != *"is not this folder's"* ]]
    ! grep -q "^run " "$CONTAINER_STUB_LOG"
    ! grep -q "^stop " "$CONTAINER_STUB_LOG"
    ! grep -q "^rm " "$CONTAINER_STUB_LOG"
    [[ "$output" == *"sshd is up"* ]]
    [ ! -s "$OPEN_STUB_LOG" ]

    # A container whose Sources name a DIFFERENT folder under /host_mnt is
    # still a stranger: it goes, and this folder's own takes its place.
    sed -i "s|^mount=/host_mnt$primary|mount=/host_mnt/not-this-folder|" \
        "$CONTAINER_STUB_STATE/containers/$name.meta"
    : > "$CONTAINER_STUB_LOG"
    : > "$OPEN_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -eq 0 ]
    [[ "$output" == *"is not this folder's (mount: /host_mnt/not-this-folder"* ]]
    [[ "$output" == *"recreating"* ]]
    rm_at="$(grep -n "^rm " "$CONTAINER_STUB_LOG" | head -1 | cut -d: -f1)"
    run_at="$(grep -n "^run .*--name $name" "$CONTAINER_STUB_LOG" | head -1 | cut -d: -f1)"
    [ -n "$rm_at" ]
    [ -n "$run_at" ]
    [ "$rm_at" -lt "$run_at" ]
}
