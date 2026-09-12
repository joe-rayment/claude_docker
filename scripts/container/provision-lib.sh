#!/usr/bin/env bash
#
# provision-lib.sh -- the four paths every provision.d step needs, sourced
# by each of them (claude-orca-dbu.4).
#
# It lives OUTSIDE provision.d on purpose: that directory is the step list,
# and anything in it that is not a step is a step whose status nobody
# writes. Everything here is re-derived rather than required, because a
# step has a second caller -- a person or an agent in a terminal, re-running
# the one step that failed, which is the only repair this design has.

PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_ORCA_ROOT:-}}"
if [ -z "$PROJECT_DIR" ]; then
    _d="$PWD"
    while [ "$_d" != "/" ]; do
        if [ -d "$_d/.claude-dev" ]; then PROJECT_DIR="$_d"; break; fi
        _d="$(dirname "$_d")"
    done
fi

# The tree this step was read from. A step is
# <tree>/scripts/container/provision.d/<step>, so the tree is three levels
# above its own directory.
STEP_TREE="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# The template the entrypoint resolved, which may be a different copy (the
# image's baked one vs the folder's own clone) -- see entrypoint.sh's
# "where the template is" note.
TEMPLATE_ROOT="${TEMPLATE_ROOT:-$STEP_TREE}"

RUN_DIR="${RUN_DIR:-$PROJECT_DIR/.claude-dev/run}"
PROVISION_DIR="${PROVISION_DIR:-$RUN_DIR/provision}"
