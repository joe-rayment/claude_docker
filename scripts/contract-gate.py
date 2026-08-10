#!/usr/bin/env python3
"""contract-gate — PreToolUse(Bash) hook: warns (or, in enforce mode,
denies) a `bd close` run against a bead that has no acceptance contract or
no recorded verifier `VERIFIED: PASS` note (bead beads_claude_docker-smo,
part of the acceptance-contracts plan). Modelled directly on
scripts/delegation-gate.py: mode ladder, fail-open-on-everything, deny JSON
shape copied verbatim.

Why: the acceptance-contracts plan (knowledge-base/ACCEPTANCE_CONTRACTS.md)
asks for a runnable CHECK/PASS-IF to be registered on a bead's
--acceptance field before an executor is dispatched, and for the verifier's
PASS to be recorded back into the bead's --notes (append-only) as
"VERIFIED: PASS ...". Nothing enforced that a bead actually carries either
before it gets closed -- this hook is the mechanical nudge (or, in
enforce mode, the block).

Mode: env CONTRACT_GATE_MODE, else ~/.claude/contract-gate.mode (single
word), else "warn". An unset OR unrecognized value falls back to "warn" --
never to "off": a hook that silently degrades to no-op on a typo defeats
the point of having it.
  off      always silent allow -- no bd call is even made.
  warn     (DEFAULT) allow the close, but print a warning to stderr when
           the bead has no acceptance contract or no recorded
           "VERIFIED: PASS" note. Silent when both are present.
  enforce  same check, but emits hookSpecificOutput.permissionDecision ==
           "deny" instead of a warning when the check fails. Silent
           (allow) when both are present.

Fires ONLY on a `bd close ...` command (a `bd close` segment found after
splitting the shell command on &&/||/|/;/newline, ignoring leading `cd`
navigation exactly like delegation-gate's exemption splitter). Any other
Bash command is ignored entirely -- no output, and no bd call is made.

The bead id is the first non-flag token after `close`; commands are
expected in the conventional `bd close <id> [flags...]` shape (as used
throughout this repo's own session-close protocol) -- a flag value placed
before the id (e.g. `bd close --reason "x" <id>`) is not specifically
handled and is a known, accepted limitation, matching delegation-gate's
own compound-command approximation.

A bead whose acceptance contract contains a `CLASS: no-contract` line is
exempt: allowed silently regardless of mode (mode=off already skips the
bd call, so the exemption is checked only for warn/enforce, after the
contract is already known).

Fail open on every error path: unparseable stdin JSON, `bd` missing or
non-zero exit, unparseable `bd show --json` output, subprocess timeout,
or any other exception -- exit 0 with no output, so a broken or slow gate
can never block a real `bd close`. The bd subprocess call carries an
explicit timeout so a hung `bd` cannot hang every Bash call.

The verdict record itself ("VERIFIED: PASS ...") is written by the
orchestrator via `bd update <id> --append-notes` on receiving the
verifier's report -- this hook only reads it back; it never writes to a
bead.
"""

import json
import os
import re
import subprocess
import sys

MODE_FILE = "~/.claude/contract-gate.mode"
RECOGNIZED_MODES = {"off", "warn", "enforce"}
BD_SHOW_TIMEOUT_SECONDS = 5

# Same compound-command splitter as delegation-gate: a single Bash tool
# call is often several shell commands chained together.
BASH_SPLIT_RE = re.compile(r"&&|\|\||\||;|\n")
BD_CLOSE_RE = re.compile(r"^(?:\S*/)?bd\s+close\b")
CLASS_NO_CONTRACT_RE = re.compile(r"CLASS:\s*no-contract", re.IGNORECASE)


def mode_file():
    return os.path.expanduser(MODE_FILE)


def get_mode():
    mode = os.environ.get("CONTRACT_GATE_MODE")
    if not mode:
        try:
            with open(mode_file()) as fh:
                mode = fh.read().strip()
        except Exception:
            mode = None
    mode = (mode or "").strip()
    if mode not in RECOGNIZED_MODES:
        return "warn"  # unset or unrecognized never silently drops the gate
    return mode


def find_bd_close_segment(command):
    """Return the `bd close ...` segment of a (possibly compound) shell
    command, or None if this command does not invoke `bd close` at all."""
    if not command or not command.strip():
        return None
    for segment in BASH_SPLIT_RE.split(command):
        segment = segment.strip()
        if BD_CLOSE_RE.match(segment):
            return segment
    return None


def extract_bead_id(segment):
    """First non-flag token after `bd close` in the segment, or None."""
    import shlex

    try:
        tokens = shlex.split(segment)
    except ValueError:
        tokens = segment.split()
    for tok in tokens[2:]:  # tokens[0]="bd" (or a path to it), tokens[1]="close"
        if tok and not tok.startswith("-"):
            return tok
    return None


def bd_show(bead_id):
    """Shell out to `bd show <id> --json` and return the issue dict, or
    None on any failure (missing bd, non-zero exit, timeout, bad JSON)."""
    result = subprocess.run(
        ["bd", "show", bead_id, "--json"],
        capture_output=True,
        text=True,
        timeout=BD_SHOW_TIMEOUT_SECONDS,
    )
    if result.returncode != 0:
        return None
    data = json.loads(result.stdout)
    if isinstance(data, list):
        return data[0] if data else None
    if isinstance(data, dict):
        return data
    return None


def emit_deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))


def emit_warn(bead_id):
    sys.stderr.write(
        f"[contract-gate warn] bd close {bead_id}: no acceptance contract "
        "or no recorded 'VERIFIED: PASS' note on this bead -- register a "
        "CHECK/PASS-IF contract before dispatch and record the verifier's "
        "PASS via `bd update --append-notes` before closing. "
        "(CONTRACT_GATE_MODE=off to silence, =enforce to block.)\n"
    )


def main():
    payload = json.load(sys.stdin)
    command = (payload.get("tool_input") or {}).get("command")

    segment = find_bd_close_segment(command)
    if not segment:
        return  # not a `bd close`: ignored entirely, no bd call

    bead_id = extract_bead_id(segment)
    if not bead_id:
        return  # couldn't determine which bead -- nothing to check

    mode = get_mode()
    if mode == "off":
        return  # silent allow, no bd call made

    issue = bd_show(bead_id)
    if issue is None:
        return  # bd unavailable/failed/unparseable: fail open, silent

    acceptance = (issue.get("acceptance_criteria") or "").strip()
    notes = issue.get("notes") or ""

    if acceptance and CLASS_NO_CONTRACT_RE.search(acceptance):
        return  # explicitly exempt: allowed silently

    has_contract = bool(acceptance)
    has_pass = "VERIFIED: PASS" in notes

    if has_contract and has_pass:
        return  # contract present and verified: allow silently

    if mode == "enforce":
        emit_deny(
            f"[contract-gate enforce] bd close {bead_id}: no acceptance "
            "contract or no recorded 'VERIFIED: PASS' note. Register a "
            "CHECK/PASS-IF contract before dispatch and record the "
            "verifier's PASS via `bd update --append-notes` before "
            "closing, or set CLASS: no-contract on the acceptance field "
            "at registration time if this bead has no observable check."
        )
        return

    # mode == "warn"
    emit_warn(bead_id)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # fail silent and open: a broken gate must never block a close
    sys.exit(0)
