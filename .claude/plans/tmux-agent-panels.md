# Plan: tmux Agent Panel Management

## Goal

When Claude Code agent teams spawn teammates, the user should:
1. See agent panes auto-appear in a tiled layout
2. Navigate to any pane to watch or chat with agents
3. Toggle all agent panes hidden/visible with one keystroke

## Critical Issues Found (and fixes)

The reviewer agent found 15 issues. The 7 most important are addressed directly in this plan:

| # | Issue | Severity | Fix |
|---|-------|----------|-----|
| 1 | Welcome screen skipped (container-welcome.sh checks `$TMUX`, always true now) | CRITICAL | Change guard to check tmux pane index, not just `$TMUX` |
| 2 | `docker exec` in launcher.sh bypasses entrypoint, user lands outside tmux | CRITICAL | Change `exec_into()` to attach to existing tmux session |
| 3 | Ctrl-a prefix conflicts with zsh beginning-of-line | HIGH | Keep default Ctrl-b prefix |
| 4 | Non-interactive commands get tmux-wrapped | HIGH | Guard with `[ -t 0 ]` (is stdin a TTY?) |
| 5 | Cleanup trap doesn't propagate to tmux | HIGH | `exec tmux` makes tmux PID 1, receives signals directly |
| 6 | tmux.conf not in config version sync | MEDIUM | Add to entrypoint sync block + Dockerfile staging |
| 7 | agent-panels edge cases (single pane, dead panes) | MEDIUM | Guard clauses in script |

---

## Files Changed

| File | Action | Lines affected |
|------|--------|----------------|
| `config/tmux.conf` | **NEW** | ~75 lines |
| `scripts/agent-panels.sh` | **NEW** | ~170 lines |
| `scripts/entrypoint.sh` | MODIFY | Lines 79-83 (add tmux auto-start), lines 29-33 (add tmux.conf to config sync) |
| `scripts/container-welcome.sh` | MODIFY | Lines 24-27 (fix $TMUX guard) |
| `scripts/launcher.sh` | MODIFY | Lines 173-175 (`exec_into` attaches tmux) |
| `config/.zshrc` | MODIFY | After line 48 (add `ap` alias) |
| `Dockerfile` | MODIFY | Add COPY/chmod for tmux.conf and agent-panels |
| `CONFIG_VERSION` | MODIFY | Bump to trigger sync |
| `tests/smoke.bats` | MODIFY | Add tests for new files |
| `tests/helpers/setup.bash` | MODIFY | Update `run_in_pane` for new welcome guard |

---

## Step 1: `config/tmux.conf` (NEW)

```tmux
# ── Claude Docker tmux config ──────────────────────────────────────────
# Prefix: Ctrl-b (tmux default). Kept to avoid conflict with Ctrl-a
# (zsh beginning-of-line), which is heavily used in shell editing.

# ── General ────────────────────────────────────────────────────────────
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",xterm-256color:Tc"
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -g mouse on
set -g focus-events on
set -g escape-time 0
set -g display-time 2000
set -g display-panes-time 3000

# ── Status bar ─────────────────────────────────────────────────────────
set -g status on
set -g status-interval 5
set -g status-position bottom
set -g status-style "bg=colour235,fg=colour248"
set -g status-left-length 30
set -g status-left "#[fg=colour81,bold] #S #[fg=colour248,nobold]| "
set -g status-right-length 60
set -g status-right "#[fg=colour248]panes: #{window_panes} #[fg=colour81]| #(if tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qx _agents; then echo '#[fg=colour214]agents hidden'; else echo '#[fg=colour248]--'; fi) "
setw -g window-status-format " #I:#W "
setw -g window-status-current-format "#[fg=colour81,bold] #I:#W "

# ── Pane styling ───────────────────────────────────────────────────────
set -g pane-border-style "fg=colour238"
set -g pane-active-border-style "fg=colour81"
set -g pane-border-lines heavy

# ── Auto-layout hooks ─────────────────────────────────────────────────
# When Claude Code creates a teammate pane (split-window), auto-tile.
set-hook -g after-split-window "select-layout tiled"
# When a pane exits, re-tile so remaining panes fill the gap.
set-hook -g pane-exited "select-layout tiled"

# ── Keybindings ────────────────────────────────────────────────────────
# All use Ctrl-b prefix (default).

# Toggle agent panels: Ctrl-b a
bind a run-shell "agent-panels toggle"

# List agent panes: Ctrl-b A
bind A run-shell "agent-panels list"

# Cycle panes: Ctrl-b Tab / Ctrl-b Shift-Tab
bind Tab select-pane -t :.+
bind BTab select-pane -t :.-

# Vim-style pane navigation
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

# Vim-style pane resize (repeatable)
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

# Manual re-tile
bind t select-layout tiled

# Split keeping current path
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

# Zoom is built-in: Ctrl-b z

# Reload config
bind r source-file ~/.tmux.conf \; display "Config reloaded"
```

---

## Step 2: `scripts/agent-panels.sh` (NEW)

