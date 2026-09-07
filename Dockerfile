# claude_orca v3 -- the Linux side of "Orca in a VM the project folder owns".
#
# One image per project runs one Orca in serve mode, headless, with the
# project bind-mounted at the same absolute path it has on the Mac and
# /home/agent bind-mounted from <project>/.claude-dev/home. The VM
# boundary IS the sandbox: there is no Seatbelt profile and no srt here.
# See .claude/plans/container-v3.md S3-S4.
#
# The install logic lives in scripts/container/setup.sh so it can be run
# and verified natively (scripts/container/verify-rootfs.sh runs it inside
# a real Ubuntu 24.04 chroot, then re-runs it to prove it is idempotent);
# this file only copies that script and calls it. Every version is pinned
# there. The Claude Code pin is the SAME string as
# scripts/install-claude.sh's CLAUDE_CODE_VERSION -- tests/container-
# entrypoint.bats greps setup.sh for it, so the two can never drift.
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    SHELL=/usr/bin/zsh \
    COLORTERM=truecolor \
    DISABLE_AUTOUPDATER=1 \
    DISABLE_AUTO_MIGRATE_TO_NATIVE=1

# The two pins the build takes as arguments (image.yml passes neither
# today, so these defaults are what ships); setup.sh reads them as env.
ARG CLAUDE_CODE_VERSION=2.1.261
ARG ORCA_VERSION=1.4.197

# Only the apt half (setup.sh's IMAGE_PHASES: base, node, gh, Orca's
# runtime libraries, the agent user), in one layer that is cached until
# setup.sh itself changes -- the repo copy below must NOT invalidate it.
#
# The other half -- Orca itself, Claude Code, opencode, bd, dolt, bats,
# ~1.2 GB of pinned payload -- is NOT baked. The entrypoint installs it on
# a folder's first start into <project>/.claude-dev/toolchain, which the
# launcher mounts over /usr/local, /opt/Orca and /opt/claude, so it is
# installed once per folder and survives every recreate. What that buys:
# an image with no fast-moving parts in it, a build that no longer carries
# them under QEMU, and a toolchain a person can see, read and delete from
# the Mac without going anywhere near a registry.
COPY scripts/container/setup.sh /opt/claude-orca-setup.sh
RUN CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION ORCA_VERSION=$ORCA_VERSION /opt/claude-orca-setup.sh --image

# --- this template ------------------------------------------------------
#
# /opt/claude-orca-host/template -> /opt/claude-orca gives config-sync.sh
# the <host>/template/config layout it expects without a --template flag
# and without touching its contract (tests/config-sync.bats).
COPY . /opt/claude-orca
RUN /opt/claude-orca/scripts/container/setup.sh --phase template

ENV HOME=/home/agent \
    ORCA_BIN=/opt/orca/orca-ide \
    ORCA_CLI=/opt/orca/resources/bin/orca-ide \
    ORCA_PORT=6768 \
    PATH=/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

EXPOSE 6768
WORKDIR /home/agent
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/claude-orca/scripts/container/entrypoint.sh"]
