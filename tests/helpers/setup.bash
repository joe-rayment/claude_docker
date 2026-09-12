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
        # `docker image inspect REF --format '{{.Id}}'`: the local image
        # id, which is what says whether a pull actually moved this
        # folder. CLAUDE_ORCA_TEST_IMAGE_ID picks it; the pull below is
        # what records it, so a test changes the variable between runs.
        for a in "$@"; do
            case "$a" in
                --format|-f|--format=*)
                    if [ -f "$state/image-id" ]; then
                        cat "$state/image-id"
                    else
                        echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
                    fi
                    exit 0 ;;
            esac
        done
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
        printf '%s\n' "$1" > "$state/image"
        printf 'sha256:%s\n' \
            "${CLAUDE_ORCA_TEST_IMAGE_ID:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
            > "$state/image-id"
        exit 0 ;;
    build)
        # `docker build --tag REF CTX`. CLAUDE_ORCA_TEST_BUILD_FAIL fails it
        # the way a real build fails: on stderr, non-zero, and the image is
        # left exactly as it was -- a failed build never overwrites what a
        # machine already had.
        ref=""; prev=""
        for a in "$@"; do
            case "$prev" in --tag) ref="$a" ;; esac
            prev="$a"
        done
        if [ "${CLAUDE_ORCA_TEST_BUILD_FAIL:-0}" = "1" ]; then
            echo "failed to solve: process \"/bin/sh -c apt-get update\" did not complete successfully" >&2
            exit 1
        fi
        [ -n "$ref" ] && printf '%s\n' "$ref" > "$state/image"
        printf 'sha256:%s\n' \
            "${CLAUDE_ORCA_TEST_IMAGE_ID:-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc}" \
            > "$state/image-id"
        exit 0 ;;
    images)
        # `docker images --format ...`: whatever the test put in
        # $state/images-list, one image per line, and nothing otherwise.
        [ -f "$state/images-list" ] && cat "$state/images-list"
        exit 0 ;;
    rmi)
        # A real `docker rmi` refuses an image another container still
        # references; CLAUDE_ORCA_TEST_RMI_FAIL is that refusal.
        if [ "${CLAUDE_ORCA_TEST_RMI_FAIL:-0}" = "1" ]; then
            echo "Error response from daemon: conflict: unable to delete" >&2
            exit 1
        fi
        printf '%s\n' "$1" >> "$state/removed-images"
        exit 0 ;;
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
        name=""; port=""; proj=""; hostproj=""; prev=""
        for a in "$@"; do
            case "$prev" in
                --name) name="$a" ;;
                -e|--env)
                    case "$a" in
                        ORCA_PORT=*)   port="${a#ORCA_PORT=}" ;;
                        PROJECT_DIR=*) proj="${a#PROJECT_DIR=}" ;;
                        CLAUDE_ORCA_HOST_PROJECT_DIR=*)
                            hostproj="${a#CLAUDE_ORCA_HOST_PROJECT_DIR=}" ;;
                    esac ;;
            esac
            prev="$a"
        done
        # PROJECT_DIR is the path INSIDE the container (/workspace/<name>),
        # which does not exist out here. What the entrypoint writes to it
        # lands in the bind mount, and the bind mount is the host folder --
        # so a stub standing in for the entrypoint writes to the host path.
        [ -n "$hostproj" ] && proj="$hostproj"
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
    exec)
        # `claude-dev verify` runs the in-container checklist through
        # `docker exec` and parses its tab-separated rows, so the stub has
        # to answer like the real thing. CLAUDE_ORCA_TEST_VERIFY_FAIL
        # makes one row fail, which is the case the launcher's exit code
        # is about.
        case "$*" in
            *config-sync.sh*)
                # The host-side config resync (launcher's resync_config).
                # CLAUDE_ORCA_TEST_RESYNC_FAIL is the case where the exec
                # cannot run at all -- an image with no agent user, a
                # container that went away -- which must warn, not fail.
                [ "${CLAUDE_ORCA_TEST_RESYNC_FAIL:-0}" = "1" ] && exit 1
                exit 0 ;;
            *bin/provision*)
                # S5 (claude-orca-dbu.5): the doctor asks the container for
                # one row per provision step, the same tab-separated shape
                # verify-folder.sh answers in.
                printf 'ok\t10-toolchain-verify\tok -- 2026-09-12 12:00:00\n'
                if [ "${CLAUDE_ORCA_TEST_PROVISION_FAIL:-0}" = "1" ]; then
                    printf 'FAIL\t20-config-sync\texit 3 -- cp: cannot create the settings file\n'
                    exit 1
                fi
                printf 'ok\t20-config-sync\tok -- 2026-09-12 12:00:01\n'
                exit 0 ;;
            *verify-folder.sh*)
                # An image older than the checklist has no such script:
                # the exec fails and nothing comes back.
                [ "${CLAUDE_ORCA_TEST_VERIFY_SILENT:-0}" = "1" ] && exit 1
                printf 'ok\tmount point\t/workspace/stub\n'
                printf 'ok\thost paths\tone folder beside it, no /Users\n'
                if [ "${CLAUDE_ORCA_TEST_VERIFY_FAIL:-0}" = "1" ]; then
                    printf 'FAIL\trulebook\t~/.claude/CLAUDE.md differs from the template\n'
                else
                    printf 'ok\trulebook\t~/.claude/CLAUDE.md matches the template\n'
                fi
                printf 'n/a\topenrouter guard\tno key in this folder\n'
                [ "${CLAUDE_ORCA_TEST_VERIFY_FAIL:-0}" = "1" ] && exit 1
                exit 0 ;;
        esac
        exit 0 ;;
    logs)
        exit 0 ;;
