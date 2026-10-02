#!/usr/bin/env bash
#
# take-screenshot -- Claude's eyes on a web UI (S10, claude-orca-3sk.21).
#
# ONE mode: `url`. The `display` and `term` modes of the old Docker template
# are gone -- nothing here drives an X display or a terminal multiplexer --
# and are rejected with a usage message rather than silently doing nothing.
#
# Mechanism: `node -e <script>` requiring the `playwright` package, NOT
# `npx playwright screenshot`. The CLI's `screenshot` subcommand has no way to
# pass browser launch arguments, and `--no-sandbox` is mandatory here:
# chromium's own sandbox cannot nest inside the container's. `npx --no-install`
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
# PLAYWRIGHT_CDN_MIRRORS) reachable. Inside the container VM they are --
# and the fetch is automatic now (claude-orca-p91): the package and the
# browser are installed on demand, the first time a screenshot actually
# needs them, into the paths below. CLAUDE_ORCA_NO_INSTALL=1 puts the old
# behaviour back (exit 3 with the manual-install hint, fetch nothing).
#
# FALLBACK (documented, not hypothetical): headless chromium may refuse to
# start in a constrained environment. If it does, do not spend the
# session fighting it -- either use Orca's own browser (`orca goto <url>` plus
# an artifact screenshot) when S9 orchestration mode is enabled, or ask the
# user for a screenshot and read it from attachments/. A screenshot the user
# drops in is worth the same as one taken here.

set -euo pipefail

PLAYWRIGHT_VERSION="1.61.1"
VIEWPORT_WIDTH=1280
VIEWPORT_HEIGHT=720
NAV_TIMEOUT_MS=60000
# How long to let the page paint after `load` fires (claude-orca-qa2.17).
DEFAULT_WAIT_MS=5000
# How long to poll for a non-empty <body> before giving up and shooting
# whatever is there -- a blank page is still worth capturing, it just must
# not be the default outcome.
BODY_TIMEOUT_MS=15000

# The _resolve_script_path loop scripts/recon.sh uses, verbatim: resolving the
# FILE symlink (bin/take-screenshot -> ../scripts/take-screenshot.sh) before
# looking for lib/paths.sh -- pwd -P resolves the directory only, so a symlink
# resolved the old way made PATH invocations look in bin/lib (claude-orca-3wd).
_resolve_script_path() {
    local src="${BASH_SOURCE[0]}"
    while [ -L "$src" ]; do
        local link dir
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *)  dir="$(case "$src" in (*/*) cd "${src%/*}/" ;; esac && pwd)"; src="$dir/$link" ;;
        esac
    done
    echo "$src"
}
SCRIPT_DIR="$(_s="$(_resolve_script_path)"; case "$_s" in (*/*) cd "${_s%/*}/" ;; esac && pwd)"
# shellcheck source=scripts/lib/paths.sh
. "$SCRIPT_DIR/lib/paths.sh"

