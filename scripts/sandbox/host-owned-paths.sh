#!/usr/bin/env bash
#
# host-owned-paths.sh -- the ONE list of paths inside a project that the
# HOST executes or trusts, sourced (never executed) by both profile
# generators: gen-settings.sh (srt's filesystem.denyWrite, layer 2 --
# the agents) and gen-orca-profile.sh (the Seatbelt profile's final deny
# block, layer 1 -- the Orca app itself). See
# .claude/plans/orca-port.md §9.2.
#
# Why one list: in v2 there is no central install. Everything the host
# runs lives under the project folder, which is also the folder the
# sandboxes may write to -- so anything the host executes has to be
# write-denied inside BOTH sandboxes, or an agent could rewrite the very
# script that will next launch it (or the profile that confines it) and
# step straight out of the folder. Two hand-maintained copies of that
# list would drift; this one cannot.
#
# host_owned_paths <project>
#   Prints one absolute path per line, in a stable order, for the given
#   project root ($1). Pure: no file system access, no side effects, so
#   it is equally correct for a path that does not exist yet (a project
#   that has no orca.yaml, a worktree that has no .claude-dev). Returns
#   1 with no output when $1 is empty.
#
# What is on it:
#   ./claude-dev            the launcher stub in the project root
#   Orca.app                the launcher bundle (double-click entry point)
#   .claude-dev/bin         launcher, wrapper, root finder, orca-launch
#   .claude-dev/template    this repo, cloned per project
#   .claude-dev/app         Orca.app itself, from the pinned DMG
#   .claude-dev/srt         the pinned sandbox-runtime install
#   .claude-dev/claude      the pinned Claude Code install
#   .claude-dev/state       generated profiles/settings the host feeds to
#                           sandbox-exec and srt -- writable = escapable
#   .claude-dev/sandbox.json the folder's own sandbox knobs (V2c)
#   orca.yaml               per-repo setup commands Orca runs unsandboxed
#   .worktreeinclude        consumed by Orca when it creates a worktree
#   .envrc                  sourced by direnv in unsandboxed shells
#   .beads/hooks            hook scripts bd runs
#
# Why sandbox.json is on it (V2c, claude-orca-qt9.7): it is never
# executed -- both generators read it as validated data and fail closed on
# anything malformed or out of scope -- but what it CONTAINS is
# orca.profileExceptions, filesystem.extraAllowWrite and
# network.extraAllowedDomains, each of which widens one of the two
# sandbox layers at the next launch. An agent that could edit it could
# hand itself the real home, one launch later. Reads stay allowed (this
# list is write-only), so the file keeps working exactly as documented;
# the user edits it from outside the sandbox, which is where the
# authority to widen a sandbox belongs.
#
# What is deliberately NOT on it: .claude-dev/run, the one directory
# under .claude-dev that the sandbox itself writes (tier.json,
# selftest.json, the srt-debug captures -- see lib/paths.sh run_dir()).
# Nothing in there is host-executed or host-trusted; it holds results,
# not authority.

host_owned_paths() {
    local project="${1:-}"
    [ -n "$project" ] || return 1
    project="${project%/}"
    printf '%s\n' \
        "$project/claude-dev" \
        "$project/Orca.app" \
        "$project/.claude-dev/bin" \
        "$project/.claude-dev/template" \
        "$project/.claude-dev/app" \
        "$project/.claude-dev/srt" \
        "$project/.claude-dev/claude" \
        "$project/.claude-dev/state" \
        "$project/.claude-dev/sandbox.json" \
        "$project/orca.yaml" \
        "$project/.worktreeinclude" \
        "$project/.envrc" \
        "$project/.beads/hooks"
}
