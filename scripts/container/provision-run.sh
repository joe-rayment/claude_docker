#!/usr/bin/env bash
#
# provision-run.sh -- the project-shaped half of a folder's start
# (claude-orca-dbu.4), run AFTER `orca-ide --serve` has published its URL.
#
# WHY THIS IS NOT IN THE ENTRYPOINT ANY MORE. The steps a folder needs --
# verify the toolchain, sync the instructions, seed the tracker, register
# the project, check the guard -- are exactly the steps most likely to
# fail: a network hiccup, a half-written config, a bad token. Every one of
# them used to run in front of the only thing that could have reported the
# failure. A folder whose config sync died had no Orca, no terminal and no
# Claude Code to say so; it just did not come up. So the boot now gets to
# the served URL first, and everything about THIS FOLDER happens after,
# where a person can watch it and an agent can read it.
#
# What stays in front of serve, deliberately:
#
#   * setup.sh itself, which needs root and installs the Orca binary the
#     serve step is about to exec (its own status is run/provision/
#     setup.status, written by the entrypoint);
#   * the OpenRouter guard's START. Orca's process environment is fixed at
#     exec, and the fail-closed rule -- the guard's token and base URL
#     reach Orca only when the guard actually came up -- is therefore a
#     decision that has to be made before serve, not after. The guard's
#     step here (70-openrouter-guard) verifies it is answering and
#     restarts it if it is not, which is the part that can safely wait.
#
# CONTRACT
#   * every executable file in provision.d runs, in filename order;
#   * each writes run/provision/<step>.log and run/provision/<step>.status,
#     truncated per run -- a folder started fifty times must not hand a
#     person fifty copies of the same failure;
#   * no step is fatal. A non-zero status stops nothing, and this script
#     always exits 0: its caller is PID 1 of the container;
#   * every step is idempotent, because the next start re-runs all of them.
#     That is the whole repair mechanism: a step that failed on a bad
#     network is simply run again by the next start.
#
# Environment:
#   PROJECT_DIR                      required; the bind-mounted project.
#   TEMPLATE_ROOT                    the template the entrypoint resolved
#                                    (setup.sh, seed-project.sh, config/).
#   CLAUDE_ORCA_PROVISION_STEPS      the steps directory (default: the
#                                    provision.d next to this script).
#   CLAUDE_ORCA_PROVISION_TIMEOUT    seconds per step (default 300). A step
#                                    that hangs must not wedge the boot.
#   CLAUDE_ORCA_OPENROUTER_REAL_KEY  the real key, for the guard step ONLY
#                                    (see the routing below).
#
# bash 3.2 clean, like everything else that a Mac might one day read.

set -uo pipefail

log()  { printf '[provision +%ss] %s\n' "$SECONDS" "$*"; }
warn() { printf '[provision +%ss] %s\n' "$SECONDS" "$*" >&2; }

_resolve_script_path() {
    src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  src="$(cd "$(dirname "$src")" && pwd)/$link" ;;
        esac
    done
    printf '%s\n' "$src"
}
SCRIPT_DIR="$(cd "$(dirname "$(_resolve_script_path)")" && pwd -P)"

PROJECT_DIR="${PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR" ]; then
    warn "PROJECT_DIR is required and must be a directory; nothing provisioned"
    exit 0
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"

TEMPLATE_ROOT="${TEMPLATE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}"
STEPS_DIR="${CLAUDE_ORCA_PROVISION_STEPS:-$SCRIPT_DIR/provision.d}"
STEP_TIMEOUT="${CLAUDE_ORCA_PROVISION_TIMEOUT:-300}"
RUN_DIR="$PROJECT_DIR/.claude-dev/run"
PROVISION_DIR="$RUN_DIR/provision"
mkdir -p "$PROVISION_DIR" 2>/dev/null

# The real OpenRouter key reaches exactly ONE step. It arrives here in the
# environment, is captured into a shell variable, removed from the
# environment every other step inherits, and handed back only to the step
# whose name says it is the guard. The guard exists because a key in a
# place no chokepoint can see is the failure it prevents; provisioning must
# not be the thing that spreads it around.
GUARD_REAL_KEY="${CLAUDE_ORCA_OPENROUTER_REAL_KEY:-}"
unset CLAUDE_ORCA_OPENROUTER_REAL_KEY

export PROJECT_DIR TEMPLATE_ROOT RUN_DIR PROVISION_DIR

if [ ! -d "$STEPS_DIR" ]; then
    warn "no provision steps directory at $STEPS_DIR; nothing provisioned"
    exit 0
fi

# `timeout` is util-linux's and is always in the image; a box without it
# runs the step unbounded rather than not at all.
run_bounded() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$STEP_TIMEOUT" "$@"
    else
        "$@"
    fi
}

log "provisioning $PROJECT_DIR from $STEPS_DIR"

ran=0
for step in "$STEPS_DIR"/*; do
    [ -f "$step" ] || continue
    [ -x "$step" ] || continue
    name="$(basename "$step")"
    step_log="$PROVISION_DIR/$name.log"
    step_status="$PROVISION_DIR/$name.status"
    : > "$step_log" 2>/dev/null

    # tee, not a redirect: the same words go to `docker logs` and to the
    # file the failure message points at.
    case "$name" in
        *openrouter-guard*)
            run_bounded env CLAUDE_ORCA_OPENROUTER_REAL_KEY="$GUARD_REAL_KEY" \
                "$step" 2>&1 | tee -a "$step_log"
            ;;
        *)
            run_bounded "$step" 2>&1 | tee -a "$step_log"
            ;;
    esac
    st="${PIPESTATUS[0]}"
    printf '%s\n' "$st" > "$step_status" 2>/dev/null
    ran=$((ran + 1))

    if [ "$st" = "0" ]; then
        log "$name: ok"
    else
        # Loud, and then onward. The next step is not this step's business,
        # and the next START is what repairs this one.
        warn "$name: FAILED (exit $st) -- see $step_log (status in $step_status)"
    fi
done

log "provisioning done: $ran step(s), statuses in $PROVISION_DIR"
exit 0
