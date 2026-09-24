#!/usr/bin/env python3
"""
patch-orca-web-theme.py -- make Orca Web open dark with a green
phosphor terminal, and let that terminal accept a paste
(claude-orca-qa2.18).

Why this exists: Orca Web 1.4.197 keeps its theme in the BROWSER, in the
localStorage record `orca.web.settings.v1`, and its default there is
"system" (prefers-color-scheme). The web client's `settings.get` merge
copies only a handful of runtime fields (worktreeVisibilityDefaults,
compactWorktreeCards, prBotAuthorOverrides, ...) -- never `theme` -- so
the `settings.theme` that seed-orca-state.sh writes into orca-data.json
steers the Electron desktop client only and the served page still renders
light in a browser with no dark preference (attachments/theme-1-asis.png).

The serve's static root is `<app.asar>/out/web` and there is no flag or
env to point it elsewhere, so the one place a default can be set before
the bundle reads localStorage is web-index.html itself. This script
rewrites that file INSIDE app.asar, in place and at exactly its original
byte size, so no header offset moves and no repack tool is needed:

  * a tiny inline <script> is inserted ahead of the module script; on
    load it writes `theme` into `orca.web.settings.v1` ONCE per configured
    value, remembered in `orca.claudeOrca.themeSeeded.v1` -- so a person
    who later picks another theme in Settings keeps it;
  * the bytes come from the tail of the `<link rel="modulepreload">`
    hint list (hints only: the module graph still loads every chunk via
    its imports) plus space padding before </head>;
  * the asar header's SHA256 for the file is rewritten to the new
    content's hash (same length, so the header does not move either).

The same rewrite injects a second inline <script>, for paste. Orca's web
client owns the terminal's paste keybinding (Mod+V / Ctrl+V): its keydown
handler calls preventDefault() and reads the clipboard through
`navigator.clipboard.readText()`, which needs Chrome's `clipboard-read`
permission. On the served origin that permission sits in state "prompt"
and the read rejects with NotAllowedError, which Orca reports as "Paste
failed."; Firefox and Safari never grant it to web content at all. So no
auth code can be pasted into the terminal -- which is how Claude Code
signs in.

Orca already ships the fallback, gated on `isWebClient &&
!clipboardReadTextAvailable`, where `clipboardReadTextAvailable` is
`typeof navigator.clipboard?.readText == "function"`. When that holds it
does NOT preventDefault, so the browser's native `paste` event -- which
needs no permission, and which xterm.js already listens for on its helper
textarea -- delivers the text. The seed makes the predicate true on the
served page by hiding `readText` on the clipboard object. Copy is
unaffected: it goes through `writeText`, which is auto-granted, with an
execCommand("copy") fallback behind it.

The same rewrite also gives the tab a favicon. The served page ships no
<link rel="icon"> at all, so every Orca Web tab wears the browser's
default mark -- while Orca's own icon is already in the archive next to
the bundle, as out/web/assets/icon-<hash>.png, served at
./assets/icon-<hash>.png relative to the page. The hash is a build
detail, so the name is DISCOVERED by listing the archive rather than
spelled out here; an Orca that renames or drops the asset gets a warning
and its default tab mark, never a broken link.

Idempotent: re-running with the same theme, the shim and the favicon
present is a no-op; a different theme replaces the theme seed and keeps
the shim and the favicon.
Run as root at image build (setup.sh --phase template) and optionally
again at boot with the folder's CLAUDE_ORCA_THEME.

The same seed also sets the TERMINAL palette, by name, into the same
localStorage record -- `terminalThemeDark` and `terminalThemeLight`. The
default is Orca's own builtin "Homebrew": black ground, #00ff00 text and
cursor, i.e. the old green-monitor look. Orca resolves the name itself,
so nothing here hard-codes a colour or has to track its xterm theme
shape; `--terminal-theme` picks any other palette Orca knows.

    patch-orca-web-theme.py [--asar PATH] [--theme dark|light|system]
                            [--terminal-theme NAME]
    patch-orca-web-theme.py --check  [--asar PATH] [--theme T]   # 0 if seeded
                                                                 # T + palette
                                                                 # + shim
                                                                 # + favicon
    patch-orca-web-theme.py --print  [--asar PATH]               # dump the html
"""

import argparse
import hashlib
import json
import re
import struct
import sys

