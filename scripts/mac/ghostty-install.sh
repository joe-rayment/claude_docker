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
#   - Self-test before any write: the template's `command =` line is run the
#     way Ghostty runs it, once with no router and once with a router that
#     exits 3; both must still reach the Mac shell. A template whose command
#     line would lock the user out of a shell is refused (return 1, nothing
#     touched).
#   - Revision refresh, upgrade only: a `# revision N` line (first 5 lines,
#     missing -> 1) lets a template change reach folders whose record already
#     says the same version; a LOWER installed revision is re-applied, an equal
#     or higher one never is. The version stays v1 on purpose: older templates
#     re-apply on ANY version difference, so bumping it would downgrade them.
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

# Run the template's `command =` line the way Ghostty does (a login bash
# exec's it, stdin closed) under a throwaway HOME whose $SHELL just prints a
# token. Twice: no router at all, and a router that exits 3. Both must land in
# that shell. 0 = both did; 1 = one did not, or the line is missing. A command
# that execs its router would fail here, and that is the lock-out this guards.
_gh_selftest() {
    local cmd h out tok="CLAUDE-DEV-SELFTEST" rc=0
    cmd="$(sed -n 's/^command = //p' "$_GH_TMPL" 2>/dev/null)"
    [ -n "$cmd" ] || return 1
    h="$(mktemp -d "${TMPDIR:-/tmp}/cdev-selftest.XXXXXX")" || return 1
    printf '#!/bin/sh\necho %s\n' "$tok" > "$h/shell" && chmod 755 "$h/shell" || { rm -rf "$h"; return 1; }
    out="$(HOME="$h" SHELL="$h/shell" /bin/bash --noprofile --norc -c "exec -l $cmd" </dev/null 2>/dev/null)" || true
    case "$out" in *"$tok"*) ;; *) rc=1 ;; esac
    if mkdir -p "$h/.local/share/claude-dev" \
        && printf '#!/bin/sh\nexit 3\n' > "$h/.local/share/claude-dev/ghostty-pane" \
        && chmod 755 "$h/.local/share/claude-dev/ghostty-pane"; then
        out="$(HOME="$h" SHELL="$h/shell" /bin/bash --noprofile --norc -c "exec -l $cmd" </dev/null 2>/dev/null)" || true
        case "$out" in *"$tok"*) ;; *) rc=1 ;; esac
    else
        rc=1
    fi
    rm -rf "$h"
    return "$rc"
}

# A file's revision (a `# revision N` line within its first 5 lines) -> _GH_REV;
# 1 when the file, the line or the number is missing or malformed. Builtins
# only: the stale check runs on every `open`.
_gh_revision() {
    local l r n=0
    _GH_REV=1
    [ -f "$1" ] && [ -r "$1" ] || return 0
    while [ "$n" -lt 5 ] && { IFS= read -r l || [ -n "$l" ]; }; do
        n=$((n + 1))
        case "$l" in
            "# revision "*)
                r="${l#\# revision }"
                case "$r" in
                    ""|*[!0-9]*) ;;
                    *) _GH_REV="$r"; return 0 ;;
                esac
                ;;
        esac
    done < "$1"
    return 0
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
    if ! _gh_selftest; then
        echo "claude-dev ghostty: the template's command line does not fall back to a shell (self-test failed) -- nothing installed" >&2
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
    [ -n "$cfg" ] && rm -f "$(dirname "$cfg")/claude-dev.ghostty"
    if [ "$created" = 1 ] && [ -n "$cfg" ] && [ -f "$cfg" ] && [ ! -s "$cfg" ]; then
        rm -f "$cfg"
        rmdir "$(dirname "$cfg")" 2>/dev/null || true
    fi
    rm -f "$_GH_ROUTER" "$_GH_REC"
    rmdir "$(dirname "$_GH_ROUTER")" "$(dirname "$_GH_REC")" 2>/dev/null || true
    _GH_CFG="$cfg"
    return 0
}

