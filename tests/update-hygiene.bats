#!/usr/bin/env bats
#
# `./claude-dev --update` says what it moved, and cleans up after itself.
#
# The complaint this answers: a rebuild that only rewrote the repo copy and
# one that replaced every layer looked alike from out here, and said
# nothing either way. The local image id is the only witness, and it is
# now reported in the same shape as the template line above it.
#
# The other half is leftovers. A build leaves the previous manifest on disk
# untagged (several GB), and a recreated container inherits the previous
# one's run/ results -- a pairing URL that pairs with nothing most of all.
# run/ holds results and state/ holds authority (CLAUDE.md), so only run/
# is cleared, and only images of OUR repo that are untagged and not the one
# just built are removed.

load helpers/setup

REPO="claude-orca"

# A 64-hex image id whose first 7 characters are $1 repeated -- what the
# docker stub reports for the image the pull just recorded.
stub_id() {
    printf '%s' "$1"
    i=0
    while [ "$i" -lt 63 ]; do printf '%s' "$1"; i=$((i + 1)); done
}

@test "update reports the image id it moved to, and says so when it did not move" {
    export CLAUDE_ORCA_TEST_IMAGE_ID="$(stub_id a)"
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    # Registration built id aaaa...; the rebuild produces bbbb...
    export CLAUDE_ORCA_TEST_IMAGE_ID="$(stub_id b)"
    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]
    [[ "$output" == *"  image: aaaaaaa -> bbbbbbb"* ]]
    [[ "$output" != *"already up to date (bbbbbbb)"* ]]

    # The same tag built again, unchanged: the line that was missing.
    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]
    [[ "$output" == *"  image: already up to date (bbbbbbb)"* ]]
    [[ "$output" != *"bbbbbbb -> "* ]]
}

@test "update removes our repo's untagged old images, never a tagged one, never another repo's, never the one just built" {
    export CLAUDE_ORCA_TEST_IMAGE_ID="$(stub_id a)"
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    export CLAUDE_ORCA_TEST_IMAGE_ID="$(stub_id b)"
    cat > "$CONTAINER_STUB_STATE/images-list" <<LIST
$REPO <none> sha256:$(stub_id c)
$REPO v9 sha256:$(stub_id d)
someone/else-image <none> sha256:$(stub_id e)
$REPO <none> sha256:$(stub_id b)
LIST

    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]
    [[ "$output" == *"  removed 1 old image version (ccccccc)"* ]]

    grep -qx "rmi ccccccc" "$CONTAINER_STUB_LOG"
    ! grep -q "^rmi ddddddd" "$CONTAINER_STUB_LOG"   # tagged: someone's
    ! grep -q "^rmi eeeeeee" "$CONTAINER_STUB_LOG"   # another repo
    ! grep -q "^rmi bbbbbbb" "$CONTAINER_STUB_LOG"   # the one just built
}

# The tag is the IMAGE_TAG file alone now, so an update that moves a folder
# onto a new tag (or off the old claude-orca:latest-orca<v> refs that
# folded in an Orca version) leaves the previous refs on the Mac -- tagged,
# so prune_old_images never collects them (that one gathers <none> layers
# only). A built update therefore rmis every OTHER ref of our repo that no
# container still uses: `docker ps -a` -- stopped ones included -- is what
# "in use" means. The ref a container was run from keeps it.
# Guards:   --update removes superseded tagged refs of our repo (an older tag, an
#           old -orca<v> ref) but never the new ref, one in use, or another repo's
# Fails if: the cleanup removes the ref just built, one a container runs from,
#           or another repo's image -- or leaves old -orca<v> refs behind
# Run:      bats -f 'update rmi' tests/update-hygiene.bats
@test "update rmi's our repo's superseded tagged refs -- an older tag and old -orca<v> refs -- that no container still uses, never the new ref, never one in use, never another repo's" {
    export CLAUDE_ORCA_TEST_IMAGE_ID="$(stub_id a)"
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    # Another folder's container is still on latest-orca1.3.0 and must keep it.
    rm -f "$CONTAINER_STUB_STATE/preset-applied"
    export DOCKER_STUB_PRESET_CONTAINER="claude-orca-past:claude-orca:latest-orca1.3.0:$primary:7777"
    export CLAUDE_ORCA_TEST_IMAGE_ID="$(stub_id b)"
    cat > "$CONTAINER_STUB_STATE/images-list" <<LIST
claude-orca:ssh1 sha256:$(stub_id c)
claude-orca:latest-orca1.4.100 sha256:$(stub_id d)
claude-orca:latest-orca1.3.0 sha256:$(stub_id f)
someone/else-image:latest sha256:$(stub_id e)
claude-orca:latest sha256:$(stub_id b)
LIST

    : > "$CONTAINER_STUB_LOG"
    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]

    grep -qx "rmi claude-orca:ssh1" "$CONTAINER_STUB_LOG"
    grep -qx "rmi claude-orca:latest-orca1.4.100" "$CONTAINER_STUB_LOG"
    ! grep -q "rmi claude-orca:latest$" "$CONTAINER_STUB_LOG"
    ! grep -qx "rmi claude-orca:latest-orca1.3.0" "$CONTAINER_STUB_LOG"
    ! grep -qx "rmi someone/else-image:latest" "$CONTAINER_STUB_LOG"
}

# `docker rmi` refuses an image another container still references. That is
# a normal answer, not a failed update.
@test "an rmi that fails does not fail the update" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    export CLAUDE_ORCA_TEST_IMAGE_ID="$(stub_id b)"
    export CLAUDE_ORCA_TEST_RMI_FAIL=1
    printf '%s <none> sha256:%s\n' "$REPO" "$(stub_id c)" \
        > "$CONTAINER_STUB_STATE/images-list"

    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]
    [[ "$output" != *"removed"* ]]
    [[ "$output" != *"conflict: unable to delete"* ]]
}

@test "update clears the folder's run/ results and leaves state/, claude-orca.json and the home alone" {
    mkdir -p "$PROJECT_DIR"
    primary="$(abspath "$PROJECT_DIR")"
    run make_project_v3 "$primary"
    [ "$status" -eq 0 ]

    run_dir="$primary/.claude-dev/run"
    mkdir -p "$run_dir" "$primary/.claude-dev/state"
    printf 'http://127.0.0.1:1/web-index.html#pairing=STALE\n' > "$run_dir/orca-web-url.txt"   # an old Orca result
    printf 'STALE\n' > "$run_dir/orca-serve.log"
    printf 'STALE\n' > "$run_dir/setup.log"
    printf '99999\n' > "$run_dir/port"
    printf 'authority\n' > "$primary/.claude-dev/state/image-digest"
    json="$primary/.claude-dev/claude-orca.json"
    before_json="$(cat "$json")"

    run bash -c "cd '$primary' && ./claude-dev --update"
    [ "$status" -eq 0 ]

    # Results: the previous container's, and gone with it.
    [ ! -f "$run_dir/orca-serve.log" ]
    [ ! -f "$run_dir/setup.log" ]
    [ ! -e "$run_dir/orca-web-url.txt" ]   # an old Orca result: cleared too
    [ "$(cat "$run_dir/port")" = "$(jq -r '.port' "$json")" ]

    # Authority, config and home: untouched.
    [ "$(cat "$primary/.claude-dev/state/image-digest")" = "authority" ]
    [ "$(cat "$json")" = "$before_json" ]
    [ -d "$primary/.claude-dev/home" ]
}
