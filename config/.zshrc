# Path configuration
export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:$PATH"

# Oh My Zsh installation path
export ZSH="$HOME/.oh-my-zsh"

# Disable oh-my-zsh theme (using Pure prompt instead)
ZSH_THEME=""

# Oh My Zsh plugins
plugins=(git zsh-syntax-highlighting)

# Source Oh My Zsh
source $ZSH/oh-my-zsh.sh

# Initialize Pure prompt
fpath+=("$HOME/.zsh/pure")
autoload -U promptinit; promptinit
prompt pure

# IntelliShell integration
if [ -f "$HOME/.local/bin/intelli-shell" ]; then
    export PATH="$HOME/.local/bin:$PATH"
    source <("$HOME/.local/bin/intelli-shell" init zsh)
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

# Claude Code shortcuts
alias cs='claude --dangerously-skip-permissions'  # Quick start
alias csd='claude --dangerously-skip-permissions --debug'  # With debug logging
alias cn='claude'  # Normal start

# Log viewing shortcuts
alias clogs='view-logs'  # View Claude logs
alias clog-latest='cat ~/.claude/debug/latest'  # Quick peek at latest log
alias clog-export='cp ~/.claude/debug/latest /workspace/logs/session-$(date +%Y%m%d-%H%M%S).log && echo "Log exported to workspace/logs/"'

# Ralph shortcuts
alias ralph-setup='setup-ralph'  # Run Ralph setup wizard

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

# Welcome message
container-welcome
