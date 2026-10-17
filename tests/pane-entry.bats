#!/usr/bin/env bats
# Guards:   an ssh pane lands in the right folder with the container's env and a usable TERM, and the shell reports its folder (OSC 7) and title only inside a pane
# Fails if: pane-entry follows a ../ or symlink out of the project, drops the client's LANG, prints to stdout, or the .zshrc hooks emit other bytes or fire outside a pane
# Run:      bats tests/pane-entry.bats

ROOT="$BATS_TEST_DIRNAME/.."
PANE_ENTRY="$ROOT/scripts/container/pane-entry"
ZSH_BIN="/usr/bin/z""sh"

setup() {
  FIX="$BATS_TEST_TMPDIR"
  export PROJECT_DIR="$FIX/proj"
  mkdir -p "$PROJECT_DIR/sub dir/deep" "$FIX/outside" "$FIX/run" "$FIX/home"
  ln -s "$FIX/outside" "$PROJECT_DIR/link"
  printf "export SNAP_VAR='from snapshot'\nexport LANG='en_US.UTF-8'\n" > "$FIX/run/env"
  STUB="$FIX/stub-shell"
  cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
printf 'argc=%s\nargv=%s\n' "$#" "$*"
printf 'pwd=%s\n' "$(pwd -P)"
printf 'term=%s\npane=%s\nsnap=%s\n' "${TERM-}" "${CDEV_PANE-}" "${SNAP_VAR-}"
printf 'lang=%s\nlc_time=%s\n' "${LANG-}" "${LC_TIME-}"
EOS
  chmod +x "$STUB"
}

# run_pane [VAR=value ...]: pane-entry in an empty environment plus the fixture's
run_pane() {
  run env -i PATH="$PATH" HOME="$FIX/home" PROJECT_DIR="$PROJECT_DIR" \
    CLAUDE_ORCA_RUNTIME_DIR="$FIX/run" CLAUDE_ORCA_PANE_SHELL="$STUB" "$@" "$PANE_ENTRY"
}

@test "pane-entry: CDEV_CWD names a sub dir -> the shell starts there, as a login shell" {
  run_pane CDEV_CWD="sub dir/deep"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pwd=$(realpath "$PROJECT_DIR")/sub dir/deep"* ]]
  [[ "$output" == *"argc=1"* && "$output" == *"argv=-l"$'\n'* ]]
}

@test "pane-entry: no CDEV_CWD -> PROJECT_DIR" {
  run_pane
  [[ "$output" == *"pwd=$(realpath "$PROJECT_DIR")"$'\n'* ]]
}

@test "pane-entry: a missing dir, an absolute path, a ../ escape and a symlink out all land in PROJECT_DIR" {
  local want c
  want="pwd=$(realpath "$PROJECT_DIR")"
  for c in "nope/not/here" "$FIX/outside" "/etc" "../outside" "sub dir/../../outside" "link"; do
    run_pane CDEV_CWD="$c"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$want"$'\n'* ]] || { echo "CDEV_CWD=$c -> $output"; return 1; }
  done
}

@test "pane-entry: the env snapshot's variables arrive, and CDEV_PANE is 1" {
  run_pane
  [[ "$output" == *"snap=from snapshot"* ]]
  [[ "$output" == *"pane=1"* ]]
}

@test "pane-entry: LANG and LC_* from the client survive a snapshot that sets another LANG" {
  run_pane LANG=de_DE.UTF-8 LC_TIME=sv_SE.UTF-8
  [[ "$output" == *"lang=de_DE.UTF-8"* ]]
  [[ "$output" == *"lc_time=sv_SE.UTF-8"* ]]
  run_pane
  [[ "$output" == *"lang=en_US.UTF-8"* ]]
}

@test "pane-entry: a TERM the container has no terminfo for becomes xterm-256color; a known one is kept" {
  run_pane TERM=bogus-term
  [[ "$output" == *"term=xterm-256color"* ]]
  run_pane TERM=xterm-256color
  [[ "$output" == *"term=xterm-256color"* ]]
  run_pane TERM=linux
  [[ "$output" == *"term=linux"* ]]
}

@test "pane-entry: SSH_ORIGINAL_COMMAND runs as -lc <command>, whole and unsplit" {
  run_pane SSH_ORIGINAL_COMMAND="echo 'a  b' && ls"
  [[ "$output" == *"argc=2"* ]]
  [[ "$output" == *"argv=-lc echo 'a  b' && ls"* ]]
}

