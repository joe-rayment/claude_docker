# Path configuration
export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:$PATH"

# Pure prompt and plugins are configured by zsh-in-docker
# No need to source oh-my-zsh manually

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
# Try to install Wozcode plugin once Claude is authenticated. The script is
# idempotent (marker-file gated) and exits in milliseconds when already done
# or when prerequisites are missing, so it's safe to call on every launch.
_woz_try_install() {
    [ -x /usr/local/bin/install-wozcode ] && /usr/local/bin/install-wozcode 2>/dev/null || true
}
cs()  { _woz_try_install; _claude_in_tmux claude --dangerously-skip-permissions "$@" }
csd() { _woz_try_install; _claude_in_tmux claude --dangerously-skip-permissions --debug "$@" }
cn()  { _woz_try_install; _claude_in_tmux claude "$@" }
alias menu='/usr/local/bin/guided-setup.sh'  # Setup menu
alias dlog='dev-log'  # Development logger
alias screenshot='take-screenshot'  # Screenshot tool
alias ss='take-screenshot'  # Screenshot shortcut

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

# Auto-completion
autoload -Uz compinit
compinit

# Key bindings
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down

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
