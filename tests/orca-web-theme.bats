#!/usr/bin/env bats
#
# Orca Web opens dark, and its terminal accepts a paste
# (claude-orca-qa2.18).
#
# Orca Web 1.4.197 reads its theme from the browser's localStorage record
# `orca.web.settings.v1` (default "system"), never from the runtime's
# settings.theme, so the seed in orca-data.json cannot darken the served
# page. scripts/container/patch-orca-web-theme.py rewrites the served
# web-index.html INSIDE app.asar, in place and at its original byte size,
# with an inline script that seeds that record once per configured theme.
#
# The same rewrite injects a second inline script for paste: Orca's web
# client preventDefault()s Mod+V and reads the clipboard through the
# permission-gated navigator.clipboard.readText(), which the served origin
# is never granted, so pasting an auth code fails. Hiding readText selects
# Orca's own fallback (isWebClient && !clipboardReadTextAvailable), which
# lets the native paste event xterm listens for through. Copy is unaffected.
#
# The same rewrite adds the <link rel="icon"> the served page has never
# carried, pointed at the icon Orca already ships next to its bundle
# (out/web/assets/icon-<hash>.png). The hash is a build detail, so the
# patcher lists the archive for it instead of naming it, and a build
# without one keeps a default tab mark rather than a broken link.
#
# tests/fixtures/orca-web-index.html is the real 1.4.197 file; the archive
# around it is built here, small, with the same duplicate the real one has
# (out/renderer/web-index.html, same bytes, same hash) and a file after it
# whose bytes must not move.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
PATCHER="$REPO_ROOT/scripts/container/patch-orca-web-theme.py"
FIXTURE="$REPO_ROOT/tests/fixtures/orca-web-index.html"

# make_asar <out> [asset-name...] -- an asar with out/web/web-index.html,
# its renderer twin, and out/web/assets/tail.js after them. Any extra
# argument becomes one more file under out/web/assets/ with bytes of its
# own, which is how a case gives the archive (or denies it) an icon asset.
make_asar() {
    local out="$1"
    shift
    python3 - "$out" "$FIXTURE" "$@" <<'EOF'
import hashlib, json, struct, sys
out, fixture = sys.argv[1], sys.argv[2]
html = open(fixture, "rb").read()
tail = b"console.log('tail');\n" * 40
def entry(data, offset):
    h = hashlib.sha256(data).hexdigest()
    return {"size": len(data), "offset": str(offset),
            "integrity": {"algorithm": "SHA256", "hash": h,
                          "blockSize": 4194304, "blocks": [h]}}
files = [("out/renderer/web-index.html", html),
         ("out/web/web-index.html", html),
         ("out/web/assets/tail.js", tail)]
files += [("out/web/assets/" + name, ("asset:" + name).encode())
          for name in sys.argv[3:]]
header = {"files": {}}
blob = b""
for path, data in files:
    node = header
    parts = path.split("/")
    for p in parts[:-1]:
        node = node.setdefault("files", {}).setdefault(p, {})
    node.setdefault("files", {})[parts[-1]] = entry(data, len(blob))
    blob += data
raw = json.dumps(header, separators=(",", ":")).encode()
pad = (4 - len(raw) % 4) % 4
# Pickle framing as Electron writes it: [4][headerSize][stringSize][jsonLen]json pad
payload = struct.pack("<II", len(raw) + pad, len(raw)) + raw + b"\0" * pad
with open(out, "wb") as f:
    f.write(struct.pack("<II", 4, len(payload)))
    f.write(payload)
    f.write(blob)
EOF
}

# asar_file <asar> <path> -- the bytes of one entry, to stdout.
asar_file() {
    python3 - "$1" "$2" <<'EOF'
import json, struct, sys
f = open(sys.argv[1], "rb")
_, hs, _, js = struct.unpack("<IIII", f.read(16))
h = json.loads(f.read(js))
node = h
for p in sys.argv[2].split("/"):
    node = node["files"][p]
f.seek(8 + hs + int(node["offset"]))
sys.stdout.buffer.write(f.read(node["size"]))
EOF
}

