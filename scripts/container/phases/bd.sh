# setup.sh's bd phase, sourced by it. A file of its own so the Dockerfile
# copies it just before its RUN: an edit rebuilds this layer on, not all.
# The pin is overridable by env, which is how the Dockerfile's ARG reaches it.
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