DEFAULT_ASAR = "/opt/Orca/resources/app.asar"
HTML_PATH = ("out", "web", "web-index.html")
ASSETS_PATH = ("out", "web", "assets")
THEMES = ("dark", "light", "system")

# Orca's web icon is one asset in out/web/assets, under a build hash
# (icon-DcVXyfru.png in 1.4.197). The prefix AND the .png tail both
# matter: icons-<hash>.js -- the lucide icon chunk -- sits in the same
# directory and is not a picture of anything.
ICON_RE = re.compile(r"^icon-[^/]*\.png$")

# Orca ships a terminal palette called "Homebrew" -- black ground,
# #00ff00 text and cursor -- which is the old phosphor-monitor look this
# template wants by default. It is one of Orca's own builtin themes
# (out/shared/terminal-custom-themes.js), so this seeds a NAME Orca
# already resolves rather than shipping colours of our own that would
# drift from its xterm theme shape.
DEFAULT_TERMINAL_THEME = "Homebrew"
# The name goes into an HTML attribute and a JS string literal, so keep
# it to characters that need no escaping in either.
TERMINAL_THEME_RE = re.compile(r"^[A-Za-z0-9 ._-]{1,64}$")

SETTINGS_KEY = "orca.web.settings.v1"
MARKER_KEY = "orca.claudeOrca.themeSeeded.v1"

SCRIPT_RE = re.compile(
    r'[ \t]*<script data-claude-orca-theme="[a-z]*"[^>]*>.*?</script>\n?',
    re.S)
CLIPBOARD_RE = re.compile(
    r'[ \t]*<script data-claude-orca-clipboard="[^"]*">.*?</script>\n?', re.S)
PRELOAD_RE = re.compile(r'[ \t]*<link rel="modulepreload"[^>]*>\n')
FAVICON_RE = re.compile(
    r'[ \t]*<link rel="icon" data-claude-orca-favicon="[^"]*"[^>]*>\n?')

# Hiding readText also empties the custom context-menu "Paste" item, which
# calls the same readClipboardText: it returns "" instead of throwing. That
# item is equally broken today -- the permission is denied, so it pastes
# nothing either way -- so this is not a regression, and the keyboard
# binding is the supported route.
CLIPBOARD_SCRIPT = (
    '    <script data-claude-orca-clipboard="1">'
    'try{var c=navigator.clipboard;'
    'if(c&&typeof c.readText==="function"){'
    'Object.defineProperty(c,"readText",{value:void 0,configurable:true})}}'
    'catch(e){}</script>\n'
)


def seed_script(theme, terminal_theme):
    """The one-time seed: page theme plus the terminal palette.

    Both terminal slots are set. Orca picks terminalThemeLight only when the
    page is light AND terminalUseSeparateLightTheme is on, so writing one
    value to both is what makes the terminal green either way -- without
    touching the separate-light-theme toggle the person may have set.

    The marker carries BOTH values, so changing either one re-seeds once
    while a person who picked their own theme in Settings still keeps it.
    """
    js = (
        'try{var k="%s",m="%s",t="%s",u="%s",v=t+"|"+u;'
        'if(localStorage.getItem(m)!==v){'
        'var s=JSON.parse(localStorage.getItem(k)||"{}");'
        's.theme=t;s.terminalThemeDark=u;s.terminalThemeLight=u;'
        'localStorage.setItem(k,JSON.stringify(s));'
        'localStorage.setItem(m,v)}}catch(e){}'
    ) % (SETTINGS_KEY, MARKER_KEY, theme, terminal_theme)
    return ('    <script data-claude-orca-theme="%s" '
            'data-claude-orca-terminal-theme="%s">%s</script>\n'
            % (theme, terminal_theme, js))


def favicon_link(asset):
    """The tab's icon, served from the archive's own assets directory."""
    return ('    <link rel="icon" data-claude-orca-favicon="1" '
            'href="./assets/%s">\n' % asset)


def seeded_favicon(html):
    m = re.search(r'<link rel="icon" data-claude-orca-favicon="[^"]*" '
                  r'href="([^"]*)"', html)
    return m.group(1) if m else None


def seeded_theme(html):
    m = re.search(r'<script data-claude-orca-theme="([a-z]*)"', html)
    return m.group(1) if m else None


def seeded_terminal_theme(html):
    m = re.search(r'data-claude-orca-terminal-theme="([^"]*)"', html)
    return m.group(1) if m else None


def clipboard_seeded(html):
    return CLIPBOARD_RE.search(html) is not None