# asar_hash_ok <asar> <path> -- 0 when the header hash matches the bytes.
asar_hash_ok() {
    python3 - "$1" "$2" <<'EOF'
import hashlib, json, struct, sys
f = open(sys.argv[1], "rb")
_, hs, _, js = struct.unpack("<IIII", f.read(16))
h = json.loads(f.read(js))
node = h
for p in sys.argv[2].split("/"):
    node = node["files"][p]
f.seek(8 + hs + int(node["offset"]))
data = f.read(node["size"])
ok = hashlib.sha256(data).hexdigest() == node["integrity"]["hash"] == node["integrity"]["blocks"][0]
sys.exit(0 if ok else 1)
EOF
}

# strip_favicon <asar> -- blank the favicon link out of the served
# web-index.html in place, keeping the file's size, so a case can hand
# --check an archive that seeds the theme and the shim but no favicon.
# --check reads no hashes, so the header is left alone.
strip_favicon() {
    python3 - "$1" <<'EOF'
import json, re, struct, sys
f = open(sys.argv[1], "r+b")
_, hs, _, js = struct.unpack("<IIII", f.read(16))
h = json.loads(f.read(js))
node = h
for p in ("out", "web", "web-index.html"):
    node = node["files"][p]
off, size = 8 + hs + int(node["offset"]), node["size"]
f.seek(off)
html = f.read(size).decode("utf-8")
new = re.sub(r'[ \t]*<link rel="icon"[^>]*>\n',
             lambda m: " " * (len(m.group(0)) - 1) + "\n", html)
assert new != html and len(new.encode()) == size
f.seek(off)
f.write(new.encode())
EOF
}

setup() {
    command -v python3 >/dev/null 2>&1 || skip "python3 is not installed"
    [ -s "$FIXTURE" ] || skip "no fixture at $FIXTURE"
    ASAR="$BATS_TEST_TMPDIR/app.asar"
    make_asar "$ASAR"
    cp "$ASAR" "$BATS_TEST_TMPDIR/pristine.asar"
}

