#!/usr/bin/env bash
#
# Shared bats helper for tests/bootstrap.bats (S1, claude-orca-3sk.1).
#
# Builds a local git fixture that stands in for the real
# https://github.com/joe-rayment/claude_orca.git template -- assembled from
# the CURRENT WORKING TREE (not HEAD), so edits made while iterating on
# bootstrap.sh/scripts/* are exercised immediately -- and stubs
# brew/npm/gh/node on PATH so bootstrap.sh and its helper scripts run
# deterministically with no network and no real macOS tooling.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# Runs once per bats FILE (bats-core setup_file hook). Vars exported here
# survive into every test's setup()/body: bats forks a fresh process per
# test off an environment that already carries them (verified: a var
# exported in setup_file is visible, unchanged, inside every later setup()
# and test body even though each runs with a different pid).
setup_file() {
    # Captured before any test's setup() prepends the stub bin dir, so a
    # helper that needs the REAL node/npm can ask for it explicitly.
    export ORIGINAL_PATH="$PATH"

    # $BATS_RUN_TMPDIR (private per bats invocation), never $BATS_TMPDIR
    # (== ${TMPDIR:-/tmp}, machine-wide and identical for every concurrent
    # agent in this container when TMPDIR is unset) -- a shared literal
    # /tmp/template.git meant two agents' parallel bats runs could rm -rf
    # and rebuild out from under each other, seen as random failures in
    # unrelated suites.
    TEMPLATE_SRC="$BATS_RUN_TMPDIR/template.git"
    rm -rf "$TEMPLATE_SRC"
    mkdir -p "$TEMPLATE_SRC"
    git init --quiet -b main "$TEMPLATE_SRC" >/dev/null 2>&1

    # Always leave at least one file to commit, even before bootstrap.sh or
    # scripts/ exist yet (RED phase) -- keeps setup_file itself from
    # failing so each test's own assertions produce the real, specific
    # failure instead of a blanket "setup_file failed".
    : > "$TEMPLATE_SRC/.template-stub"
    [ -f "$REPO_ROOT/bootstrap.sh" ] && cp "$REPO_ROOT/bootstrap.sh" "$TEMPLATE_SRC/bootstrap.sh"
    [ -d "$REPO_ROOT/scripts" ] && cp -R "$REPO_ROOT/scripts" "$TEMPLATE_SRC/scripts"
    # S4 (claude-orca-3sk.4): config-sync's source and the bin/ symlinks it
    # and tier-gate/tier-set etc. are resolved through -- `cp -R` preserves
    # bin/<name>'s relative symlinks (e.g. bin/tier-set -> ../scripts/
    # tier-set.sh) as symlinks, so they still resolve correctly once re-rooted
    # under $TEMPLATE_SRC and, later, under <project>/.claude-dev/template.
    [ -d "$REPO_ROOT/config" ] && cp -R "$REPO_ROOT/config" "$TEMPLATE_SRC/config"
    [ -d "$REPO_ROOT/bin" ] && cp -R "$REPO_ROOT/bin" "$TEMPLATE_SRC/bin"
    # v3 (claude-orca-qa2.2): the image pin the launcher reads out of the
    # folder's own template clone, and the Dockerfile its build fallback
    # points `container build -f` at.
    [ -f "$REPO_ROOT/IMAGE_TAG" ] && cp "$REPO_ROOT/IMAGE_TAG" "$TEMPLATE_SRC/IMAGE_TAG"
    [ -f "$REPO_ROOT/Dockerfile" ] && cp "$REPO_ROOT/Dockerfile" "$TEMPLATE_SRC/Dockerfile"

    git -C "$TEMPLATE_SRC" add -A >/dev/null 2>&1
    git -C "$TEMPLATE_SRC" \
        -c user.email=test@example.com -c user.name=test \
        commit --quiet -m "template snapshot" >/dev/null 2>&1

    export TEMPLATE_SRC
}

# --- stub executables ----------------------------------------------------

write_stub_brew() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
echo "brew $*" >> "$STUB_LOG"
if [ "$1" = "list" ] && [ "$2" = "--cask" ] && [ "$3" = "orca" ]; then
    [ "${STUB_ORCA_INSTALLED:-}" = "1" ] && exit 0
    exit 1
fi
# The bootstrap's gh install, brew branch: stand in for the formula by
# putting the saved gh stub back on PATH.
if [ "$1" = "install" ] && [ "$2" = "gh" ]; then
    if [ -n "${STUB_GH_SRC:-}" ] && [ -e "$STUB_GH_SRC" ]; then
        cp "$STUB_GH_SRC" "$STUB_BIN/gh"
        chmod +x "$STUB_BIN/gh"
    fi
    exit 0
