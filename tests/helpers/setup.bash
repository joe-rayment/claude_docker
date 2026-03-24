#!/bin/bash

# Test helpers for bats experience tests
# Uses 'script' to provide a pseudo-TTY for scripts that check [ -t 0 ]

# Run a command in a pseudo-TTY and capture output
# Usage: run_in_pty command [args...]
run_in_pty() {
    script -qc "$*" /dev/null 2>&1
}

# Run a command in a pseudo-TTY with piped stdin
# Usage: run_in_pty_with_input "input_string" command [args...]
run_in_pty_with_input() {
    local input="$1"
    shift
    printf '%s\n' "$input" | script -qc "$*" /dev/null 2>&1
}
