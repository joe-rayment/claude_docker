#!/usr/bin/env bash
#
# take-screenshot -- Claude's eyes on a web UI, inside the Seatbelt sandbox
# (S10, claude-orca-3sk.21; see .claude/plans/orca-port.md S3.6).
#
# ONE mode: `url`. The Docker template's `display` (Xvfb + ImageMagick) and
# `term` (termshot) modes are gone -- a Seatbelt sandbox on macOS has no X
# display server and no tmux -- and are rejected with a usage message rather
# than silently doing nothing.
#
# Mechanism: `node -e <script>` requiring the `playwright` package, NOT
# `npx playwright screenshot`. The CLI's `screenshot` subcommand has no way to
# pass browser launch arguments, and `--no-sandbox` is mandatory here:
# chromium's own sandbox cannot nest inside Seatbelt's. `npx --no-install`
# would also re-resolve the package on every run. So the package is resolved
# once, by directory, and driven directly.
#
# Where things live:
#   package  -- $CLAUDE_ORCA_PLAYWRIGHT_HOME/node_modules/playwright
#               (default $HOME/.cache/claude-orca-playwright), else the global
#               npm root ("npm i -g playwright@$PLAYWRIGHT_VERSION").
#   browsers -- PLAYWRIGHT_BROWSERS_PATH=<config home>/.cache/ms-playwright,
#               i.e. <project>/.claude-dev/home/.cache/ms-playwright: inside
#               the sandbox's writable scope, never the real ~/Library.
#   output   -- <project root>/attachments/<name>.png (the drop directory the
#               rulebook tells Claude to read images from).
#
# Network: fetching chromium needs cdn.playwright.dev and
# playwright.download.prss.microsoft.com (playwright-core's
# PLAYWRIGHT_CDN_MIRRORS) on the sandbox allowlist. They are not in
# gen-settings.sh's defaults -- add them per project in
# .claude-dev/sandbox.json under network.extraAllowedDomains, then run
# `npx playwright install chromium` once.
#
# FALLBACK (documented, not hypothetical): headless chromium may refuse to
# start under a nested Seatbelt profile on macOS. If it does, do not spend the
# session fighting it -- either use Orca's own browser (`orca goto <url>` plus
# an artifact screenshot) when S9 orchestration mode is enabled, or ask the
# user for a screenshot and read it from attachments/. A screenshot the user
# drops in is worth the same as one taken here.

set -euo pipefail

PLAYWRIGHT_VERSION="1.61.1"
VIEWPORT_WIDTH=1280
VIEWPORT_HEIGHT=720
NAV_TIMEOUT_MS=60000

# shellcheck source=scripts/lib/paths.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/paths.sh"

usage() {
    cat <<EOF
Usage: take-screenshot url <URL> [--name <name>] [--full-page]

  Captures <URL> with headless chromium (Playwright $PLAYWRIGHT_VERSION) and
  writes <project>/attachments/<name>.png, printing the path.

Options:
  --name <name>   Output basename (default: <url-host>-<UTC timestamp>)
  --full-page     Capture the full scrollable page, not just the viewport

The 'term' and 'display' modes of the Docker template are removed: a Seatbelt
sandbox has no X display server and no termshot. Capture terminal output by
reading it, and ask the user to drop any other screenshot into attachments/.
EOF
}

die_usage() {
    if [ -n "${1:-}" ]; then
        echo "take-screenshot: $1" >&2
    fi
    usage >&2
    exit 2
}

ts() { date -u +"%Y%m%d-%H%M%S"; }

# Host of a URL, sanitised for a filename ("http://localhost:3000/x" ->
# "localhost-3000"). Falls back to "page" for anything unparseable.
url_slug() {
    local u="$1" host
    host="${u#*://}"
    host="${host%%/*}"
    host="${host%%\?*}"
    host="$(printf '%s' "$host" | tr -c 'A-Za-z0-9._-' '-')"
    host="${host#-}"
    host="${host%-}"
    if [ -z "$host" ]; then
        host="page"
    fi
    printf '%s\n' "$host"
}

