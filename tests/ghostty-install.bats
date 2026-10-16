#!/usr/bin/env bats
#
# Guards:   `claude-dev ghostty` puts exactly three things on the Mac (the
#           include beside the user's Ghostty config, the router copy, one
#           `config-file = ?claude-dev.ghostty` line), is a no-op the second
#           time, refuses a config that sets its own `command =`, and
#           `--uninstall` hands the user's config back byte for byte.
# Fails if: a re-install rewrites or duplicates anything, a config with no
#           trailing newline gets two lines glued together (or keeps a stray
#           newline after uninstall), the Application Support config is
#           ignored in favour of a new ~/.config one, a user `command =` is
#           overwritten instead of refused, or uninstall leaves a file behind.
# Run:      bats tests/ghostty-install.bats < /dev/null
#
# The install library (scripts/mac/ghostty-install.sh) is sourced and called
# directly; one case drives `./claude-dev ghostty` through the launcher
# fixture. Every path is under $BATS_TEST_TMPDIR (HOME is a fixture); nothing
# here starts Ghostty, Docker or ssh.

load helpers/setup

LIB="$BATS_TEST_DIRNAME/../scripts/mac/ghostty-install.sh"
LINE='config-file = ?claude-dev.ghostty'

# Every case: HOME is the fixture setup() made; the Ghostty seams are cleared
# so a stray variable of the dev box never points an install at a real config.
gsetup() {
    case "$HOME" in
        "$BATS_TEST_TMPDIR"/*) ;;
        *) echo "refusing to run: HOME=$HOME is not a fixture" >&2; return 1 ;;
    esac
    unset XDG_CONFIG_HOME CLAUDE_ORCA_GHOSTTY_CONFIG_DIR CLAUDE_ORCA_GHOSTTY_BIN GHOSTTY_TEMPLATE_ROOT
    export SHELL=/bin/zsh
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    CFG="$HOME/.config/ghostty/config.ghostty"
    AS_DIR="$HOME/Library/Application Support/com.mitchellh.ghostty"
    ROUTER="$HOME/.local/share/claude-dev/ghostty-pane"
    REC="$HOME/.local/state/claude-dev/ghostty-install"
}

# Call library function $1 (args after) in a fresh bash, as the launcher does.
glib() {
    run bash -c 'source "$1"; shift; "$@"' _ "$LIB" "$@"
}

# A config file at $1 holding exactly the bytes of printf format $2.
put_config() {
    mkdir -p "$(dirname "$1")"
    # shellcheck disable=SC2059
    printf "$2" > "$1"
}

@test "a fresh install makes config.ghostty with the one line, the include, the router and the record" {
    gsetup
    glib ghostty_install
    [ "$status" -eq 0 ]
    [ "$output" = "Ghostty settings v1 installed ($CFG) -- new panes use them; reload with cmd+shift+," ]
    [ "$(cat "$CFG")" = "$LINE" ]
    [ "$(head -1 "$HOME/.config/ghostty/claude-dev.ghostty")" = "# claude-dev ghostty v1" ]
    grep -q '^shell-integration = zsh$' "$HOME/.config/ghostty/claude-dev.ghostty"
    ! grep -q '@SHELL_INTEGRATION@' "$HOME/.config/ghostty/claude-dev.ghostty"
    [ -x "$ROUTER" ]
    [ "$(file_mode "$ROUTER")" = "755" ]
    cmp "$ROUTER" "$BATS_TEST_DIRNAME/../scripts/mac/ghostty-pane"
    [ "$(cat "$REC")" = "$(printf 'config=%s\ncreated=1\nadded_newline=0\nversion=1' "$CFG")" ]
}

@test "installing twice changes no byte and no file mtime" {
    gsetup
    put_config "$CFG" 'font-size = 14\n'
    glib ghostty_install
    [ "$status" -eq 0 ]
    cksum "$CFG" "$HOME/.config/ghostty/claude-dev.ghostty" "$ROUTER" "$REC" > "$BATS_TEST_TMPDIR/before"
    touch "$BATS_TEST_TMPDIR/marker"
    sleep 1
    glib ghostty_install
    [ "$status" -eq 0 ]
    cksum "$CFG" "$HOME/.config/ghostty/claude-dev.ghostty" "$ROUTER" "$REC" > "$BATS_TEST_TMPDIR/after"
    cmp "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
    [ "$(grep -c -F "$LINE" "$CFG")" = "1" ]
    # The include and the router are not even rewritten.
    [ ! "$ROUTER" -nt "$BATS_TEST_TMPDIR/marker" ]
    [ ! "$HOME/.config/ghostty/claude-dev.ghostty" -nt "$BATS_TEST_TMPDIR/marker" ]
}

@test "a config with no trailing newline gets a newline, then the line; uninstall removes both" {
    gsetup
    put_config "$CFG" 'font-size = 14'
    cp "$CFG" "$BATS_TEST_TMPDIR/orig"
    glib ghostty_install
    [ "$status" -eq 0 ]
    [ "$(cat "$CFG")" = "$(printf 'font-size = 14\n%s' "$LINE")" ]
    [ "$(tail -c 1 "$CFG" | od -An -c | tr -d ' ')" = '\n' ]
    grep -q '^added_newline=1$' "$REC"
    glib ghostty_uninstall
    [ "$status" -eq 0 ]
    cmp "$CFG" "$BATS_TEST_TMPDIR/orig"
}

@test "the Application Support config is the one used when it is the only one" {
    gsetup
    put_config "$AS_DIR/config.ghostty" '# my mac config\nfont-size = 13\n'
    cp "$AS_DIR/config.ghostty" "$BATS_TEST_TMPDIR/orig"
    glib ghostty_install
    [ "$status" -eq 0 ]
    [ "$(tail -1 "$AS_DIR/config.ghostty")" = "$LINE" ]
    [ -f "$AS_DIR/claude-dev.ghostty" ]
    [ ! -e "$HOME/.config/ghostty" ]
    glib ghostty_uninstall
    [ "$status" -eq 0 ]
    cmp "$AS_DIR/config.ghostty" "$BATS_TEST_TMPDIR/orig"
    [ ! -e "$AS_DIR/claude-dev.ghostty" ]
}

@test "an old-style ~/.config/ghostty/config (no .ghostty) is the one used, and config.ghostty wins over it" {
    gsetup
    put_config "$HOME/.config/ghostty/config" 'theme = dark\n'
    glib ghostty_install
    [ "$status" -eq 0 ]
    [ "$(tail -1 "$HOME/.config/ghostty/config")" = "$LINE" ]
    [ ! -e "$CFG" ]
    glib ghostty_uninstall
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/.config/ghostty/config")" = "theme = dark" ]

    put_config "$CFG" 'a = 1\n'
    glib ghostty_install
    [ "$status" -eq 0 ]
    [ "$(tail -1 "$CFG")" = "$LINE" ]
    [ "$(cat "$HOME/.config/ghostty/config")" = "theme = dark" ]
}

@test "a config that sets its own command is refused, named by line, and nothing is touched" {
    gsetup
    put_config "$CFG" 'font-size = 14\ncommand = /opt/homebrew/bin/fish\n'
    cp "$CFG" "$BATS_TEST_TMPDIR/orig"
    glib ghostty_install
    [ "$status" -eq 1 ]
    [[ "$output" == *"$CFG line 2 sets its own command"* ]]
    [[ "$output" == *"command = /opt/homebrew/bin/fish"* ]]
    [[ "$output" == *"Nothing was changed"* ]]
    cmp "$CFG" "$BATS_TEST_TMPDIR/orig"
    [ ! -e "$HOME/.config/ghostty/claude-dev.ghostty" ]
    [ ! -e "$ROUTER" ]
    [ ! -e "$REC" ]
}

@test "an indented command is refused too, a commented-out one is not" {
    gsetup
    put_config "$CFG" '  command   =  zsh\n'
    glib ghostty_install
    [ "$status" -eq 1 ]
    put_config "$CFG" '# command = zsh\nfont-size = 14\n'
    glib ghostty_install
    [ "$status" -eq 0 ]
    [ "$(tail -1 "$CFG")" = "$LINE" ]
}

@test "uninstall gives each kind of config back byte for byte" {
    gsetup
    # trailing newline / none / blank lines last / empty file / CRLF-ish text
    local i=0 body
    for body in 'a = 1\n' 'a = 1' 'a = 1\n\n\n' '' 'a = 1\r\nb = 2\r\n' '# only a comment'; do
        i=$((i + 1))
        put_config "$CFG" "$body"
        cp "$CFG" "$BATS_TEST_TMPDIR/orig.$i"
        glib ghostty_install
        [ "$status" -eq 0 ]
        grep -q -F "$LINE" "$CFG"
        glib ghostty_uninstall
        [ "$status" -eq 0 ]
        cmp "$CFG" "$BATS_TEST_TMPDIR/orig.$i"
        [ ! -e "$HOME/.config/ghostty/claude-dev.ghostty" ]
        [ ! -e "$ROUTER" ]
        [ ! -e "$REC" ]
    done
}

@test "uninstall deletes a config the install created, and the folders it made" {
    gsetup
    [ ! -e "$HOME/.config" ]
    glib ghostty_install
    [ "$status" -eq 0 ]
    [ -f "$CFG" ]
    glib ghostty_uninstall
    [ "$status" -eq 0 ]
    [[ "$output" == "Ghostty settings removed"* ]]
    [ ! -e "$CFG" ]
    [ ! -e "$HOME/.config/ghostty" ]
    [ ! -e "$ROUTER" ]
    [ ! -e "$REC" ]
    [ ! -e "$HOME/.local/share/claude-dev" ]
    [ ! -e "$HOME/.local/state/claude-dev" ]
}

@test "a second install keeps the first install's created answer, so uninstall still deletes the config" {
    gsetup
    glib ghostty_install
    glib ghostty_install
    [ "$status" -eq 0 ]
    grep -q '^created=1$' "$REC"
    glib ghostty_uninstall
    [ ! -e "$CFG" ]
}

@test "uninstall with no record changes nothing and says so" {
    gsetup
    put_config "$CFG" 'a = 1\n'
    printf '%s\n' "$LINE" >> "$CFG"
    cp "$CFG" "$BATS_TEST_TMPDIR/orig"
    glib ghostty_uninstall
    [ "$status" -eq 0 ]
    [[ "$output" == *"not installed by claude-dev (no record)"* ]]
    cmp "$CFG" "$BATS_TEST_TMPDIR/orig"
}

@test "the include's shell-integration follows SHELL: a known shell by name, anything else detect" {
    gsetup
    export SHELL=/opt/homebrew/bin/fish
    glib ghostty_install
    grep -q '^shell-integration = fish$' "$HOME/.config/ghostty/claude-dev.ghostty"
    glib ghostty_uninstall
    export SHELL=/usr/local/bin/nu
    glib ghostty_install
    grep -q '^shell-integration = detect$' "$HOME/.config/ghostty/claude-dev.ghostty"
}

@test "the launcher's own ghostty command installs and uninstalls the same way" {
    gsetup
    local dir="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$dir"
    dir="$(abspath "$dir")"
    run make_project_v3 "$dir"
    [ "$status" -eq 0 ]
    put_config "$CFG" 'font-size = 14'
    cp "$CFG" "$BATS_TEST_TMPDIR/orig"
    run "$dir/claude-dev" ghostty
    [ "$status" -eq 0 ]
    [[ "$output" == *"Ghostty settings v1 installed ($CFG)"* ]]
    [ "$(tail -1 "$CFG")" = "$LINE" ]
    [ -x "$ROUTER" ]
    run "$dir/claude-dev" ghostty --uninstall
    [ "$status" -eq 0 ]
    [[ "$output" == "Ghostty settings removed"* ]]
    cmp "$CFG" "$BATS_TEST_TMPDIR/orig"
    [ ! -e "$ROUTER" ]
}
