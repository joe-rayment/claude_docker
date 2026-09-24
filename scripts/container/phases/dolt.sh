# phases/dolt.sh -- setup.sh's `dolt` phase: its pin and its code, in a
# file of their own so the Dockerfile can copy it in right before the one
# RUN that uses it -- editing this phase (or bumping its pin) rebuilds this
# layer and the ones after it, not the whole image. Sourced by setup.sh,
# which owns the shared helpers (say, need_root, stamp, deb_arch, ...).

# Pinned, and overridable by env (the Dockerfile's ARG reaches it that way).
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
