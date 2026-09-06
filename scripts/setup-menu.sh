#!/usr/bin/env bash
#
# setup-menu.sh -- `claude-dev setup`, the guided walk-through a first-time
# user gets instead of a wall of text (V6, claude-orca-riu.5). Five steps --
# git identity, GitHub auth, OpenRouter key, beads, the one-time Orca
# setting -- then a closing menu. Signing in to Claude is not among them:
# Claude Code does its own login the first time it runs from Orca, whose
# HOME is redirected into the folder, so the credentials land in
# .claude-dev/home/.claude/.credentials.json with nothing to do here.
# Sourced by scripts/launcher.sh (setup_menu_main <project-dir>), so it runs
# from the <project>/.claude-dev/template clone exactly as it does from a
# checkout.
#
# Two rules the whole file follows:
#   - Interactive input comes from /dev/tty, never stdin: the bootstrap
#     one-liner is itself piped into bash, so stdin is the script.
#     CLAUDE_ORCA_SETUP_INPUT replaces that source for tests -- a readable
#     file supplies the answers; set but empty (or unreadable) means there
#     is no input at all, which is the no-terminal case.
#   - No step ever blocks. Every question takes 'a' for skip-all, anything
#     unrecognised is a skip, and EOF is a skip -- so a walk-through that
#     loses its input finishes rather than hanging.
#
# Nothing here writes a credential the user did not type: the OpenRouter
# step writes state/openrouter.key from a paste and shows a masked tail.

# --- input source ----------------------------------------------------------

setup_input_available() {
    if [ "${CLAUDE_ORCA_SETUP_INPUT+set}" = "set" ]; then
        [ -n "$CLAUDE_ORCA_SETUP_INPUT" ] && [ -r "$CLAUDE_ORCA_SETUP_INPUT" ]
        return $?
    fi
    (exec 3</dev/tty) 2>/dev/null
}

setup_input_open() {
    if [ "${CLAUDE_ORCA_SETUP_INPUT+set}" = "set" ]; then
        exec 3<"$CLAUDE_ORCA_SETUP_INPUT"
    else
        exec 3</dev/tty
    fi
}

setup_input_close() {
    exec 3<&-
}

# $1 = prompt. Answer in $SETUP_REPLY; EOF reads as an empty answer. The
# answer is echoed back only when stdout is not a terminal -- a real
# terminal has echoed it already.
setup_ask() {
    SETUP_REPLY=""
    printf '%s' "$1"
    if ! IFS= read -r SETUP_REPLY <&3; then
        SETUP_REPLY=""
    fi
    if [ ! -t 1 ]; then
        printf '%s\n' "$SETUP_REPLY"
    fi
}

# Same, for a secret: never echoed, on a terminal or off it.
setup_ask_secret() {
    SETUP_REPLY=""
    printf '%s' "$1"
    if ! IFS= read -r -s SETUP_REPLY <&3; then
        SETUP_REPLY=""
    fi
    printf '\n'
}

# $1 = prompt, $2 = default answer for an empty line (y or n).
# Returns 0 = yes, 1 = no/skip this step, 2 = skip every remaining step.
setup_ask_choice() {
    local reply
    setup_ask "$1"
    reply="$SETUP_REPLY"
    [ -z "$reply" ] && reply="$2"
    case "$reply" in
        y|Y|yes|Yes|YES)  return 0 ;;
        a|A|all|All|ALL)  return 2 ;;
        *)                return 1 ;;
    esac
}

setup_colors() {
    C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_RESET=""
    if [ -t 1 ]; then
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_RESET=$'\033[0m'
    fi
}

setup_header() {
    printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
}

setup_note() {
    printf '  %s%s%s\n' "$C_DIM" "$1" "$C_RESET"
}

setup_ok() {
    printf '  %s->%s %s\n' "$C_GREEN" "$C_RESET" "$1"
}

setup_warn() {
    printf '  %s!%s  %s\n' "$C_YELLOW" "$C_RESET" "$1"
}

# --- step 1: git identity --------------------------------------------------

# The sandbox runs with GIT_CONFIG_GLOBAL pointed at the folder's own
# .gitconfig (see launcher.sh's seed_git_identity), so this file -- not the
# Mac's ~/.gitconfig -- is what every commit made in here is signed with.
setup_gitconfig_get() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    git config --file "$file" --get "user.$key" 2>/dev/null || true
}

