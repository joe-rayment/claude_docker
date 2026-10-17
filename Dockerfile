# claude_orca v3 -- the Linux side of "a VM the project folder owns".
#
# One image per project runs one sshd (the way in for the Mac's terminal
# panes), headless, with the project bind-mounted at /workspace/<name> and
# /home/agent bind-mounted from <project>/.claude-dev/home. The VM boundary
# IS the sandbox: there is no Seatbelt profile and no srt here.
# See .claude/plans/container-v3.md S3-S4 and .claude/plans/ghostty.md.
#
# The install logic lives in scripts/container/setup.sh so it can be run
# and verified natively (scripts/container/verify-rootfs.sh runs it inside
# a real Ubuntu 24.04 chroot, then re-runs it to prove it is idempotent);
# this file only copies that script and calls it. Every version is pinned
# there.
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    SHELL=/usr/bin/zsh \
    COLORTERM=truecolor \
    DISABLE_AUTOUPDATER=1 \
    DISABLE_AUTO_MIGRATE_TO_NATIVE=1

# The apt half (setup.sh's IMAGE_PHASES: base, node, gh, the agent user),
# in one layer that is cached until setup.sh itself changes -- the repo copy
# below must NOT invalidate it.
COPY scripts/container/setup.sh /opt/claude-orca-setup.sh
RUN /opt/claude-orca-setup.sh --image

# ... and the payload: opencode, bd, dolt, helix and bats, pinned tools. Claude Code is the exception: it is installed
# per folder by provision.d/15-claude-on-path, never baked here.
#
# This was briefly NOT baked -- the entrypoint installed it on a folder's
# first start into <project>/.claude-dev/toolchain -- and the measurement
# that ended that experiment was a folder taking ~18 minutes to come up on
# a real Mac, 15.5 of them downloading this payload at 2.5 MB/s, once per
# folder, shared with no other folder. Docker's layer cache does that job
# for every folder on the machine at once, and does it here. (The other
# half of the verdict: installing into a bind mount is what made the
# macOS CI job impossible -- colima's virtiofs refuses the chown.)
#
# ONE RUN PER PHASE, rarest-changing first, so moving a pin rebuilds that
# layer and the ones below it rather than all 1.3 GB. Each phase's code
# and pin live in their own file (scripts/container/phases/), copied in
# right before the RUN that uses it -- copying all of setup.sh up front
# meant any edit to it rebuilt every layer here.
COPY scripts/container/phases/bats.sh /opt/claude-orca-phases/bats.sh
RUN /opt/claude-orca-setup.sh --phase bats
COPY scripts/container/phases/dolt.sh /opt/claude-orca-phases/dolt.sh
RUN /opt/claude-orca-setup.sh --phase dolt
COPY scripts/container/phases/helix.sh /opt/claude-orca-phases/helix.sh
RUN /opt/claude-orca-setup.sh --phase helix
COPY scripts/container/phases/bd.sh /opt/claude-orca-phases/bd.sh
RUN /opt/claude-orca-setup.sh --phase bd
COPY scripts/container/phases/opencode.sh /opt/claude-orca-phases/opencode.sh
RUN /opt/claude-orca-setup.sh --phase opencode

# --- this template ------------------------------------------------------
#
# /opt/claude-orca-host/template -> /opt/claude-orca gives config-sync.sh
# the <host>/template/config layout it expects without a --template flag
# and without touching its contract (tests/config-sync.bats).
COPY --chown=agent:agent . /opt/claude-orca
RUN /opt/claude-orca/scripts/container/setup.sh --phase template

ENV HOME=/home/agent \
    PATH=/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

# sshd listens on CLAUDE_ORCA_SSHD_PORT (the launcher sets it; 2222 when unset).
EXPOSE 2222
WORKDIR /home/agent
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/claude-orca/scripts/container/entrypoint.sh"]
