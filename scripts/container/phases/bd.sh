# phases/bd.sh -- setup.sh's `bd` phase: its pin and its code, in a
# file of their own so the Dockerfile can copy it in right before the one
# RUN that uses it -- editing this phase (or bumping its pin) rebuilds this
# layer and the ones after it, not the whole image. Sourced by setup.sh,
# which owns the shared helpers (say, need_root, stamp, deb_arch, ...).

# Pinned, and overridable by env (the Dockerfile's ARG reaches it that way).
BD_VERSION="${BD_VERSION:-1.2.2}"

installed_bd() {
    command -v bd >/dev/null 2>&1 || return 1
    bd version 2>/dev/null | sed -n 's/^bd version \([0-9][^ ]*\).*/\1/p' | head -1
}

# --- beads (bd), the agent task tracker (pinned) ------------------------
phase_bd() {
    need_root bd
    if [ "$(installed_bd || true)" = "$BD_VERSION" ]; then
        say "bd: ${BD_VERSION} already present"
        return 0
    fi
    say "bd: installing ${BD_VERSION}"
    local bdarch base archive tmp
    bdarch="$(deb_arch)"
    base="https://github.com/gastownhall/beads/releases/download/v${BD_VERSION}"
    archive="beads_${BD_VERSION}_linux_${bdarch}.tar.gz"
    tmp="$(mktemp -d)"
    curl -fsSL -o "${tmp}/${archive}" "${base}/${archive}"
    curl -fsSL -o "${tmp}/checksums.txt" "${base}/checksums.txt"
    (cd "$tmp" && grep " ${archive}\$" checksums.txt | sha256sum -c -)
    tar -xzf "${tmp}/${archive}" -C "$tmp"
    install -m 0755 "${tmp}/bd" /usr/local/bin/bd
    rm -rf "$tmp"
    bd version
}