def rewrite_html(html, theme, terminal_theme, icon_asset):
    """Return html with both seeds and the favicon, at exactly len(html) bytes.

    icon_asset is the name of the archive's own web icon, or None -- in
    which case no <link rel="icon"> is written and any earlier one is
    dropped, because the file it pointed at is no longer there.
    """
    size = len(html.encode("utf-8"))
    # Strip earlier seeds and their padding so re-theming starts clean.
    html = SCRIPT_RE.sub("", html)
    html = CLIPBOARD_RE.sub("", html)
    html = FAVICON_RE.sub("", html)
    html = re.sub(r" +\n  </head>", "\n  </head>", html)

    anchor = html.find("    <script type=\"module\"")
    if anchor < 0:
        raise SystemExit("web-index.html has no module script tag; "
                         "unexpected Orca Web layout")
    head = favicon_link(icon_asset) if icon_asset else ""
    html = (html[:anchor] + head + seed_script(theme, terminal_theme)
            + CLIPBOARD_SCRIPT + html[anchor:])

    # Free bytes from the END of the modulepreload hint list, only as many
    # as the injections need.
    while len(html.encode("utf-8")) > size:
        hints = list(PRELOAD_RE.finditer(html))
        if not hints:
            raise SystemExit("web-index.html has no room for the seeds")
        last = hints[-1]
        html = html[:last.start()] + html[last.end():]

    pad = size - len(html.encode("utf-8"))
    head_end = html.rfind("\n  </head>")
    if head_end < 0:
        raise SystemExit("web-index.html has no </head>")
    html = html[:head_end] + (" " * pad) + html[head_end:]
    assert len(html.encode("utf-8")) == size
    return html


def read_header(f):
    f.seek(0)
    magic, header_size, _payload, json_len = struct.unpack("<IIII", f.read(16))
    if magic != 4:
        raise SystemExit("not an asar archive (bad pickle magic)")
    raw = f.read(json_len)
    return header_size, raw, json.loads(raw)


def find_node(header, parts):
    """The header node at parts, or None when the archive has no such path."""
    node = header
    for part in parts:
        node = (node.get("files") or {}).get(part)
        if node is None:
            return None
    return node


def web_icon_asset(header):
    """The name of Orca's own web icon in this archive, or None.

    Discovered, never hard-coded: the asset carries a build hash that
    changes with every Orca release. Sorted, so an archive that somehow
    ships two of them seeds the same one on every run.
    """
    node = find_node(header, ASSETS_PATH) or {}
    names = [n for n in (node.get("files") or {}) if ICON_RE.match(n)]
    return sorted(names)[0] if names else None