fi
# ...and the Docker Desktop cask, the same way: the saved docker stub goes
# back on PATH, so the bootstrap carries on in the same run.
if [ "$1" = "install" ] && [ "$2" = "--cask" ] && [ "$3" = "docker" ]; then
    if [ -n "${STUB_DOCKER_SRC:-}" ] && [ -e "$STUB_DOCKER_SRC" ]; then
        cp "$STUB_DOCKER_SRC" "$STUB_BIN/docker"
        chmod +x "$STUB_BIN/docker"
    fi
    exit 0
fi
exit 0
STUB
    chmod +x "$1"
}

# --- dependency-install stubs (bootstrap installs what it finds missing) ---
#
# `sudo` logs the command and runs it unprivileged; `installer` fakes a .pkg
# by restoring the stub the test saved aside ($STUB_GH_SRC);
# `softwareupdate` and `xcode-select` stand in for the Xcode Command Line
# Tools install that carries git. Docker is a brew cask, not a .pkg, so it
# is write_stub_brew that puts $STUB_DOCKER_SRC back.

write_stub_sudo() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >> "$STUB_LOG"
exec "$@"
STUB
    chmod +x "$1"
}

write_stub_installer() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
echo "installer $*" >> "$STUB_LOG"
pkg=""
prev=""
for arg in "$@"; do
    [ "$prev" = "-pkg" ] && pkg="$arg"
    prev="$arg"
done
case "$pkg" in
    *gh*.pkg)
        if [ -n "${STUB_GH_SRC:-}" ] && [ -e "$STUB_GH_SRC" ]; then
            cp "$STUB_GH_SRC" "$STUB_BIN/gh"
            chmod +x "$STUB_BIN/gh"
        fi
        ;;
esac
exit 0
STUB
    chmod +x "$1"
}

write_stub_softwareupdate() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
echo "softwareupdate $*" >> "$STUB_LOG"
case "$1" in
    -l|--list)
        echo "Software Update Tool"
        echo "Finding available software"
        echo "* Label: Command Line Tools for Xcode-16.4"
        echo "	Title: Command Line Tools for Xcode, Version: 16.4"
        exit 0
        ;;
    -i|--install)
        if [ -n "${STUB_GIT_RESTORE:-}" ]; then
            ln -sf "$STUB_GIT_RESTORE" "$STUB_BIN/git"
        fi
        exit 0
        ;;
esac
exit 0
STUB
    chmod +x "$1"
}

write_stub_xcode_select() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
echo "xcode-select $*" >> "$STUB_LOG"
case "$1" in
    -p|--print-path)
        [ -e "$STUB_BIN/git" ] && { echo "/Library/Developer/CommandLineTools"; exit 0; }
        exit 1
        ;;
esac
exit 0
STUB
    chmod +x "$1"
}

write_stub_npm() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
echo "npm $*" >> "$STUB_LOG"