@test "pane-entry: writes nothing to stdout itself, even when the env snapshot is noisy" {
  printf "echo leaked-line\nexport SNAP_VAR=x\n" > "$FIX/run/env"
  printf '#!/bin/sh\nexit 0\n' > "$STUB"
  run_pane CDEV_CWD="sub dir"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Guards:   a pane (interactive, or `ssh host <command>`) finds the template's xclip shim before /usr/bin/xclip, because pane-entry itself puts the template bin on PATH
# Fails if: pane-entry stops prepending the template bin (only config/.zshrc does, and a `zsh -lc cmd` pane never reads it), or lets it lose to a system xclip, or breaks the folder-clone / host-copy order
# Run:      bats -f 'template bin' tests/pane-entry.bats
@test "pane-entry: the template bin leads PATH for both the interactive and the SSH_ORIGINAL_COMMAND pane" {
  local sys="$FIX/sysbin" own="$PROJECT_DIR/.claude-dev/template/bin" host="$FIX/host"
  mkdir -p "$sys" "$own" "$host/template/bin"
  printf '#!/bin/sh\n' > "$sys/xclip"; cp "$sys/xclip" "$own/xclip"; cp "$sys/xclip" "$host/template/bin/xclip"
  chmod +x "$sys/xclip" "$own/xclip" "$host/template/bin/xclip"
  printf '#!/usr/bin/env bash\ncommand -v xclip\n' > "$STUB"
  # the folder's clone beats the system copy, interactive and command pane alike
  run_pane PATH="$sys:/usr/bin:/bin" CLAUDE_ORCA_HOST_DIR="$host"
  [ "$status" -eq 0 ]
  [ "$output" = "$own/xclip" ]
  run_pane PATH="$sys:/usr/bin:/bin" CLAUDE_ORCA_HOST_DIR="$host" SSH_ORIGINAL_COMMAND='xclip -o'
  [ "$output" = "$own/xclip" ]
  # no clone in the folder -> the host copy, still ahead of the system's
  rm -rf "$PROJECT_DIR/.claude-dev"
  run_pane PATH="$sys:/usr/bin:/bin" CLAUDE_ORCA_HOST_DIR="$host" SSH_ORIGINAL_COMMAND='xclip -o'
  [ "$output" = "$host/template/bin/xclip" ]
}

# --- the .zshrc hooks, run in the real Z shell against a copy of config/.zshrc.
# The whole file is sourced (it loads fine without plugins), then every function
# on precmd_functions is called by hand, exactly as the prompt would.

run_hooks() {  # run_hooks <subdir> [VAR=value ...]; stdout of the hooks lands in $FIX/out
  local sub=$1; shift
  cp "$ROOT/config/.zshrc" "$FIX/home/.zshrc"
  mkdir -p "$PROJECT_DIR/$sub"
  env -i PATH="$PATH" HOME="$FIX/home" PROJECT_DIR="$PROJECT_DIR" \
    CLAUDE_ORCA_HOST_PROJECT_DIR='/Users/me/My Proj' "$@" \
    "$ZSH_BIN" -f -c 'source "$HOME/.zshrc" >/dev/null 2>&1; cd "$PROJECT_DIR/$1" || exit 9; for f in $precmd_functions; do $f; done' _ "$sub" > "$FIX/out"
}

@test ".zshrc hooks: in a sub dir, OSC 7 carries the encoded Mac path and the title is <name> ▸ <sub dir>" {
  export PROJECT_DIR="$FIX/My Proj"
  run_hooks "a b" CDEV_PANE=1 CLAUDE_ORCA_PROJECT_NAME=demo
  printf '\033]7;file://localhost/Users/me/My%%20Proj/a%%20b\007\033]2;demo ▸ a b\007' > "$FIX/want"
  cmp "$FIX/want" "$FIX/out"
}

@test ".zshrc hooks: at the project root the title is just the name (default: the folder's basename)" {
  export PROJECT_DIR="$FIX/proj"
  run_hooks "." CDEV_PANE=1
  printf '\033]7;file://localhost/Users/me/My%%20Proj\007\033]2;proj\007' > "$FIX/want"
  cmp "$FIX/want" "$FIX/out"
}

@test ".zshrc hooks: bytes outside the safe set are percent-encoded, UTF-8 as its raw bytes" {
  run_hooks "café#1" CDEV_PANE=1 CLAUDE_ORCA_PROJECT_NAME=demo
  grep -qF 'file://localhost/Users/me/My%20Proj/caf%C3%A9%231'$'\a' "$FIX/out"
}

@test ".zshrc hooks: outside a pane (CDEV_PANE unset) neither OSC 7 nor the title is printed" {
  run_hooks "a b" CLAUDE_ORCA_PROJECT_NAME=demo
  run grep -c $'\033]' "$FIX/out"    # a bare `! grep` never fails a bats test
  [ "$output" = "0" ]
}

# Guards:   the pane block runs `startup-menu --pane` only for a person at a terminal, never under Claude Code
# Fails if: the call loses its interactive/tty/CLAUDECODE guard, or fires outside a pane
# Run:      bats -f 'startup-menu' tests/pane-entry.bats
@test ".zshrc: the pane block calls startup-menu --pane only when interactive on a tty and not under CLAUDECODE" {
  mkdir -p "$FIX/stub"
  printf '#!/bin/sh\necho "called $*"\n' > "$FIX/stub/startup-menu"
  chmod +x "$FIX/stub/startup-menu"
  cp "$ROOT/config/.zshrc" "$FIX/home/.zshrc"
  command -v script >/dev/null || skip "no script(1) to give zsh a tty"
  tty_zsh() {  # tty_zsh [VAR=value ...]
    env -i PATH="$FIX/stub:$PATH" HOME="$FIX/home" PROJECT_DIR="$PROJECT_DIR" TERM=xterm "$@" \
      script -qec "$ZSH_BIN -i" /dev/null < <(printf 'exit\n') 2>&1
  }
  run tty_zsh CDEV_PANE=1
  case "$output" in *"called --pane"*) ;; *) echo "pane on a tty did not call it: $output"; return 1 ;; esac
  run tty_zsh CDEV_PANE=1 CLAUDECODE=1
  case "$output" in *"called"*) echo "ran under CLAUDECODE: $output"; return 1 ;; esac
  run tty_zsh
  case "$output" in *"called"*) echo "ran outside a pane: $output"; return 1 ;; esac
  # and not on a pipe, even in a pane
  run env -i PATH="$FIX/stub:$PATH" HOME="$FIX/home" PROJECT_DIR="$PROJECT_DIR" CDEV_PANE=1 "$ZSH_BIN" -i -c 'exit' </dev/null
  case "$output" in *"called"*) echo "ran without a tty: $output"; return 1 ;; esac
}
