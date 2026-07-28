# Path configuration
export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:$PATH"

# oh-my-zsh + pure prompt + plugins (installed at image build via zsh-in-docker).
# This file replaces the zsh-in-docker-generated .zshrc, so it must source
# oh-my-zsh itself — nothing else does.
export ZSH="$HOME/.oh-my-zsh"
if [ -f "$ZSH/oh-my-zsh.sh" ]; then
    ZSH_THEME=""    # pure loads via promptinit below, not as an omz theme
    plugins=(git zsh-syntax-highlighting)
    # Only on images built after the plugin was added (existing home volumes
    # keep their original ~/.oh-my-zsh) — include when present.
    [ -d "$ZSH/custom/plugins/zsh-history-substring-search" ] && plugins+=(zsh-history-substring-search)
    source "$ZSH/oh-my-zsh.sh"
    fpath+=("$ZSH/custom/themes/pure")
    autoload -U promptinit && promptinit
    prompt pure
fi

# IntelliShell integration
if [ -f "$HOME/.local/share/intelli-shell/bin/intelli-shell" ]; then
    export PATH="$HOME/.local/share/intelli-shell/bin:$PATH"
    source <("$HOME/.local/share/intelli-shell/bin/intelli-shell" init zsh)
fi

# Preferred editor
export EDITOR='hx'
export VISUAL='hx'

# Language environment
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Terminal colors - Homebrew-inspired theme
# Base colors
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

# Claude Code shortcuts — always launch inside tmux so a second session is
# always one Ctrl-b % away. If already in tmux, run claude directly.
_claude_in_tmux() {
    if [ -n "$TMUX" ]; then
        "$@"
    else
        tmux new-session "${(q)@}"
    fi
}
cs()  { _claude_in_tmux claude --dangerously-skip-permissions "$@" }
csd() { _claude_in_tmux claude --dangerously-skip-permissions --debug "$@" }
cn()  { _claude_in_tmux claude "$@" }

# ── Tiered orchestration: /tier (slash command) is the primary interface ────
# The engine is /usr/local/bin/tier-set (repo: scripts/tier-set.sh). You pick
# ONE top model (alias fable/opus/sonnet/haiku or a full id); worker and recon
# are DERIVED via tier-derive — worker one rung down CAPPED at sonnet-class,
# recon one below the worker — so the trio can't drift from the default
# (2/3-arg forms pin them explicitly).
# tier-set writes .model (ladder ids bind instantly; off-ladder ids are
# probed, TIER_PROBE=1 probes everything with downward degradation) into
# ~/.claude/settings.json and a CONCRETE model id into the frontmatter of
# ~/.claude/agents/executor.md (worker) and scout.md (recon). tier-reconcile
# (a SessionStart + UserPromptSubmit hook) keeps those bindings synced to
# .model whenever /model changes it; bindings apply to NEW sessions (agent
# files are snapshotted at session start). Verifier & oracle use `model:
# inherit` and track the orchestrator. Inside any session:
#   /tier opus   or  /model opus   or  /tier show
#
# NEVER set ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL(_NAME) or
# CLAUDE_CODE_SUBAGENT_MODEL anywhere (shell or settings env): the first six
# corrupt the native /model picker (its rows read those vars and selections
# persist bare aliases — the 2026-07-17 model-selection trap), the last
# flattens all tiers onto one model. tier-set and tier-reconcile purge all
# of them on sight — always go through tier-set.
#
# Shell sugar for the same engine (works even if you never open a session):
tier() {
    tier-set "$@" || return 1
    # bare `tier` or `tier show` just prints current state — don't launch.
    { [ $# -eq 0 ] || [ "${1:-}" = show ]; } && return 0
    _claude_in_tmux claude --dangerously-skip-permissions
}
tier-show() { tier-set show }
alias menu='/usr/local/bin/guided-setup.sh'  # Setup menu
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
alias clog-export='mkdir -p /home/agent/.claude/exported-logs && cp ~/.claude/debug/latest /home/agent/.claude/exported-logs/session-$(date +%Y%m%d-%H%M%S).log && echo "Log exported to ~/.claude/exported-logs/"'

# History configuration
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE

# Auto-completion (oh-my-zsh runs compinit itself when sourced above)
if [ ! -f "$ZSH/oh-my-zsh.sh" ]; then
    autoload -Uz compinit
    compinit
fi

# Key bindings — Up/Down substring-search history, only if the plugin loaded
# (binding a missing widget breaks arrow-key history entirely)
if (( ${+widgets[history-substring-search-up]} )); then
    bindkey '^[[A' history-substring-search-up
    bindkey '^[[B' history-substring-search-down
    bindkey '^[OA' history-substring-search-up
    bindkey '^[OB' history-substring-search-down
fi

# Project identity — terminal title and prompt tag for multi-project use
if [ -n "$CLAUDE_PROJECT_NAME" ]; then
    print -Pn "\e]0;${CLAUDE_PROJECT_NAME} — Claude Dev\a"
    export RPROMPT="%F{blue}[${CLAUDE_PROJECT_NAME}]%f"
fi

# grab: translate host paths to container paths or copy files to /drops
# Usage: grab /Users/you/Downloads/screenshot.png
#   - If file exists at that path in container, prints the container path
#   - If not, suggests copying to ~/claude-drops/
grab() {
    local host_path="$1"
    if [ -z "$host_path" ]; then
        echo "Usage: grab <path>"
        echo "Translates host file paths to container paths"
        return 1
    fi

    # Already a valid container path?
    if [ -e "$host_path" ]; then
        echo "$host_path"
        return 0
    fi

    # Check if it's in /drops under a different prefix
    local basename
    basename=$(basename "$host_path")
    if [ -e "/drops/$basename" ]; then
        echo "/drops/$basename"
        return 0
    fi

    # Check attachments
    if [ -e "/workspace/attachments/$basename" ]; then
        echo "/workspace/attachments/$basename"
        return 0
    fi

    # Not found — give instructions
    echo "File not found in container."
    echo ""
    echo "To share this file, copy it on your host machine:"
    echo "  cp \"$host_path\" ~/claude-drops/"
    echo ""
    echo "Then access it here as: /drops/$basename"
    return 1
}

# Welcome message
command -v container-welcome >/dev/null 2>&1 && container-welcome || true

# User customizations — this file survives config version updates
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local
