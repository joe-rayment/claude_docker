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
ARG CLAUDE_CODE_VERSION=2.1.271
ARG ORCA_VERSION=1.4.197

# The apt half (setup.sh's IMAGE_PHASES: base, node, gh, Orca's runtime
# libraries, the agent user), in one layer that is cached until setup.sh
# itself changes -- the repo copy below must NOT invalidate it.
COPY scripts/container/setup.sh /opt/claude-orca-setup.sh
RUN CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION ORCA_VERSION=$ORCA_VERSION /opt/claude-orca-setup.sh --image

# ... and the payload: Orca, Claude Code, opencode, bd, dolt and bats,
# ~1.3 GB of pinned tools.
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
# layer and the ones below it rather than all 1.3 GB. The ARGs above are
# in scope for every RUN in this stage, which is how setup.sh sees the
# two pins the build takes as arguments.
RUN /opt/claude-orca-setup.sh --phase bats
RUN /opt/claude-orca-setup.sh --phase dolt
RUN /opt/claude-orca-setup.sh --phase bd
RUN /opt/claude-orca-setup.sh --phase orca
RUN /opt/claude-orca-setup.sh --phase opencode
RUN /opt/claude-orca-setup.sh --phase claude

# --- this template ------------------------------------------------------
#
# /opt/claude-orca-host/template -> /opt/claude-orca gives config-sync.sh
# the <host>/template/config layout it expects without a --template flag
# and without touching its contract (tests/config-sync.bats).
COPY --chown=agent:agent . /opt/claude-orca
RUN /opt/claude-orca/scripts/container/setup.sh --phase template

ENV HOME=/home/agent \
    ORCA_BIN=/opt/orca/orca-ide \
    ORCA_CLI=/opt/orca/resources/bin/orca-ide \
    ORCA_PORT=6768 \
    PATH=/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

EXPOSE 6768
WORKDIR /home/agent
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/claude-orca/scripts/container/entrypoint.sh"]
