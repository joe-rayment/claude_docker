# setup.sh's orca phase, sourced by it. A file of its own so the Dockerfile
# copies it just before its RUN: an edit rebuilds this layer on, not all.
# The pin is overridable by env, which is how the Dockerfile's ARG reaches it.
ORCA_VERSION="${ORCA_VERSION:-1.4.197}"

# --- Orca Linux, pinned, from the release .deb --------------------------
#
# NOT the AppImage (claude-orca-qa2.6). An AppImage's runtime carries the
# "AI\x02" magic in its ELF e_ident padding, which QEMU's binfmt pattern
# does not match, so the self-extractor cannot run under emulation: the
# linux/arm64 leg of the multi-arch build died on `./orca.AppImage: Exec
# format error`. Installing the .deb goes through apt, the same path every
# other phase already takes under QEMU, and its Depends supply the
# GTK/NSS/at-spi/xdotool/xclip/xvfb set so this script need not list them.
#
# Nothing here EXECUTES the Orca binary. Under emulation a 200 MB Electron
# binary is slow to start and proves nothing about the target machine;
# `test -x` is the only claim a build can honestly make. The runtime check
# that Orca actually serves belongs to scripts/container/smoke.sh.
# The three names the rest of the system reaches Orca by. Two of them
# (/opt/orca, /usr/bin/orca-ide) live outside the toolchain cache, so a
# recreated container has neither even when the payload is right there --
# they are re-made on every run, before anything asks a question about
# what is installed.
orca_relink() {
    [ -d /opt/Orca ] || return 0
    ln -sfn /opt/Orca /opt/orca
    ln -sf /opt/Orca/resources/bin/orca-ide /usr/local/bin/orca
    ln -sf /opt/Orca/resources/bin/orca-ide /usr/bin/orca-ide
}

phase_orca() {
    need_root orca
    orca_relink
    if [ "$(stamp /opt/orca/VERSION || true)" = "$ORCA_VERSION" ] \
        && [ -x /opt/orca/orca-ide ]; then
        say "orca: ${ORCA_VERSION} already present"
        return 0
    fi
    say "orca: installing ${ORCA_VERSION}"
    local debarch asset url tmp dep installed missing=""
    debarch="$(deb_arch)"
    asset="orca-ide_${ORCA_VERSION}_${debarch}.deb"
    url="https://github.com/stablyai/orca/releases/download/v${ORCA_VERSION}/${asset}"
    tmp="$(mktemp -d)"
    curl -fsSL -o "${tmp}/orca.deb" "$url"

    # The .deb's own Depends, checked against what the image actually has.
    # phase_orcadeps hand-lists those packages because the payload no
    # longer goes in through apt, and a hand-list drifts -- so the drift
    # is caught HERE, by the package itself, naming what is missing
    # instead of leaving Orca to die on a missing .so at first start.
    # Provides counts: 24.04 satisfies libgtk-3-0 with libgtk-3-0t64.
    installed=" $(dpkg-query -W -f='${Package} ${Provides}\n' 2>/dev/null \
        | tr ',()' '   ' | tr -s ' ' | tr '\n' ' ') "
    for dep in $(dpkg-deb --field "${tmp}/orca.deb" Depends 2>/dev/null \
        | tr ',' '\n' | awk '{print $1}'); do
        [ -n "$dep" ] || continue
        case "$installed" in
            *" $dep "*) ;;
            *) missing="$missing $dep" ;;
        esac
    done
    if [ -n "$missing" ]; then
        die "orca ${ORCA_VERSION} depends on packages this image does not have:${missing}
      Add them to ORCA_PACKAGES in this file (phase orcadeps) and rebuild the image."
    fi

    # dpkg-deb -x, not `apt-get install`: the payload belongs to the
    # folder's toolchain cache, and apt would register a package in a dpkg
    # database that dies with the container -- leaving the next start with
    # an installed-but-unknown Orca. Extraction has no such memory, which
    # is what makes the cache the single source of truth. /opt/Orca is a
    # mount point, so its CONTENTS are replaced, never the directory.
    dpkg-deb -x "${tmp}/orca.deb" "${tmp}/x"
    test -x "${tmp}/x/opt/Orca/orca-ide"
    mkdir -p /opt/Orca
    find /opt/Orca -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -a "${tmp}/x/opt/Orca/." /opt/Orca/
    rm -rf "$tmp"

    test -x /opt/Orca/orca-ide
    test -x /opt/Orca/resources/bin/orca-ide
    orca_relink
    echo "${ORCA_VERSION}" > /opt/orca/VERSION
    # Seed the default theme in the same step that unpacked the archive: a
    # later image layer that rewrote app.asar carried a second ~113 MB copy
    # of it. phase_template still re-seeds a folder's own theme at boot.
    patch_orca_web_theme
}
