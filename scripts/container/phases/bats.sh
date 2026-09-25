# setup.sh's bats phase, sourced by it. A file of its own so the Dockerfile
# copies it just before its RUN: an edit rebuilds this layer on, not all.
# The pin is overridable by env, which is how the Dockerfile's ARG reaches it.
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