@test "patch-orca-web-theme seeds orca.web.settings.v1 theme=dark into the served web-index.html at its original size, hash kept true, nothing else moved" {
    run python3 "$PATCHER" --asar "$ASAR" --theme dark
    [ "$status" -eq 0 ]
    [[ "$output" == *"now seeds theme dark"* ]]

    # Same archive size, same bytes for everything but the one entry.
    [ "$(wc -c <"$ASAR")" = "$(wc -c <"$BATS_TEST_TMPDIR/pristine.asar")" ]
    asar_file "$ASAR" out/web/web-index.html >"$BATS_TEST_TMPDIR/served.html"
    [ "$(wc -c <"$BATS_TEST_TMPDIR/served.html")" = "$(wc -c <"$FIXTURE")" ]
    asar_file "$ASAR" out/web/assets/tail.js | cmp -s - <(asar_file "$BATS_TEST_TMPDIR/pristine.asar" out/web/assets/tail.js)
    asar_file "$ASAR" out/renderer/web-index.html | cmp -s - "$FIXTURE"

    # The seed: the client's own localStorage key, the theme, the terminal
    # palette, and a marker carrying both so a later choice in Settings sticks.
    grep -q '<script data-claude-orca-theme="dark"' "$BATS_TEST_TMPDIR/served.html"
    grep -q 'data-claude-orca-terminal-theme="Homebrew"' "$BATS_TEST_TMPDIR/served.html"
    grep -q 'k="orca.web.settings.v1"' "$BATS_TEST_TMPDIR/served.html"
    grep -q 'm="orca.claudeOrca.themeSeeded.v1"' "$BATS_TEST_TMPDIR/served.html"
    grep -q 't="dark"' "$BATS_TEST_TMPDIR/served.html"
    grep -q 'u="Homebrew"' "$BATS_TEST_TMPDIR/served.html"
    grep -q 's.theme=t' "$BATS_TEST_TMPDIR/served.html"

    # Green on black in BOTH slots: Orca reads terminalThemeLight only when
    # the page is light and the separate-light-theme toggle is on, and this
    # must not depend on either.
    grep -q 's.terminalThemeDark=u' "$BATS_TEST_TMPDIR/served.html"
    grep -q 's.terminalThemeLight=u' "$BATS_TEST_TMPDIR/served.html"

    # The clipboard shim: readText hidden so Orca takes its native-paste path.
    grep -q '<script data-claude-orca-clipboard="1">' "$BATS_TEST_TMPDIR/served.html"
    grep -q 'navigator.clipboard' "$BATS_TEST_TMPDIR/served.html"
    grep -q 'Object.defineProperty(c,"readText",{value:void 0,configurable:true})' \
        "$BATS_TEST_TMPDIR/served.html"
    [ "$(grep -n 'data-claude-orca-clipboard' "$BATS_TEST_TMPDIR/served.html" | cut -d: -f1)" \
        -lt "$(grep -n 'type="module"' "$BATS_TEST_TMPDIR/served.html" | cut -d: -f1)" ]
    # It runs before the bundle, which is what reads localStorage.
    [ "$(grep -n 'data-claude-orca-theme' "$BATS_TEST_TMPDIR/served.html" | cut -d: -f1)" \
        -lt "$(grep -n 'type="module"' "$BATS_TEST_TMPDIR/served.html" | cut -d: -f1)" ]
    # The bundle and stylesheet still load; only modulepreload hints went.
    grep -q 'type="module" crossorigin src="./assets/web-' "$BATS_TEST_TMPDIR/served.html"
    grep -q 'rel="stylesheet"' "$BATS_TEST_TMPDIR/served.html"
    [ "$(grep -c modulepreload "$BATS_TEST_TMPDIR/served.html")" -lt "$(grep -c modulepreload "$FIXTURE")" ]
    [ "$(grep -c modulepreload "$BATS_TEST_TMPDIR/served.html")" -gt 0 ]

    # The header's integrity record follows the bytes, for both twins.
    asar_hash_ok "$ASAR" out/web/web-index.html
    asar_hash_ok "$ASAR" out/renderer/web-index.html

    run python3 "$PATCHER" --asar "$ASAR" --check --theme dark
    [ "$status" -eq 0 ]
    run python3 "$PATCHER" --asar "$ASAR" --check --theme light
    [ "$status" -eq 1 ]
}

@test "--check fails on an unpatched archive and names what is missing" {
    run python3 "$PATCHER" --asar "$ASAR" --check --theme dark
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL"* ]]
    [[ "$output" == *"theme dark"* ]]
    [[ "$output" == *"clipboard shim"* ]]

    python3 "$PATCHER" --asar "$ASAR" --theme dark >/dev/null
    run python3 "$PATCHER" --asar "$ASAR" --check --theme dark
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok"* ]]
    [[ "$output" == *"clipboard shim present"* ]]

    # --check reads, never writes: it must work without write access, and
    # must not touch a byte.
    cp "$ASAR" "$BATS_TEST_TMPDIR/before-check.asar"
    chmod a-w "$ASAR"
    run python3 "$PATCHER" --asar "$ASAR" --check --theme dark
    [ "$status" -eq 0 ]
    chmod u+w "$ASAR"
    cmp -s "$ASAR" "$BATS_TEST_TMPDIR/before-check.asar"
}

