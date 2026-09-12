#!/usr/bin/env bats
#
# S1 acceptance contract (claude-orca-3sk.1), rebased onto the v2
# per-folder layout by V1 (claude-orca-qt9.1) and re-pointed at the v3
# container install by claude-orca-qa2.2 (Docker runtime): bootstrap.sh no
# longer runs brew bundle, installs sandbox-runtime or Claude Code, mounts an Orca DMG or
# writes a shell-rc hook, and registration seeds claude-orca.json rather
# than sandbox.json -- so every assertion that named one of those now
# names its v3 replacement. Exercises bootstrap.sh + scripts/launcher.sh
# against a local git fixture (built from the working tree by
# helpers/setup.bash) with docker/open/sw_vers/uname/gh stubbed on
# PATH -- no Mac and no network required. The layout itself is pinned by
# tests/layout.bats.

load helpers/setup

# Every case runs as if on an Apple-silicon Mac; the stub answers only
# what a test pins, so this is the one line that makes the preflight pass.
mac_env() {
    export STUB_UNAME_S=Darwin
    export STUB_UNAME_M=arm64
}

# A PATH that genuinely lacks the named tools. Removing a stub is not
# enough: this container ships a real /usr/bin/gh and /usr/bin/git that
# would then be exposed. So $ORIGINAL_PATH is shadowed into one directory
# of symlinks, minus those names, and PATH becomes $STUB_BIN plus it.
shadow_path_without() {
    local shadow="$BATS_TEST_TMPDIR/shadow" d oifs tool
    mkdir -p "$shadow"
    oifs="$IFS"; IFS=:
    for d in $ORIGINAL_PATH; do
        IFS="$oifs"
        [ -d "$d" ] || continue
        ln -s "$d"/* "$shadow/" 2>/dev/null || true
        IFS=:
    done
    IFS="$oifs"
    for tool in "$@"; do
        rm -f "$shadow/$tool" "$STUB_BIN/$tool"
    done
    export PATH="$STUB_BIN:$shadow"
}

@test "bootstrap refuses without gh auth" {
    mac_env
    export STUB_GH_UNAUTH=1
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"gh"* ]]
    [ ! -d "$ORCA_HOST" ]
}

# The runtime is Docker, so the host requirement is only "somewhere Docker
# runs": macOS or Linux. Anything else is refused in the preflight, before
# the first mkdir. (Apple's `container` needed macOS 26 on Apple silicon;
# that gate is what the switch removed.)
@test "preflight refuses an unsupported OS before cloning anything" {
    mac_env

    export STUB_UNAME_S=FreeBSD
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"macOS or Linux"* ]]
    [[ "$output" == *"FreeBSD"* ]]
    [ ! -e "$ORCA_HOST" ]
    export STUB_UNAME_S=Darwin

    # An Intel Mac and an older macOS are both fine now: Docker Desktop runs
    # on both, so neither is a preflight failure any more.
    export STUB_UNAME_M=x86_64
    export CLAUDE_ORCA_TEST_MACOS=15.7
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    [ -d "$ORCA_HOST/template/.git" ]
}

# The bootstrap installs what it finds missing rather than handing the user
# a command: Docker Desktop is a Homebrew cask, and the same run carries
# straight on into the install.
@test "a missing docker is installed with brew, then bootstrap continues" {
    mac_env
    # This box ships a real /usr/bin/docker AND a real daemon: dropping only
    # the stub would point the whole case at it. shadow_path_without takes
    # both away, and brew stays to put the stub back.
    export STUB_DOCKER_SRC="$BATS_TEST_TMPDIR/docker-stub"
    cp "$STUB_BIN/docker" "$STUB_DOCKER_SRC"
    shadow_path_without docker
    ! command -v docker >/dev/null 2>&1
    command -v brew >/dev/null 2>&1

    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    grep -q "^brew install --cask docker" "$STUB_LOG"

    # And the run continued past the install: the daemon answered and the
    # template was cloned by the CLI that had just been put on PATH.
    grep -q "^info" "$CONTAINER_STUB_LOG"
    [ -d "$ORCA_HOST/template/.git" ]
}

# The install can still be impossible -- no Homebrew to install the cask
# with -- and then the old contract holds: name the download, name the
# command, write nothing.
@test "when docker cannot be installed, bootstrap stops with the download page and nothing is written" {
    mac_env
    shadow_path_without docker brew
    ! command -v docker >/dev/null 2>&1
    ! command -v brew >/dev/null 2>&1

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"docker.com/products/docker-desktop"* ]]
    [[ "$output" == *"brew install --cask docker"* ]]
    [[ "$output" == *"re-run this same command"* ]]

    [ ! -e "$ORCA_HOST" ]
}

# Past the preflight, a step that dies mid-install says which one, so the
# fix-and-re-run loop has somewhere to start.
@test "a failing step is named by the error trap" {
    mac_env
    export CLAUDE_ORCA_TEMPLATE_URL="$BATS_TEST_TMPDIR/no-such-template.git"

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Bootstrap failed during: Installing the claude_orca template"* ]]
    [[ "$output" == *"idempotent and picks up where it left off"* ]]
}

# gh is a dependency the bootstrap installs, and Homebrew is the path it
# takes when brew is already there.
@test "missing gh is installed with brew when brew is present" {
    mac_env
    export STUB_GH_SRC="$BATS_TEST_TMPDIR/gh-stub"
    cp "$STUB_BIN/gh" "$STUB_GH_SRC"
    shadow_path_without gh
    ! command -v gh >/dev/null 2>&1
    command -v brew >/dev/null 2>&1

    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    grep -q "^brew install gh" "$STUB_LOG"
    [ -d "$ORCA_HOST/template/.git" ]
}

# Without Homebrew it is cli/cli's own signed macOS .pkg, found by reading
# the latest release and picking the universal build out of it.
@test "missing gh without brew is installed from the cli/cli .pkg" {
    mac_env
    export STUB_GH_SRC="$BATS_TEST_TMPDIR/gh-stub"
    cp "$STUB_BIN/gh" "$STUB_GH_SRC"
    shadow_path_without gh brew
    ! command -v gh >/dev/null 2>&1
    ! command -v brew >/dev/null 2>&1

    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    run grep "^curl " "$STUB_LOG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cli/cli/releases"* ]]

    grep -qE "^sudo installer -pkg .*gh\.pkg -target /$" "$STUB_LOG"
    ! grep -q "^brew " "$STUB_LOG"
    [ -d "$ORCA_HOST/template/.git" ]
}

# git lives in the Xcode Command Line Tools, which softwareupdate installs
# headlessly -- no dialog, just the admin password sudo asks for.
@test "missing git installs the Xcode Command Line Tools headlessly" {
    mac_env
    STUB_GIT_RESTORE="$(command -v git)"
    export STUB_GIT_RESTORE
    shadow_path_without git
    ! command -v git >/dev/null 2>&1

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    grep -q "softwareupdate -i Command Line Tools for Xcode-16.4" "$STUB_LOG"
    [ -d "$ORCA_HOST/template/.git" ]
}

@test "bootstrap installs the template clone and bin under <project>/.claude-dev, and nothing else" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    [ -L "$ORCA_HOST/bin/claude-dev" ]
    [ "$(readlink "$ORCA_HOST/bin/claude-dev")" = "../template/scripts/launcher.sh" ]
    [ -x "$ORCA_HOST/bin/claude-dev" ]

    [ -d "$ORCA_HOST/template/.git" ]
    [ -f "$ORCA_HOST/template/bootstrap.sh" ]
    [ -f "$ORCA_HOST/template/IMAGE_TAG" ]

    # The v2 installs are gone: no sandbox-runtime, no in-folder Claude
    # Code, no Orca.app from a DMG -- all three live in the image now.
    [ ! -e "$ORCA_HOST/srt" ]
    [ ! -e "$ORCA_HOST/claude" ]
    [ ! -e "$ORCA_HOST/app" ]
    [ ! -e "$PROJECT_DIR/Orca.app" ]
    ! grep -q "sandbox-runtime" "$STUB_LOG"
}

@test "the docker daemon is checked and brew is never called" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    # `docker info` succeeding IS the daemon being up -- there is no service
    # verb to call and nothing to answer on stdin, which matters here
    # because stdin is the rest of the piped script.
    grep -q "^info" "$CONTAINER_STUB_LOG"
    ! grep -q "^brew " "$STUB_LOG"
    ! grep -q "hdiutil" "$STUB_LOG"
}

@test "registration creates .claude-dev/{home,run,state} and claude-orca.json defaults" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    [ -d "$PROJECT_DIR/.claude-dev/home" ]
    [ -d "$PROJECT_DIR/.claude-dev/run" ]
    [ -d "$PROJECT_DIR/.claude-dev/state" ]
    [ -f "$PROJECT_DIR/.claude-dev/claude-orca.json" ]
    [ ! -e "$PROJECT_DIR/.claude-dev/sandbox.json" ]

    run jq -e '.version == 3
        and (.port | type) == "number"
        and .cpus == null
        and .memory == null
        and .extraMounts == []' "$PROJECT_DIR/.claude-dev/claude-orca.json"
    [ "$status" -eq 0 ]
}

# The port is chosen once and reused forever: the same number has to be
# free on both sides, because the pairing code the browser is handed
# advertises ws://127.0.0.1:<port>.
@test "register chooses a port once and records it in run/port and claude-orca.json" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    port="$(jq -r '.port' "$PROJECT_DIR/.claude-dev/claude-orca.json")"
    [[ "$port" =~ ^[0-9]+$ ]]
    [ "$port" -ge 6768 ]
    [ "$(cat "$PROJECT_DIR/.claude-dev/run/port")" = "$port" ]

    run bash -c "cd '$PROJECT_DIR' && '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.port' "$PROJECT_DIR/.claude-dev/claude-orca.json")" = "$port" ]
}

@test "register never overwrites an existing claude-orca.json" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    config="$PROJECT_DIR/.claude-dev/claude-orca.json"
    printf '%s\n' '{"version":3,"port":6999,"cpus":4,"memory":"8g","extraMounts":["/opt/data"]}' > "$config"

    run bash -c "cd '$PROJECT_DIR' && '$ORCA_HOST/bin/claude-dev' register"
    [ "$status" -eq 0 ]

    run jq -e '.port == 6999 and .cpus == 4 and .memory == "8g"
        and .extraMounts == ["/opt/data"]' "$config"
    [ "$status" -eq 0 ]
}

# "Run one command, start working" ends with a browser open on Orca, so
# the last thing the install prints is the URL and the two commands that
# get the user back to it.
@test "registration ends with the URL, the reopen command and the shell command" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    url="$(cat "$PROJECT_DIR/.claude-dev/run/orca-web-url.txt")"
    [[ "$output" == *"$url"* ]]
    [[ "$output" == *"./claude-dev"* ]]
    [[ "$output" == *"./claude-dev shell"* ]]
    [ "$(tail -1 "$OPEN_STUB_LOG")" = "$url" ]
}

# The .gitignore seeding moved into the container (startup v4,
# claude-orca-qa2.9): the entrypoint owns it now, and
# tests/container-entrypoint.bats exercises it natively rather than through
# a stubbed Mac.

# V1 (claude-orca-qt9.1) inverts S1's rule: the project root DOES get one
# executable, the ./claude-dev stub that execs the in-folder launcher. It
# is still the ONLY one outside .claude-dev/ -- and in v3 there is no
# generated Orca.app beside it any more.
@test "the only executable outside .claude-dev is the ./claude-dev stub" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    [ -x "$PROJECT_DIR/claude-dev" ]
    [ -x "$ORCA_HOST/bin/claude-dev" ]

    # git's own sample hooks are executable and are not ours.
    run find "$PROJECT_DIR" -type f -perm -u+x \
        -not -path "$PROJECT_DIR/.claude-dev/*" \
        -not -path "$PROJECT_DIR/.git/*"
    [ "$status" -eq 0 ]
    [ "$output" = "$PROJECT_DIR/claude-dev" ]
}

# v3 (claude-orca-qa2.2): the Claude config dir is synced INSIDE the VM by
# scripts/container/entrypoint.sh, into the same folder-local home the Mac
# mounts. startup v4 (claude-orca-qa2.10) puts the git identity on the same
# footing: the Mac reads its own global config and passes the two values as
# env, and the entrypoint writes the folder home's .gitconfig from them.
@test "register leaves the home gitconfig and .claude to the entrypoint, passing only the identity in" {
    git config --global user.name "Test User"
    git config --global user.email "test@example.com"

    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    run_line="$(grep "^run " "$CONTAINER_STUB_LOG" | head -1)"
    [[ "$run_line" == *"-e CLAUDE_ORCA_GIT_NAME=Test User"* ]]
    [[ "$run_line" == *"-e CLAUDE_ORCA_GIT_EMAIL=test@example.com"* ]]

    [ ! -e "$PROJECT_DIR/.claude-dev/home/.gitconfig" ]
    [ ! -e "$PROJECT_DIR/.claude-dev/home/.claude/settings.json" ]
}

@test "second run is a no-op" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    local project_sum1 project_sum2
    project_sum1="$(tree_checksum "$PROJECT_DIR")"

    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    project_sum2="$(tree_checksum "$PROJECT_DIR")"

    # One checksum covers both sides: the host install lives inside the
    # project folder.
    [ "$project_sum1" = "$project_sum2" ]
}

@test "bootstrap succeeds with brew, npm and hdiutil absent from PATH" {
    rm -f "$STUB_BIN/brew" "$STUB_BIN/npm" "$STUB_BIN/hdiutil"

    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    [ -d "$ORCA_HOST/template/.git" ]
    [ -s "$PROJECT_DIR/.claude-dev/run/orca-web-url.txt" ]
}

# v3 (claude-orca-qa2.2): the sandbox self-test and the shell-rc hook both
# belonged to Seatbelt. The VM boundary replaces them, so registration
# must run neither -- nothing on the Mac confines anything any more.
@test "registration runs no sandbox self-test and installs no shell hook" {
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    [[ "$output" != *"self-test"* ]]
    [[ "$output" != *"Refusing to hand off"* ]]
    [ ! -e "$PROJECT_DIR/.claude-dev/run/selftest.json" ]
    [ ! -e "$PROJECT_DIR/.claude-dev/state/orca.sb" ]
    [ ! -e "$HOME/.zprofile" ]
    [ ! -e "$HOME/.zshrc" ]
    [ ! -e "$HOME/.bash_profile" ]
}

@test "a template clone with local changes is stashed, not left to abort the pull" {
    mac_env
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    local tmpl="$PROJECT_DIR/.claude-dev/template"
    [ -d "$tmpl/.git" ]

    # What an agent testing a patch leaves behind -- and what `git pull
    # --ff-only` refuses to move past, aborting bootstrap with a git error
    # ("Your local changes to the following files would be overwritten by
    # merge"). Seen for real on 2026-09-07.
    printf '\n# a local edit\n' >> "$tmpl/bootstrap.sh"
    [ -n "$(git -C "$tmpl" status --porcelain --untracked-files=no)" ]

    # A second bootstrap over the same folder has to get past it.
    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"stashing them"* ]]

    # Stashed, not discarded: the edit is recoverable and named.
    run git -C "$tmpl" stash list
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude-orca bootstrap"* ]]

    # And the clone is clean, so the pull had a tree it could move.
    [ -z "$(git -C "$tmpl" status --porcelain --untracked-files=no)" ]
}

# --- recovery plan steps 1 and 2 ----------------------------------------

@test "the preflight prints the facts it decided on, so a pasted log says which path the folder took" {
    # Four days of diagnosis in September 2026 turned on questions a log
    # could not answer: which gh account, what kind of token, which
    # docker. The token no longer decides which image a folder runs --
    # the image is built here from the template clone -- but which
    # account and which docker still decide whether the clone and the
    # build work at all, and neither was written down.
    mac_env
    mkdir -p "$PROJECT_DIR"
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]

    local want
    for want in "macOS" "git " "gh " "docker "; do
        case "$output" in
            *"$want"*) ;;
            *) printf 'the preflight facts do not mention %s:\n%s\n' "$want" "$output"; return 1 ;;
        esac
    done
    # The account and the token kind, which is what made the 2026-09-06
    # incident unreadable: a fine-grained PAT and a classic OAuth token
    # read alike everywhere except here.
    case "$output" in
        *"classic"*|*"fine-grained"*) ;;
        *) printf 'the preflight does not say what kind of token this is:\n%s\n' "$output"; return 1 ;;
    esac
}

@test "bootstrap refuses a .claude-dev left by an older layout instead of installing on top of it" {
    # The owner's own repo carried one: .claude-dev was a git clone of the
    # PREVIOUS template (claude_docker, docker-compose era) with the v4
    # layout written into it as untracked files -- two generations in one
    # directory, and every diagnosis after that had to guess which
    # generation a file belonged to.
    mac_env
    mkdir -p "$PROJECT_DIR/.claude-dev"
    git -C "$PROJECT_DIR" init --quiet -b main >/dev/null 2>&1
    git -C "$PROJECT_DIR/.claude-dev" init --quiet -b main >/dev/null 2>&1
    printf 'services:\n' > "$PROJECT_DIR/.claude-dev/docker-compose.yml"

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -ne 0 ]
    case "$output" in
        *"older claude_orca"*|*"older layout"*) ;;
        *) printf 'the refusal does not name the cause:\n%s\n' "$output"; return 1 ;;
    esac
    # It has to say the exact command, because bootstrap is piped into
    # bash and cannot ask a question.
    case "$output" in
        *"mv "*) ;;
        *) printf 'the refusal does not name the way out:\n%s\n' "$output"; return 1 ;;
    esac
    # And it must not have started installing over the top.
    [ ! -e "$PROJECT_DIR/.claude-dev/template" ]
    [ ! -e "$PROJECT_DIR/claude-dev" ]
}

@test "a .claude-dev this template wrote is not mistaken for a foreign one" {
    mac_env
    mkdir -p "$PROJECT_DIR"
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    # Second run: the folder now has template/, bin/ and claude-orca.json,
    # and the guard must let it straight through.
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    [ -d "$PROJECT_DIR/.claude-dev/template" ]
}

# --- desktop Orca, S2 (claude-orca-8uo.3) ---------------------------------
#
# A folder that means to run the desktop Orca needs the app to exist before
# anything is installed, so the preflight asks after it the way it asks
# after docker: Darwin only, before the first mkdir, and with the download
# page named rather than a command the user cannot run. A folder that means
# to stay on Orca Web says so with CLAUDE_ORCA_UI=web and is never asked.
# Linux never looks at all -- there is no Orca.app to find.

@test "bootstrap on Darwin stops with the download URL when no Orca.app is found" {
    mac_env
    # An explicit override that points nowhere is the answer on any host --
    # including a developer's Mac with a real Orca.app in /Applications.
    export CLAUDE_ORCA_APP="$BATS_TEST_TMPDIR/no-such-Orca.app"

    run bash "$REPO_ROOT/bootstrap.sh" "$PROJECT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"https://orca.dev/download"* ]]
    [[ "$output" == *"Orca"* ]]

    # The preflight stops before the first mkdir, exactly like the docker
    # check: nothing is left behind to clean up or to confuse a re-run.
    [ ! -e "$ORCA_HOST" ]
}

@test "bootstrap on Darwin with CLAUDE_ORCA_UI=web registers without the app" {
    mac_env
    export CLAUDE_ORCA_APP="$BATS_TEST_TMPDIR/no-such-Orca.app"
    export CLAUDE_ORCA_UI=web

    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" != *"orca.dev/download"* ]]
    [ -d "$ORCA_HOST/template/.git" ]
    [ "$(jq -r '.ui' "$PROJECT_DIR/.claude-dev/claude-orca.json")" = "web" ]
}

@test "bootstrap on Linux registers ui web" {
    export STUB_UNAME_S=Linux
    export STUB_UNAME_M=aarch64
    # The fixture Mac's Orca.app is still on the environment; a Linux host
    # has no desktop Orca to attach to whatever the override says.
    run make_project_v3 "$PROJECT_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" != *"orca.dev/download"* ]]
    [ "$(jq -r '.ui' "$PROJECT_DIR/.claude-dev/claude-orca.json")" = "web" ]
}
