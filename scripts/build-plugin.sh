#!/usr/bin/env bash
# build-plugin.sh — regenerates /workspace/plugin/, a Claude Code plugin
# tree, from the existing config/ sources. Single source of truth stays
# config/: this script only ever reads from config/ (and the Dockerfile,
# for the hook-script -> /usr/local/bin name mapping) and writes plugin/ —
# never the reverse. Idempotent: rerunning produces byte-identical output
# (no timestamps, no unsorted directory iteration; JSON key order mirrors
# each source file's own order).
#
# Generated tree is TRACKED IN GIT (no plugin/ line in .gitignore) so a
# container image build can consume the plugin directly without needing to
# run this generator first — beads_claude_docker-fo2. Every generated file
# under .claude-plugin/ carries a "$comment" provenance field (JSON has no
# real comment syntax; "$comment" is a widely-recognized convention that
# `claude plugin validate --strict` explicitly tolerates: "Claude Code
# ignores unrecognized fields at load time, so it's safe to keep").
#
# Layout produced:
#   .claude-plugin/plugin.json   manifest: name claude-dev, semver version
#   agents/*.md                  verbatim copies of config/agents/*.md (6)
#   skills/snowpark-deploy/      verbatim copy of config/skills/snowpark-deploy
#   skills/tier/SKILL.md         converted from config/claude-commands/tier.md
#   skills/code-map/SKILL.md     converted from config/claude-commands/code-map.md
#   hooks/hooks.json             config/claude-settings.json's "hooks" block,
#                                 wrapped as {"hooks": ...} (unmodified commands —
#                                 see NOTE below)
#   bin/<name>                   the PATH scripts those hooks invoke via
#                                 `command -v <name>`, plus a small explicit
#                                 STANDALONE_NAMES set of user-facing CLI
#                                 tools (e.g. cs-new) that ship in bin/
#                                 without being hook-invoked; resolved
#                                 through the Dockerfile's COPY mapping
#                                 (the same parser
#                                 scripts/image-drift.py:copy_entries() owns
#                                 as the single source of truth for that
#                                 mapping — reused here by dynamic import,
#                                 mirroring tests/helpers/hook-staging-check.py's
#                                 own reuse of the same function, rather than
#                                 keeping a second regex that could drift).
#
# NOTE — hooks.json commands are a faithful passthrough (same `command -v
# <name> && exec <name> ...` PATH-lookup idiom as the source), NOT rewritten
# to invoke ${CLAUDE_PLUGIN_ROOT}/bin/<name>. This is milestone fo2, which
# only generates and inventories the plugin tree; the bead description is
# explicit that "config-sync retirement is a separate follow-up"
# (beads_claude_docker-54s) — that is the natural place to cut the hooks
# over to running from the plugin's own bin/ instead of relying on the
# Docker-baked PATH. bin/ ships now so 54s has it ready to wire in.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$ROOT/plugin"
CONFIG_DIR="$ROOT/config"

rm -rf "$PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR/.claude-plugin" "$PLUGIN_DIR/agents" "$PLUGIN_DIR/skills" "$PLUGIN_DIR/hooks" "$PLUGIN_DIR/bin"

