#!/bin/bash
set -euo pipefail

# take-screenshot — Unified screenshot helper for Claude Code
# Supports three modes:
#   url     — Capture a web page using Playwright
#   display — Capture the X11 display using ImageMagick
#   term    — Capture terminal command output using termshot

OUTPUT_DIR="/workspace/attachments"

# go-installed tools (termshot) live in ~/go/bin, which may not be on PATH
export PATH="/home/agent/go/bin:$PATH"

ts() { date -u +"%Y%m%d-%H%M%S"; }

ensure_dir() { mkdir -p "$OUTPUT_DIR"; }

usage() {
    cat <<'EOF'
Usage: take-screenshot <command> [options] [args...]

Commands:
  url [options] <URL>     Capture a web page screenshot
  display                 Capture the current X11 display
  term <command>          Capture terminal command output

Options for 'url':
  --full-page             Capture the full scrollable page
  --device <name>         Emulate a device (e.g. "iPhone 11")
  -o, --output <path>     Custom output path

Options for 'display':
  -o, --output <path>     Custom output path

Options for 'term':
  -o, --output <path>     Custom output path

Defaults:
  Output directory: /workspace/attachments/
  Filenames are auto-generated with timestamps if not specified.

Examples:
  take-screenshot url http://localhost:3000
  take-screenshot url --full-page http://localhost:3000
  take-screenshot url --device "iPhone 11" http://localhost:3000
  take-screenshot display
  take-screenshot term "pytest tests/"
EOF
}

cmd_url() {
    local full_page=""
    local device=""
    local output=""
    local url=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --full-page)
                full_page="--full-page"
                shift
                ;;
            --device)
                device="$2"
                shift 2
                ;;
            -o|--output)
                output="$2"
                shift 2
                ;;
            -*)
                echo "Unknown option: $1" >&2
                return 1
                ;;
            *)
                url="$1"
                shift
                ;;
        esac
    done

    if [ -z "$url" ]; then
        echo "Usage: take-screenshot url [--full-page] [--device <name>] [-o <path>] <URL>" >&2
        return 1
    fi

    ensure_dir
    if [ -z "$output" ]; then
        output="${OUTPUT_DIR}/url-$(ts).png"
    fi

    local args=()
    if [ -n "$full_page" ]; then
        args+=("$full_page")
    fi
    if [ -n "$device" ]; then
        args+=(--device "$device")
    fi
    args+=("$url" "$output")

    # Prefer the image's pinned global CLI; `npx --yes` re-resolves 'latest'
    # at runtime and can drift ahead of the baked browsers. npx fallback
    # covers images built before playwright was installed globally.
    if command -v playwright >/dev/null 2>&1; then
        playwright screenshot "${args[@]}"
    else
        npx --yes playwright screenshot "${args[@]}"
    fi

    echo "$output"
}

cmd_display() {
    local output=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -o|--output)
                output="$2"
                shift 2
                ;;
            -*)
                echo "Unknown option: $1" >&2
                return 1
                ;;
            *)
                echo "Unknown argument: $1" >&2
                return 1
                ;;
        esac
    done

    # Ensure Xvfb is running
    if [ -z "${DISPLAY:-}" ]; then
        export DISPLAY=:99
    fi
    if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        echo "Starting Xvfb on $DISPLAY..." >&2
        Xvfb "$DISPLAY" -screen 0 1280x720x24 &
        sleep 1
    fi

    ensure_dir
    if [ -z "$output" ]; then
        output="${OUTPUT_DIR}/display-$(ts).png"
    fi

    import -window root -display "$DISPLAY" "$output"
    echo "$output"
}

cmd_term() {
    local output=""
    local cmd=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -o|--output)
                output="$2"
                shift 2
                ;;
            -*)
                echo "Unknown option: $1" >&2
                return 1
                ;;
            *)
                cmd="$1"
                shift
                ;;
        esac
    done

    if [ -z "$cmd" ]; then
        echo "Usage: take-screenshot term [-o <path>] <command>" >&2
        return 1
    fi

    ensure_dir
    if [ -z "$output" ]; then
        output="${OUTPUT_DIR}/term-$(ts).png"
    fi

    # Run through bash -c so pipes, quotes, and globs in the command behave
    # like a shell one-liner instead of being word-split into termshot args.
    termshot -f "$output" -- bash -c "$cmd"
    echo "$output"
}

case "${1:-}" in
    url)     shift; cmd_url "$@" ;;
    display) shift; cmd_display "$@" ;;
    term)    shift; cmd_term "$@" ;;
    -h|--help|"") usage ;;
    *)       echo "Unknown command: $1" >&2; usage; exit 1 ;;
esac
