# setup.sh's dolt phase, sourced by it. A file of its own so the Dockerfile
# copies it just before its RUN: an edit rebuilds this layer on, not all.
# The pin is overridable by env, which is how the Dockerfile's ARG reaches it.
DOLT_VERSION="${DOLT_VERSION:-2.3.1}"

installed_dolt() {
    command -v dolt >/dev/null 2>&1 || return 1
    dolt version 2>/dev/null | sed -n 's/^dolt version \([0-9][^ ]*\).*/\1/p' | head -1
}

# --- dolt, bd's storage engine (pinned) ---------------------------------
phase_dolt() {
    need_root dolt
    if [ "$(installed_dolt || true)" = "$DOLT_VERSION" ]; then
        say "dolt: ${DOLT_VERSION} already present"
        return 0
    fi
    say "dolt: installing ${DOLT_VERSION}"
    curl -fsSL "https://github.com/dolthub/dolt/releases/download/v${DOLT_VERSION}/install.sh" | bash
    dolt version
}