# Prints the node_modules directory that contains `playwright`, or nothing
# (status 1) if the package is installed nowhere we look.
find_playwright_modules() {
    local home_dir global_root candidate
    home_dir="${CLAUDE_ORCA_PLAYWRIGHT_HOME:-$HOME/.cache/claude-orca-playwright}"

    candidate="$home_dir/node_modules"
    if [ -f "$candidate/playwright/package.json" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    if command -v npm >/dev/null 2>&1; then
        global_root="$(npm root -g 2>/dev/null || true)"
        if [ -n "$global_root" ] && [ -f "$global_root/playwright/package.json" ]; then
            printf '%s\n' "$global_root"
            return 0
        fi
    fi

    return 1
}

# The browser cache, inside the project-local config home: claude_config_dir()
# is <project>/.claude-dev/home/.claude, so its parent is the sandbox home.
browsers_path() {
    local cfg
    cfg="$(claude_config_dir)"
    printf '%s\n' "$(dirname "$cfg")/.cache/ms-playwright"
}

# Driven with: node -e <this> <url> <output> <fullPage 0|1> <launch args...>
NODE_SCRIPT='
const { chromium } = require("playwright");
const argv = process.argv.slice(1);
const url = argv[0], out = argv[1], full = argv[2] === "1";
const args = argv.slice(3);
const width = parseInt(process.env.SHOT_WIDTH || "1280", 10);
const height = parseInt(process.env.SHOT_HEIGHT || "720", 10);
const timeout = parseInt(process.env.SHOT_TIMEOUT_MS || "60000", 10);
(async () => {
  const browser = await chromium.launch({ args });
  try {
    const page = await browser.newPage({ viewport: { width, height } });
    await page.goto(url, { waitUntil: "load", timeout });
    await page.screenshot({ path: out, fullPage: full });
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error("take-screenshot: " + (e && e.message ? e.message : String(e)));
  process.exit(1);
});
'

cmd_url() {
    local url="" name="" full_page=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --name)
                [ $# -ge 2 ] || die_usage "--name requires an argument"
                name="$2"
                shift 2
                ;;
            --full-page)
                full_page=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                die_usage "unknown option: $1"
                ;;
            *)
                [ -z "$url" ] || die_usage "unexpected argument: $1"
                url="$1"
                shift
                ;;
        esac
    done

    [ -n "$url" ] || die_usage "url mode needs a URL"

    local modules
    if ! modules="$(find_playwright_modules)"; then
        echo "take-screenshot: playwright not installed -- run: npm i -g playwright@$PLAYWRIGHT_VERSION && npx playwright install chromium" >&2
        exit 3
    fi

    local root
    if ! root="$(claude_orca_root)"; then
        echo "take-screenshot: not inside a registered claude_orca project (set CLAUDE_ORCA_ROOT)" >&2
        exit 2
    fi

    if [ -z "$name" ]; then
        name="$(url_slug "$url")-$(ts)"
    fi
    name="${name%.png}"

    local out_dir out
    out_dir="$root/attachments"
    mkdir -p "$out_dir"
    out="$out_dir/$name.png"

    NODE_PATH="$modules" \
    PLAYWRIGHT_BROWSERS_PATH="$(browsers_path)" \
    SHOT_WIDTH="$VIEWPORT_WIDTH" \
    SHOT_HEIGHT="$VIEWPORT_HEIGHT" \
    SHOT_TIMEOUT_MS="$NAV_TIMEOUT_MS" \
        node -e "$NODE_SCRIPT" "$url" "$out" "$full_page" "--no-sandbox"

    printf '%s\n' "$out"
}

case "${1:-}" in
    url)
        shift
        cmd_url "$@"
        ;;
    -h|--help)
        usage
        ;;
    term|display)
        die_usage "the '$1' mode was removed with the Docker container (no X display server, no termshot in the sandbox)"
        ;;
    "")
        die_usage ""
        ;;
    *)
        die_usage "unknown command: $1"
        ;;
esac
