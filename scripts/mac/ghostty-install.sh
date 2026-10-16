# claude-dev ghostty install library (claude-orca-9bh.8, B3)
#
# Sourced by scripts/launcher.sh ("$SCRIPT_DIR/mac/ghostty-install.sh"), and
# directly by tests/ghostty-install.bats. FUNCTIONS ONLY: sourcing it runs
# nothing and sets nothing. bash 3.2 (the Mac's /bin/bash).
#
# Usage (through the launcher):
#   ./claude-dev ghostty              install (idempotent; also the "force")
#   ./claude-dev ghostty --uninstall  remove all three pieces, config restored
#   ./claude-dev ghostty --check      ask Ghostty's own CLI whether it applies
#
# What an install puts on the Mac -- three things, nothing else:
#   1. <config dir>/claude-dev.ghostty   the include (config/ghostty/
#      claude-dev.ghostty with @SHELL_INTEGRATION@ filled), written BESIDE the
#      Ghostty config because config-file paths are relative to the file that
#      names them.
#   2. ~/.local/share/claude-dev/ghostty-pane   the router, a COPY (755).
#   3. ONE line, `config-file = ?claude-dev.ghostty`, appended to the config
#      Ghostty loads: the first existing of $XDG_CONFIG_HOME|~/.config
#      /ghostty/config.ghostty, .../config, ~/Library/Application Support/
#      com.mitchellh.ghostty/config.ghostty, .../config; none -> the first is
#      created. Nothing else in the user's config is ever edited.
# ~/.local/state/claude-dev/ghostty-install records what install did (plain
# key=value: config= created=0|1 added_newline=0|1 version=N) so --uninstall
# gives back the config byte for byte.
#
# Contracts:
#   - Refuses (return 1, naming the line) when the config sets `command =`
#     itself: that command IS the routing. Nothing is touched then.
#   - Re-install is a no-op for every file; the record keeps the ORIGINAL
#     created/added_newline answers.
#   - ghostty_refresh_if_stale never installs uninvited (no record -> nothing)
#     and never fails: it runs at the top of every `open`.
#   - Test seams: HOME, XDG_CONFIG_HOME, CLAUDE_ORCA_GHOSTTY_CONFIG_DIR (the
#     one directory searched/created instead of the four paths above),
#     CLAUDE_ORCA_GHOSTTY_BIN (Ghostty's CLI), GHOSTTY_TEMPLATE_ROOT.