Full script with edge-case guards:
- `toggle` — show if hidden, hide if visible, no-op if no agents
- `hide` — move non-primary panes to `_agents` window; no-op if only 1 pane
- `show` — join panes back from `_agents`; filter dead panes
- `list` — display visible + hidden agent panes with status

Key edge cases handled:
- Single pane (no agents) = silent no-op for hide
- Dead panes in `_agents` = skipped during show
- `_agents` window auto-destroys when last pane is joined out
- Not in tmux = error message, exit 1

---

## Step 3: `scripts/container-welcome.sh` (MODIFY)

**Problem**: Lines 24-27 check `if [ -n "$TMUX" ]` and skip the welcome. With auto-tmux, this is ALWAYS true, breaking first-time onboarding.

**Fix**: Replace the blanket `$TMUX` check with a pane-index check. Only skip for non-primary panes (where agents run).

Replace lines 24-27:
```bash
# Skip welcome in tmux panes
if [ -n "$TMUX" ]; then
    return 2>/dev/null || exit 0
fi
```

With:
```bash
# Skip welcome in tmux teammate panes (but show in the primary pane).
# The entrypoint auto-starts tmux, so $TMUX is always set.
# Only show welcome in pane 1 of window 1 (where the user lands).
if [ -n "$TMUX" ]; then
    _pane_idx=$(tmux display-message -p '#{pane_index}' 2>/dev/null || echo "1")
    _win_idx=$(tmux display-message -p '#{window_index}' 2>/dev/null || echo "1")
    if [ "$_win_idx" != "1" ] || [ "$_pane_idx" != "1" ]; then
        return 2>/dev/null || exit 0
    fi
    unset _pane_idx _win_idx
fi
```

---

## Step 4: `scripts/entrypoint.sh` (MODIFY)

### 4a: Add tmux.conf to config version sync (after line 33)

```bash
    cp /etc/claude-dev/configs/tmux.conf /home/agent/.tmux.conf 2>/dev/null || true
```

### 4b: Add tmux auto-start (replace lines 79-83)

Current:
```bash
# Change to workspace directory
cd /workspace

# Execute the provided command or start zsh
exec "$@"
```

New:
```bash
# Change to workspace directory
cd /workspace

# Auto-start tmux for agent teams support.
# teammateMode: "tmux" requires a tmux session for teammate panes.
# Skip if: already in tmux, non-interactive, or command is tmux itself.
if [ -z "${TMUX:-}" ] && [ -t 0 ] && [ "${1:-}" != "tmux" ]; then
    exec tmux -u new-session -A -s main "$@"
fi

# Fallback: already in tmux, non-interactive, or explicit tmux command
exec "$@"
```

**Why `exec`**: `exec tmux` replaces the entrypoint process, so tmux becomes PID 1 and receives SIGTERM from `docker stop` directly. The cleanup trap (`kill -- -$$`) is no longer relevant — tmux handles its own cleanup. This fixes the signal propagation issue.

**Why `-A`**: `new-session -A` means "attach if session 'main' exists, create if not." Idempotent across container restarts.

---

## Step 5: `scripts/launcher.sh` (MODIFY)

**Problem**: `exec_into()` (line 173-175) uses `docker exec -it "$CONTAINER_NAME" /bin/zsh`, which bypasses the entrypoint. The user lands in raw zsh, outside tmux, unable to see agent panes.

**Fix**: Detect if a tmux session exists and attach to it.

Replace lines 172-176:
```bash
# Helper: exec into container
exec_into() {
    echo -e "${C_GREEN}✓${C_RESET} Entering ${C_BOLD}${CONTAINER_NAME}${C_RESET}..."
    exec docker exec -it "$CONTAINER_NAME" /bin/zsh
}
```

With:
```bash
# Helper: exec into container
# If a tmux session is running (from the entrypoint), attach to it.
# This puts the user into the same tmux session where agent panes live.
exec_into() {
    echo -e "${C_GREEN}✓${C_RESET} Entering ${C_BOLD}${CONTAINER_NAME}${C_RESET}..."
    if docker exec "$CONTAINER_NAME" tmux has-session -t main 2>/dev/null; then
        exec docker exec -it "$CONTAINER_NAME" tmux attach-session -t main
    else
        exec docker exec -it "$CONTAINER_NAME" /bin/zsh
    fi
}
```

**Note**: On first start (container just created), the entrypoint starts tmux. On subsequent `./claude-dev` invocations (container already running), the launcher execs in. The `tmux has-session` check ensures we attach if available, fall back to raw zsh if not (e.g., during startup race).

---

## Step 6: `config/.zshrc` (MODIFY)

Add after line 48 (after `alias dlog=`):
```bash
alias ap='agent-panels'  # Agent panel management
```

---

## Step 7: `Dockerfile` (MODIFY)

### 7a: Add agent-panels.sh to scripts COPY block (after line 106)
```dockerfile
COPY --chown=agent:agent scripts/agent-panels.sh /usr/local/bin/agent-panels
```