setup_step_git() {
    local dir="$1" gc="$1/.claude-dev/home/.gitconfig" name email ans=0
    setup_header "Step 1/5: Git identity"

    name="$(setup_gitconfig_get "$gc" name)"
    email="$(setup_gitconfig_get "$gc" email)"
    if [ -n "$name" ] || [ -n "$email" ]; then
        setup_note "commits made inside this folder are signed:"
        printf '    name:  %s\n' "${name:-(not set)}"
        printf '    email: %s\n' "${email:-(not set)}"
        printf '    file:  %s\n' "$gc"
        SETUP_R1="kept"
    else
        setup_warn "no identity in $gc -- commits inside the sandbox will fail"
        SETUP_R1="skipped"
    fi
    setup_note "(the Mac's own ~/.gitconfig is not visible in here)"

    setup_ask_choice "  Change it? [y/N/a] " n || ans=$?
    if [ "$ans" = "2" ]; then return 2; fi
    if [ "$ans" != "0" ]; then return 0; fi

    local new_name new_email
    setup_ask "  Name  [${name:-none}]: ";  new_name="$SETUP_REPLY"
    setup_ask "  Email [${email:-none}]: "; new_email="$SETUP_REPLY"
    [ -n "$new_name" ]  || new_name="$name"
    [ -n "$new_email" ] || new_email="$email"
    if [ -z "$new_name" ] && [ -z "$new_email" ]; then
        setup_warn "nothing entered -- left as it was"
        return 0
    fi

    mkdir -p "$(dirname "$gc")"
    {
        printf '[user]\n'
        [ -n "$new_name" ]  && printf '\tname = %s\n' "$new_name"
        [ -n "$new_email" ] && printf '\temail = %s\n' "$new_email"
    } > "$gc"
    setup_ok "identity written to $gc"
    SETUP_R1="updated"
    return 0
}

# --- step 2: GitHub auth ---------------------------------------------------

# Informational only: it asks nothing, so it never returns 2. Signing gh in
# is a one-liner the user runs when they want it, and the host's own token
# already covers github.com through srt's proxy in the meantime.
setup_step_gh() {
    local dir="$1" hosts="$1/.claude-dev/home/.config/gh/hosts.yml"
    setup_header "Step 2/5: GitHub auth"

    if [ -f "$hosts" ]; then
        setup_ok "gh is signed in for this folder ($hosts)"
        SETUP_R2="already"
    else
        setup_note "gh inside the sandbox keeps its config in this folder:"
        printf '    %s\n' "$hosts"
        setup_note "To sign it in, from a terminal here:"
        printf '    cd %s && gh auth login\n' "$dir"
        SETUP_R2="not-signed-in"
    fi
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        setup_note "this Mac's own gh is signed in, so the wrapper already passes GH_TOKEN in masked"
    fi
    return 0
}

# --- step 3: OpenRouter key ------------------------------------------------

# Last four characters only -- enough to tell two keys apart, useless to
# anyone reading over a shoulder or a scrollback.
setup_mask_tail() {
    local value="$1"
    if [ "${#value}" -le 4 ]; then
        printf '****'
    else
        printf '%s' "${value: -4}"
    fi
}

setup_step_openrouter() {
    local dir="$1" ans=0 pasted key
    key="$(openrouter_key_file "$dir")"
    setup_header "Step 3/5: OpenRouter key"

    if [ -f "$key" ]; then
        setup_ok "a key is configured (ends $(setup_mask_tail "$(cat "$key")"))"
        SETUP_R3="already"
        setup_ask_choice "  Replace it? [y/N/a] " n || ans=$?
    else
        setup_note "OpenRouter is the default provider for delegated workers."
        setup_note "The key stays host-side in state/, write-denied to the sandbox;"
        setup_note "srt masks it, so an agent in here never sees the value."
        SETUP_R3="skipped"
        setup_ask_choice "  Paste your OpenRouter key now? [y/N/a] " n || ans=$?
    fi
    if [ "$ans" = "2" ]; then return 2; fi
    if [ "$ans" != "0" ]; then return 0; fi

    setup_ask_secret "  Key (not echoed): "
    pasted="$SETUP_REPLY"
    SETUP_REPLY=""
    if [ -z "$pasted" ]; then
        setup_warn "nothing pasted -- skipped"
        return 0
    fi

    if write_openrouter_key "$dir" "$pasted"; then
        setup_ok "key saved: $key (mode 600, ends $(setup_mask_tail "$pasted"))"
        SETUP_R3="written"
    else
        # state/ is write-denied inside layer 2, so this is what a
        # walk-through run from an already-sandboxed terminal hits.
        setup_warn "could not write $key -- state/ is host-owned, and a sandboxed shell cannot write it"
        setup_note "From a terminal outside the sandbox (or right after the bootstrap):"
        printf "    printf '%%s\\\\n' '<your key>' > %s && chmod 600 %s\n" "$key" "$key"
        SETUP_R3="skipped"
    fi
    pasted=""
    return 0
}

