#!/usr/bin/env python3
"""
patch-orca-web-theme.py -- make Orca Web open dark, and let its
terminal accept a paste (claude-orca-qa2.18).

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

Idempotent: re-running with the same theme and the shim present is a
no-op; a different theme replaces the theme seed and keeps the shim.
Run as root at image build (setup.sh --phase template) and optionally
again at boot with the folder's CLAUDE_ORCA_THEME.

    patch-orca-web-theme.py [--asar PATH] [--theme dark|light|system]
    patch-orca-web-theme.py --check  [--asar PATH] [--theme T]   # 0 if seeded
                                                                 # T + shim
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
THEMES = ("dark", "light", "system")

SETTINGS_KEY = "orca.web.settings.v1"
MARKER_KEY = "orca.claudeOrca.themeSeeded.v1"

SCRIPT_RE = re.compile(
    r'[ \t]*<script data-claude-orca-theme="[a-z]*">.*?</script>\n?', re.S)
CLIPBOARD_RE = re.compile(
    r'[ \t]*<script data-claude-orca-clipboard="[^"]*">.*?</script>\n?', re.S)
PRELOAD_RE = re.compile(r'[ \t]*<link rel="modulepreload"[^>]*>\n')

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


def seed_script(theme):
    js = (
        'try{var k="%s",m="%s",t="%s";'
        'if(localStorage.getItem(m)!==t){'
        'var s=JSON.parse(localStorage.getItem(k)||"{}");'
        's.theme=t;localStorage.setItem(k,JSON.stringify(s));'
        'localStorage.setItem(m,t)}}catch(e){}'
    ) % (SETTINGS_KEY, MARKER_KEY, theme)
    return '    <script data-claude-orca-theme="%s">%s</script>\n' % (theme, js)


def seeded_theme(html):
    m = re.search(r'<script data-claude-orca-theme="([a-z]*)">', html)
    return m.group(1) if m else None


def clipboard_seeded(html):
    return CLIPBOARD_RE.search(html) is not None


def rewrite_html(html, theme):
    """Return html with both seeds, at exactly len(html) bytes."""
    size = len(html.encode("utf-8"))
    # Strip earlier seeds and their padding so re-theming starts clean.
    html = SCRIPT_RE.sub("", html)
    html = CLIPBOARD_RE.sub("", html)
    html = re.sub(r" +\n  </head>", "\n  </head>", html)

    anchor = html.find("    <script type=\"module\"")
    if anchor < 0:
        raise SystemExit("web-index.html has no module script tag; "
                         "unexpected Orca Web layout")
    html = html[:anchor] + seed_script(theme) + CLIPBOARD_SCRIPT + html[anchor:]

    # Free bytes from the END of the modulepreload hint list, only as many
    # as the two seeds need.
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


def html_entry(header):
    node = header
    for part in HTML_PATH:
        node = node.get("files", {}).get(part)
        if node is None:
            raise SystemExit("app.asar has no %s" % "/".join(HTML_PATH))
    if node.get("unpacked"):
        raise SystemExit("web-index.html is unpacked; patch the file on disk")
    return node


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--asar", default=DEFAULT_ASAR)
    ap.add_argument("--theme", default="dark")
    ap.add_argument("--check", action="store_true",
                    help="exit 0 if the archive already seeds --theme")
    ap.add_argument("--print", action="store_true",
                    help="write the current web-index.html to stdout")
    args = ap.parse_args(argv)

    if args.theme not in THEMES:
        print("[patch-orca-web] unknown theme %r; using dark" % args.theme,
              file=sys.stderr)
        args.theme = "dark"

    # Read-only for the two modes that only read. setup.sh --check says
    # it "installs nothing, needs no root", and opening the archive r+b
    # made that false: every non-root caller got PermissionError on a
    # root-owned app.asar and read it as the theme not being seeded.
    mode = "rb" if (args.check or args.print) else "r+b"
    with open(args.asar, mode) as f:
        header_size, raw, header = read_header(f)
        entry = html_entry(header)
        data_start = 8 + header_size
        offset = data_start + int(entry["offset"])
        size = int(entry["size"])
        f.seek(offset)
        old = f.read(size).decode("utf-8")

        if args.print:
            sys.stdout.write(old)
            return 0

        current = seeded_theme(old)
        clip = clipboard_seeded(old)
        if args.check:
            theme_ok = current == args.theme
            ok = theme_ok and clip
            missing = []
            if not theme_ok:
                missing.append("theme %s (has %s)"
                               % (args.theme, current or "none"))
            if not clip:
                missing.append("the clipboard shim")
            print("[patch-orca-web] %s: web-index.html seeds theme %s, "
                  "clipboard shim %s%s"
                  % ("ok" if ok else "FAIL", current or "(none)",
                     "present" if clip else "MISSING",
                     "" if ok else " -- missing: " + " and ".join(missing)))
            return 0 if ok else 1

        if current == args.theme and clip:
            print("[patch-orca-web] already seeds theme %s + clipboard shim "
                  "(%s)" % (args.theme, args.asar))
            return 0

        new = rewrite_html(old, args.theme)
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

        f.seek(offset)
        f.write(new_b)
        if new_raw != raw:
            f.seek(16)
            f.write(new_raw)
        f.flush()

    print("[patch-orca-web] web-index.html now seeds theme %s + the "
          "clipboard shim (%s)" % (args.theme, args.asar))
    return 0


if __name__ == "__main__":
    sys.exit(main())