### 7b: Add tmux.conf to staged configs (after line 118)
```dockerfile
COPY config/tmux.conf /etc/claude-dev/configs/tmux.conf
```

### 7c: Add tmux.conf to agent home COPY (after line 125)
```dockerfile
COPY --chown=agent:agent config/tmux.conf /home/agent/.tmux.conf
```

### 7d: Add agent-panels to chmod block (line 134 area)
```dockerfile
             /usr/local/bin/agent-panels \
```

---

## Step 8: `CONFIG_VERSION` (MODIFY)

Bump from `2026.02.12` to `2026.02.15` to trigger config sync on next start.

---

## Step 9: Tests

### `tests/smoke.bats` — add:

```bash
@test "agent-panels script is present and executable" {
    [ -x /usr/local/bin/agent-panels ]
}

@test "tmux.conf is staged for version-sync" {
    [ -f /etc/claude-dev/configs/tmux.conf ]
}

@test "tmux.conf is installed in agent home" {
    [ -f /home/agent/.tmux.conf ]
}

@test "agent-panels shows help with no arguments" {
    run agent-panels
    [ "$status" -eq 0 ]
    [[ "$output" == *"toggle"* ]]
}

@test "zshrc has agent-panels alias" {
    grep -q "alias ap=" /etc/claude-dev/configs/.zshrc
}
```

### `tests/helpers/setup.bash` — update `run_in_pane`:

The existing `unset TMUX` workaround in `run_in_pane` (line 49) still works since the new welcome guard checks pane index, not just `$TMUX`. No change strictly required, but consider adding a comment.

---

## Keybinding Reference

### tmux keybindings (Ctrl-b is the prefix)

| Keys | Action | When to use |
|------|--------|-------------|
| **Ctrl-b  a** | **Toggle agent panels** (hide/show) | Declutter when agents are noisy; restore to check progress |
| **Ctrl-b  A** | **List agent panes** (info) | See what agents are running, their PIDs |
| **Ctrl-b  Tab** | **Next pane** | Cycle forward through visible panes |
| **Ctrl-b  Shift-Tab** | **Previous pane** | Cycle backward |
| **Ctrl-b  z** | **Zoom/unzoom pane** | Full-screen one agent to chat with it |
| **Ctrl-b  h/j/k/l** | **Navigate panes** (vim-style) | Jump to a specific direction |
| **Ctrl-b  H/J/K/L** | **Resize panes** | Make one pane bigger/smaller |
| **Ctrl-b  t** | **Re-tile layout** | Reset to even grid after manual resizing |
| **Ctrl-b  \|** | **Split horizontal** | Manual pane creation |
| **Ctrl-b  -** | **Split vertical** | Manual pane creation |
| **Ctrl-b  r** | **Reload tmux config** | After manual config edits |
| **Mouse click** | **Select pane** | Click any pane to focus it |
| **Mouse drag** | **Resize pane border** | Drag borders between panes |
| **Mouse scroll** | **Scroll history** | Scroll back in any pane |

### Shell aliases

| Alias | Command | Purpose |
|-------|---------|---------|
| `ap toggle` | `agent-panels toggle` | Same as Ctrl-b a |
| `ap hide` | `agent-panels hide` | Hide agents to background |
| `ap show` | `agent-panels show` | Bring agents back |
| `ap list` | `agent-panels list` | Show agent pane info |

### Claude Code keybindings (unchanged, pass through tmux)

| Keys | Action |
|------|--------|
| Shift-Tab | Toggle delegate mode (agent teams) |
| Shift-Up/Down | Select teammate |
| Ctrl-T | Toggle task list |

---

## UX Flow

```
1. ./claude-dev                 → builds/starts container, attaches tmux session "main"
2. Welcome screen shows         → status checks, guided setup (pane 1, window 1 only)
3. cs                           → starts Claude Code
4. Shift-Tab to delegate        → Claude creates teammate in new tmux pane
5. Panes auto-tile              → after-split-window hook fires, layout: tiled
6. Ctrl-b Tab                   → cycle to agent pane, watch it work
7. Ctrl-b z                     → zoom agent pane to full screen, type to chat
8. Ctrl-b z                     → unzoom, back to tiled view
9. Ctrl-b a                     → hide all agent panes (status bar: "agents hidden")
10. Ctrl-b a                    → show them again, re-tiled
11. ./claude-dev (2nd terminal) → attaches to SAME tmux session, sees everything
```

---

## Implementation Order

1. `config/tmux.conf` (new, no deps)
2. `scripts/agent-panels.sh` (new, no deps)
3. `config/.zshrc` (add alias)
4. `scripts/container-welcome.sh` (fix guard — must happen before step 5)
5. `scripts/entrypoint.sh` (tmux auto-start + config sync)
6. `scripts/launcher.sh` (tmux attach in exec_into)
7. `Dockerfile` (COPY + chmod)
8. `CONFIG_VERSION` (bump)
9. `tests/smoke.bats` (add new tests)
10. Build, test, verify