# --- step 4: beads ---------------------------------------------------------

# The prefix a fresh database gets: the git remote's repo name when there is
# one, the folder name otherwise -- both squeezed through the launcher's own
# name rule when this file is sourced by it.
setup_beads_prefix() {
    local dir="$1" url="" raw=""
    url="$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)"
    if [ -n "$url" ]; then
        raw="$(basename "$url" .git)"
    fi
    [ -n "$raw" ] || raw="$(basename "$dir")"
    if command -v derive_project_name >/dev/null 2>&1; then
        derive_project_name "$raw"
    else
        printf '%s\n' "$raw"
    fi
}

setup_step_beads() {
    local dir="$1" ans=0 prefix chosen
    setup_header "Step 4/5: Beads"

    if [ -d "$dir/.beads" ]; then
        setup_ok "beads is initialized here ($dir/.beads)"
        SETUP_R4="already"
        setup_ask_choice "  Re-run 'bd init' anyway? [y/N/a] " n || ans=$?
        if [ "$ans" = "2" ]; then return 2; fi
        if [ "$ans" != "0" ]; then return 0; fi
        prefix="$(setup_beads_prefix "$dir")"
    else
        prefix="$(setup_beads_prefix "$dir")"
        setup_note "Beads is the task tracker agents in here use as their memory."
        printf '    bd init --prefix %s\n' "$prefix"
        SETUP_R4="skipped"
        setup_ask_choice "  Initialize beads now? [Y/n/a] " y || ans=$?
        if [ "$ans" = "2" ]; then return 2; fi
        if [ "$ans" != "0" ]; then return 0; fi
    fi

    if ! command -v bd >/dev/null 2>&1; then
        setup_warn "bd is not on PATH -- run 'bd init --prefix $prefix' in here later"
        SETUP_R4="skipped"
        return 0
    fi

    setup_ask "  Prefix [$prefix]: "
    chosen="$SETUP_REPLY"
    [ -n "$chosen" ] || chosen="$prefix"
    if ( cd "$dir" && bd init --prefix "$chosen" ) 2>&1; then
        setup_ok "beads initialized (prefix: $chosen)"
        SETUP_R4="initialized"
    else
        setup_warn "bd init failed -- run it by hand in $dir"
        SETUP_R4="skipped"
    fi
    return 0
}

# --- step 5: the one-time Orca setting -------------------------------------

setup_step_orca() {
    local dir="$1" ans=0 cli="false"
    setup_header "Step 5/5: Orca settings"

    setup_note "One setting, once, in Orca (Settings -> Repository):"
    printf '    worktree base path: %s/.orca-worktrees\n' "$dir"
    setup_note "Worktrees made outside this folder are outside the sandbox."

    if [ -f "$dir/.claude-dev/sandbox.json" ] && command -v jq >/dev/null 2>&1; then
        cli="$(jq -r '.orca.cli // false' "$dir/.claude-dev/sandbox.json" 2>/dev/null || true)"
    fi
    if [ "$cli" = "true" ]; then
        setup_note "Orca orchestration is ON here, and Orca itself is not sandboxed:"
        setup_note "turn off Floating Workspace and public artifact links, and keep"
        setup_note "per-repo setup hooks out of orca.yaml while it is."
    fi

    setup_ask_choice "  Set it in Orca? [Y/n/a] " y || ans=$?
    if [ "$ans" = "2" ]; then return 2; fi
    if [ "$ans" = "0" ]; then
        SETUP_R5="done"
    else
        SETUP_R5="skipped"
    fi
    return 0
}

