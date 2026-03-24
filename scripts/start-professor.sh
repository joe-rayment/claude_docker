#!/bin/bash
unset CLAUDECODE
cd /workspace 2>/dev/null || true
exec claude-screen --agent professor --dangerously-skip-permissions
