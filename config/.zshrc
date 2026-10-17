# Path configuration
usr_local_dir="/usr/local"
export PATH="$HOME/.local/bin:$HOME/bin:$usr_local_dir/bin:$PATH"

# The template's own CLIs. The rulebook tells the agent to type `lane`,
# `tier-set`, `dispatch`, `bd-guard` and the rest by name, and the
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

# Preferred editor (Helix, baked into the image by setup.sh's helix phase)
export EDITOR='hx'
export VISUAL='hx'

# Language environment
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# ── Terminal foreground ─────────────────────────────────────────────────────
# The terminal is the Mac's own (Ghostty over ssh), so the palette is the
# Mac terminal's business; what the folder can still do is make unstyled
# output the folder's colour, from the shell, with the OSC escapes the
# terminal honours. (Until claude-orca-9bh the palette was resolved by name
# inside Orca's browser UI, and a stale image once silently left every
# terminal on Orca's default white-on-grey -- the shell never depended on
# the image, which is why it stayed.)
#
# Deliberately only TWO of them: OSC 10 (the default foreground) and
# OSC 12 (the cursor).
#
# NOT OSC 4 and NOT OSC 11. Painting all sixteen ANSI slots and the ground is
# what a terminal theme does, and it is what the "Homebrew" palette does in
# a terminal's own renderer -- but it also repaints the colours other programs chose
# for themselves, and on 2026-09-08 doing it live collapsed Claude Code's TUI:
# the chat input and the status bar disappeared, because their greys and
# whites had been remapped onto the ground. The default foreground is the half
# that makes unstyled output green without overruling anyone else's choices.
#
# CLAUDE_ORCA_TERMINAL_THEME (claude-orca.json's `terminalTheme`) names the
# palette; the foreground is taken from this table. A name this table does
# not carry leaves the terminal alone.
_co_terminal_foreground() {
  case "${CLAUDE_ORCA_TERMINAL_THEME:-Homebrew}" in
    Homebrew|homebrew) print -r -- '#00ff00' ;;   # green phosphor
    *) return 1 ;;
  esac
}

_co_apply_terminal_foreground() {
  [ -t 1 ] || return 0
  local fg
  fg="$(_co_terminal_foreground)" || return 0
  printf '\033]10;%s\a\033]12;%s\a' "$fg" "$fg"
}
_co_apply_terminal_foreground

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

# Ghostty ssh panes (scripts/container/pane-entry sets CDEV_PANE=1) -- tell the
# terminal where the shell is, so a new tab opens in the same folder, and keep
# the tab title honest. Both hooks go on precmd, so they run at every prompt
# and after the one-shot identity title above, which they replace.
#   OSC 7: the Mac-side path (CLAUDE_ORCA_HOST_PROJECT_DIR + the part of $PWD
#          under $PROJECT_DIR), every byte outside [A-Za-z0-9/._~-] %XX-encoded.
#          Skipped when the Mac path is unknown.
#   title: "<project> ▸ <sub/dir>", just "<project>" at the root.
if [[ -n "$CDEV_PANE" ]]; then
    # _cdev_pct <string>: the %XX-encoded string, left in $REPLY.
    _cdev_pct() {
        emulate -L zsh
        unsetopt multibyte
        local s=$1 c i
        REPLY=
        if [[ $s != *[^A-Za-z0-9/._~-]* ]]; then
            REPLY=$s
            return
        fi
        for (( i = 1; i <= ${#s}; i++ )); do
            c=${s[i]}
            if [[ $c == [A-Za-z0-9/._~-] ]]; then
                REPLY+=$c
            else
                REPLY+=$(printf '%%%02X' $(( #c )))
            fi
        done
    }

    # _cdev_pane_rel: $PWD below $PROJECT_DIR as "/sub/dir" (empty at the root
    # or outside the project), left in $REPLY.
    _cdev_pane_rel() {
        local root=${PROJECT_DIR%/}
        REPLY=
        if [[ -n $root && $PWD == "$root"/* ]]; then
            REPLY=${PWD#"$root"}
        fi
    }

    _cdev_pane_osc7() {
        [[ -n $CLAUDE_ORCA_HOST_PROJECT_DIR ]] || return 0
        _cdev_pane_rel
        _cdev_pct "${CLAUDE_ORCA_HOST_PROJECT_DIR%/}$REPLY"
        print -rn -- $'\e]7;file://localhost'"$REPLY"$'\a'
    }

    _cdev_pane_title() {
        local name=${CLAUDE_ORCA_PROJECT_NAME:-${PROJECT_DIR:t}} rel
        _cdev_pane_rel
        rel=${REPLY#/}
        name=${name//[[:cntrl:]]/}
        rel=${rel//[[:cntrl:]]/}
        if [[ -n $rel ]]; then
            print -rn -- $'\e]2;'"$name ▸ $rel"$'\a'
        else
            print -rn -- $'\e]2;'"$name"$'\a'
        fi
    }

    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _cdev_pane_osc7
    add-zsh-hook precmd _cdev_pane_title
fi

# User customizations — this file survives config version updates
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local
