#!/usr/bin/env bats

# Guards:   the Mac-side scripts stay runnable on macOS's stock bash 3.2
#           (no associative arrays, mapfile, ${x^^}, &>>, |&, or an unguarded
#           "${arr[@]}" append under set -u).
# Fails if: someone adds a bash 4+ construct to bootstrap.sh, launcher.sh,
#           link-bin.sh, scripts/lib/ or run-tests.sh.
# Run:      bats tests/lint-bash32.bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

@test "the Mac-side scripts pass the bash 3.2 lint" {
    cd "$REPO_ROOT"
    run bash scripts/lint-bash32.sh bootstrap.sh scripts/launcher.sh \
        scripts/link-bin.sh scripts/lib run-tests.sh
    echo "$output"
    [ "$status" -eq 0 ]
}
