#!/bin/bash
set -euo pipefail

# dev-log — Structured development logger
# Writes to /workspace/.claude/logs/ with four category files:
#   runs.log      — command executions and their outcomes
#   decisions.log — architectural/design decisions
#   errors.log    — failures and root causes
#   changes.log   — what changed and why

LOG_DIR="/workspace/.claude/logs"
AGENT="${CLAUDE_AGENT_NAME:-$(whoami)}"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

ensure_dir() { mkdir -p "$LOG_DIR"; }

append() {
    local file="$1"
    shift
    ensure_dir
    printf '%s\n' "$@" >> "$LOG_DIR/$file"
}

usage() {
    cat <<'EOF'
Usage: dev-log <command> [args...]

Commands:
  run <cmd> <pass|fail> <reason> [detail]   Log a command execution
  decision <description>                     Log an architectural decision
  error <what> [detail]                      Log a failure
  change <what> <why>                        Log a code change
  show [category] [N]                        Show recent entries (default: all, 20)

Categories: runs, decisions, errors, changes

Examples:
  dev-log run "npm test" pass "Verify auth fix"
  dev-log run "pytest" fail "Auth tests" "Token expiry not handled"
  dev-log decision "Use polling instead of websockets for simplicity"
  dev-log error "Docker build failed" "Missing dependency in requirements.txt"
  dev-log change "Add retry logic to API client" "Intermittent 503s in production"
  dev-log show errors 10
EOF
}

cmd_run() {
    local cmd="${1:-}" result="${2:-}" reason="${3:-}" detail="${4:-}"
    if [ -z "$cmd" ] || [ -z "$result" ] || [ -z "$reason" ]; then
        echo "Usage: dev-log run <cmd> <pass|fail> <reason> [detail]" >&2
        return 1
    fi
    if [ "$result" != "pass" ] && [ "$result" != "fail" ]; then
        echo "Error: result must be 'pass' or 'fail', got '$result'" >&2
        echo "Usage: dev-log run <cmd> <pass|fail> <reason> [detail]" >&2
        return 1
    fi
    local entry="--- run | $(ts) | $AGENT
command: $cmd
exit: $result
reason: $reason"
    [ -n "$detail" ] && entry="$entry
detail: $detail"
    entry="$entry
---"
    append "runs.log" "$entry"
}

cmd_decision() {
    local desc="${1:-}"
    if [ -z "$desc" ]; then
        echo "Usage: dev-log decision <description>" >&2
        return 1
    fi
    append "decisions.log" "--- decision | $(ts) | $AGENT
$desc
---"
}

cmd_error() {
    local what="${1:-}" detail="${2:-}"
    if [ -z "$what" ]; then
        echo "Usage: dev-log error <what> [detail]" >&2
        return 1
    fi
    local entry="--- error | $(ts) | $AGENT
what: $what"
    [ -n "$detail" ] && entry="$entry
detail: $detail"
    entry="$entry
---"
    append "errors.log" "$entry"
}

cmd_change() {
    local what="${1:-}" why="${2:-}"
    if [ -z "$what" ] || [ -z "$why" ]; then
        echo "Usage: dev-log change <what> <why>" >&2
        return 1
    fi
    append "changes.log" "--- change | $(ts) | $AGENT
what: $what
why: $why
---"
}

cmd_show() {
    local category="${1:-}" count="${2:-20}"
    ensure_dir

    if [ -z "$category" ]; then
        for f in runs.log decisions.log errors.log changes.log; do
            if [ -f "$LOG_DIR/$f" ]; then
                echo "=== $f ==="
                tail -n "$count" "$LOG_DIR/$f"
                echo ""
            fi
        done
    else
        local file="${category}.log"
        if [ -f "$LOG_DIR/$file" ]; then
            tail -n "$count" "$LOG_DIR/$file"
        else
            echo "No entries in $category" >&2
        fi
    fi
}

case "${1:-}" in
    run)      shift; cmd_run "$@" ;;
    decision) shift; cmd_decision "$@" ;;
    error)    shift; cmd_error "$@" ;;
    change)   shift; cmd_change "$@" ;;
    show)     shift; cmd_show "$@" ;;
    -h|--help|"") usage ;;
    *)        echo "Unknown command: $1" >&2; usage; exit 1 ;;
esac
