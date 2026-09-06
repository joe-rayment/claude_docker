#!/usr/bin/env bash
#
# verify-rootfs.sh -- run scripts/container/setup.sh for real.
#
# This box cannot build container images (no mount namespaces, no Docker
# layers), but it CAN chroot into an extracted ubuntu-base 24.04 rootfs,
# and apt, HTTPS and dpkg all work in there. That is close enough to the
# image build to catch what static greps never will: a package that no
# longer exists, a checksum that moved, an install step that is not
# idempotent.
#
# What it does, in order:
#   1. fetch (or reuse) the ubuntu-base 24.04 tarball for this arch
#   2. extract it fresh into <rootfs>
#   3. mknod the handful of /dev nodes apt and friends need
#      (`mount` is not permitted here, so there is no /proc or /sys --
#      setup.sh must not need them)
#   4. copy this checkout to <rootfs>/opt/claude-orca
#   5. chroot: setup.sh          -- the full install
#   6. chroot: setup.sh --check  -- every phase's result
#   7. chroot: setup.sh          -- again, and it must install nothing
#
# Usage: sudo scripts/container/verify-rootfs.sh [rootfs-dir]
#        (default: ${CLAUDE_ORCA_ROOTFS:-/tmp/claude-orca-rootfs})

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOTFS="${1:-${CLAUDE_ORCA_ROOTFS:-/tmp/claude-orca-rootfs}}"
UBUNTU_BASE_VERSION="${UBUNTU_BASE_VERSION:-24.04.4}"

say() { printf '\n=== %s\n' "$*"; }
run() { printf '+ %s\n' "$*"; "$@"; }
die() { printf 'verify-rootfs: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root: sudo $0 ${ROOTFS}"

case "$(uname -m)" in
    x86_64|amd64)  BASE_ARCH=amd64 ;;
    arm64|aarch64) BASE_ARCH=arm64 ;;
    *) die "unsupported arch: $(uname -m)" ;;
esac
TARBALL_NAME="ubuntu-base-${UBUNTU_BASE_VERSION}-base-${BASE_ARCH}.tar.gz"
TARBALL_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/${UBUNTU_BASE_VERSION%.*}/release/${TARBALL_NAME}"

# A cached tarball, wherever a previous run (or a human) left it.
TARBALL=""
for candidate in \
    "${ROOTFS}.base.tgz" \
    "$(dirname "$ROOTFS")/base.tgz" \
    "$(dirname "$ROOTFS")/${TARBALL_NAME}"; do
    [ -s "$candidate" ] && { TARBALL="$candidate"; break; }
done
if [ -z "$TARBALL" ]; then
    TARBALL="${ROOTFS}.base.tgz"
    say "fetching ${TARBALL_URL}"
    run curl -fSL --retry 3 -o "$TARBALL" "$TARBALL_URL"
else
    say "using cached base tarball ${TARBALL}"
fi

say "extracting a fresh rootfs at ${ROOTFS}"
run rm -rf "$ROOTFS"
run mkdir -p "$ROOTFS"
run tar -xzf "$TARBALL" -C "$ROOTFS"

# `mount` is not permitted in this sandbox, so /proc and /sys stay empty
# and the /dev nodes are made by hand. setup.sh is written to survive that.
say "creating /dev nodes (no mount namespaces here, so no /proc or /sys)"
run mkdir -p "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys"
mknod_if_absent() { # name major minor
    [ -e "$ROOTFS/dev/$1" ] && return 0
    run mknod -m 666 "$ROOTFS/dev/$1" c "$2" "$3"
}
mknod_if_absent null 1 3
mknod_if_absent zero 1 5
mknod_if_absent random 1 8
mknod_if_absent urandom 1 9
mknod_if_absent tty 5 0

run cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

say "copying this checkout to ${ROOTFS}/opt/claude-orca"
run mkdir -p "$ROOTFS/opt/claude-orca"
printf '+ tar -C %s --exclude=.git --exclude=tests/.cache -cf - . | tar -C %s -xf -\n' \
    "$REPO_ROOT" "$ROOTFS/opt/claude-orca"
tar -C "$REPO_ROOT" --exclude=./.git --exclude=./tests/.cache -cf - . \
    | tar -C "$ROOTFS/opt/claude-orca" -xf -

# The ENV block from the Dockerfile, so the chroot sees what the image will.
CHROOT_ENV=(
    env -i
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    HOME=/root
    DEBIAN_FRONTEND=noninteractive
    LANG=en_US.UTF-8
    LC_ALL=en_US.UTF-8
    SHELL=/usr/bin/zsh
    COLORTERM=truecolor
    DISABLE_AUTOUPDATER=1
    DISABLE_AUTO_MIGRATE_TO_NATIVE=1
)
SETUP=/opt/claude-orca/scripts/container/setup.sh

say "chroot: ${SETUP}   (the full install)"
run chroot "$ROOTFS" "${CHROOT_ENV[@]}" "$SETUP"

say "chroot: ${SETUP} --check"
run chroot "$ROOTFS" "${CHROOT_ENV[@]}" "$SETUP" --check

say "chroot: ${SETUP}   (again -- must install nothing)"
second="$(mktemp)"
start=$SECONDS
run chroot "$ROOTFS" "${CHROOT_ENV[@]}" "$SETUP" 2>&1 | tee "$second"
elapsed=$((SECONDS - start))
printf 'second run took %ss\n' "$elapsed"

status=0
if grep -qE '^\[setup\] [a-z-]+: (installing|creating|repairing|linking|generating)' "$second"; then
    printf '\nNOT IDEMPOTENT -- the second run did work:\n'
    grep -nE '^\[setup\] [a-z-]+: (installing|creating|repairing|linking|generating)' "$second"
    status=1
fi
if [ "$elapsed" -gt 120 ]; then
    printf '\nNOT IDEMPOTENT -- the second run took %ss (expected seconds)\n' "$elapsed"
    status=1
fi
rm -f "$second"

if [ "$status" -eq 0 ]; then
    printf '\nPASS: setup.sh installs, checks clean, and is idempotent in a real 24.04 rootfs.\n'
else
    printf '\nFAIL: see above.\n'
fi
exit "$status"