@test "patch-orca-web-theme is a no-op the second time and re-seeds when the theme changes" {
    python3 "$PATCHER" --asar "$ASAR" --theme dark >/dev/null
    cp "$ASAR" "$BATS_TEST_TMPDIR/once.asar"
    run python3 "$PATCHER" --asar "$ASAR" --theme dark
    [ "$status" -eq 0 ]
    [[ "$output" == *"already seeds theme dark"* ]]
    cmp -s "$ASAR" "$BATS_TEST_TMPDIR/once.asar"

    run python3 "$PATCHER" --asar "$ASAR" --theme light
    [ "$status" -eq 0 ]
    [ "$(wc -c <"$ASAR")" = "$(wc -c <"$BATS_TEST_TMPDIR/pristine.asar")" ]
    asar_file "$ASAR" out/web/web-index.html >"$BATS_TEST_TMPDIR/served.html"
    [ "$(wc -c <"$BATS_TEST_TMPDIR/served.html")" = "$(wc -c <"$FIXTURE")" ]
    [ "$(grep -c 'data-claude-orca-theme=' "$BATS_TEST_TMPDIR/served.html")" = "1" ]
    grep -q 't="light"' "$BATS_TEST_TMPDIR/served.html"
    # Re-theming keeps the clipboard shim, and keeps exactly one of it.
    [ "$(grep -c 'data-claude-orca-clipboard=' "$BATS_TEST_TMPDIR/served.html")" = "1" ]
    asar_hash_ok "$ASAR" out/web/web-index.html
    python3 "$PATCHER" --asar "$ASAR" --check --theme light

    # An unknown theme falls back to dark rather than seeding garbage.
    run python3 "$PATCHER" --asar "$ASAR" --theme neon
    [ "$status" -eq 0 ]
    python3 "$PATCHER" --asar "$ASAR" --check --theme dark
}

@test "the shipped .zshrc turns the default foreground and cursor green and repaints nothing else, and leaves the terminal alone for a name only Orca resolves" {
    command -v script >/dev/null 2>&1 || skip "script is not installed"
    command -v zsh >/dev/null 2>&1 || skip "zsh is not installed"

    run script -qec "zsh -c 'source $REPO_ROOT/config/.zshrc'" /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *']10;#00ff00'* ]]
    [[ "$output" == *']12;#00ff00'* ]]

    # The sixteen ANSI slots and the ground stay as the person set them.
    # Repainting those is what made Claude Code's chat input and status bar
    # disappear on 2026-09-08 -- their greys had been remapped onto the
    # background -- so the rc must never emit OSC 4 or OSC 11.
    [[ "$output" != *']4;'* ]]
    [[ "$output" != *']11;'* ]]

    run env CLAUDE_ORCA_TERMINAL_THEME=Snazzy \
        script -qec "zsh -c 'source $REPO_ROOT/config/.zshrc'" /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" != *']10;'* ]]
    [[ "$output" != *']12;'* ]]
}

@test "the fixture is Orca Web 1.4.197's served page, unpatched" {
    [ "$(wc -c <"$FIXTURE")" = "3975" ]
    grep -q '<title>Orca Web</title>' "$FIXTURE"
    ! grep -q 'data-claude-orca-theme' "$FIXTURE"
    ! grep -q 'data-claude-orca-clipboard' "$FIXTURE"
}

@test "setup.sh seeds the theme into /opt/Orca's app.asar in the template phase and checks it" {
    local setup="$REPO_ROOT/scripts/container/setup.sh"
    sed -n '/^phase_template()/,/^}/p' "$setup" | grep -q 'patch_orca_web_theme'
    sed -n '/^patch_orca_web_theme()/,/^}/p' "$setup" | grep -q 'CLAUDE_ORCA_THEME:-dark'
    sed -n '/^patch_orca_web_theme()/,/^}/p' "$setup" | grep -q '/opt/Orca/resources/app.asar'
    sed -n '/^run_checks()/,/^}/p' "$setup" | grep -q -- '--check --asar /opt/Orca/resources/app.asar'
}

