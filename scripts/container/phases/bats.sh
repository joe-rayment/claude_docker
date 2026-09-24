# phases/bats.sh -- setup.sh's `bats` phase: its pin and its code, in a
# file of their own so the Dockerfile can copy it in right before the one
# RUN that uses it -- editing this phase (or bumping its pin) rebuilds this
# layer and the ones after it, not the whole image. Sourced by setup.sh,
# which owns the shared helpers (say, need_root, stamp, deb_arch, ...).

# Pinned, and overridable by env (the Dockerfile's ARG reaches it that way).
BATS_VERSION="${BATS_VERSION:-1.14.0}"

installed_bats() {
    command -v bats >/dev/null 2>&1 || return 1
    bats --version 2>/dev/null | sed -n 's/^Bats \([0-9][^ ]*\).*/\1/p'
}

# --- bats-core (pinned) -------------------------------------------------
phase_bats() {
    need_root bats
    if [ "$(installed_bats || true)" = "$BATS_VERSION" ]; then
        say "bats: ${BATS_VERSION} already present"
        return 0
    fi
    say "bats: installing ${BATS_VERSION}"
    rm -rf /tmp/bats-core
    git clone --depth 1 --branch "v${BATS_VERSION}" \
        https://github.com/bats-core/bats-core.git /tmp/bats-core
    /tmp/bats-core/install.sh /usr/local
    rm -rf /tmp/bats-core
    bats --version
}