# ── agents/ — verbatim copies ──────────────────────────────────────────
cp "$CONFIG_DIR"/agents/*.md "$PLUGIN_DIR/agents/"

# ── skills/snowpark-deploy — verbatim copy ─────────────────────────────
mkdir -p "$PLUGIN_DIR/skills/snowpark-deploy"
cp "$CONFIG_DIR/skills/snowpark-deploy/SKILL.md" "$PLUGIN_DIR/skills/snowpark-deploy/SKILL.md"

# ── skills/tier, skills/code-map — converted from claude-commands/*.md ─
# Commands carry model/tools/argument-hint frontmatter and a `!`cmd``
# shell-passthrough body meant for a user-typed `/slash` command. Skills
# have no such frontmatter (confirmed against the installed CLI's own
# `claude plugin init --with skills` scaffold: SKILL.md is name+description
# only) and are invoked autonomously by Claude matching on `description`,
# so the body becomes an instruction for Claude to run the same underlying
# CLI itself via Bash, rather than a `!`-prefixed auto-exec line.
mkdir -p "$PLUGIN_DIR/skills/tier" "$PLUGIN_DIR/skills/code-map"

cat > "$PLUGIN_DIR/skills/tier/SKILL.md" <<'EOF'
---
name: tier
description: >-
  Bind or inspect the model tier used for orchestrator/executor/scout
  delegation: switch the top model, pin worker/recon models explicitly,
  lift the worker cap with overdrive, or print the tiering spend report.
  Use when the user asks to change model or tier ("switch to opus", "use
  fable", "pin worker to sonnet"), asks what tier is currently active, or
  asks how much the tiers have cost ("tier cost", "spend report").
---

# Tier management

Runs `tier-set`, the single entry point for both binding and reporting on
the model tier.

- No args — show the current tier binding.
- `<top>` — bind one top model; worker and recon auto-derive from it.
- `<top> <worker> [<recon>]` — pin a specific combination explicitly.
- `overdrive` — lift the worker cap so the executor runs the top model
  (recon stays cheap); expensive, stays lifted until a 1-arg `tier-set
  <top>` clears it.
- `cost [report flags]` — print the spend report (what the tiers actually
  cost); trailing flags pass straight through, e.g. `cost --since 7d`.

Run `tier-set` via Bash with the arguments the user's request implies, and
print its output verbatim — it is complete and written for the user; add
no analysis or commentary of your own.
EOF

cat > "$PLUGIN_DIR/skills/code-map/SKILL.md" <<'EOF'
---
name: code-map
description: >-
  Query or manage the project's code map (call graph / structure index):
  check status, refresh or build it, explain a symbol, find what a file
  change would affect, find the path between two symbols, run a free-text
  query, print the human-readable report, or upgrade the underlying
  engine. Use when the user asks what calls something, what a change
  would break or affect, how two symbols connect, or to refresh or
  inspect the code map itself.
---

# Code map queries

Runs `code-map`, the project structure index CLI: `status | refresh |
build | explain <sym> | affected <file> | path A B | query "<q>" | report
| html | upgrade [ver] | doctor`.

Run `code-map` via Bash with the arguments the user's request implies, and
print its output verbatim — it is complete and written for the user; add
no analysis or commentary of your own.
EOF

# ── .claude-plugin/plugin.json — manifest ──────────────────────────────
AUTHOR_NAME="$(git -C "$ROOT" config user.name 2>/dev/null || echo "")"
AUTHOR_EMAIL="$(git -C "$ROOT" config user.email 2>/dev/null || echo "")"

PLUGIN_DIR="$PLUGIN_DIR" AUTHOR_NAME="$AUTHOR_NAME" AUTHOR_EMAIL="$AUTHOR_EMAIL" python3 - <<'PYEOF'
import json
import os

plugin_dir = os.environ["PLUGIN_DIR"]
author_name = os.environ.get("AUTHOR_NAME") or ""
author_email = os.environ.get("AUTHOR_EMAIL") or ""

manifest = {
    "$schema": "https://anthropic.com/claude-code/plugin.schema.json",
    "$comment": (
        "GENERATED FILE — do not edit by hand. Source: config/ via "
        "scripts/build-plugin.sh. See that script's header for the full "
        "generation map."
    ),
    "name": "claude-dev",
    "version": "0.1.0",
    "description": (
        "Claude Code Development Container: agents, skills, and hooks for "
        "tiered orchestrator/executor/scout delegation, beads-based task "
        "tracking, and code-map-aware development."
    ),
}
if author_name or author_email:
    manifest["author"] = {"name": author_name, "email": author_email}

path = os.path.join(plugin_dir, ".claude-plugin", "plugin.json")
with open(path, "w") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
PYEOF

# ── hooks/hooks.json — derived from config/claude-settings.json ───────
ROOT="$ROOT" PLUGIN_DIR="$PLUGIN_DIR" python3 - <<'PYEOF'
import json
import os

root = os.environ["ROOT"]
plugin_dir = os.environ["PLUGIN_DIR"]

with open(os.path.join(root, "config", "claude-settings.json")) as fh:
    settings = json.load(fh)

hooks_block = settings.get("hooks", {})

out_path = os.path.join(plugin_dir, "hooks", "hooks.json")
with open(out_path, "w") as fh:
    json.dump({"hooks": hooks_block}, fh, indent=2)
    fh.write("\n")
PYEOF

# ── bin/ — scripts the hooks block invokes via `command -v <name>` ────
# Reuses image-drift.py's copy_entries() (loaded dynamically by path, the
# same technique tests/helpers/hook-staging-check.py uses) as the single
# owner of the Dockerfile COPY -> /usr/local/bin/<name> mapping, so this
# never keeps a second parser that could drift out of sync with it.
ROOT="$ROOT" PLUGIN_DIR="$PLUGIN_DIR" python3 - <<'PYEOF'
import importlib.util
import json
import os
import re
import shutil
import stat
import sys

root = os.environ["ROOT"]
plugin_dir = os.environ["PLUGIN_DIR"]

spec = importlib.util.spec_from_file_location(
    "image_drift", os.path.join(root, "scripts", "image-drift.py")
)
image_drift = importlib.util.module_from_spec(spec)
spec.loader.exec_module(image_drift)

with open(os.path.join(root, "Dockerfile")) as fh:
    dockerfile_text = fh.read()

dest_to_src = {dest: src for src, dest in image_drift.copy_entries(dockerfile_text)}

with open(os.path.join(root, "config", "claude-settings.json")) as fh:
    settings = json.load(fh)

hooks_block = settings.get("hooks", {})

names = set()
cmd_pattern = re.compile(r"command -v (\S+)")


def walk(obj):
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key == "command" and isinstance(value, str):
                for m in cmd_pattern.finditer(value):
                    names.add(m.group(1))
            else:
                walk(value)
    elif isinstance(obj, list):
        for item in obj:
            walk(item)


walk(hooks_block)

# Standalone user-facing CLI tools that ship in the plugin's bin/ even
# though nothing in claude-settings.json's hooks block invokes them via
# `command -v` -- they're run directly by a person (e.g. via a shell
# alias), not by a hook. Keep this list small and explicit rather than
# inferring it from anywhere else that could drift.
STANDALONE_NAMES = {"cs-new", "fleet-menu", "fleet"}
names |= STANDALONE_NAMES

bin_dir = os.path.join(plugin_dir, "bin")
os.makedirs(bin_dir, exist_ok=True)

shipped = []
missing = []
for name in sorted(names):
    src = dest_to_src.get(name)
    if not src:
        missing.append(name)
        continue
    src_path = os.path.join(root, src)
    dst_path = os.path.join(bin_dir, name)
    shutil.copy2(src_path, dst_path)
    st = os.stat(dst_path)
    os.chmod(dst_path, st.st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    shipped.append(name)

if missing:
    print(
        "build-plugin: WARNING hook-invoked names with no Dockerfile COPY "
        f"mapping (skipped): {', '.join(missing)}",
        file=sys.stderr,
    )

print(f"build-plugin: bin/ carries {len(shipped)} scripts (hook-invoked + standalone): {', '.join(shipped)}")
PYEOF

echo "build-plugin: regenerated $PLUGIN_DIR"