@test "the real app.asar takes the seed (copy of /opt/Orca, when present)" {
    [ -f /opt/Orca/resources/app.asar ] || skip "no Orca install at /opt/Orca"
    local real="$BATS_TEST_TMPDIR/real.asar"
    cp /opt/Orca/resources/app.asar "$real"
    run python3 "$PATCHER" --asar "$real" --theme dark
    [ "$status" -eq 0 ]
    [[ "$output" != *"warning"* ]]
    [ "$(wc -c <"$real")" = "$(wc -c </opt/Orca/resources/app.asar)" ]
    asar_hash_ok "$real" out/web/web-index.html
    python3 "$PATCHER" --asar "$real" --print | grep -q 'data-claude-orca-theme="dark"'
    python3 "$PATCHER" --asar "$real" --print | grep -q 'data-claude-orca-clipboard="1"'
    # The real archive ships out/web/assets/icon-<hash>.png, so the tab
    # gets Orca's own mark and the href names a file the serve can answer.
    python3 "$PATCHER" --asar "$real" --print \
        | grep -o 'href="./assets/icon-[^"]*\.png"' >"$BATS_TEST_TMPDIR/href"
    [ -s "$BATS_TEST_TMPDIR/href" ]
    asar_file "$real" "out/web/assets/$(sed 's|.*assets/||;s|"$||' "$BATS_TEST_TMPDIR/href")" \
        | head -c 8 | grep -q PNG
    python3 "$PATCHER" --asar "$real" --check --theme dark

    # A second run changes nothing at all.
    cp "$real" "$BATS_TEST_TMPDIR/real-once.asar"
    run python3 "$PATCHER" --asar "$real" --theme dark
    [ "$status" -eq 0 ]
    [[ "$output" == *"already seeds"* ]]
    cmp -s "$real" "$BATS_TEST_TMPDIR/real-once.asar"
}

# The green phosphor terminal. Orca ships a builtin palette called
# "Homebrew" -- black ground, #00ff00 text and cursor -- so the seed writes
# a NAME Orca already resolves rather than colours of our own that would
# drift from its xterm theme shape. It is the template's default; the flag
# picks any other palette Orca knows.
@test "the terminal palette defaults to Homebrew, re-seeds when it changes, and --check catches a mismatch" {
    python3 "$PATCHER" --asar "$ASAR" --theme dark >/dev/null
    asar_file "$ASAR" out/web/web-index.html >"$BATS_TEST_TMPDIR/served.html"
    grep -q 'u="Homebrew"' "$BATS_TEST_TMPDIR/served.html"
    python3 "$PATCHER" --asar "$ASAR" --check --theme dark

    # The marker carries BOTH values, so a different palette re-seeds even
    # though the page theme did not move.
    grep -q 'v=t+"|"+u' "$BATS_TEST_TMPDIR/served.html"
    run python3 "$PATCHER" --asar "$ASAR" --check --theme dark --terminal-theme Snazzy
    [ "$status" -eq 1 ]
    [[ "$output" == *"terminal theme Snazzy (has Homebrew)"* ]]

    run python3 "$PATCHER" --asar "$ASAR" --theme dark --terminal-theme Snazzy
    [ "$status" -eq 0 ]
    [ "$(wc -c <"$ASAR")" = "$(wc -c <"$BATS_TEST_TMPDIR/pristine.asar")" ]
    asar_file "$ASAR" out/web/web-index.html >"$BATS_TEST_TMPDIR/served.html"
    [ "$(wc -c <"$BATS_TEST_TMPDIR/served.html")" = "$(wc -c <"$FIXTURE")" ]
    [ "$(grep -c 'data-claude-orca-terminal-theme=' "$BATS_TEST_TMPDIR/served.html")" = "1" ]
    [ "$(grep -c 'data-claude-orca-clipboard=' "$BATS_TEST_TMPDIR/served.html")" = "1" ]
    grep -q 'u="Snazzy"' "$BATS_TEST_TMPDIR/served.html"
    asar_hash_ok "$ASAR" out/web/web-index.html

    # A name that would break out of the JS string literal is refused, and
    # the shipped default is used instead of seeding garbage.
    run python3 "$PATCHER" --asar "$ASAR" --theme dark --terminal-theme 'a";alert(1);var z="'
    [ "$status" -eq 0 ]
    python3 "$PATCHER" --asar "$ASAR" --check --theme dark --terminal-theme Homebrew
}

