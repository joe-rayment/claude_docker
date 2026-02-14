# Fix Plan: Robustness Review Findings

## Critical

1. **CONFIG_VERSION regex in smoke test** — `^[0-9]+$` doesn't match `2026.02.15` (has dots). Test will fail.
   - Fix: Update regex to `^[0-9.]+$`

2. **tmux as PID 1 signal handling** — tmux doesn't properly forward SIGTERM to children.
   - Fix: Add `init: true` to docker-compose.yml.template so tini is PID 1

## High

3. **tmux exec failure = crash loop** — If tmux fails (bad config, etc.), container restarts forever.
   - Fix: Test tmux works before exec'ing, with fallback to raw shell

4. **`set -e` in agent-panels.sh** — tmux commands in loops can fail, killing the script mid-operation.
   - Fix: Remove `set -e`, add explicit `|| continue` in loops, track actual move count

5. **Global tmux hooks affect test sessions** — `-g` hooks fire for test session too.
   - Fix: Use session-targeted hooks via a startup command instead of global hooks

6. **exec_into race condition** — tmux may not be ready when launcher tries to attach.
   - Fix: Add retry loop with timeout in exec_into()
