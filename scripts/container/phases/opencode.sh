# setup.sh's opencode phase, sourced by it. A file of its own so the Dockerfile
# copies it just before its RUN: an edit rebuilds this layer on, not all.
# The pin is overridable by env, which is how the Dockerfile's ARG reaches it.
OPENCODE_VERSION="${OPENCODE_VERSION:-1.18.25}"

# What npm has on disk, read from the package rather than by running the
# binary: opencode is a Bun executable and Bun reads /proc at startup,
# which the chroot verify-rootfs.sh uses does not have (the same
# constraint the phase comments below document). Reading package.json is
# also what keeps the phase idempotent in there -- a check that had to RUN
# opencode would re-install on every pass.
installed_opencode() {
    local root pkg
    command -v npm >/dev/null 2>&1 || return 1
    command -v opencode >/dev/null 2>&1 || return 1
    root="$(npm_global_root)"
    pkg="$root/opencode-ai"
    [ -f "$pkg/package.json" ] || return 1
    [ -x "$pkg/bin/opencode.exe" ] || return 1
    jq -r '.version // empty' "$pkg/package.json" 2>/dev/null
}

# --- opencode, the OpenRouter worker's CLI (pinned) ---------------------
#
# An Orca worker terminal running a non-Anthropic model is `opencode
# --model openrouter/<vendor>/<model>` (.claude/plans/orca-orchestration.md).
# It is a plain npm global install -- the package ships the per-platform
# binary in its postinstall, so nothing here maps an arch by hand -- and
# its config comes from the file config-sync writes into the agent home,
# pointed at by OPENCODE_CONFIG in Orca's own settings
# (scripts/container/seed-orca-state.sh). No key is baked in anywhere: the
# config reads OPENROUTER_API_KEY from the environment the VM already
# carries (claude-orca-qa2.7).
phase_opencode() {
    need_root opencode
    if [ "$(installed_opencode || true)" = "$OPENCODE_VERSION" ]; then
        say "opencode: ${OPENCODE_VERSION} already present"
        return 0
    fi
    say "opencode: installing ${OPENCODE_VERSION}"
    # --ignore-scripts, then place the platform binary by hand. The
    # package's postinstall picks that binary by probing the machine and
    # then RUNS it to confirm; under a chroot with no /proc the run fails,
    # postinstall falls through to the musl build, npm rejects it
    # (EBADPLATFORM) and the whole install exits 1. The optional
    # dependency npm already resolved for this platform is the same
    # binary, so copying it is the honest, probe-free version of what the
    # postinstall would have done.
    npm install -g --prefix "$NPM_PREFIX" --ignore-scripts --no-fund --no-audit "opencode-ai@${OPENCODE_VERSION}"

    local root pkg binpkg src tmp=""
    root="$(npm_global_root)"
    pkg="$root/opencode-ai"
    # opencode spells the arch the way downloads.claude.ai does: x64/arm64.
    # (x64 also has a `-baseline` build for CPUs without AVX2; the image is
    # cross-built under QEMU, whose CPU says nothing about the Mac that
    # will run it, so the normal build is the right default.)
    binpkg="opencode-linux-$(claude_arch)"
    src="$pkg/node_modules/$binpkg/bin/opencode"
    [ -f "$src" ] || src="$root/$binpkg/bin/opencode"
    if [ ! -f "$src" ]; then
        tmp="$(mktemp -d)"
        npm install --prefix "$tmp" --no-save --ignore-scripts --loglevel=error \
            "${binpkg}@${OPENCODE_VERSION}"
        src="$tmp/node_modules/$binpkg/bin/opencode"
    fi
    install -m 0755 "$src" "$pkg/bin/opencode.exe"
    if [ -n "$tmp" ]; then rm -rf "$tmp"; fi

    # npm keeps every tarball it downloaded under $HOME/.npm, and in an
    # image build that cache is 264 MB of dead weight riding in the same
    # layer as the package it produced. Nothing reads it again: the pin is
    # in this file, and a re-install is a rebuild.
    npm cache clean --force >/dev/null 2>&1 || true

    if [ -r /proc/self/cmdline ]; then
        opencode --version
    else
        say "opencode: not running \`opencode --version\` (no /proc; npm's own integrity check is the proof)"
    fi
}