prefix=""
do_install=0
spec=""
prev=""
for arg in "$@"; do
    case "$arg" in
        install) do_install=1 ;;
        --prefix=*) prefix="${arg#--prefix=}" ;;
        @*/*@*) spec="$arg" ;;
    esac
    [ "$prev" = "--prefix" ] && prefix="$arg"
    prev="$arg"
done

# The version actually asked for, so a moved pin is observable in the
# fabricated package.json and not just in $STUB_LOG.
want_version="${spec##*@}"

# V1 (claude-orca-qt9.1): a per-folder `npm --prefix` install of Claude Code
# -- fabricate its package.json and the node_modules/.bin/claude executable
# a real install would leave. (v3 installs Claude in the image instead; the
# stub stays because bootstrap.bats proves npm is never called at all.)
if [ "$do_install" = "1" ] && [ -n "$prefix" ] && [ "${spec#*claude-code}" != "$spec" ]; then
    mkdir -p "$prefix/node_modules/@anthropic-ai/claude-code" "$prefix/node_modules/.bin"
    printf '{"name":"@anthropic-ai/claude-code","version":"%s"}' "$want_version" \
        > "$prefix/node_modules/@anthropic-ai/claude-code/package.json"
    printf '#!/usr/bin/env bash\necho "claude-code %s"\n' "$want_version" \
        > "$prefix/node_modules/.bin/claude"
    chmod +x "$prefix/node_modules/.bin/claude"
    exit 0
fi

exit 0
STUB
    chmod +x "$1"
}

write_stub_gh() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    [ "${STUB_GH_UNAUTH:-}" = "1" ] && exit 1
    exit 0
fi
# The bootstrap signs in itself when a terminal is available.
if [ "$1" = "auth" ] && [ "$2" = "login" ]; then
    echo "gh $*" >> "$STUB_LOG"
    exit 0
fi
# ...and asks an existing login for the read:packages scope the image pull
# needs. Recorded only; the scopes `api -i user` answers with do not change.
if [ "$1" = "auth" ] && [ "$2" = "refresh" ]; then
    echo "gh $*" >> "$STUB_LOG"
    exit 0
fi
# The bootstrap's container install: Apple's signed .pkg off the releases
# page. STUB_GH_NO_ASSET=1 stands in for "the release carries no such
# asset" -- nothing is written to --dir.
if [ "$1" = "release" ] && [ "$2" = "download" ]; then
    echo "gh $*" >> "$STUB_LOG"
    [ "${STUB_GH_NO_ASSET:-}" = "1" ] && exit 1
    dir=""
    prev=""
    for arg in "$@"; do
        [ "$prev" = "--dir" ] && dir="$arg"
        prev="$arg"
    done
    [ -n "$dir" ] || exit 1
    mkdir -p "$dir"
    printf 'FAKE-PKG\n' > "$dir/container-1.3.1-installer-signed.pkg"
    exit 0
fi
# S5 (claude-orca-3sk.17): the launcher reads the GitHub token on the Mac
# side via `gh auth token` and passes it into the VM as GH_TOKEN. Fixed fake
# value (override with STUB_GH_TOKEN); STUB_GH_UNAUTH=1 stands in for "no
# token on this machine" (real gh exits nonzero, prints nothing).
if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
    [ "${STUB_GH_UNAUTH:-}" = "1" ] && exit 1
    printf '%s\n' "${STUB_GH_TOKEN:-gho_stubfaketoken0123456789abcdef}"
    exit 0
fi
# qa2.8: the launcher reads the token's OAuth scopes from the response
# header of an authenticated API call (`gh api -i user` -> X-Oauth-Scopes),
# because `gh auth status` words its scopes line differently per version.
# CLAUDE_ORCA_TEST_GH_SCOPES pins the comma-separated list; the default
# carries read:packages, which is what every pre-qa2.8 suite assumes (they
# assert the pull path runs).
if [ "$1" = "api" ] && [ "$2" = "-i" ] && [ "${3:-}" = "user" ]; then
    [ "${STUB_GH_UNAUTH:-}" = "1" ] && exit 1
    scopes="${CLAUDE_ORCA_TEST_GH_SCOPES:-repo, read:org, workflow, read:packages}"
    printf 'HTTP/2.0 200 OK\r\n'
    # STUB_GH_NO_SCOPE_HEADER=1: a fine-grained PAT or GitHub App token,
    # which never sends X-Oauth-Scopes at all (the header is classic-only).
    [ "${STUB_GH_NO_SCOPE_HEADER:-}" = "1" ] || printf 'X-Oauth-Scopes: %s\r\n' "$scopes"
    printf 'X-Accepted-Oauth-Scopes: \r\n'
    printf '\r\n'
    printf '{"login":"%s"}\n' "${STUB_GH_LOGIN:-joe-rayment}"
    exit 0
fi
# v3 (claude-orca-qa2.2): `container registry login ghcr.io` needs a
# username, and the launcher reads it from `gh api user --jq .login`.
if [ "$1" = "api" ] && [ "$2" = "user" ]; then
    [ "${STUB_GH_UNAUTH:-}" = "1" ] && exit 1
    printf '%s\n' "${STUB_GH_LOGIN:-joe-rayment}"
    exit 0
fi
if [ "$1" = "api" ]; then
    echo ""
    exit 0
fi
exit 0
STUB
    chmod +x "$1"
}

# --- v3 stubs (claude-orca-qa2.2; Docker runtime) ------------------------
#
# The Mac half of v3 drives `docker`, `open`, `sw_vers` and `uname`; none of
# them means anything on this Linux box (there is no daemon here and the
# suite must never talk to one), so each is faked. `docker` is the
# substantial one: it logs every invocation's argv as one line to
# $CONTAINER_STUB_LOG and keeps its whole world -- daemon up, image present,
# per-container state -- as marker files under $CONTAINER_STUB_STATE, so a
# test can put the folder into any state ("stopped", no image) by touching
# one file. The two variable names predate the runtime switch and are kept:
# renaming them would touch every suite for nothing.

write_stub_docker() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CONTAINER_STUB_LOG:-/dev/null}"
state="${CONTAINER_STUB_STATE:-${TMPDIR:-/tmp}/container-stub}"
mkdir -p "$state/containers" "$state/volumes"

# `docker image inspect REF` -- two words, so it is matched before the
# one-word dispatch below.
case "$1 ${2:-}" in
    "image inspect"|"image ls"|"image list")
        [ -f "$state/image" ] || exit 1
        cat "$state/image"
        exit 0 ;;
esac

cmd="$1"; shift
case "$cmd" in
    info)
        # `docker info` succeeding IS the daemon being up, on both sides.
        [ "${CLAUDE_ORCA_TEST_SERVICE_DOWN:-0}" = "1" ] && exit 1
        : > "$state/service"
        echo "Server Version: 27.0-stub"
        exit 0 ;;
    pull)
        [ "${CLAUDE_ORCA_TEST_PULL_FAIL:-0}" = "1" ] && { echo "pull failed" >&2; exit 1; }
        printf '%s\n' "$1" > "$state/image"; exit 0 ;;
    login)
        # The password must arrive on stdin -- never in argv.
        cat > "$state/registry-password"
        printf 'login %s\n' "$*" > "$state/registry-argv"
        exit 0 ;;
    logout)
        rm -f "$state/registry-password" "$state/registry-argv"
        exit 0 ;;
    inspect)
        # `docker inspect -f '{{.State.Status}}' NAME`: the name is the last
        # argument, and the state word is what the launcher parses.
        [ "${CLAUDE_ORCA_TEST_SERVICE_DOWN:-0}" = "1" ] && exit 1
        name=""
        for a in "$@"; do name="$a"; done
        [ -n "$name" ] || exit 1
        [ -f "$state/containers/$name" ] || exit 1
        cat "$state/containers/$name"
        exit 0 ;;
    run)
        # CLAUDE_ORCA_TEST_RUN_FAIL=1: `docker run` pulling an image that is
        # not there, refused by the registry. No container marker, so
        # nothing is left running.
        if [ "${CLAUDE_ORCA_TEST_RUN_FAIL:-0}" = "1" ]; then
            echo "docker: Error response from daemon: pull access denied" >&2
            exit 1
        fi
        name=""; port=""; proj=""; prev=""
        for a in "$@"; do
            case "$prev" in
                --name) name="$a" ;;
                -e|--env)
                    case "$a" in
                        ORCA_PORT=*)   port="${a#ORCA_PORT=}" ;;
                        PROJECT_DIR=*) proj="${a#PROJECT_DIR=}" ;;
                    esac ;;
            esac
            prev="$a"
        done
        [ -n "$name" ] || { echo "docker: run needs --name" >&2; exit 1; }
        echo running > "$state/containers/$name"
        # A --volume whose source is not a path is a NAMED volume, and
        # docker creates it on demand here. It outlives `docker rm`, so
        # the stub keeps it in its own directory, not the container's.
        prev=""
        for a in "$@"; do
            case "$prev" in
                -v|--volume)
                    case "$a" in
                        /*) ;;
                        *)  : > "$state/volumes/${a%%:*}" ;;
                    esac ;;
            esac
            prev="$a"
        done
        # Stands in for the entrypoint (scripts/container/entrypoint.sh):
        # Orca comes up and publishes its pairing URL and bound port.
        # CLAUDE_ORCA_TEST_NO_URL: the container starts but never publishes
        # a URL -- what a first start looks like while setup.sh is still
        # installing the toolchain.
        if [ -n "$proj" ] && [ -z "${CLAUDE_ORCA_TEST_NO_URL:-}" ]; then
            mkdir -p "$proj/.claude-dev/run"
            printf 'http://127.0.0.1:%s/web-index.html#pairing=stub\n' "$port" \
                > "$proj/.claude-dev/run/orca-web-url.txt"
            printf '%s\n' "$port" > "$proj/.claude-dev/run/port"
        fi
        echo "$name"
        exit 0 ;;
    start)
        [ -f "$state/containers/$1" ] || exit 1
        echo running > "$state/containers/$1"; exit 0 ;;
    stop)
        [ -f "$state/containers/$1" ] || exit 1
        echo exited > "$state/containers/$1"; exit 0 ;;
    rm)
        rm -f "$state/containers/$1"; exit 0 ;;
    ps)
        [ "${CLAUDE_ORCA_TEST_SERVICE_DOWN:-0}" = "1" ] && exit 1
        printf '%-38s%s\n' "NAMES" "STATUS"
        for f in "$state"/containers/*; do
            [ -e "$f" ] || continue
            printf '%-38s%s\n' "$(basename "$f")" "$(cat "$f")"
        done
        exit 0 ;;
    volume)
        sub="$1"; shift
        case "$sub" in
            create)  : > "$state/volumes/$1"; printf '%s\n' "$1"; exit 0 ;;
            inspect) [ -f "$state/volumes/$1" ] || exit 1; printf '[]\n'; exit 0 ;;
            rm)      [ -f "$state/volumes/$1" ] || exit 1
                     rm -f "$state/volumes/$1"; exit 0 ;;
            ls)      for f in "$state"/volumes/*; do
                         [ -e "$f" ] || continue
                         basename "$f"
                     done
                     exit 0 ;;
        esac
        exit 0 ;;
    exec|logs)
        exit 0 ;;
esac
exit 0
STUB
    chmod +x "$1"
}

# Records the URL macOS was asked to hand to the default browser.
write_stub_open() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${OPEN_STUB_LOG:-/dev/null}"
exit "${STUB_OPEN_EXIT:-0}"
STUB
    chmod +x "$1"
}

write_stub_sw_vers() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    -productVersion) printf '%s\n' "${CLAUDE_ORCA_TEST_MACOS:-26.0}" ;;
    -productName)    printf 'macOS\n' ;;
    *)               printf 'ProductName:\tmacOS\nProductVersion:\t%s\n' "${CLAUDE_ORCA_TEST_MACOS:-26.0}" ;;
esac
exit 0
STUB
    chmod +x "$1"
}

# Same shape as the darwin_bin stub in tests/register-flow.bats: answer
# only what a test has explicitly pinned ($STUB_UNAME_S / $STUB_UNAME_M),
# and defer everything else to the real uname -- so this stub sitting on
# PATH for every suite changes nothing until a test asks it to.
write_stub_uname() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    -s) [ -n "${STUB_UNAME_S:-}" ] && { printf '%s\n' "$STUB_UNAME_S"; exit 0; } ;;
    -m) [ -n "${STUB_UNAME_M:-}" ] && { printf '%s\n' "$STUB_UNAME_M"; exit 0; } ;;
esac
PATH="${ORIGINAL_PATH:-/usr/bin:/bin}" exec uname "$@"
STUB
    chmod +x "$1"
}

# V1 (claude-orca-qt9.1): the Orca DMG download. Only a download (`-o
# <file>`) is faked -- every other curl call is handed to the real binary
# so suites that probe reachability keep their unstubbed behaviour.
write_stub_curl() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
out=""
prev=""
for arg in "$@"; do
    [ "$prev" = "-o" ] && out="$arg"
    prev="$arg"
done

if [ -z "$out" ]; then
    PATH="${ORIGINAL_PATH:-/usr/bin:/bin}" exec curl "$@"
fi

echo "curl $*" >> "$STUB_LOG"
mkdir -p "$(dirname "$out")"

# The bootstrap's no-brew gh install reads cli/cli's latest release and
# picks the macOS universal .pkg out of it.
case "$*" in
    *api.github.com/repos/cli/cli/releases*)
        cat > "$out" <<'JSON'
{"tag_name":"v2.100.0","assets":[{"name":"gh_2.100.0_macOS_universal.pkg","browser_download_url":"https://github.com/cli/cli/releases/download/v2.100.0/gh_2.100.0_macOS_universal.pkg"}]}
JSON
        exit "${STUB_CURL_EXIT:-0}"
        ;;
esac

printf 'FAKE-DMG %s\n' "${STUB_DMG_BODY:-orca}" > "$out"
exit "${STUB_CURL_EXIT:-0}"
STUB
    chmod +x "$1"
}

# V1: `hdiutil attach -nobrowse -readonly -mountpoint <mnt> <dmg>` fakes a
# mounted Orca.app (Info.plist carrying $STUB_ORCA_DMG_VERSION); `detach`
# unmounts it. macOS-only tool, so there is nothing to fall back to.
write_stub_hdiutil() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
echo "hdiutil $*" >> "$STUB_LOG"

mnt=""
prev=""
for arg in "$@"; do
    [ "$prev" = "-mountpoint" ] && mnt="$arg"
    prev="$arg"
done

case "$1" in
    attach)
        [ -n "$mnt" ] || exit 1
        [ "${STUB_HDIUTIL_EXIT:-0}" = "0" ] || exit "$STUB_HDIUTIL_EXIT"
        mkdir -p "$mnt/Orca.app/Contents/MacOS"
        printf 'fake orca binary\n' > "$mnt/Orca.app/Contents/MacOS/Orca"
        chmod +x "$mnt/Orca.app/Contents/MacOS/Orca"
        cat > "$mnt/Orca.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleShortVersionString</key>
	<string>${STUB_ORCA_DMG_VERSION:-1.4.197}</string>
</dict>
</plist>
PLIST
        ;;
    detach)
        [ -d "$2" ] && rm -rf "$2"
        ;;
esac
exit 0
STUB
    chmod +x "$1"
}

write_stub_node() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
    echo "${STUB_NODE_VERSION:-v24.0.0}"
    exit 0
fi
exit 0
STUB
    chmod +x "$1"
}

# S10 (claude-orca-3sk.21): a `node` stub that records what take-screenshot
# asked for -- one argv element per line to $STUB_ARGV, a full env dump to
# $STUB_NODE_ENV -- and fakes Playwright's side effect by creating the PNG
# path it was handed (the argument that ends in .png). Replaces the plain
# write_stub_node on PATH for tests that need to inspect the invocation.
write_stub_node_recording() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
    echo "${STUB_NODE_VERSION:-v24.0.0}"
    exit 0
fi
printf '%s\n' "$@" >> "$STUB_ARGV"
env > "$STUB_NODE_ENV"
for arg in "$@"; do
    case "$arg" in
        /*.png) mkdir -p "$(dirname "$arg")"; : > "$arg" ;;
    esac
done
exit "${STUB_NODE_EXIT:-0}"
STUB
    chmod +x "$1"
}

# S10 (claude-orca-3sk.21): a resolvable-but-inert `playwright` package under
# $1/node_modules, standing in for `npm i -g playwright@<pin>` having been run
# -- take-screenshot only checks that the package directory exists before
# handing the work to node, which is stubbed too.
fake_playwright_package() {
    mkdir -p "$1/node_modules/playwright"
    printf '{"name":"playwright","version":"1.61.1"}' \
        > "$1/node_modules/playwright/package.json"
}

# --- S8 delegation stubs (claude-orca-3sk.19) ------------------------------
#
# delegate.sh hands every runner a scrubbed env (`env -i` + only PATH, HOME,
# XDG_CONFIG_HOME, TERM and the route's provider key), so an arbitrary
# "record here" variable never reaches the stub. The job's own HOME does,
# by design -- so every runner stub records into $HOME: <name>.argv (one
# argv element per line), <name>.env (a full env dump) and `runner` (the
# name that ran). Each emits a realistic NDJSON stream carrying one
# usage/cost event, and exits with $STUB_RUNNER_EXIT (default 0).

write_stub_opencode() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
mkdir -p "$HOME"
printf '%s\n' "$@" > "$HOME/opencode.argv"
env > "$HOME/opencode.env"
echo opencode > "$HOME/runner"
cat <<'JSON'
{"type":"session.updated","timestamp":1788224900000,"sessionID":"ses_fake"}
{"type":"message","timestamp":1788224900500,"role":"assistant","text":"working"}
{"type":"finish","timestamp":1788224901000,"sessionID":"ses_fake","usage":{"inputTokens":1234,"outputTokens":567,"cost":0.0089}}
JSON
exit "${STUB_RUNNER_EXIT:-0}"
STUB
    chmod +x "$1"
}

write_stub_codex() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
mkdir -p "$HOME"
printf '%s\n' "$@" > "$HOME/codex.argv"
env > "$HOME/codex.env"
echo codex > "$HOME/runner"
cat <<'JSON'
{"type":"thread.started","thread_id":"th_fake"}
{"type":"item.completed","item":{"type":"agent_message","text":"working"}}
{"type":"turn.completed","usage":{"input_tokens":2048,"output_tokens":301,"cost":0.0042}}
JSON
exit "${STUB_RUNNER_EXIT:-0}"
STUB
    chmod +x "$1"
}

write_stub_gemini() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
mkdir -p "$HOME"
printf '%s\n' "$@" > "$HOME/gemini.argv"
env > "$HOME/gemini.env"
echo gemini > "$HOME/runner"
pwd > "$HOME/gemini.cwd"
cat <<'JSON'
{"type":"content","text":"working"}
{"type":"result","usage":{"promptTokens":900,"completionTokens":120,"cost":0.0011}}
JSON
exit "${STUB_RUNNER_EXIT:-0}"
STUB
    chmod +x "$1"
}

# A `bd` stub backed by one JSON file per project dir (<dir>/.bd-stub.json).
# Covers exactly the four calls delegate.sh makes -- create (tests only),
# show --json, update --append-notes, list --notes-contains --json -- and
# logs every invocation's argv to $BD_STUB_LOG when set. Never touches a
# real Dolt DB, so no test can reach this repo's own beads.
write_stub_bd() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
[ -n "${BD_STUB_LOG:-}" ] && printf '%s\n' "$*" >> "$BD_STUB_LOG"

dir="$PWD"
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -C) dir="$2"; shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
db="$dir/.bd-stub.json"
[ -f "$db" ] || echo '[]' > "$db"

cmd="${args[0]}"
case "$cmd" in
    create)
        title="${args[1]}"; desc=""; acc=""
        i=2
        while [ "$i" -lt "${#args[@]}" ]; do
            case "${args[$i]}" in
                -d|--description) i=$((i+1)); desc="${args[$i]}" ;;
                --acceptance) i=$((i+1)); acc="${args[$i]}" ;;
            esac
            i=$((i+1))
        done
        id="test-$(jq 'length + 1' "$db")"
        jq --arg id "$id" --arg t "$title" --arg d "$desc" --arg a "$acc" \
            '. + [{id: $id, title: $t, description: $d, acceptance_criteria: $a, notes: ""}]' \
            "$db" > "$db.tmp" && mv "$db.tmp" "$db"
        echo "created $id"
        ;;
    show)
        jq --arg id "${args[1]}" '[.[] | select(.id == $id)]' "$db"
        ;;
    init)
        # What `claude-dev register` calls (claude-orca-2qo): make the
        # marker a real bd would make, and keep the prefix where a test
        # can read it back.
        prefix=""
        i=1
        while [ "$i" -lt "${#args[@]}" ]; do
            [ "${args[$i]}" = "--prefix" ] && { i=$((i+1)); prefix="${args[$i]}"; }
            i=$((i+1))
        done
        mkdir -p "$dir/.beads"
        printf '%s\n' "$prefix" > "$dir/.beads/stub-prefix"
        echo "initialized $prefix"
        ;;
    update)
        id="${args[1]}"; notes=""
        i=2
        while [ "$i" -lt "${#args[@]}" ]; do
            [ "${args[$i]}" = "--append-notes" ] && { i=$((i+1)); notes="${args[$i]}"; }
            i=$((i+1))
        done
        jq --arg id "$id" --arg n "$notes" \
            'map(if .id == $id then .notes = ((.notes // "") + (if (.notes // "") == "" then "" else "\n" end) + $n) else . end)' \
            "$db" > "$db.tmp" && mv "$db.tmp" "$db"
        ;;
    list)
        needle=""
        i=1
        while [ "$i" -lt "${#args[@]}" ]; do
            [ "${args[$i]}" = "--notes-contains" ] && { i=$((i+1)); needle="${args[$i]}"; }
            i=$((i+1))
        done
        jq --arg n "$needle" '[.[] | select(($n == "") or ((.notes // "") | contains($n))) | {id: .id}]' "$db"
        ;;
    *)
        exit 0
        ;;
esac
exit 0
STUB
    chmod +x "$1"
}

# --- per-test environment -------------------------------------------------

setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"

    export CLAUDE_ORCA_TEMPLATE_URL="$TEMPLATE_SRC"

    export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    : > "$STUB_LOG"
    export STUB_ENV="$BATS_TEST_TMPDIR/stub.env"
    : > "$STUB_ENV"

    # Exported: the install stubs (installer, softwareupdate) put a
    # restored binary back here, so they have to know where "here" is.
    export STUB_BIN="$BATS_TEST_TMPDIR/stubs"
    mkdir -p "$STUB_BIN"
    write_stub_brew "$STUB_BIN/brew"
    write_stub_npm  "$STUB_BIN/npm"
    write_stub_gh   "$STUB_BIN/gh"
    write_stub_node "$STUB_BIN/node"
    write_stub_curl "$STUB_BIN/curl"
    write_stub_hdiutil "$STUB_BIN/hdiutil"

    # v3 (claude-orca-qa2.2): the Mac tooling the v3 bootstrap and launcher
    # drive. `open` and `sw_vers` do not exist on this box at all, the
    # `uname` stub is a pass-through until a test pins it, and the `docker`
    # stub shadows any real daemon -- so putting all four on PATH for every
    # suite is inert.
    export CONTAINER_STUB_LOG="$BATS_TEST_TMPDIR/container.log"
    : > "$CONTAINER_STUB_LOG"
    export CONTAINER_STUB_STATE="$BATS_TEST_TMPDIR/container-state"
    mkdir -p "$CONTAINER_STUB_STATE/containers"
    export OPEN_STUB_LOG="$BATS_TEST_TMPDIR/open.log"
    : > "$OPEN_STUB_LOG"
    write_stub_docker "$STUB_BIN/docker"
    write_stub_open "$STUB_BIN/open"
    write_stub_sw_vers "$STUB_BIN/sw_vers"
    write_stub_uname "$STUB_BIN/uname"

    # The bootstrap installs a missing dependency rather than instructing
    # it, so the tools that install things are stubbed too. All four are
    # inert until a test removes a dependency from PATH.
    write_stub_sudo "$STUB_BIN/sudo"
    write_stub_installer "$STUB_BIN/installer"
    write_stub_softwareupdate "$STUB_BIN/softwareupdate"
    write_stub_xcode_select "$STUB_BIN/xcode-select"

    export PATH="$STUB_BIN:$PATH"

    # V7 (claude-orca-2qo): `claude-dev register` now runs `bd init`
    # itself when bd is on PATH and the folder has no .beads. A real bd
    # IS on PATH in the dev container, and make_project registers a
    # folder in hundreds of tests -- so the suite opts out globally and
    # tests/register-flow.bats is the one place that turns it back on,
    # against write_stub_bd rather than a real Dolt DB.
    export CLAUDE_ORCA_SKIP_BEADS=1

    export PROJECT_DIR="$BATS_TEST_TMPDIR/project"
    mkdir -p "$PROJECT_DIR"

    # V1 (claude-orca-qt9.1): the per-folder host root -- everything the
    # bootstrap installs lives under the project itself now, so this is
    # derived from $PROJECT_DIR rather than being a place of its own.
    export ORCA_HOST="$PROJECT_DIR/.claude-dev"

    # Merge compat (V1 x V4): tests written before the per-folder move name
    # the host root CLAUDE_ORCA_HOME. Nothing under scripts/ reads it any
    # more (tests/layout.bats greps for that), so this is just the old
    # spelling of $ORCA_HOST for those suites.
    export CLAUDE_ORCA_HOME="$ORCA_HOST"

}

# --- S2 fixtures (claude-orca-3sk.14) --------------------------------------

# v3 (claude-orca-qa2.2): a git project put through the real bootstrap.sh
# with the Mac tooling stubbed -- the template clone into
# <dir>/.claude-dev/template, bin/, claude-orca.json, the image pull and the
# container run, all against the stubs.
# uname is pinned to Apple silicon for the bootstrap call only (a test that
# exports STUB_UNAME_S/STUB_UNAME_M itself wins), and stdout is left alone
# so `run make_project_v3 <dir>` can assert on what the install printed.
make_project_v3() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init --quiet -b main >/dev/null 2>&1
    git -C "$dir" -c user.email=test@example.com -c user.name=test \
        commit --quiet --allow-empty -m init >/dev/null 2>&1
    STUB_UNAME_S="${STUB_UNAME_S:-Darwin}" STUB_UNAME_M="${STUB_UNAME_M:-arm64}" \
        bash "$REPO_ROOT/bootstrap.sh" "$dir"
}

# v3 (claude-orca-qa2.3): the same fixture, quiet -- the two spellings are
# one thing now that there is only one bootstrap.
make_project() {
    make_project_v3 "$@" >/dev/null
}

# Adds a linked worktree as a sibling of $1 (Orca's default layout:
# <repo>/../<repoName>-<name>) and prints its path.
make_worktree() {
    local project="$1" name="$2" wt
    wt="$(dirname "$project")/$(basename "$project")-$name"
    git -C "$project" worktree add --quiet -b "$name" "$wt" >/dev/null 2>&1
    printf '%s\n' "$wt"
}

# A fake "real" (unsandboxed) HOME, distinct from $HOME (which setup()
# already points at a fixture root used for other purposes) -- stands in
# for CLAUDE_ORCA_REAL_HOME, pre-populated with the directories the S2
# contract re-opens allowRead for.
make_real_home() {
    local home="$BATS_TEST_TMPDIR/real-home"
    mkdir -p "$home/.local/bin" "$home/.local/share/claude" "$home/.orca/agent-hooks" "$home/.ssh"
    printf '%s\n' "$home"
}

# Canonical absolute path -- matches how gen-settings.sh/claude-orca-shell
# resolve every path (`cd ... && pwd -P`), so expected-value strings built
# in tests agree with what the scripts under test actually produce.
abspath() {
    (cd "$1" && pwd -P)
}

# Portable file-permission-bits read (GNU stat here, BSD/macOS stat on the
# real target platform).
file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# --- assertion helpers -----------------------------------------------------

# Content-addressed checksum of a directory tree, ignoring .git internals:
# `git pull --ff-only` legitimately rewrites reflogs/FETCH_HEAD (with a
# fresh timestamp) even when nothing new was fetched, so including .git
# would make an otherwise-true no-op look like a change.
#
# container.log is excluded for the same reason: every launcher command
# appends the `container` invocation it made, so it legitimately differs
# run to run even when nothing else changed.
tree_checksum() {
    {
        find "$1" -not -path '*/.git*' \
            -not -name 'container.log' \
            -type f -exec sha256sum {} + 2>/dev/null
        find "$1" -not -path '*/.git*' -type l 2>/dev/null | while IFS= read -r link; do
            printf 'SYMLINK %s -> %s\n' "$link" "$(readlink "$link")"
        done
    } | sort | sha256sum | cut -d' ' -f1
}
