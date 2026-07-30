#!/usr/bin/env python3
"""
Mechanically checks three invariants tying config/claude-settings.json hooks
to the Dockerfile staging that installs the scripts they invoke. All three
are derived from the actual files, not a hardcoded list, so a new offending
hook or a stripped staging step is caught automatically.

  A. GUARD  — a hook `command` whose first invoked executable is not a
     shell builtin/keyword or a system tool the base image guarantees
     (SAFE_FIRST_TOKENS below) must fail open when that executable is
     absent — i.e. it must use the `command -v` guard idiom used
     throughout this file. A command with no such guard whose first
     executable isn't in SAFE_FIRST_TOKENS is treated as a project-script
     invocation and flagged, WHETHER OR NOT that script happens to already
     be staged — an unstaged bare name (e.g. a brand new hook that is
     just `"ghost-script"`, never COPY'd) is exactly the failure shape
     this must catch, not just the case where it happens to be staged
     already (this is the bfa2d70 delegation-gate defect: a bare
     unguarded reference to a project script).

  B. STAGED — every script name a hook references via `command -v <name>`
     (the guard idiom itself) must have a matching
     `COPY ... /usr/local/bin/<name>` line in the Dockerfile (this is the
     "script added to the hook config but never COPY'd" defect).

  C. CHMOD — every script COPY'd to /usr/local/bin/<name> must end up
     executable in the image. COPY preserves the source file's mode, so
     this only matters when the repo file isn't already mode 755 (per
     git, not the working tree — a local `chmod` never lands in the
     image); in that case the Dockerfile's `chmod +x` block MUST list it.
     Silently dropping a script's chmod line while its COPY line survives
     is a defect of the same shape as A/B but on the filesystem-mode axis
     instead of the hook-config axis.

Usage: hook-staging-check.py <dockerfile> <settings.json>
Prints one violation per line and exits 1 if any are found, else exits 0
silently.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys


# Executables a hook may bare-invoke as its first token without the
# `command -v <name> && ...` guard idiom. Kept small and explicit: anything
# NOT in this set is assumed to be an optional project script and must be
# both guarded and staged. Each entry is a shell builtin/keyword or a system
# tool the base image installs unconditionally — never one of this repo's
# scripts/*.sh|py hook scripts, which are always optional and always COPY'd.
SAFE_FIRST_TOKENS = {
    # shell builtins/keywords used by the guard idiom itself and by the
    # multi-clause hooks in claude-settings.json
    "command", "exec", "exit", "test", "[", "true", "false",
    # coreutils/POSIX utilities apt-get installs (or the base image ships)
    # unconditionally — never optional
    "sh", "bash", "mkdir", "cp", "mv", "rm", "cat", "echo", "grep", "sed",
    "awk", "printf", "date",
    # apt-get/pip packages installed unconditionally earlier in the
    # Dockerfile (jq, python3) — always present, not optional hook scripts
    "jq", "python3",
    # beads CLI: installed via a pinned `install -m 0755 .../bd` RUN block
    # (not a COPY from scripts/), a hard dependency of every session, not
    # an optional hook script that can be absent — SessionStart/PreCompact
    # invoke it unguarded by design, not by oversight
    "bd",
}


_copy_entries_fn = None


def _load_copy_entries():
    """Import copy_entries() from scripts/image-drift.py — the single owner
    of this parser (beads_claude_docker-0v3 blocker 1). image-drift.py is a
    production script staged into the image; this test helper is the one
    allowed to depend on the repo tree (it always runs from a git checkout,
    never from a stripped/staged image), so the import direction points
    test -> production, never the reverse.

    Loaded dynamically (by path, not package import) so this stays a
    zero-dependency script.
    """
    global _copy_entries_fn
    if _copy_entries_fn is None:
        root = repo_root()
        target = os.path.join(root, "scripts", "image-drift.py")
        spec = importlib.util.spec_from_file_location("image_drift", target)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _copy_entries_fn = module.copy_entries
    return _copy_entries_fn


def copy_entries(dockerfile_text):
    """(source_path, dest_name) for every `COPY [flags] <src> /usr/local/bin/<dest>` line."""
    return _load_copy_entries()(dockerfile_text)


def copy_dest_names(dockerfile_text):
    """Destination basenames of every `COPY ... /usr/local/bin/<name>` line."""
    return {dest for _src, dest in copy_entries(dockerfile_text)}


def chmod_dest_names(dockerfile_text):
    """Basenames chmod +x'd under /usr/local/bin/ anywhere in the Dockerfile.

    `chmod +x` blocks are typically a backslash-continued RUN spanning many
    lines, so backslash-newline continuations are collapsed into spaces
    first (real Dockerfile-instruction newlines are left alone) and the
    logical line is then scanned for `/usr/local/bin/<name>` tokens.
    """
    joined = re.sub(r"\\\s*\n", " ", dockerfile_text)
    names = set()
    for m in re.finditer(r"chmod\s+\+x\s+([^\n;&|]+)", joined):
        names.update(re.findall(r"/usr/local/bin/(\S+)", m.group(1)))
    return names


def repo_root():
    """Repo root, derived from THIS script's own location rather than the
    Dockerfile path given on the command line — the latter may be a
    scratch/mutated copy living outside the repo (as the bats mutation
    tests use), but `git ls-files` must always resolve source paths
    against the real tracked repo.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    out = subprocess.run(
        ["git", "-C", here, "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, check=True,
    )
    return out.stdout.strip()


def git_mode(root, path):
    """Git's recorded file mode for a tracked path (e.g. '100755'), or None
    if the path isn't tracked. Deliberately reads git's index rather than
    the working tree: a local `chmod +x` on a checked-out file never makes
    it into the image — only the mode git records (and hence what a fresh
    `git clone`/build context sees) does.
    """
    out = subprocess.run(
        ["git", "-C", root, "ls-files", "-s", "--", path],
        capture_output=True, text=True, check=True,
    )
    line = out.stdout.strip()
    return line.split()[0] if line else None


def hook_commands(settings):
    """(event, command) for every hooks.<event>[].hooks[].command entry."""
    cmds = []
    for event, entries in settings.get("hooks", {}).items():
        for entry in entries:
            for h in entry.get("hooks", []):
                c = h.get("command")
                if c:
                    cmds.append((event, c))
    return cmds


def first_token(cmd):
    """The first invoked executable name in a hook command string.

    Unwraps an inline `VAR=` assignment or `$(`/backtick command-substitution
    prefix stuck directly to the first token with no intervening whitespace
    (e.g. `e=$(grep ...)` -> `grep`), so a hook that stashes command output
    in a variable isn't misread as invoking a program named after the
    assignment target.
    """
    stripped = cmd.strip().lstrip("(")
    m = re.match(r"[^\s;&|]+", stripped)
    token = m.group(0) if m else ""
    while True:
        am = re.match(r"^[A-Za-z_][A-Za-z0-9_]*=(.*)$", token)
        if am:
            token = am.group(1)
            continue
        if token.startswith("$("):
            token = token[2:]
            continue
        if token.startswith("`"):
            token = token[1:]
            continue
        if token.startswith("("):
            token = token[1:]
            continue
        break
    return token


def main():
    dockerfile_path, settings_path = sys.argv[1], sys.argv[2]
    with open(dockerfile_path) as fh:
        dockerfile_text = fh.read()
    with open(settings_path) as fh:
        settings = json.load(fh)

    staged = copy_dest_names(dockerfile_text)
    violations = []

    # ── A: GUARD ─────────────────────────────────────────────────────────
    for event, cmd in hook_commands(settings):
        guarded = "command -v" in cmd
        if not guarded:
            token = first_token(cmd)
            if token and token not in SAFE_FIRST_TOKENS:
                violations.append(f"GUARD_FAIL: [{event}] unguarded project-script invocation: {cmd!r}")

        # ── B: STAGED ────────────────────────────────────────────────────
        for name in re.findall(r"command -v ([A-Za-z0-9_.-]+)", cmd):
            if name not in staged:
                violations.append(
                    f"COPY_FAIL: [{event}] hook references '{name}' via command -v, "
                    f"but Dockerfile has no COPY ... /usr/local/bin/{name}"
                )

    # ── C: CHMOD ─────────────────────────────────────────────────────────
    root = repo_root()
    chmodded = chmod_dest_names(dockerfile_text)
    for source, dest in copy_entries(dockerfile_text):
        mode = git_mode(root, source)
        if mode == "100755":
            continue  # already executable in git; COPY preserves it, chmod not needed
        if dest not in chmodded:
            violations.append(
                f"CHMOD_FAIL: '{source}' is COPY'd to /usr/local/bin/{dest} but is mode "
                f"{mode!r} in git (not 100755) and is not chmod +x'd in the Dockerfile"
            )

    if violations:
        print("\n".join(sorted(set(violations))))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
