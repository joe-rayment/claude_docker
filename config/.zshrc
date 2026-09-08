# Path configuration
usr_local_dir="/usr/local"
export PATH="$HOME/.local/bin:$HOME/bin:$usr_local_dir/bin:$PATH"

# The template's own CLIs. The rulebook tells the agent to type `lane`,
# `tier-set`, `orca-dispatch`, `bd-guard` and the rest by name, and the
# hooks already run them by absolute path from here -- without this the
# names resolve to nothing and the first line of every session fails.
# The folder's clone wins; the image's copy is the fallback for a folder
# on the runtime path, where /opt/claude-orca-host does not exist.
for _co_bin in "${PROJECT_DIR:-/nonexistent}/.claude-dev/template/bin" \
             "${CLAUDE_ORCA_HOST_DIR:-/opt/claude-orca-host}/template/bin" \
             /opt/claude-orca/bin; do
  if [ -d "$_co_bin" ]; then
    case ":$PATH:" in
      *":$_co_bin:"*) ;;
      *) export PATH="$_co_bin:$PATH" ;;
    esac
    break
  fi
done
unset _co_bin

# Preferred editor
export EDITOR='hx'
export VISUAL='hx'

# Language environment
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# ── Terminal palette ────────────────────────────────────────────────────────
# Orca resolves its terminal palette BY NAME, and only in the browser: the
# name lives in localStorage (`orca.web.settings.v1`), seeded into the served
# web-index.html by scripts/container/patch-orca-web-theme.py. That makes the
# colour a property of the IMAGE a folder happens to be running, which is how
# it silently failed on 2026-09-08: the folder's `docker pull` came back 403
# (private GHCR package), the launcher ran the local image anyway, that
# image's older patcher reported "already seeds theme dark" and skipped the
# palette, and every terminal stayed on Orca's default white-on-grey.
#
# So the palette is set from the shell as well, with the OSC sequences
# xterm.js honours (4 = the sixteen ANSI slots, 10 = default foreground,
# 11 = background, 12 = cursor). No image, no browser state and no root are
# involved, it reaches every terminal in the folder rather than only the ones
# a seeded browser opened, and it agrees with the seed rather than fighting
# it: the numbers below are Orca's own builtin "Homebrew" record, copied from
# out/shared in the 1.4.197 bundle.
#
# CLAUDE_ORCA_TERMINAL_THEME picks the palette (claude-orca.json's
# `terminalTheme`); `none` leaves the terminal alone, and so does any name
# only Orca knows -- there the browser seed is still the one that resolves it.
_co_palette_homebrew=(
  '#000000' '#990000' '#00a600' '#999900'   # black red green yellow
  '#0000b2' '#b200b2' '#00a6b2' '#bfbfbf'   # blue magenta cyan white
  '#666666' '#e50000' '#00d900' '#e5e500'   # bright black red green yellow
  '#0000ff' '#e500e5' '#00e5e5' '#e5e5e5'   # bright blue magenta cyan white
  '#00ff00' '#000000' '#00ff00'             # foreground background cursor
)

_co_apply_terminal_palette() {
  [ -t 1 ] || return 0
  local -a pal
  case "${CLAUDE_ORCA_TERMINAL_THEME:-Homebrew}" in
    Homebrew|homebrew) pal=("${_co_palette_homebrew[@]}") ;;
    *) return 0 ;;
  esac
  local i
  for i in {1..16}; do
    printf '\033]4;%d;%s\a' "$((i - 1))" "${pal[$i]}"
  done
  printf '\033]10;%s\a\033]11;%s\a\033]12;%s\a' \
    "${pal[17]}" "${pal[18]}" "${pal[19]}"
}
_co_apply_terminal_palette

# ls(1) colours, in the same key.
export LS_COLORS='di=34:ln=35:so=32:pi=33:ex=31:bd=34;46:cd=34;43:su=30;41:sg=30;46:tw=30;42:ow=30;43'

# Aliases
alias ll='ls -lah'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'

# Git aliases
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline --graph --decorate'

# Helix aliases
alias vim='hx'
alias vi='hx'

# Claude Code shortcuts
cs()  { claude --dangerously-skip-permissions "$@" }
csd() { claude --dangerously-skip-permissions --debug "$@" }
cn()  { claude "$@" }

# ── Tiered orchestration: /tier (slash command) is the primary interface ────
# The engine is .claude-dev/template/bin/tier-set (repo: scripts/tier-set.sh).
# You pick ONE top model (alias fable/opus/sonnet/haiku or a full id); worker
# and recon are DERIVED via tier-derive — worker one rung down CAPPED at
# sonnet-class, recon one below the worker — so the trio can't drift from the
# default (2/3-arg forms pin them explicitly).
# tier-set writes .claude-dev/state/tier.json (top/worker/recon/pinned/
# overdrive) and .model into this project's settings.local.json — NEVER
# agents/executor.md or scout.md frontmatter, which the sandbox write-denies.
# tier-gate (a PreToolUse[Agent] hook) reads tier.json at spawn time and
# injects the worker/recon model into an executor/scout Agent call that
# omits one; tier-reconcile (SessionStart/PostModelSwitch/ConfigChange) keeps
# tier.json's worker/recon linked to whatever /model last set. Verifier &
# oracle use `model: inherit` and track the orchestrator. Inside any session:
#   /tier opus   or  /model opus   or  /tier show
#
# NEVER set ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL(_NAME) or
# CLAUDE_CODE_SUBAGENT_MODEL anywhere (shell or settings env): the first six
# corrupt the native /model picker (its rows read those vars and selections
# persist bare aliases — the 2026-07-17 model-selection trap), the last
# flattens all tiers onto one model. tier-reconcile purges all of them on
# sight — always go through tier-set.
#
# Shell sugar for the same engine (works even if you never open a session):
tier() {
    tier-set "$@" || return 1
    # bare `tier` or `tier show` just prints current state — don't launch.
    { [ $# -eq 0 ] || [ "${1:-}" = show ]; } && return 0
    claude --dangerously-skip-permissions
}
tier-show() { tier-set show }
alias tier-cost='cost-mirror --report'  # full per-model dollar breakdown
alias dlog='dev-log'  # Development logger
alias screenshot='take-screenshot'  # Screenshot tool
alias ss='take-screenshot'  # Screenshot shortcut
alias cse='csearch'  # Lean combined code search (glob+grep+read+sig)

# Beads issue tracker shortcuts
if command -v bd &>/dev/null; then
    alias br='bd ready'           # Show actionable tasks
    alias bds='bd show'           # Show issue details
    alias bdc='bd create'         # Create new issue
fi

# Log viewing shortcuts
alias clogs='view-logs'  # View Claude logs
alias clog-latest='cat ~/.claude/debug/latest'  # Quick peek at latest log
alias clog-export='mkdir -p "$HOME/.claude/exported-logs" && cp ~/.claude/debug/latest "$HOME/.claude/exported-logs/session-$(date +%Y%m%d-%H%M%S).log" && echo "Log exported to ~/.claude/exported-logs/"'

# History configuration
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE

# Auto-completion
autoload -Uz compinit
compinit

# Project identity — terminal title and prompt tag for multi-project use
if [ -n "$CLAUDE_PROJECT_NAME" ]; then
    print -Pn "\e]0;${CLAUDE_PROJECT_NAME} — Claude Dev\a"
    export RPROMPT="%F{blue}[${CLAUDE_PROJECT_NAME}]%f"
fi

# User customizations — this file survives config version updates
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local