# Runs at the top of every `open`. Bash builtins only until something differs:
# no record (the user never ran `claude-dev ghostty`) -> nothing; a record made
# by an older template version -> re-apply it and say so in one line; the same
# version but a LOWER installed revision -> re-apply likewise (never the other
# way round: an equal or higher revision is left alone).
# Always returns 0: a failed refresh must never stop a folder opening.
ghostty_refresh_if_stale() {
    local rec_ver trev cfg
    _gh_paths
    [ -f "$_GH_REC" ] || return 0
    _gh_template_version
    [ -n "$_GH_TVER" ] || return 0
    _gh_rec_get version
    rec_ver="$_GH_VAL"
    if [ "$rec_ver" != "$_GH_TVER" ]; then
        if _gh_install_core 2>/dev/null; then
            echo "Ghostty settings updated to v$_GH_TVER -- new panes use them"
        fi
        return 0
    fi
    _gh_revision "$_GH_TMPL"
    trev="$_GH_REV"
    _gh_rec_get config
    cfg="$_GH_VAL"
    [ -n "$cfg" ] || return 0
    _gh_revision "${cfg%/*}/claude-dev.ghostty"
    if [ "$_GH_REV" -lt "$trev" ]; then
        if _gh_install_core 2>/dev/null; then
            echo "Ghostty settings updated to v$_GH_TVER revision $trev -- new panes use them"
        fi
    fi
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

# --- --check: ask Ghostty's own CLI whether the settings really apply -------
#
# Two rows, "ghostty settings" and "ghostty splits", each ok|n/a|warn|FAIL,
# left in _GH_ST1/_GH_TX1 and _GH_ST2/_GH_TX2. Nothing here is a guess about
# Ghostty's config rules: the answers come from +validate-config,
# +show-config, +list-keybinds and +version of the installed app itself.

# _gh_sev CUR NEW -> the worse of two statuses (FAIL > warn > ok).
_gh_sev() {
    case "$1:$2" in
        FAIL:*|*:FAIL) echo FAIL ;;
        warn:*|*:warn) echo warn ;;
        *)             echo ok ;;
    esac
}

# _gh_conf_get KEY < "+show-config output in $_GH_SHOW" -> _GH_VAL (last wins).
_gh_conf_get() {
    local l v
    _GH_VAL=""
    while IFS= read -r l || [ -n "$l" ]; do
        case "$l" in
            "$1 = "*) v="${l#"$1 = "}"; _GH_VAL="$v" ;;
            "$1="*)   v="${l#"$1="}"; _GH_VAL="$v" ;;
        esac
    done <<EOF_SHOW
$_GH_SHOW
EOF_SHOW
    return 0
}

# The value of the template's `command =` line, the router the include names.
_gh_expected_command() {
    local l
    _GH_CMD=""
    while IFS= read -r l || [ -n "$l" ]; do
        case "$l" in
            "command = "*) _GH_CMD="${l#command = }"; break ;;
        esac
    done < "$_GH_TMPL"
    return 0
}

# Ghostty's version -> _GH_MAJ _GH_MIN (empty when it printed none).
_gh_version() {
    local out l v
    _GH_MAJ=""
    _GH_MIN=""
    out="$("$1" +version 2>/dev/null)" || true
    while IFS= read -r l || [ -n "$l" ]; do
        case "$l" in
            "Ghostty "[0-9]*) v="${l#Ghostty }" ;;
            *"version: "[0-9]*) v="${l#*version: }" ;;
            *) continue ;;
        esac
        _GH_MAJ="${v%%.*}"
        v="${v#*.}"
        _GH_MIN="${v%%[!0-9]*}"
        break
    done <<EOF_VER
$out
EOF_VER
    case "$_GH_MAJ$_GH_MIN" in
        ""|*[!0-9]*) _GH_MAJ=""; _GH_MIN="" ;;
    esac
    return 0
}

# Row 1's findings. Runs inside _gh_check_core and edits ITS locals (s1, t1,
# inc) -- bash's dynamic scope -- with $_GH_SHOW already holding +show-config.
_gh_check_settings() {
    local want got l
    _gh_expected_command
    _gh_conf_get command
    got="${_GH_VAL#shell:}"
    if [ -z "$got" ]; then
        s1=FAIL; t1="$t1; command is not set: Ghostty is not reading claude-dev.ghostty"
    elif [ "$got" != "$_GH_CMD" ]; then
        s1=FAIL; t1="$t1; command is '$got', not claude-dev's router: another config line wins"
    fi
    want=""
    if [ -f "$inc" ]; then
        while IFS= read -r l || [ -n "$l" ]; do
            case "$l" in "shell-integration = "*) want="${l#shell-integration = }" ;; esac
        done < "$inc"
    fi
    [ -n "$want" ] || want="$(_gh_shell_integration)"
    _gh_conf_get shell-integration
    got="${_GH_VAL:-detect}"
    if [ "$got" != "$want" ]; then
        s1=FAIL; t1="$t1; shell-integration is '$got', claude-dev set '$want'"
    fi
    _gh_conf_get window-inherit-working-directory
    if [ "$_GH_VAL" != false ]; then
        s1=FAIL; t1="$t1; window-inherit-working-directory is '${_GH_VAL:-true}', claude-dev set false"
    fi
    _gh_conf_get clipboard-write
    if [ "$_GH_VAL" = deny ]; then
        [ "$s1" = FAIL ] || s1=warn
        t1="$t1; clipboard-write = deny: Claude Code's copy will not reach the Mac clipboard"
    fi
    return 0
}