# Set the _GH_* paths every function below shares. No forks: the stale check
# runs on every `open` and has to cost about a millisecond.
_gh_paths() {
    local f="${BASH_SOURCE[0]}"
    case "$f" in
        */*) f="${f%/*}" ;;
        *)   f="." ;;
    esac
    _GH_ROOT="${GHOSTTY_TEMPLATE_ROOT:-$f/../..}"
    _GH_TMPL="$_GH_ROOT/config/ghostty/claude-dev.ghostty"
    _GH_SRC_ROUTER="$_GH_ROOT/scripts/mac/ghostty-pane"
    _GH_REC="$HOME/.local/state/claude-dev/ghostty-install"
    _GH_ROUTER="$HOME/.local/share/claude-dev/ghostty-pane"
    _GH_LINE='config-file = ?claude-dev.ghostty'
    _GH_LINE_RE='^[[:space:]]*config-file[[:space:]]*=[[:space:]]*"?\?claude-dev\.ghostty"?[[:space:]]*$'
}

# _gh_rec_get KEY -> _GH_VAL (empty when the record or the key is absent).
_gh_rec_get() {
    local l
    _GH_VAL=""
    [ -f "$_GH_REC" ] || return 0
    while IFS= read -r l || [ -n "$l" ]; do
        case "$l" in
            "$1="*) _GH_VAL="${l#*=}" ;;
        esac
    done < "$_GH_REC"
    return 0
}

# The template's version number (first line `# claude-dev ghostty v<N>`)
# -> _GH_TVER, empty when the line is missing or malformed.
_gh_template_version() {
    local l=""
    _GH_TVER=""
    IFS= read -r l < "$_GH_TMPL" 2>/dev/null || true
    case "$l" in
        "# claude-dev ghostty v"*) _GH_TVER="${l#\# claude-dev ghostty v}" ;;
    esac
    case "$_GH_TVER" in
        ""|*[!0-9]*) _GH_TVER="" ;;
    esac
    return 0
}

# The config file Ghostty loads -> _GH_CFG: the first that exists, else the
# first candidate (the one install creates).
_gh_find_config() {
    local c d
    if [ -n "${CLAUDE_ORCA_GHOSTTY_CONFIG_DIR:-}" ]; then
        d="$CLAUDE_ORCA_GHOSTTY_CONFIG_DIR"
        set -- "$d/config.ghostty" "$d/config"
    else
        d="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
        set -- "$d/config.ghostty" "$d/config" \
            "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty" \
            "$HOME/Library/Application Support/com.mitchellh.ghostty/config"
    fi
    _GH_CFG="$1"
    for c in "$@"; do
        if [ -f "$c" ]; then
            _GH_CFG="$c"
            return 0
        fi
    done
    return 0
}

# The @SHELL_INTEGRATION@ value: $SHELL's name when Ghostty knows it.
_gh_shell_integration() {
    case "$(basename "${SHELL:-}")" in
        zsh)    echo zsh ;;
        bash)   echo bash ;;
        fish)   echo fish ;;
        elvish) echo elvish ;;
        *)      echo detect ;;
    esac
}

# Write $2 to $1 only when the bytes differ (via a temp file beside it, so a
# pane starting mid-install never reads half a router).
_gh_put_file() {
    local dest="$1" src="$2" mode="$3" tmp
    if [ -f "$dest" ] && cmp -s "$src" "$dest" && [ "$(_gh_mode "$dest")" = "$mode" ]; then
        return 0
    fi
    mkdir -p "$(dirname "$dest")" || return 1
    tmp="$dest.tmp.$$"
    cp "$src" "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
}

# Octal permission bits, GNU or BSD stat.
_gh_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

# The install itself, quiet. 0 = installed (version in _GH_TVER, config in
# _GH_CFG), 1 = refused or failed (the reason on stderr, nothing half-done
# for a refusal).
_gh_install_core() {
    local rec_cfg created=0 added=0 hit tmp si
    _gh_paths
    _gh_template_version
    if [ -z "$_GH_TVER" ] || [ ! -f "$_GH_SRC_ROUTER" ]; then
        echo "claude-dev ghostty: the template's include or router is missing ($_GH_TMPL)" >&2
        return 1
    fi
    _gh_find_config
    if [ -f "$_GH_CFG" ]; then
        hit="$(grep -n -E '^[[:space:]]*command[[:space:]]*=' "$_GH_CFG" 2>/dev/null | head -1)"
        if [ -n "$hit" ]; then
            echo "claude-dev ghostty: $_GH_CFG line ${hit%%:*} sets its own command (${hit#*:})." >&2
            echo "  That command is the routing: Ghostty would keep yours and no pane would open in a sandbox." >&2
            echo "  Remove that line to route panes into sandboxed folders, or keep it and skip routing. Nothing was changed." >&2
            return 1
        fi
    fi
    # A record made for another config file (the user moved their config):
    # undo that one first, so uninstall can still hand it back.
    _gh_rec_get config
    rec_cfg="$_GH_VAL"
    if [ -f "$_GH_REC" ] && [ "$rec_cfg" != "$_GH_CFG" ]; then
        _gh_uninstall_core || return 1
        _gh_find_config
    elif [ -f "$_GH_REC" ] && [ -f "$_GH_CFG" ]; then
        _gh_rec_get created
        created="${_GH_VAL:-0}"
        _gh_rec_get added_newline
        added="${_GH_VAL:-0}"
    fi
    if [ ! -f "$_GH_CFG" ]; then
        created=1
        added=0
        mkdir -p "$(dirname "$_GH_CFG")" && : > "$_GH_CFG" || return 1
    fi
    if ! grep -q -E "$_GH_LINE_RE" "$_GH_CFG"; then
        added=0
        if [ -s "$_GH_CFG" ] && [ -n "$(tail -c 1 "$_GH_CFG")" ]; then
            printf '\n' >> "$_GH_CFG" || return 1
            added=1
        fi
        printf '%s\n' "$_GH_LINE" >> "$_GH_CFG" || return 1
    fi
    # The include beside the config, its placeholder filled from $SHELL.
    si="$(_gh_shell_integration)"
    tmp="$(mktemp "${TMPDIR:-/tmp}/cdev-ghostty.XXXXXX")" || return 1
    sed "s|@SHELL_INTEGRATION@|$si|" "$_GH_TMPL" > "$tmp"
    _gh_put_file "$(dirname "$_GH_CFG")/claude-dev.ghostty" "$tmp" 644 || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    _gh_put_file "$_GH_ROUTER" "$_GH_SRC_ROUTER" 755 || return 1
    mkdir -p "$(dirname "$_GH_REC")" || return 1
    printf 'config=%s\ncreated=%s\nadded_newline=%s\nversion=%s\n' \
        "$_GH_CFG" "$created" "$added" "$_GH_TVER" > "$_GH_REC.tmp.$$" \
        && mv -f "$_GH_REC.tmp.$$" "$_GH_REC" || return 1
    return 0
}

# Undo what the record says install did. 0 = undone, 2 = no record (nothing
# to undo), 1 = could not write.
_gh_uninstall_core() {
    local cfg created added tmp tmp2 size
    _gh_paths
    [ -f "$_GH_REC" ] || return 2
    _gh_rec_get config
    cfg="$_GH_VAL"
    _gh_rec_get created
    created="${_GH_VAL:-0}"
    _gh_rec_get added_newline
    added="${_GH_VAL:-0}"
    if [ -n "$cfg" ] && [ -f "$cfg" ] && grep -q -E "$_GH_LINE_RE" "$cfg"; then
        tmp="$(mktemp "${TMPDIR:-/tmp}/cdev-ghostty.XXXXXX")" || return 1
        tmp2="$tmp.2"
        # Drop our line; when install added a newline to finish the user's
        # last line AND our line is still last, drop that newline too.
        grep -v -E "$_GH_LINE_RE" "$cfg" > "$tmp" || true
        if [ "$added" = 1 ] && tail -n 1 "$cfg" | grep -q -E "$_GH_LINE_RE"; then
            size="$(wc -c < "$tmp")"
            size=$((size + 0))
            if [ "$size" -gt 0 ]; then
                head -c $((size - 1)) "$tmp" > "$tmp2" && mv -f "$tmp2" "$tmp"
            fi
        fi
        cat "$tmp" > "$cfg" || { rm -f "$tmp" "$tmp2"; return 1; }
        rm -f "$tmp" "$tmp2"
    fi
    if [ "$created" = 1 ] && [ -n "$cfg" ] && [ -f "$cfg" ] && [ ! -s "$cfg" ]; then
        rm -f "$cfg"
        rmdir "$(dirname "$cfg")" 2>/dev/null || true
    fi
    [ -n "$cfg" ] && rm -f "$(dirname "$cfg")/claude-dev.ghostty"
    rm -f "$_GH_ROUTER" "$_GH_REC"
    rmdir "$(dirname "$_GH_ROUTER")" "$(dirname "$_GH_REC")" 2>/dev/null || true
    _GH_CFG="$cfg"
    return 0
}

# `claude-dev ghostty`: install (or re-apply) and say so in one line.
ghostty_install() {
    _gh_install_core || return 1
    echo "Ghostty settings v$_GH_TVER installed ($_GH_CFG) -- new panes use them; reload with cmd+shift+,"
}

# `claude-dev ghostty --uninstall`: the config is byte-identical to before.
ghostty_uninstall() {
    local rc=0
    _gh_uninstall_core || rc=$?
    case "$rc" in
        0) echo "Ghostty settings removed ($_GH_CFG is as it was before the install) -- reload with cmd+shift+," ;;
        2) echo "Ghostty settings were not installed by claude-dev (no record) -- nothing to remove" ;;
        *) echo "claude-dev ghostty: could not remove the Ghostty settings" >&2; return 1 ;;
    esac
}

# Dispatcher for `claude-dev ghostty [flag]`.
ghostty_main() {
    case "${1:-}" in
        "")          ghostty_install ;;
        --uninstall) ghostty_uninstall ;;
        --check)     ghostty_check ;;
        -h|--help)   echo "usage: claude-dev ghostty [--uninstall|--check]" ;;
        *)           echo "usage: claude-dev ghostty [--uninstall|--check]" >&2; return 2 ;;
    esac
}
