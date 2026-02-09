#!/usr/bin/env bats

# Experience tests — verify interactive UX using tmux
# These simulate real user interaction with the container

load helpers/setup

setup() {
    setup_tmux
    # Clear the session marker so welcome runs fresh
    rm -f /tmp/.claude-dev-welcome-shown
}

teardown() {
    teardown_tmux
}

@test "welcome screen renders on first login" {
    run_in_pane "container-welcome"
    wait_for_text "Status:"
    local output
    output=$(capture_pane)
    [[ "$output" == *"Claude"* ]]
    [[ "$output" == *"Status:"* ]]
}

@test "welcome shows Claude auth status" {
    run_in_pane "container-welcome"
    wait_for_text "Claude:"
    local output
    output=$(capture_pane)
    # Should show either authenticated or not — both are valid
    [[ "$output" == *"Claude:"* ]]
}

@test "welcome shows Git config status" {
    run_in_pane "container-welcome"
    wait_for_text "Git:"
    local output
    output=$(capture_pane)
    [[ "$output" == *"Git:"* ]]
}

@test "session marker prevents duplicate welcome" {
    # First run creates the marker
    touch /tmp/.claude-dev-welcome-shown
    run_in_pane "container-welcome"
    wait_for_text "Commands:" 5
    local output
    output=$(capture_pane)
    # Should show compact hint, not full status
    [[ "$output" == *"menu"* ]]
    [[ "$output" != *"Status:"* ]]
}

@test "guided-setup menu displays options" {
    run_in_pane "/usr/local/bin/guided-setup.sh --menu-only"
    wait_for_text "Start Claude"
    local output
    output=$(capture_pane)
    [[ "$output" == *"Start Claude"* ]]
    [[ "$output" == *"Shell"* ]]
}

@test "guided-setup menu handles invalid input" {
    run_in_pane "/usr/local/bin/guided-setup.sh --menu-only"
    wait_for_text "Choice:"
    send_keys "x" Enter
    wait_for_text "Invalid choice"
    local output
    output=$(capture_pane)
    [[ "$output" == *"Invalid choice"* ]]
}

@test "guided-setup skip to shell works" {
    run_in_pane "/usr/local/bin/guided-setup.sh --menu-only"
    wait_for_text "Choice:"
    send_keys "s" Enter
    # Should return to shell prompt — wait for it
    sleep 1
    local output
    output=$(capture_pane)
    # Menu should have exited (no more "Choice:" at the bottom)
    # The pane should show a shell prompt
    [[ "$output" != *"Invalid"* ]]
}