usage() {
    cat <<EOF
Usage: take-screenshot url <URL> [--name <name>] [--full-page]
                           [--wait-ms <ms>] [--wait-for <selector>]

  Captures <URL> with headless chromium (Playwright $PLAYWRIGHT_VERSION) and
  writes <project>/attachments/<name>.png, printing the path.

Options:
  --name <name>       Output basename (default: <url-host>-<UTC timestamp>)
  --full-page         Capture the full scrollable page, not just the viewport
  --wait-ms <ms>      Settle time after load before the shot
                      (default $DEFAULT_WAIT_MS; 0 disables it)
  --wait-for <sel>    Also wait for this CSS selector to be visible

  The playwright package and the chromium browser are installed on demand,
  the first time a screenshot needs them (~850 MB, one-time). Set
  CLAUDE_ORCA_NO_INSTALL=1 to skip the fetch (exit 3, manual-install hint).

  A single-page app (Orca Web among them) answers 'load' with an empty body
  and paints afterwards, which is how a screenshot comes back blank. The
  wait is therefore on by default: the page is polled for a non-empty body
  first, then --wait-ms is spent settling.

The 'term' and 'display' modes of the old Docker template are removed: there
is no X display server and no termshot here. Capture terminal output by
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

# The one-line hint the exit-3 paths print: what is missing and what a
# manual install would run.
install_hint() {
    echo "take-screenshot: playwright not installed -- run: npm i -g playwright@$PLAYWRIGHT_VERSION && npx playwright install chromium" >&2
}

# Install on demand (claude-orca-p91): the package into the playwright home,
# the chromium browser into the project-local browser cache. Nothing here is
# carried by the image or the template -- a browser is fetched only when some
# work actually looks at a page. Returns non-zero when the install is off
# (CLAUDE_ORCA_NO_INSTALL=1), the tooling is missing, or any fetch fails.
install_on_demand() {
    if [ "${CLAUDE_ORCA_NO_INSTALL:-0}" = "1" ]; then
        return 1
    fi
    if ! command -v npm >/dev/null 2>&1 || ! command -v npx >/dev/null 2>&1; then
        return 1
    fi

    local home
    home="${CLAUDE_ORCA_PLAYWRIGHT_HOME:-$HOME/.cache/claude-orca-playwright}"
    mkdir -p "$home"

    ( cd "$home" && npm install "playwright@$PLAYWRIGHT_VERSION" ) || return 1

    # A "successful" npm that left nothing resolvable behind is a failed
    # install: check before moving on to the browser download.
    find_playwright_modules >/dev/null || return 1

    echo "take-screenshot: fetching playwright@$PLAYWRIGHT_VERSION + chromium on demand (~850 MB, first use only) -- this screenshot needs a real browser" >&2
    ( cd "$home" && \
      PLAYWRIGHT_BROWSERS_PATH="$(browsers_path)" npx playwright install chromium ) || return 1
    return 0
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
const waitMs = parseInt(process.env.SHOT_WAIT_MS || "0", 10);
const bodyTimeout = parseInt(process.env.SHOT_BODY_TIMEOUT_MS || "15000", 10);
const waitFor = process.env.SHOT_WAIT_FOR || "";
(async () => {
  const browser = await chromium.launch({ args });
  try {
    const page = await browser.newPage({ viewport: { width, height } });
    await page.goto(url, { waitUntil: "load", timeout });
    // A single-page app answers `load` with an empty shell. Wait for it to
    // put something in the body, then let it settle -- neither wait is
    // fatal, because a blank shot beats no shot at all.
    if (bodyTimeout > 0) {
      try {
        await page.waitForFunction(
          () => !!document.body && document.body.innerText.trim().length > 0,
          undefined,
          { timeout: bodyTimeout },
        );
      } catch (e) {
        console.error("take-screenshot: body still empty after " +
          bodyTimeout + "ms; capturing anyway");
      }
    }
    if (waitFor) {
      try {
        await page.waitForSelector(waitFor, { state: "visible", timeout });
      } catch (e) {
        console.error("take-screenshot: selector " + waitFor +
          " never appeared; capturing anyway");
      }
    }
    if (waitMs > 0) {
      await page.waitForTimeout(waitMs);
    }
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
    local wait_ms="$DEFAULT_WAIT_MS" wait_for=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --name)
                [ $# -ge 2 ] || die_usage "--name requires an argument"
                name="$2"
                shift 2
                ;;
            --wait-ms)
                [ $# -ge 2 ] || die_usage "--wait-ms requires an argument"
                case "$2" in
                    ''|*[!0-9]*) die_usage "--wait-ms takes milliseconds" ;;
                esac
                wait_ms="$2"
                shift 2
                ;;
            --wait-for)
                [ $# -ge 2 ] || die_usage "--wait-for requires a selector"
                wait_for="$2"
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

    local root
    if ! root="$(claude_orca_root)"; then
        echo "take-screenshot: not inside a registered claude_orca project (set CLAUDE_ORCA_ROOT)" >&2
        exit 2
    fi

    local modules
    if ! modules="$(find_playwright_modules)"; then
        install_on_demand || { install_hint; exit 3; }
        modules="$(find_playwright_modules)" || { install_hint; exit 3; }
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
    SHOT_WAIT_MS="$wait_ms" \
    SHOT_WAIT_FOR="$wait_for" \
    SHOT_BODY_TIMEOUT_MS="$BODY_TIMEOUT_MS" \
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
        die_usage "the '$1' mode was removed with the old container template (no X display server, no termshot in the sandbox)"
        ;;
    "")
        die_usage ""
        ;;
    *)
        die_usage "unknown command: $1"
        ;;
esac
