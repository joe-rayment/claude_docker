#!/usr/bin/env bats
#
# The line between what an image bakes and what a folder installs.
#
# The image used to carry the whole toolchain: ~1.9 GB, ~11 minutes of
# install, and 15m41s of every CI run spent carrying it through QEMU for
# an arm64 image (run 34138260827's own step timings). All of it rebuilt
# and republished whenever any pin moved, and none of it visible from the
# Mac -- a version bump meant a CI round trip before a folder could see
# the result.
#
# So the line is drawn at apt, because that is where it can be drawn:
#
#   IMAGE_PHASES      base, node, gh, Orca's GTK/at-spi/xvfb libraries,
#                     the agent user. apt state -- /var/lib/dpkg, /etc,
#                     ld caches -- which no bind mount can hold.
#   TOOLCHAIN_PHASES  bats, bd, dolt, claude, opencode, orca. Files, under
#                     /usr/local, /opt/Orca and /opt/claude and nowhere
#                     else, which a bind mount holds perfectly well.
#
# The second set installs into <project>/.claude-dev/toolchain on a
# folder's first start, mounted over those three paths -- so it survives
# every recreate, a person can read and delete it from the Mac, and the
# filesystem Orca runs on is the same one the baked image produced.
#
# Measured on a real Mac, 2026-09-07: with the prebuilt image, a recreate
# went from ~11 minutes to 3.7 s, every phase reporting "already present".
# On the runtime path (plain ubuntu:24.04) the apt half still reinstalls,
# because dpkg state is exactly what a bind mount cannot carry.
#
# One thing did move, deliberately: opencode installs with --prefix
# /usr/local instead of npm's default /usr/lib/node_modules, so its 352 MB
# lands in the cache. Same binary, same PATH, same version -- a different
# node_modules root, and `installed_opencode` looks where it installs.
#
# These cases are the static half: the partition, the Dockerfile, and the
# mounts. The half that needs a real container -- that the shape after
# setup.sh matches the shape the old image had (`setup.sh --check`), and
# that a recreate says "already present" instead of installing again --
# is in .github/workflows/image.yml, which has a daemon to prove it with.
#
# Assertions are functions, never a bare `[[ ]]`: under macOS bash 3.2 a
# failing `[[ ]]` does not fail its test (see run-tests.sh).

load helpers/setup

SETUP="${BATS_TEST_DIRNAME}/../scripts/container/setup.sh"
DOCKERFILE="${BATS_TEST_DIRNAME}/../Dockerfile"
LAUNCHER="${BATS_TEST_DIRNAME}/../scripts/launcher.sh"

contains() {
    case "$1" in
        *"$2"*) return 0 ;;
    esac
    printf 'expected to contain: %s\n           actual: %s\n' "$2" "$1" >&2
    return 1
}

@test "the phase sets partition every phase except template, which the Dockerfile runs by name" {
    local all image toolchain p
    all="$(bash "$SETUP" --list | tr '\n' ' ')"
    image="$(bash "$SETUP" --list image | tr '\n' ' ')"
    toolchain="$(bash "$SETUP" --list toolchain | tr '\n' ' ')"

    [ -n "$image" ]
    [ -n "$toolchain" ]

    # Nothing in both -- a phase that ran at build AND at start would be
    # doing its work twice on every folder.
    for p in $image; do
        case " $toolchain " in
            *" $p "*) echo "phase $p is in both sets"; return 1 ;;
        esac
    done

    # Nothing unaccounted for except `template`, which needs a template
    # copied in first and so is run by name, after the COPY.
    for p in $all; do
        case " $image $toolchain template " in
            *" $p "*) ;;
            *) echo "phase $p is in neither set"; return 1 ;;
        esac
    done
}

@test "the toolchain set is exactly the six tools that live under the cached paths" {
    local toolchain
    toolchain="$(bash "$SETUP" --list toolchain | sort | tr '\n' ' ')"
    [ "$toolchain" = "bats bd claude dolt opencode orca " ]
}

@test "the Dockerfile bakes the image phases only, and never the toolchain" {
    run grep -qE '^RUN .*/opt/claude-orca-setup\.sh --image$' "$DOCKERFILE"
    [ "$status" -eq 0 ]

    # The old form ran every phase, which is what baked 1.2GB of payload.
    run grep -qE '^RUN .*claude-orca-setup\.sh$' "$DOCKERFILE"
    [ "$status" -ne 0 ]

    # `template` still runs by name after the repo is copied in.
    run grep -qE '^RUN /opt/claude-orca/scripts/container/setup\.sh --phase template' "$DOCKERFILE"
    [ "$status" -eq 0 ]
}