# Row 2's findings (same dynamic-scope contract, s2/t2): the two split
# keybinds exist in the keybinds Ghostty really loaded, and the version.
_gh_check_splits() {
    local keys
    keys="$("$1" +list-keybinds 2>/dev/null)" || true
    if ! printf '%s\n' "$keys" | grep -q -E '(^|[^[:alnum:]+])(super|cmd)\+d=new_split:right'; then
        s2=FAIL; t2="$t2; cmd+d is not new_split:right (a keybind overrides claude-dev's split)"
    fi
    if ! printf '%s\n' "$keys" | grep -q -E '(^|[^[:alnum:]+])((super|cmd)\+shift|shift\+(super|cmd))\+d=new_split:down'; then
        s2=FAIL; t2="$t2; cmd+shift+d is not new_split:down (a keybind overrides claude-dev's split)"
    fi
    _gh_version "$1"
    if [ -z "$_GH_MAJ" ]; then
        [ "$s2" = FAIL ] || s2=warn
        t2="$t2; could not read Ghostty's version"
    elif [ "$_GH_MAJ" -lt 1 ] || { [ "$_GH_MAJ" -eq 1 ] && [ "$_GH_MIN" -lt 3 ]; }; then
        s2=FAIL; t2="$t2; Ghostty $_GH_MAJ.$_GH_MIN is older than 1.3, which claude-dev's settings are written for"
    fi
    return 0
}

# The core: sets the two rows, returns 0 ok/n-a, 1 warn, 2 FAIL.
_gh_check_core() {
    local bin cfg dir out s1=ok s2=ok t1="" t2="" sev rc=0 inc rv nl
    nl=$'\n'
    _gh_paths
    bin="${CLAUDE_ORCA_GHOSTTY_BIN:-/Applications/Ghostty.app/Contents/MacOS/ghostty}"
    if [ ! -x "$bin" ]; then
        _GH_ST1="n/a"; _GH_TX1="Ghostty is not installed on this Mac"
        _GH_ST2="n/a"; _GH_TX2="Ghostty is not installed on this Mac"
        return 0
    fi
    if [ ! -f "$_GH_REC" ]; then
        _GH_ST1="warn"; _GH_TX1="not installed -- ./claude-dev ghostty"
        _GH_ST2="n/a";  _GH_TX2="no claude-dev settings to check"
        return 1
    fi
    _gh_rec_get config
    cfg="$_GH_VAL"
    _gh_rec_get version
    rv="$_GH_VAL"
    dir="${cfg%/*}"
    inc="$dir/claude-dev.ghostty"
    [ -x "$_GH_ROUTER" ] || { s1=FAIL; t1="$t1; router $_GH_ROUTER missing or not executable"; }
    [ -f "$inc" ] || { s1=FAIL; t1="$t1; include $inc missing"; }
    if [ ! -f "$cfg" ] || ! grep -q -E "$_GH_LINE_RE" "$cfg"; then
        s1=FAIL; t1="$t1; $cfg no longer has the line: $_GH_LINE"
    fi
    if ! out="$("$bin" +validate-config 2>&1)"; then
        s1=FAIL
        t1="$t1; +validate-config rejects the config (${out%%"$nl"*})"
    fi
    _GH_SHOW="$("$bin" +show-config 2>/dev/null)" || true
    _gh_check_settings
    _gh_check_splits "$bin"
    [ "$s1" = ok ] || t1="${t1#; }"
    [ "$s2" = ok ] || t2="${t2#; }"
    [ -n "$t1" ] || t1="v$rv installed; Ghostty reports the include applied"
    [ -n "$t2" ] || t2="cmd+d / cmd+shift+d split in place, Ghostty $_GH_MAJ.$_GH_MIN"
    _GH_ST1="$s1"; _GH_TX1="$t1"; _GH_ST2="$s2"; _GH_TX2="$t2"
    sev="$(_gh_sev "$s1" "$s2")"
    case "$sev" in FAIL) rc=2 ;; warn) rc=1 ;; esac
    return "$rc"
}

# One row, through the launcher's doctor_row when sourced there.
_gh_row() {
    if type doctor_row >/dev/null 2>&1; then
        doctor_row "$1" "$2" "$3"
    else
        printf '  [%-7s] %-17s %s\n' "$1" "$2" "$3"
    fi
}

# `claude-dev ghostty --check`: the two rows; 0 ok or n/a, 1 warn, 2 FAIL.
ghostty_check() {
    local rc=0
    _gh_check_core || rc=$?
    _gh_row "$_GH_ST1" "ghostty settings" "$_GH_TX1"
    _gh_row "$_GH_ST2" "ghostty splits" "$_GH_TX2"
    return "$rc"
}

# The same two rows for `doctor` / `verify`: returns 2 on a FAIL only (a Mac
# without Ghostty, or one that never ran `claude-dev ghostty`, is not broken).
ghostty_doctor_rows() {
    local rc=0
    ghostty_check || rc=$?
    [ "$rc" -eq 2 ] && return 2
    return 0
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