esac
exit 0
STUB
    chmod +x "$1"
}

# Records what macOS was asked to open: a URL for the default browser, or
# `-a <bundle>` for an application (S3, claude-orca-8uo.4). The whole argv,
# so the one-argument URL case still logs exactly the URL. Also stands in
# for the app process itself actually coming up: any `-a <bundle>` launch
# flips the orca stub's own "is the app running" answer to true, the way a
# real `open -a` starting the process would (claude-orca-tgr) -- guarded
# on $ORCA_STUB_STATE existing at all, so a suite that never touches the
# orca stub writes one unread file and nothing else.
write_stub_open() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${OPEN_STUB_LOG:-/dev/null}"
if [ "${1:-}" = "-a" ] && [ -n "${ORCA_STUB_STATE:-}" ]; then
    mkdir -p "$ORCA_STUB_STATE"
    printf 'true\n' > "$ORCA_STUB_STATE/app-running"
fi
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

# S2 (claude-orca-8uo.3): `defaults read <plist> <key>` -- enough of the
# real macOS tool to read CFBundleShortVersionString out of the Info.plist
# of the fake Orca.app below, and nothing else. The real one takes the
# path with or without the .plist extension, so this takes both.
write_stub_defaults() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "read" ] || exit 1
plist="${2:-}"
key="${3:-}"
[ -f "$plist" ] || plist="$plist.plist"
[ -f "$plist" ] || { echo "Domain ${2:-} does not exist" >&2; exit 1; }
v="$(grep -A1 "<key>$key</key>" "$plist" \
    | sed -n 's|.*<string>\(.*\)</string>.*|\1|p' | head -1)"
[ -n "$v" ] || { echo "The domain/default pair of (${2:-}, $key) does not exist" >&2; exit 1; }
printf '%s\n' "$v"
STUB
    chmod +x "$1"
}

# An Orca.app bundle with the two files the launcher reads: the CLI under
# Contents/Resources/bin and the Info.plist `defaults` is asked for.
# Prints the bundle path. $1 is the bundle, $2 the version string.
make_fake_orca_app() {
    local app="${1:-$BATS_TEST_TMPDIR/Applications/Orca.app}" version="${2:-1.4.197}"
    mkdir -p "$app/Contents/Resources/bin"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$app/Contents/Resources/bin/orca"
    chmod +x "$app/Contents/Resources/bin/orca"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Orca</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
</dict>
</plist>
PLIST
    printf '%s\n' "$app"
}

# S3 (claude-orca-8uo.4): the Orca CLI the desktop hand-off drives, at
# the path orca_cli() resolves -- the app bundle's own
# Contents/Resources/bin/orca. It logs every invocation's argv as one line
# to $ORCA_STUB_LOG and keeps its world (how many times it has been asked
# for status, which environments the app has saved, which repos the Mac's
# own Orca tracks locally) in $ORCA_STUB_STATE and a handful of env vars,
# so a test puts it into any state without a fixture file.
#
# The one behaviour that matters and is easy to get wrong: `status --json`
# EXITS 0 whether the runtime is reachable or not (verified against
# 1.4.197, bead claude-orca-8uo.1), so the boolean in the JSON is the only
# signal there is. Same for a refused `environment add`: ok:false, exit 0.
write_stub_orca() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ORCA_STUB_LOG:-/dev/null}"
printf '%s\n' "${ORCA_USER_DATA_PATH:-}" >> "${ORCA_STUB_ENVPATH_LOG:-/dev/null}"
state="${ORCA_STUB_STATE:-${TMPDIR:-/tmp}/orca-stub}"
mkdir -p "$state"
envs="$state/environments"
[ -f "$envs" ] || : > "$envs"

# The value after a flag in argv, or nothing.
arg_after() {
    local want="$1" prev="" a
    shift
    for a in "$@"; do
        if [ "$prev" = "$want" ]; then printf '%s\n' "$a"; return 0; fi
        prev="$a"
    done
    return 1
}