@test "the launcher mounts the folder's toolchain cache over the three paths the tools live at" {
    mkdir -p "$PROJECT_DIR"
    local primary line
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    line="$(grep '^run ' "$CONTAINER_STUB_LOG" | head -1)"
    [ -n "$line" ]

    contains "$line" "--volume $primary/.claude-dev/toolchain/usr-local:/usr/local"
    contains "$line" "--volume $primary/.claude-dev/toolchain/opt-Orca:/opt/Orca"
    contains "$line" "--volume $primary/.claude-dev/toolchain/opt-claude:/opt/claude"

    # Never /opt itself: that would shadow /opt/claude-orca, which IS the
    # image's copy of this template.
    run grep -qE -- "--volume [^ ]*toolchain[^ ]*:/opt " <<<"$line"
    [ "$status" -ne 0 ]
}

@test "the launcher creates the cache directories before the run, so docker does not" {
    mkdir -p "$PROJECT_DIR"
    local primary d
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    for d in usr-local opt-Orca opt-claude; do
        [ -d "$primary/.claude-dev/toolchain/$d" ]
    done
}

@test "orca's already-present check is answerable from the cache alone" {
    # /opt/orca and /usr/bin/orca-ide are symlinks OUTSIDE the cache: a
    # recreated container has neither, even with the payload right there.
    # Re-linking has to happen before the version check, or every recreate
    # pays the full reinstall the cache exists to avoid.
    local body
    body="$(sed -n '/^phase_orca()/,/^}/p' "$SETUP")"
    contains "$body" "orca_relink"

    local relink_line check_line
    relink_line="$(printf '%s\n' "$body" | grep -n 'orca_relink' | head -1 | cut -d: -f1)"
    check_line="$(printf '%s\n' "$body" | grep -n 'stamp /opt/orca/VERSION' | head -1 | cut -d: -f1)"
    [ -n "$relink_line" ]
    [ -n "$check_line" ]
    [ "$relink_line" -lt "$check_line" ]
}

@test "the orca payload is extracted, not apt-installed, so no dpkg state is required to own it" {
    local body
    body="$(sed -n '/^phase_orca()/,/^}/p' "$SETUP")"
    contains "$body" "dpkg-deb -x"

    # apt would register a package in a dpkg database that dies with the
    # container, leaving the next start with an installed-but-unknown Orca.
    run grep -qE 'apt-get install .*orca\.deb' <<<"$body"
    [ "$status" -ne 0 ]

    # And the hand-listed dependency set is checked against the .deb's own
    # Depends, so the list cannot drift silently.
    contains "$body" "dpkg-deb --field"
    contains "$body" "ORCA_PACKAGES"
}

@test "opencode installs into the cached prefix rather than the image's node_modules" {
    run grep -qE '^NPM_PREFIX=' "$SETUP"
    [ "$status" -eq 0 ]

    local body
    body="$(sed -n '/^phase_opencode()/,/^}/p' "$SETUP")"
    contains "$body" '--prefix "$NPM_PREFIX"'

    # `npm root -g` answers /usr/lib/node_modules, which the container
    # layer holds -- the version check has to look where it installed.
    # Comments stripped first: this file explains npm root -g at the top.
    run bash -c "grep -vE '^[[:space:]]*#' '$SETUP' | grep -qE 'npm root -g'"
    [ "$status" -ne 0 ]
}

@test "a full cache does not shorten the wait when the image itself installs apt on every start" {
    # The regression this case exists for: keying the short timeout on the
    # toolchain cache alone. A folder on the runtime path (plain
    # ubuntu:24.04) reinstalls the apt half on every recreate -- ~5
    # minutes -- and a full toolchain cache says nothing about that. On a
    # real Mac (2026-09-07) that folder got 120 s for a 280 s job and the
    # launcher gave up on a container that was working fine.
    mkdir -p "$PROJECT_DIR"
    local primary
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    # A cache with Orca in it: the "nothing left to install" flag.
    mkdir -p "$primary/.claude-dev/toolchain/opt-Orca"
    printf '#!/bin/sh\n' > "$primary/.claude-dev/toolchain/opt-Orca/orca-ide"
    chmod +x "$primary/.claude-dev/toolchain/opt-Orca/orca-ide"
    printf 'runtime\n' > "$primary/.claude-dev/run/image-source"

    # ... and a container that comes up but publishes no URL, so the wait
    # runs to its limit and the error names the limit it chose.
    export CLAUDE_ORCA_TEST_NO_URL=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT_RUNTIME=2
    rm -f "$primary/.claude-dev/run/orca-web-url.txt"
    rm -f "$CONTAINER_STUB_STATE/containers/claude-orca-$(basename "$primary")"

    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -ne 0 ]
    contains "$output" "within 2s"
}
