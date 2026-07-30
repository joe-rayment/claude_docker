#!/usr/bin/env python3
"""
image-drift — SessionStart check: repo scripts/* vs their staged
/usr/local/bin/* counterparts in this image.

/usr/local/bin/<tool> holds the image's baked copy of each script;
scripts/<tool> in the repo holds the truth. Nothing else warns when they
diverge (a rebuild lags a repo change), which has caused real confusion —
see the delegation-gate (2dac0b4), cost-mirror, and run-tests.sh drift
cases in beads_claude_docker-0v3. This prints ONE line naming every
drifted script, or nothing at all when everything matches.

Mapping is DERIVED from the Dockerfile's `COPY ... /usr/local/bin/<dest>`
lines — never hardcoded — via copy_entries() below, the single owner of
that parser. tests/helpers/hook-staging-check.py's sibling "missing COPY"
check imports copy_entries FROM this file (not the other way around):
image-drift is a production script staged into the image, while
tests/helpers/ is dev-only and often absent (post-teardown, sparse
checkout, nested repo) — a production check must never depend on a test
helper being present, or it goes silent exactly when staleness is most
likely. Writing a second regex in either file would let the two drift
apart, which is the same defect shape this tool exists to catch.

Comparison is by content hash (mode is ignored — COPY preserves source
mode, which is a solved problem covered by hook-staging-check.py's CHMOD
check, not this one).

Fails open, always: any error (no Dockerfile, no repo, unreadable file,
malformed Dockerfile) exits 0 silently rather than delay or break session
start. Only fires inside the template repo itself: the positive marker is
the Dockerfile referencing `/opt/claude-dev` (the template's own staging
root for tests/knowledge-base — see that file's COPY lines), combined with
a scripts/ subdir actually existing. A bare Dockerfile + scripts/ pair
with no /opt/claude-dev reference is not this template (a scratch project
that happens to have both produced a spurious hit before this marker was
added — beads_claude_docker-0v3 blocker 2).

Env knobs (mainly for tests):
  REPO_ROOT       skip git-root detection, use this path directly as root
  WORKSPACE       cwd to resolve the git root from (default: os.getcwd())
  STAGED_BIN_DIR  where staged copies live                (default: /usr/local/bin)
"""
import hashlib
import os
import re
import subprocess
import sys

DEFAULT_STAGED_DIR = "/usr/local/bin"
TEMPLATE_MARKER = "/opt/claude-dev"


def git_root(start):
    try:
        out = subprocess.run(
            ["git", "-C", start, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
    except Exception:
        return None
    if out.returncode != 0:
        return None
    root = out.stdout.strip()
    return root or None


def resolve_root():
    override = os.environ.get("REPO_ROOT")
    if override:
        return override
    start = os.environ.get("WORKSPACE") or os.getcwd()
    return git_root(start) or start


def copy_entries(dockerfile_text):
    """(source_path, dest_name) for every `COPY [flags] <src> /usr/local/bin/<dest>` line.

    The single owner of this parser (beads_claude_docker-0v3 blocker 1):
    tests/helpers/hook-staging-check.py imports this function from here
    rather than each file keeping its own copy that could drift apart.
    """
    entries = []
    for m in re.finditer(
        r"^COPY\s+(?:--\S+\s+)*(\S+)\s+/usr/local/bin/(\S+)\s*$",
        dockerfile_text,
        re.MULTILINE,
    ):
        entries.append((m.group(1), m.group(2)))
    return entries


def sha256_of(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def main():
    root = resolve_root()
    dockerfile_path = os.path.join(root, "Dockerfile")
    if not os.path.isfile(dockerfile_path):
        return 0  # no repo/Dockerfile at all — nothing to compare

    with open(dockerfile_path) as fh:
        dockerfile_text = fh.read()

    if TEMPLATE_MARKER not in dockerfile_text:
        return 0  # not the template repo — no positive marker of its staging root

    scripts_dir = os.path.join(root, "scripts")
    if not os.path.isdir(scripts_dir):
        return 0  # Dockerfile references the marker but scripts/ is missing — nothing to compare

    entries = copy_entries(dockerfile_text)

    staged_dir = os.environ.get("STAGED_BIN_DIR", DEFAULT_STAGED_DIR)

    drifted = []
    for src, dest in entries:
        repo_path = os.path.join(root, src)
        staged_path = os.path.join(staged_dir, dest)
        try:
            repo_hash = sha256_of(repo_path)
        except OSError:
            continue  # repo source unreadable/missing — not this check's job
        try:
            staged_hash = sha256_of(staged_path)
        except OSError:
            drifted.append(dest)  # staged copy absent entirely
            continue
        if repo_hash != staged_hash:
            drifted.append(dest)

    if drifted:
        names = ", ".join(sorted(set(drifted)))
        print(
            f"image-drift: staged /usr/local/bin copies are stale vs repo "
            f"({names}) — run ./claude-dev --rebuild on the host"
        )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)  # fail open, always