case "$1" in
    status)
        n=0
        [ -f "$state/status-calls" ] && n="$(cat "$state/status-calls")"
        n=$((n + 1))
        printf '%s\n' "$n" > "$state/status-calls"
        reachable=true
        [ "$n" -le "${ORCA_STUB_REACHABLE_AFTER:-0}" ] && reachable=false
        [ "${ORCA_STUB_UNREACHABLE:-0}" = "1" ] && reachable=false
        # .result.app.running is a SEPARATE signal from runtime.reachable
        # (claude-orca-tgr): whether the desktop PROCESS is up at all.
        # ORCA_STUB_APP_RUNNING sets the initial answer (false by
        # default -- the ordinary "not launched yet" case); the file lets
        # the open/osascript stubs flip it as the run actually happens.
        running="${ORCA_STUB_APP_RUNNING:-false}"
        [ -f "$state/app-running" ] && running="$(cat "$state/app-running")"
        printf '{"ok":true,"result":{"runtime":{"reachable":%s},"app":{"running":%s}}}\n' \
            "$reachable" "$running"
        exit 0 ;;
    environment)
        sub="${2:-}"; shift 2 2>/dev/null || shift $#
        case "$sub" in
            add)
                name="$(arg_after --name "$@")" || name=""
                code="$(arg_after --pairing-code "$@")" || code=""
                if [ "${ORCA_STUB_ADD_FAIL:-0}" = "1" ]; then
                    printf '{"ok":false,"error":"the pairing offer was refused"}\n'
                    exit 0
                fi
                if grep -qxF "$name" "$envs"; then
                    printf '{"ok":false,"error":"A server named \"%s\" already exists."}\n' "$name"
                    exit 0
                fi
                printf '%s\n' "$name" >> "$envs"
                printf '%s\n' "$code" > "$state/pairing-code"
                printf '{"ok":true,"result":{"environment":{"id":"%s","name":"%s"}}}\n' \
                    "${ORCA_STUB_ENV_ID:-68b6f2e5-1111-2222-3333-444455556666}" "$name"
                exit 0 ;;
            rm)
                name="$(arg_after --environment "$@")" || name=""
                if grep -qxF "$name" "$envs"; then
                    grep -vxF "$name" "$envs" > "$envs.t" || :
                    mv "$envs.t" "$envs"
                    printf '{"ok":true,"result":{"removed":{"name":"%s"}}}\n' "$name"
                    exit 0
                fi
                printf '{"ok":false,"error":"No server named \"%s\" is saved."}\n' "$name"
                exit 0 ;;
            list)
                out=""; sep=""
                while IFS= read -r nm; do
                    [ -n "$nm" ] || continue
                    out="$out$sep{\"name\":\"$nm\"}"; sep=","
                done < "$envs"
                printf '{"ok":true,"result":{"environments":[%s]}}\n' "$out"
                exit 0 ;;
        esac
        exit 0 ;;
    repo)
        # `repo list --json` with NO --environment is the MAC's own list --
        # the local workspaces the desktop app would run outside any
        # container. `repo list` has no --host flag (1.4.197). When
        # $ORCA_STUB_DATA_DIR/orca-data.json exists this reads that file
        # back (the same store orca_strip_local_repo rewrites, so a strip
        # actually changes what this answers next); otherwise it falls
        # back to the plain $ORCA_STUB_LOCAL_REPOS list, for a case that
        # wants a leak the strip can never clear (claude-orca-tgr).
        remote=0
        for a in "$@"; do [ "$a" = "--environment" ] && remote=1; done
        if [ "$remote" = "1" ]; then
            printf '{"ok":true,"result":{"repos":[{"path":"/workspace/stub"}]}}\n'
            exit 0
        fi
        out=""; sep=""
        f="${ORCA_STUB_DATA_DIR:-}/orca-data.json"
        if [ -n "${ORCA_STUB_DATA_DIR:-}" ] && [ -f "$f" ] && command -v jq >/dev/null 2>&1; then
            while IFS= read -r p; do
                [ -n "$p" ] || continue
                out="$out$sep{\"path\":\"$p\"}"; sep=","
            done <<PATHS
$(jq -r '.repos[]?.path // empty' "$f" 2>/dev/null)
PATHS
        else
            for p in ${ORCA_STUB_LOCAL_REPOS:-}; do
                out="$out$sep{\"path\":\"$p\"}"; sep=","
            done
        fi
        printf '{"ok":true,"result":{"repos":[%s]}}\n' "$out"
        exit 0 ;;
esac
exit 0
STUB
    chmod +x "$1"
}