# The browser tab. The served page ships no <link rel="icon">, so a tab
# shows the browser's default mark; Orca's own icon is already in the
# archive as out/web/assets/icon-<hash>.png and is served next to the
# bundle. The name carries a build hash, so the patcher discovers it in
# the asar rather than spelling it out.
@test "patch-orca-web-theme injects a favicon link pointing at the asar's own web icon asset, at the original size, hash kept true" {
    # icons-<hash>.js sits in the same directory in the real archive and
    # must not be mistaken for the icon: the tab wants the png.
    local iconed="$BATS_TEST_TMPDIR/iconed.asar"
    make_asar "$iconed" icons-xUlpmk3_.js icon-DcVXyfru.png
    cp "$iconed" "$BATS_TEST_TMPDIR/iconed-pristine.asar"

    run python3 "$PATCHER" --asar "$iconed" --theme dark
    [ "$status" -eq 0 ]
    [[ "$output" != *"warning"* ]]
    [[ "$output" == *"favicon"* ]]

    # Same archive size, same page size: the rewrite is still in place.
    [ "$(wc -c <"$iconed")" = "$(wc -c <"$BATS_TEST_TMPDIR/iconed-pristine.asar")" ]
    asar_file "$iconed" out/web/web-index.html >"$BATS_TEST_TMPDIR/served.html"
    [ "$(wc -c <"$BATS_TEST_TMPDIR/served.html")" = "$(wc -c <"$FIXTURE")" ]

    grep -q '<link rel="icon" data-claude-orca-favicon="1" href="./assets/icon-DcVXyfru.png">' \
        "$BATS_TEST_TMPDIR/served.html"
    ! grep -q 'icons-xUlpmk3_' "$BATS_TEST_TMPDIR/served.html"
    [ "$(grep -n 'data-claude-orca-favicon' "$BATS_TEST_TMPDIR/served.html" | cut -d: -f1)" \
        -lt "$(grep -n 'type="module"' "$BATS_TEST_TMPDIR/served.html" | cut -d: -f1)" ]

    # Everything the page already did still happens.
    grep -q 'type="module" crossorigin src="./assets/web-' "$BATS_TEST_TMPDIR/served.html"
    grep -q 'rel="stylesheet"' "$BATS_TEST_TMPDIR/served.html"
    grep -q '<script data-claude-orca-theme="dark"' "$BATS_TEST_TMPDIR/served.html"
    grep -q '<script data-claude-orca-clipboard="1">' "$BATS_TEST_TMPDIR/served.html"
    [ "$(grep -c modulepreload "$BATS_TEST_TMPDIR/served.html")" -gt 0 ]

    # The icon asset itself is not touched, and the header stays true for
    # both twins of the page.
    asar_file "$iconed" out/web/assets/icon-DcVXyfru.png \
        | cmp -s - <(asar_file "$BATS_TEST_TMPDIR/iconed-pristine.asar" out/web/assets/icon-DcVXyfru.png)
    asar_hash_ok "$iconed" out/web/web-index.html
    asar_hash_ok "$iconed" out/renderer/web-index.html

    # Discovered, never hard-coded: another build's icon is found under
    # its own hash.
    local other="$BATS_TEST_TMPDIR/other.asar"
    make_asar "$other" icon-ZZ9testQ.png
    run python3 "$PATCHER" --asar "$other" --theme dark
    [ "$status" -eq 0 ]
    asar_file "$other" out/web/web-index.html >"$BATS_TEST_TMPDIR/other.html"
    grep -q 'href="./assets/icon-ZZ9testQ.png"' "$BATS_TEST_TMPDIR/other.html"
    ! grep -q 'icon-DcVXyfru' "$BATS_TEST_TMPDIR/other.html"
    asar_hash_ok "$other" out/web/web-index.html
}