# --- summary and closing menu ----------------------------------------------

setup_print_summary() {
    printf '\n%sSetup summary:%s\n' "$C_BOLD" "$C_RESET"
    printf '  git-identity: %s\n'   "$SETUP_R1"
    printf '  github-auth: %s\n'    "$SETUP_R2"
    printf '  openrouter-key: %s\n' "$SETUP_R3"
    printf '  beads: %s\n'          "$SETUP_R4"
    printf '  orca-settings: %s\n'  "$SETUP_R5"
}

# cmd_open/cmd_doctor when this file is sourced by launcher.sh (the normal
# case), the folder's own ./claude-dev stub when it is not. Never fatal:
# --doctor exits 2 on a folder with findings, and that is a result to read,
# not a reason to end the walk-through.
setup_run_launcher() {
    local dir="$1"; shift
    if command -v cmd_doctor >/dev/null 2>&1 && [ "$1" = "--doctor" ]; then
        cmd_doctor || true
    elif command -v cmd_open >/dev/null 2>&1 && [ "$1" = "open" ]; then
        cmd_open || true
    elif [ -x "$dir/claude-dev" ]; then
        "$dir/claude-dev" "$@" || true
    else
        setup_warn "no claude-dev launcher in $dir"
    fi
}

setup_final_menu() {
    local dir="$1"
    while :; do
        printf '\n%sWhat next?%s\n' "$C_BOLD" "$C_RESET"
        printf '  [1] Open Orca.app for this folder\n'
        printf '  [2] Sandboxed shell -- how to open one\n'
        printf '  [3] claude-dev --doctor\n'
        printf '  [q] Quit\n'
        setup_ask "  Choice: "
        case "$SETUP_REPLY" in
            1)  setup_run_launcher "$dir" open ;;
            2)  setup_note "Open a terminal, then:"
                printf '    cd %s\n' "$dir"
                setup_note "The shell hook re-execs it sandboxed; you will see"
                setup_note "[claude-orca] sandboxed: writes limited to $dir"
                ;;
            3)  setup_run_launcher "$dir" --doctor ;;
            q|Q|quit|"") return 0 ;;
            *)  setup_warn "not a choice: $SETUP_REPLY" ;;
        esac
    done
}

# --- the walk-through ------------------------------------------------------

setup_menu_main() {
    local dir="$1" step rc=0 aborted=0
    setup_colors

    if ! setup_input_available; then
        printf '\nNo terminal available for the guided setup.\n'
        printf "  Run 'claude-dev setup' from a terminal in %s when you want it.\n" "$dir"
        return 0
    fi
    setup_input_open

    SETUP_R1="skipped"; SETUP_R2="skipped"; SETUP_R3="skipped"
    SETUP_R4="skipped"; SETUP_R5="skipped"

    printf '\n%sclaude-dev setup -- %s%s\n' "$C_BOLD" "$dir" "$C_RESET"
    setup_note "Every step is skippable: Enter or 'n' skips one, 'a' skips the rest."
    setup_note "Claude Code signs in on its own the first time you run it from Orca -- nothing to do here."
    trap 'printf "\n  Interrupted -- run '\''claude-dev setup'\'' again any time.\n"; exit 0' INT

    for step in 1 2 3 4 5; do
        rc=0
        case "$step" in
            1) setup_step_git        "$dir" || rc=$? ;;
            2) setup_step_gh         "$dir" || rc=$? ;;
            3) setup_step_openrouter "$dir" || rc=$? ;;
            4) setup_step_beads      "$dir" || rc=$? ;;
            5) setup_step_orca       "$dir" || rc=$? ;;
        esac
        if [ "$rc" = "2" ]; then
            aborted=1
            break
        fi
    done

    if [ "$aborted" = "1" ]; then
        printf '\nSkipping the remaining steps.\n'
    fi
    setup_print_summary
    if [ "$aborted" = "0" ]; then
        setup_final_menu "$dir"
    fi

    trap - INT
    setup_input_close
    return 0
}

# Sourced, never run: the walk-through needs the launcher's own functions
# (the key path and its one writer, cmd_open, cmd_doctor, the project name
# rule), and `claude-dev setup` is how a folder gets all of them.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "setup-menu.sh is sourced by the launcher -- run: claude-dev setup" >&2
    exit 1
fi
