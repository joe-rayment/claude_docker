#!/usr/bin/env bats

# Experience tests — verify interactive UX
# These test the container's user-facing scripts
# Uses 'script -qc' to provide a pseudo-TTY (required by scripts that check -t 0)

load helpers/setup

setup() {
    # Clear the session marker so welcome runs fresh
    rm -f /tmp/.claude-dev-welcome-shown
}

@test "welcome screen renders on first login" {
    run run_in_pty container-welcome </dev/null
    [[ "$output" == *"Claude"* ]]
    [[ "$output" == *"Status:"* ]]
}

@test "welcome shows Claude auth status" {
    run run_in_pty container-welcome </dev/null
    [[ "$output" == *"Claude:"* ]]
    [[ "$output" == *"["* ]]
}

@test "welcome shows Git config status" {
    run run_in_pty container-welcome </dev/null
    [[ "$output" == *"Git:"* ]]
    [[ "$output" == *"["* ]]
}

@test "session marker prevents duplicate welcome" {
    touch /tmp/.claude-dev-welcome-shown
    run run_in_pty container-welcome </dev/null
    # Should show compact hint, not full status
    [[ "$output" == *"menu"* ]]
    [[ "$output" != *"Status:"* ]]
}

@test "welcome screen shows project name when CLAUDE_PROJECT_NAME is set" {
    run run_in_pty "CLAUDE_PROJECT_NAME=testproject container-welcome" </dev/null
    [[ "$output" == *"testproject"* ]]
    [[ "$output" == *"Claude Dev"* ]]
}

@test "returning session shows project name in compact hint" {
    touch /tmp/.claude-dev-welcome-shown
    run run_in_pty "CLAUDE_PROJECT_NAME=testproject container-welcome" </dev/null
    [[ "$output" == *"testproject"* ]]
    [[ "$output" == *"menu"* ]]
}

@test "guided-setup menu displays options" {
    run run_in_pty_with_input "q" "/usr/local/bin/guided-setup.sh --menu-only"
    [[ "$output" == *"Start Claude"* ]]
    [[ "$output" == *"View logs"* ]]
    [[ "$output" == *"Quit to shell"* ]]
}

@test "guided-setup menu handles invalid input" {
    run bash -c 'printf "x\nq\n" | script -qc "/usr/local/bin/guided-setup.sh --menu-only" /dev/null 2>&1'
    [[ "$output" == *"Invalid choice"* ]]
}

@test "guided-setup quit to shell works with q" {
    run run_in_pty_with_input "q" "/usr/local/bin/guided-setup.sh --menu-only"
    [[ "$output" != *"Invalid"* ]]
}

@test "guided-setup menu shows beads option" {
    run run_in_pty_with_input "q" "/usr/local/bin/guided-setup.sh --menu-only"
    [[ "$output" == *"Beads"* ]]
}

@test "guided-setup quit to shell works with s (backwards compat)" {
    run run_in_pty_with_input "s" "/usr/local/bin/guided-setup.sh --menu-only"
    [[ "$output" != *"Invalid"* ]]
}