@test "the favicon link is not duplicated on a second run" {
    local iconed="$BATS_TEST_TMPDIR/iconed.asar"
    make_asar "$iconed" icon-DcVXyfru.png
    python3 "$PATCHER" --asar "$iconed" --theme dark >/dev/null
    cp "$iconed" "$BATS_TEST_TMPDIR/once.asar"

    run python3 "$PATCHER" --asar "$iconed" --theme dark
    [ "$status" -eq 0 ]
    [[ "$output" == *"already seeds"* ]]
    cmp -s "$iconed" "$BATS_TEST_TMPDIR/once.asar"
    asar_file "$iconed" out/web/web-index.html >"$BATS_TEST_TMPDIR/served.html"
    [ "$(grep -c 'data-claude-orca-favicon' "$BATS_TEST_TMPDIR/served.html")" = "1" ]

    # Re-theming rewrites the whole head and still leaves exactly one.
    run python3 "$PATCHER" --asar "$iconed" --theme light
    [ "$status" -eq 0 ]
    [ "$(wc -c <"$iconed")" = "$(wc -c <"$BATS_TEST_TMPDIR/once.asar")" ]
    asar_file "$iconed" out/web/web-index.html >"$BATS_TEST_TMPDIR/served.html"
    [ "$(wc -c <"$BATS_TEST_TMPDIR/served.html")" = "$(wc -c <"$FIXTURE")" ]
    [ "$(grep -c 'data-claude-orca-favicon' "$BATS_TEST_TMPDIR/served.html")" = "1" ]
    [ "$(grep -c 'rel="icon"' "$BATS_TEST_TMPDIR/served.html")" = "1" ]
    asar_hash_ok "$iconed" out/web/web-index.html
}

@test "--check reports a missing favicon and passes once it is present" {
    local iconed="$BATS_TEST_TMPDIR/iconed.asar"
    make_asar "$iconed" icon-DcVXyfru.png

    run python3 "$PATCHER" --asar "$iconed" --check --theme dark
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL"* ]]
    [[ "$output" == *"favicon MISSING"* ]]

    python3 "$PATCHER" --asar "$iconed" --theme dark >/dev/null
    run python3 "$PATCHER" --asar "$iconed" --check --theme dark
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok"* ]]
    [[ "$output" == *"favicon ./assets/icon-DcVXyfru.png"* ]]

    # The favicon is its own dimension: with the theme and the shim still
    # seeded and only the link gone, --check must fail rather than read the
    # archive as patched.
    strip_favicon "$iconed"
    run python3 "$PATCHER" --asar "$iconed" --check --theme dark
    [ "$status" -eq 1 ]
    [[ "$output" == *"favicon MISSING"* ]]
    [[ "$output" == *"clipboard shim present"* ]]

    # And a re-run puts it back.
    run python3 "$PATCHER" --asar "$iconed" --theme dark
    [ "$status" -eq 0 ]
    [ "$(wc -c <"$iconed")" = "$(wc -c <"$BATS_TEST_TMPDIR/pristine.asar")" ]
    python3 "$PATCHER" --asar "$iconed" --check --theme dark
    asar_hash_ok "$iconed" out/web/web-index.html
}

@test "no favicon is injected and the patch still succeeds when the asar carries no web icon asset" {
    # $ASAR from setup() carries out/web/assets/tail.js and no icon, which
    # is the shape of an Orca that renamed or dropped the asset.
    run python3 "$PATCHER" --asar "$ASAR" --theme dark
    [ "$status" -eq 0 ]
    [[ "$output" == *"no out/web/assets/icon-"* ]]
    [ "$(wc -c <"$ASAR")" = "$(wc -c <"$BATS_TEST_TMPDIR/pristine.asar")" ]
    asar_file "$ASAR" out/web/web-index.html >"$BATS_TEST_TMPDIR/served.html"
    [ "$(wc -c <"$BATS_TEST_TMPDIR/served.html")" = "$(wc -c <"$FIXTURE")" ]
    ! grep -q 'rel="icon"' "$BATS_TEST_TMPDIR/served.html"

    # The theme and the shim still land, and the header is still true.
    grep -q '<script data-claude-orca-theme="dark"' "$BATS_TEST_TMPDIR/served.html"
    grep -q '<script data-claude-orca-clipboard="1">' "$BATS_TEST_TMPDIR/served.html"
    asar_hash_ok "$ASAR" out/web/web-index.html

    # And --check does not fail a folder whose Orca ships no web icon.
    run python3 "$PATCHER" --asar "$ASAR" --check --theme dark
    [ "$status" -eq 0 ]
    [[ "$output" == *"favicon n/a"* ]]
}
