#!/usr/bin/env bats
#
# The line between what the image bakes and what a folder installs.
#
# It has moved twice, and the second move is the one that stuck.
#
# Until 2026-09-07 the image carried the whole toolchain: ~1.9 GB, and
# 15m41s of every CI run spent carrying it through QEMU for the arm64 leg.
# So it was split at apt -- apt state in the image, the five pinned tools
# into <project>/.claude-dev/toolchain on a folder's first start -- on the
# reasoning that a bind mount can hold files and cannot hold dpkg state.
#
# Then the split was measured on a real Mac, and the reasoning was right
# about bind mounts and wrong about the cost. A folder's FIRST start went
# to ~18 minutes, of which 15.5 were setup.sh downloading 1.3 GB of
# payload at the network's 2.5 MB/s -- once per folder, with nothing
# shared between folders, because a per-folder cache is by definition not
# a cache anyone else can use. Docker's own layer cache had been doing
# exactly that job for free. Worse, installing into a bind mount is what
# broke the macOS CI job outright: colima's virtiofs refuses the chown
# (`install: cannot change ownership of '/usr/local/bin/dolt'`), so the
# one automated check of the Mac path could never pass.
#
# So the toolchain is baked again, and the folder carries a cache only on
# the runtime path -- plain ubuntu:24.04, which is what a folder runs when
# the local build fails and there is no baked anything to reuse. One build
# per Mac, layer-cached and shared by every folder; a pin bump rebuilds the
# layers below it and no more, which is what the per-phase RUN ordering in
# the Dockerfile is for.
#
# The phase partition itself is unchanged and still load-bearing: --image
# and --toolchain are how the Dockerfile bakes in two halves, and how a
# runtime-path folder installs the half it is missing.
#
# These cases are the static half: the partition, the Dockerfile, the
# mounts and the wait. The half that needs a real container -- that the
# shape after setup.sh is the shape the image promised -- is in
# tests/mac-e2e.sh, which has a daemon.
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

lacks() {
    case "$1" in
        *"$2"*)
            printf 'expected NOT to contain: %s\n               actual: %s\n' "$2" "$1" >&2
            return 1 ;;
    esac
    return 0
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
    [ "$toolchain" = "bats bd dolt helix opencode orca " ]
}

@test "the Dockerfile bakes the apt half in one layer and each toolchain phase in its own" {
    run grep -qE '^RUN .*/opt/claude-orca-setup\.sh --image$' "$DOCKERFILE"
    [ "$status" -eq 0 ]

    # One RUN per toolchain phase, not one RUN for all five: a pin bump
    # then rebuilds that layer and the ones after it, never the whole
    # 1.3 GB.
    local p
    for p in $(bash "$SETUP" --list toolchain); do
        run grep -qE "^RUN .*claude-orca-setup\.sh --phase $p\$" "$DOCKERFILE"
        [ "$status" -eq 0 ] || { echo "no RUN for toolchain phase $p"; return 1; }
    done

    # `template` still runs by name after the repo is copied in.
    run grep -qE '^RUN /opt/claude-orca/scripts/container/setup\.sh --phase template' "$DOCKERFILE"
    [ "$status" -eq 0 ]
}

@test "the repo copy comes after every toolchain layer, so editing a script rebuilds none of them" {
    # COPY . /opt/claude-orca changes on every commit. Above the toolchain
    # RUNs it would invalidate all of them, and the image would cost a
    # full payload rebuild for a one-line comment.
    local copy_at last_phase_at p at
    copy_at="$(grep -nE '^COPY (--chown=[^ ]+ )?\. /opt/claude-orca$' "$DOCKERFILE" | head -1 | cut -d: -f1)"
    [ -n "$copy_at" ]

    last_phase_at=0
    for p in $(bash "$SETUP" --list toolchain); do
        at="$(grep -n -- "--phase $p\$" "$DOCKERFILE" | head -1 | cut -d: -f1)"
        [ -n "$at" ] || { echo "no RUN for toolchain phase $p"; return 1; }
        [ "$at" -gt "$last_phase_at" ] && last_phase_at="$at"
    done

    [ "$copy_at" -gt "$last_phase_at" ] \
        || { echo "COPY . /opt/claude-orca is at line $copy_at, above a toolchain RUN at $last_phase_at"; return 1; }
}

@test "a folder on the built image mounts no toolchain cache, and grows no toolchain directory" {
    # The image carries the payload now. Mounting a folder directory over
    # /usr/local would hide it and hand the folder a 15-minute install it
    # does not need.
    mkdir -p "$PROJECT_DIR"
    local primary line
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    [ "$(cat "$primary/.claude-dev/run/image-source")" = "built" ]

    line="$(grep '^run ' "$CONTAINER_STUB_LOG" | head -1)"
    [ -n "$line" ]
    lacks "$line" "toolchain"

    [ ! -d "$primary/.claude-dev/toolchain" ] \
        || { echo "a folder on the built image grew a toolchain directory"; return 1; }
}

