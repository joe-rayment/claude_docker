# setup.sh's helix phase, sourced by it. A file of its own so the Dockerfile
# copies it just before its RUN: an edit rebuilds this layer on, not all.
# The pin is overridable by env, which is how the Dockerfile's ARG reaches it.
HELIX_VERSION="${HELIX_VERSION:-25.07.1}"

installed_helix() {
    command -v hx >/dev/null 2>&1 || return 1
    hx --version 2>/dev/null | sed -n 's/^helix \([0-9][^ ]*\).*/\1/p' | head -1
}

# --- helix, the terminal editor config/.zshrc points EDITOR at (pinned) --
# Ubuntu 24.04 does not package it, so this is the upstream release
# tarball: hx plus its runtime/ (themes, queries, grammars). Everything
# lands under /usr/local, so a runtime-path folder's toolchain cache keeps
# it too. hx finds runtime/ next to its resolved executable, which is why
# /usr/local/bin/hx is a symlink rather than a copy.
phase_helix() {
    need_root helix
    if [ "$(installed_helix || true)" = "$HELIX_VERSION" ]; then
        say "helix: ${HELIX_VERSION} already present"
        return 0
    fi
    local arch
    case "$(uname -m)" in
        x86_64|amd64)  arch=x86_64 ;;
        arm64|aarch64) arch=aarch64 ;;
        *) die "helix: unsupported arch: $(uname -m)" ;;
    esac
    say "helix: installing ${HELIX_VERSION}"
    rm -rf /usr/local/lib/helix /tmp/helix.tar.xz
    mkdir -p /usr/local/lib/helix /usr/local/bin
    curl -fsSL -o /tmp/helix.tar.xz \
        "https://github.com/helix-editor/helix/releases/download/${HELIX_VERSION}/helix-${HELIX_VERSION}-${arch}-linux.tar.xz"
    tar -xJf /tmp/helix.tar.xz -C /usr/local/lib/helix --strip-components=1
    rm -f /tmp/helix.tar.xz
    ln -sfn /usr/local/lib/helix/hx /usr/local/bin/hx
    hx --version
}
