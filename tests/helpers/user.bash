#!/usr/bin/env bash
#
# Which user a case needs, declared in one line at the top of the case.
#
# The suite runs in two places that disagree about uid: the image's own
# checks run as root, and the folder's container runs everything as the
# `agent` user (uid 501 here). A handful of cases genuinely cannot run as
# one or the other -- installing apt packages needs root, and a case whose
# whole assertion is "a non-root run is refused and says so" needs a
# non-root user to refuse. Left undeclared, those show up as red rows that
# say nothing about the code, and they bury the ones that do.
#
# A skip is a claim, so the reason has to name what is missing rather than
# just the uid: `need_root "installs apt packages"` reads
#
#   ok 3 ... # skip needs root: installs apt packages
#
# in the TAP output, which is enough to tell a legitimately-skipped row
# from a case that quietly stopped testing anything.
#
# Deliberately free of setup_file and of any fixture, so a file can pick
# these up (`load helpers/user`) without also inheriting the bootstrap
# stub tree that tests/helpers/setup.bash builds.

# Skip unless this run is root. $1 is what root is for.
need_root() {
    [ "$(id -u)" = "0" ] || skip "needs root: ${1:-the operation under test}"
}

# Skip when this run IS root -- the mirror image, for a case that measures
# what happens to someone who is not root. $1 is what would go wrong.
need_nonroot() {
    [ "$(id -u)" = "0" ] && skip "needs non-root: ${1:-the operation under test}"
    return 0
}