@test "a folder on the runtime path mounts the cache it installs into, and the launcher makes it first" {
    # No image within reach -- the build could not run and the daemon
    # holds no copy -- so the folder runs plain ubuntu:24.04 and setup.sh
    # installs the payload at first start, into the folder, mounted over
    # the three paths those tools live at, so a recreate reuses it.
    mkdir -p "$PROJECT_DIR"
    local primary line d
    primary="$(abspath "$PROJECT_DIR")"
    export CLAUDE_ORCA_TEST_BUILD_FAIL=1
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]
    [ "$(cat "$primary/.claude-dev/run/image-source")" = "runtime" ]

    line="$(grep '^run ' "$CONTAINER_STUB_LOG" | head -1)"
    [ -n "$line" ]
    contains "$line" "--volume $primary/.claude-dev/toolchain/usr-local:/usr/local"
    contains "$line" "--volume $primary/.claude-dev/toolchain/opt-Orca:/opt/Orca"

    # Never /opt itself: that would shadow /opt/claude-orca, which IS the
    # image's copy of this template.
    run grep -qE -- "--volume [^ ]*toolchain[^ ]*:/opt " <<<"$line"
    [ "$status" -ne 0 ]

    # Made by the launcher, so docker does not create root-owned ones.
    for d in usr-local opt-Orca; do
        [ -d "$primary/.claude-dev/toolchain/$d" ]
    done
}

@test "the wait is chosen by which image the folder runs, and a cache cannot shorten it" {
    # Keying the short timeout on a folder's cache is what killed a
    # working container at 2m12s on a real Mac. The question is only ever
    # "does this start install anything", and the image answers it.
    local fns probe out
    fns="$(sed -n '/^image_source()/,/^}$/p;/^folder_installs_toolchain()/,/^}$/p;/^weburl_timeout()/,/^}$/p' "$LAUNCHER")"
    [ -n "$fns" ]
    probe="$BATS_TEST_TMPDIR/timeout-probe.sh"
    mkdir -p "$BATS_TEST_TMPDIR/pulled/.claude-dev/run" \
             "$BATS_TEST_TMPDIR/runtime/.claude-dev/run" \
             "$BATS_TEST_TMPDIR/runtime/.claude-dev/toolchain/opt-Orca"
    printf 'pulled\n'  > "$BATS_TEST_TMPDIR/pulled/.claude-dev/run/image-source"
    printf 'runtime\n' > "$BATS_TEST_TMPDIR/runtime/.claude-dev/run/image-source"
    # A full cache on the runtime folder: it still installs apt every time.
    printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/runtime/.claude-dev/toolchain/opt-Orca/orca-ide"

    {
        printf '%s\n' 'set -uo pipefail'
        printf '%s\n' "$fns"
        printf '%s\n' 'printf "pulled=%s runtime=%s\n" "$(weburl_timeout "$1")" "$(weburl_timeout "$2")"'
    } > "$probe"
    out="$(bash "$probe" "$BATS_TEST_TMPDIR/pulled" "$BATS_TEST_TMPDIR/runtime")"
    [ "$out" = "pulled=120 runtime=1800" ] \
        || { echo "want 'pulled=120 runtime=1800', got '$out'"; return 1; }
}

@test "the build context excludes the folder's own .claude-dev, and the template copy is not chowned into a second layer" {
    # The first real build of the toolchain image came out at 7.84 GB.
    # 1.39 GB of that was `COPY . /opt/claude-orca` carrying the working
    # checkout's OWN .claude-dev -- an agent home and, on the runtime
    # path, a 1.3 GB toolchain -- and another 1.51 GB was phase_template's
    # `chown -R` rewriting every one of those inodes into a fresh
    # overlayfs layer.
    local ignore="${BATS_TEST_DIRNAME}/../.dockerignore"
    local d
    for d in .claude-dev .git tests/.cache attachments; do
        grep -qxF "$d" "$ignore" || { echo ".dockerignore does not exclude $d"; return 1; }
    done

    # COPY --chown, so the chown in phase_template has nothing to do.
    grep -qE '^COPY --chown=[^ ]+ \. /opt/claude-orca$' "$DOCKERFILE" \
        || { echo "the template COPY does not set ownership itself"; return 1; }

    # ... and the phase only chowns when it is actually wrong.
    local body
    body="$(sed -n '/^phase_template()/,/^}/p' "$SETUP")"
    contains "$body" "stat -c '%u' /opt/claude-orca"
}