def html_entry(header):
    node = find_node(header, HTML_PATH)
    if node is None:
        raise SystemExit("app.asar has no %s" % "/".join(HTML_PATH))
    if node.get("unpacked"):
        raise SystemExit("web-index.html is unpacked; patch the file on disk")
    return node


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--asar", default=DEFAULT_ASAR)
    ap.add_argument("--theme", default="dark")
    ap.add_argument("--terminal-theme", default=DEFAULT_TERMINAL_THEME,
                    help="name of an Orca terminal palette "
                         "(default %s -- green on black)"
                         % DEFAULT_TERMINAL_THEME)
    ap.add_argument("--check", action="store_true",
                    help="exit 0 if the archive already seeds --theme")
    ap.add_argument("--print", action="store_true",
                    help="write the current web-index.html to stdout")
    args = ap.parse_args(argv)

    if args.theme not in THEMES:
        print("[patch-orca-web] unknown theme %r; using dark" % args.theme,
              file=sys.stderr)
        args.theme = "dark"

    # An unresolvable name is Orca's problem, not ours -- it falls back to its
    # own default palette. A name carrying a quote would break the seed
    # script itself, so that one is refused here.
    if not TERMINAL_THEME_RE.match(args.terminal_theme or ""):
        print("[patch-orca-web] unusable terminal theme %r; using %s"
              % (args.terminal_theme, DEFAULT_TERMINAL_THEME), file=sys.stderr)
        args.terminal_theme = DEFAULT_TERMINAL_THEME

    # Read-only until a write is actually needed. setup.sh --check says it
    # "installs nothing, needs no root", and opening the archive r+b made
    # that false (every non-root caller got PermissionError on a root-owned
    # app.asar). And on an overlay filesystem -- a Docker layer, a
    # container's writable layer -- merely opening for write copies the
    # whole ~113 MB archive up, even when nothing changes.
    with open(args.asar, "rb") as f:
        header_size, raw, header = read_header(f)
        entry = html_entry(header)
        icon = web_icon_asset(header)
        want_fav = ("./assets/%s" % icon) if icon else None
        data_start = 8 + header_size
        offset = data_start + int(entry["offset"])
        size = int(entry["size"])
        f.seek(offset)
        old = f.read(size).decode("utf-8")

        if args.print:
            sys.stdout.write(old)
            return 0

        current = seeded_theme(old)
        current_term = seeded_terminal_theme(old)
        clip = clipboard_seeded(old)
        fav = seeded_favicon(old)
        # An archive with no icon asset is in its right state with no
        # favicon at all: nothing to point a link at, so --check passes
        # and a stale link from an older Orca is what fails.
        fav_ok = fav == want_fav
        fav_state = fav or ("n/a (no icon asset)" if icon is None
                            else "MISSING")
        if args.check:
            theme_ok = current == args.theme
            term_ok = current_term == args.terminal_theme
            ok = theme_ok and term_ok and clip and fav_ok
            missing = []
            if not theme_ok:
                missing.append("theme %s (has %s)"
                               % (args.theme, current or "none"))
            if not term_ok:
                missing.append("terminal theme %s (has %s)"
                               % (args.terminal_theme, current_term or "none"))
            if not clip:
                missing.append("the clipboard shim")
            if not fav_ok:
                missing.append("the stale favicon %s removed" % fav
                               if want_fav is None
                               else "favicon %s (has %s)"
                                    % (want_fav, fav or "none"))
            print("[patch-orca-web] %s: web-index.html seeds theme %s, "
                  "terminal theme %s, clipboard shim %s, favicon %s%s"
                  % ("ok" if ok else "FAIL", current or "(none)",
                     current_term or "(none)",
                     "present" if clip else "MISSING", fav_state,
                     "" if ok else " -- missing: " + " and ".join(missing)))
            return 0 if ok else 1

        # The tab's icon is Orca's own, so a build that renames or drops it
        # leaves the browser's default mark rather than a broken link.
        if icon is None:
            print("[patch-orca-web] warning: no out/web/assets/icon-*.png in "
                  "%s; the tab keeps the browser's default mark" % args.asar,
                  file=sys.stderr)
        fav_note = "favicon %s" % icon if icon else "no favicon"

        if current == args.theme and current_term == args.terminal_theme \
                and clip and fav_ok:
            print("[patch-orca-web] already seeds theme %s + terminal theme "
                  "%s + clipboard shim + %s (%s)"
                  % (args.theme, args.terminal_theme, fav_note, args.asar))
            return 0

        new = rewrite_html(old, args.theme, args.terminal_theme, icon)
        new_b = new.encode("utf-8")
        assert len(new_b) == size

        # Keep the header's integrity record true to the new bytes. Both
        # fields (hash + the single block) carry the same hex for a file
        # smaller than one block; the strings are the same length, so the
        # header stays put. The same html also ships as
        # out/renderer/web-index.html with the same hash, so the edit is
        # confined to this entry's own JSON span, found by its offset.
        integ = entry.get("integrity") or {}
        old_hash = integ.get("hash")
        new_raw = raw
        if old_hash:
            new_hash = hashlib.sha256(new_b).hexdigest()
            key = ('"offset":"%s"' % entry["offset"]).encode()
            start = raw.find(key)
            span = raw[start:start + 400] if start >= 0 else b""
            if (len(new_hash) == len(old_hash)
                    and raw.count(key) == 1
                    and span.count(old_hash.encode()) == 2):
                span = span.replace(old_hash.encode(), new_hash.encode())
                new_raw = raw[:start] + span + raw[start + 400:]
            else:
                print("[patch-orca-web] warning: leaving the header hash "
                      "for web-index.html untouched", file=sys.stderr)

        with open(args.asar, "r+b") as w:
            w.seek(offset)
            w.write(new_b)
            if new_raw != raw:
                w.seek(16)
                w.write(new_raw)
            w.flush()

    print("[patch-orca-web] web-index.html now seeds theme %s + terminal "
          "theme %s + the clipboard shim + %s (%s)"
          % (args.theme, args.terminal_theme, fav_note, args.asar))
    return 0


if __name__ == "__main__":
    sys.exit(main())
