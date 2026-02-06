#!/bin/bash
# Wrapper for Claude CLI in Docker sandbox
# Used as CLAUDE_CODE_CMD in Ralph so that `timeout "$cmd"` works
# (timeout requires a single executable, not a multi-word shell command)
export NODE_TLS_REJECT_UNAUTHORIZED=0
exec claude --dangerously-skip-permissions "$@"