# The Mac's clipboard, as a file: the manual fallback puts the pairing URL
# on it when the CLI could not save the environment.
write_stub_pbcopy() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
cat > "${PBCOPY_STUB_LOG:-/dev/null}"
STUB
    chmod +x "$1"
}

# 1.4.197 has no `orca://` protocol handler, so a self-heal quits Orca by
# name through the GUI scripting bridge (claude-orca-tgr): `osascript -e
# 'tell application "<Name>" to quit'`. Records the whole argv and, like a
# real quit, flips the orca stub's own "is the app running" answer to
# false -- guarded on $ORCA_STUB_STATE existing, same as the open stub.
# OSASCRIPT_STUB_FAIL=1 stands in for a Mac with no osascript, or a quit
# that was refused.
write_stub_osascript() {
    cat > "$1" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${OSASCRIPT_STUB_LOG:-/dev/null}"
if [ "${OSASCRIPT_STUB_FAIL:-0}" = "1" ]; then
    exit 1
fi
if [ -n "${ORCA_STUB_STATE:-}" ]; then
    mkdir -p "$ORCA_STUB_STATE"
    printf 'false\n' > "$ORCA_STUB_STATE/app-running"
fi
exit 0
STUB
    chmod +x "$1"
}

# --- per-test environment -------------------------------------------------

setup() {
    # This suite can itself be running inside a claude-orca container (the
    # dev box this template runs on IS one), which sets these two for its
    # OWN real Orca -- leaving either set would point orca_user_data_dir()
    # and orca_strip_local_repo() at the HOST's actual state instead of a
    # test's fixture (claude-orca-tgr).
    unset ORCA_USER_DATA_PATH
    unset CLAUDE_ORCA_HOST_PROJECT_DIR

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

    # S2 (claude-orca-8uo.3): every suite drives the bootstrap as a Mac
    # (make_project_v3 pins uname to Darwin), and the Darwin preflight now
    # refuses to install without an Orca.app. So the fixture Mac has one,
    # pointed at by the same override a real user would use -- and the
    # cases that are ABOUT a Mac with no Orca point the override at a path
    # that does not exist, which is an answer on any host, Mac included.
    write_stub_defaults "$STUB_BIN/defaults"
    export CLAUDE_ORCA_APP="$(make_fake_orca_app)"

    # S3 (claude-orca-8uo.4): where the orca CLI stub logs its argv and
    # keeps its state, and where the clipboard ends up. `pbcopy` goes on
    # PATH for every suite and is inert until the desktop hand-off's
    # manual fallback runs; the orca stub is NOT installed globally -- the
    # fake app carries an inert `exit 0` until a desktop case replaces it,
    # so no other suite's `./claude-dev` learns to talk to an app.
    export ORCA_STUB_LOG="$BATS_TEST_TMPDIR/orca.log"
    : > "$ORCA_STUB_LOG"
    # One line per ORCA_STUB_LOG line, the value $ORCA_USER_DATA_PATH
    # carried into that call (empty line when it carried none) -- a
    # companion file rather than baking it into ORCA_STUB_LOG itself, so
    # every existing exact-line assertion against that log stays literal.
    # Since claude-orca-tgr the launcher never SETS this itself; the log
    # is what "carries no override" (a PASS-IF case) checks against.
    export ORCA_STUB_ENVPATH_LOG="$BATS_TEST_TMPDIR/orca-envpath.log"
    : > "$ORCA_STUB_ENVPATH_LOG"
    export ORCA_STUB_STATE="$BATS_TEST_TMPDIR/orca-state"
    mkdir -p "$ORCA_STUB_STATE"
    export PBCOPY_STUB_LOG="$BATS_TEST_TMPDIR/pbcopy.log"
    : > "$PBCOPY_STUB_LOG"
    write_stub_pbcopy "$STUB_BIN/pbcopy"
    export OSASCRIPT_STUB_LOG="$BATS_TEST_TMPDIR/osascript.log"
    : > "$OSASCRIPT_STUB_LOG"
    write_stub_osascript "$STUB_BIN/osascript"
    # orca_user_data_dir()'s own fallback path (claude-orca-tgr) --
    # $HOME/Library/Application Support/Orca, standing in for the Mac's
    # own copy without a folder-specific override. Not created here: a
    # test creates it (and drops an orca-data.json fixture in it) only
    # when it means to exercise that path, the same way no other Mac
    # directory in this suite exists until a case needs it.
    export ORCA_STUB_DATA_DIR="$HOME/Library/Application Support/Orca"

    # A desktop hand-off that cannot complete falls back to the browser,
    # and every suite that registers a folder takes that path (the docker
    # stub publishes no real pairing offer). Nothing should sit in a poll
    # loop for a minute to get there: the cases that are ABOUT the wait
    # raise it themselves.
    export CLAUDE_ORCA_ORCA_WAIT=2

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