@test "orca's already-present check is answerable from the cache alone" {
    # /opt/orca and /usr/bin/orca-ide are symlinks OUTSIDE the cache: a
    # recreated container has neither, even with the payload right there.
    # Re-linking has to happen before the version check, or every recreate
    # pays the full reinstall the cache exists to avoid.
    local body
    body="$(sed -n '/^phase_orca()/,/^}/p' "$SETUP" "${SETUP%/*}"/phases/*.sh)"
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
    body="$(sed -n '/^phase_orca()/,/^}/p' "$SETUP" "${SETUP%/*}"/phases/*.sh)"
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
    body="$(sed -n '/^phase_opencode()/,/^}/p' "$SETUP" "${SETUP%/*}"/phases/*.sh)"
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

    # ... and a container that comes up but never gets sshd listening, so the wait
    # runs to its limit and the error names the limit it chose.
    export CLAUDE_ORCA_TEST_NO_SSHD=1
    export CLAUDE_ORCA_WEBURL_TIMEOUT_RUNTIME=2
    rm -f "$primary/.claude-dev/run/sshd.ready"
    rm -f "$CONTAINER_STUB_STATE/containers/claude-orca-$(basename "$primary")"

    run bash -c "cd '$primary' && ./claude-dev open"
    [ "$status" -ne 0 ]
    contains "$output" "within 2s"
}

@test "the entrypoint hands a mounted toolchain cache to the host uid, so the folder can be deleted" {
    # setup.sh installs the cache as root. On Linux a bind mount keeps
    # that, so <project>/.claude-dev/toolchain ends up full of root-owned
    # files the folder's owner cannot remove and `--teardown` dies on 1.3
    # GB it cannot delete (CI run 34150776165). macOS hides it: Docker
    # Desktop maps every write to the calling user. So the entrypoint
    # chowns the cache after the uid remap -- and only when those paths
    # really are the folder's mounts, never the image's own /usr/local.
    local body
    body="$(sed -n '/HOST_UID/,/^fi$/p' "${BATS_TEST_DIRNAME}/../scripts/container/entrypoint.sh")"
    contains "$body" "mountpoint -q"
    contains "$body" "/opt/Orca"
    contains "$body" "chown_agent_tree"
}

@test "a build that says nothing is reported as such, with the clock and a way out" {
    # `==> Building ...` and then nothing was the whole of the output while
    # two wedged pulls of the same image sat with no network activity for
    # 20 minutes on 2026-09-07 -- the same shape a wedged build can take
    # now that the image is built rather than pulled. The setup.log wait
    # had already solved this shape; the builder had not.
    local fns out
    fns="$(sed -n '/^BUILD_OUT=/,/^}$/p' "${BATS_TEST_DIRNAME}/../scripts/launcher.sh" \
        | sed -n '/^try_build()/,/^}$/p')"
    [ -n "$fns" ]

    # A build that speaks once and then wedges, which is what a stuck one
    # looks like from out here.
    out="$(CTR_RUN_DIR="$BATS_TEST_TMPDIR" bash -c "
set -uo pipefail
ctr() { printf 'Step 1/12 : FROM ubuntu:24.04\n'; sleep 6; }
$fns
BUILD_TICK=1; BUILD_STALL=2
try_build claude-orca:latest /tmp/ctx" 2>&1)"

    contains "$out" "building (1s): Step 1/12 : FROM ubuntu:24.04"
    contains "$out" "the build has said nothing for"
    contains "$out" "^C is safe"

    # The how-to once, the clock as often as it likes.
    [ "$(printf '%s\n' "$out" | grep -c '\^C is safe')" = "1" ]
    [ "$(printf '%s\n' "$out" | grep -c 'the build has said nothing for')" -ge 2 ]
}

@test "a build that works still returns its output for the failure diagnosis" {
    local fns probe out
    fns="$(sed -n '/^BUILD_OUT=/,/^}$/p' "${BATS_TEST_DIRNAME}/../scripts/launcher.sh" \
        | sed -n '/^try_build()/,/^}$/p')"
    [ -n "$fns" ]
    probe="$BATS_TEST_TMPDIR/probe.sh"

    # Failure: the last line of the build's own output is the diagnosis the
    # caller prints, so try_build has to keep carrying it in BUILD_OUT.
    {
        printf '%s\n' 'set -uo pipefail'
        printf '%s\n' 'ctr() { printf "failed to solve: process did not complete successfully\n"; return 1; }'
        printf '%s\n' "$fns"
        printf '%s\n' 'BUILD_TICK=1; BUILD_STALL=999'
        printf '%s\n' 'if try_build claude-orca:latest /tmp/ctx; then'
        printf '%s\n' '    echo "rc=0"'
        printf '%s\n' 'else'
        printf '%s\n' '    echo "rc=$?"'
        printf '%s\n' '    printf "last=%s\n" "$(printf "%s\n" "$BUILD_OUT" | tail -1)"'
        printf '%s\n' 'fi'
    } > "$probe"
    out="$(CTR_RUN_DIR="$BATS_TEST_TMPDIR" bash "$probe" 2>&1)"
    contains "$out" "rc=1"
    contains "$out" "last=failed to solve: process did not complete successfully"

    # Success: rc 0, and nothing extra on a build too quick to tick.
    {
        printf '%s\n' 'set -uo pipefail'
        printf '%s\n' 'ctr() { printf "Successfully tagged claude-orca:latest\n"; return 0; }'
        printf '%s\n' "$fns"
        printf '%s\n' 'BUILD_TICK=1; BUILD_STALL=999'
        printf '%s\n' 'try_build x /tmp/ctx && echo "rc=0"'
    } > "$probe"
    out="$(CTR_RUN_DIR="$BATS_TEST_TMPDIR" bash "$probe" 2>&1)"
    contains "$out" "rc=0"
    lacks "$out" "said nothing"
}
