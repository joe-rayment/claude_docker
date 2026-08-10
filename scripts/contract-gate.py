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

Fires on every shape of close bd actually offers (bead
beads_claude_docker-p9r closed four bypass holes), found by splitting the
shell command on &&/||/|/;/newline exactly like delegation-gate's
exemption splitter:

  bd close <id> [...]      the conventional shape
  bd done <id> [...]       bd's own alias (`bd close --help`: "Aliases:
                           close, done")
  bd close id1 id2 ...     `bd close [id...]` takes many ids; EVERY id is
                           checked, and one failing bead is enough to warn
                           (one line per failing bead) or to deny
  bd close                 with no id at all, bd closes the LAST-TOUCHED
                           issue. `bd show --json` with no id refuses ("at
                           least one issue ID is required"), so the gate
                           cannot resolve that bead cheaply and takes the
                           conservative branch instead: warn (or, in
                           enforce mode, deny) asking for an explicit bead
                           id. That is a deliberate conservative decision,
                           not a fail-open path -- the fail-open paths
                           below are strictly the error paths.
  bd update <id> --status closed      also `--status=closed`, `-s closed`,
                                      `-s=closed`: a close that never says
                                      "close", checked identically. Any
                                      other `bd update` is ignored.

Any other Bash command is ignored entirely -- no output, and no bd call is
made.

The bead ids are the non-flag tokens after the subcommand, minus the
values of bd's known value-taking flags (VALUE_FLAGS: `--reason "x"`, the
"closed" in `--status closed`, ...), so a close carrying a reason and no
id is correctly recognised as a bare close rather than a close of a
phantom bead named after the reason. A value of some flag NOT in that
table would still be collected as a phantom id; `bd show` then fails on
it and it is skipped by the same fail-open rule as any other bd failure,
which is the same order of approximation as delegation-gate's own
compound-command splitter.

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
BD_CLOSE_RE = re.compile(r"^(?:\S*/)?bd\s+(?:close|done)\b")
BD_UPDATE_RE = re.compile(r"^(?:\S*/)?bd\s+update\b")
# `bd update <id> --status closed` closes a bead without saying "close".
STATUS_FLAGS = ("--status", "-s")
STATUS_CLOSED_EQ = ("--status=closed", "-s=closed")

# Flags that consume the NEXT token as their value (from `bd close --help`
# and bd's global flags), so that value is never mistaken for a bead id.
# Boolean flags (-f/--force, --claim-next, --continue, --no-auto,
# --suggest-next, -q, ...) are deliberately absent: swallowing the token
# after `bd close -f <id>` would drop the real id.
VALUE_FLAGS = {
    "-r", "--reason", "--reason-file", "--session",
    "--actor", "--db", "-C", "--directory", "--dolt-auto-commit",
    "-s", "--status", "-p", "--priority", "-t", "--type",
    "-a", "--assignee", "-d", "--design", "--notes", "--append-notes",
    "--acceptance", "--labels",
}
CLASS_NO_CONTRACT_RE = re.compile(r"CLASS:\s*no-contract", re.IGNORECASE)

# Anchored at the start of a line (optional leading whitespace) on purpose:
# a bare substring match false-positives whenever notes merely MENTION the
# phrase without recording it -- e.g. this hook's own RED-AT proof, which
# quotes the frozen test's case names ("...contract + VERIFIED: PASS: fully
# silent") verbatim mid-sentence. A real recorded verdict, written via
# `bd update --append-notes "VERIFIED: PASS ..."`, always starts its own
# line because bd joins appended notes with a newline separator.
VERIFIED_PASS_RE = re.compile(r"^\s*VERIFIED:\s*PASS\b", re.MULTILINE)


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


def split_tokens(segment):
    """Shell-split a segment, falling back to whitespace on bad quoting."""
    import shlex

    try:
        return shlex.split(segment)
    except ValueError:
        return segment.split()


def sets_status_closed(tokens):
    """True when a `bd update` token list sets the status to closed, in any
    of the four spellings: `--status closed`, `--status=closed`,
    `-s closed`, `-s=closed`."""
    for i, tok in enumerate(tokens):
        if tok in STATUS_CLOSED_EQ:
            return True
        if tok in STATUS_FLAGS and i + 1 < len(tokens) and tokens[i + 1] == "closed":
            return True
    return False


def find_bd_close_segment(command):
    """Return the close-shaped segment of a (possibly compound) shell
    command -- `bd close ...`, `bd done ...`, or a `bd update ...` that
    sets status to closed -- or None if this command closes nothing."""
    if not command or not command.strip():
        return None
    for segment in BASH_SPLIT_RE.split(command):
        segment = segment.strip()
        if BD_CLOSE_RE.match(segment):
            return segment
        if BD_UPDATE_RE.match(segment) and sets_status_closed(split_tokens(segment)):
            return segment
    return None


def extract_bead_ids(segment):
    """Every non-flag token after the subcommand, in order, minus the
    values of known value-taking flags. `bd close` takes `[id...]`, so all
    the survivors are real candidate ids; an empty list means a bare
    close, which targets the last-touched bead.

    Excluding flag values matters for correctness, not tidiness: without
    it `bd close -r "wrapped up"` -- a bare close in bd's semantics --
    would yield the phantom id "wrapped up", fail open on it, and be
    silently allowed, which is precisely the bare-close hole this gate
    closes."""
    # tokens[0]="bd" (or a path to it), tokens[1]="close"/"done"/"update"
    ids = []
    skip_next = False
    for tok in split_tokens(segment)[2:]:
        if skip_next:
            skip_next = False
            continue
        if not tok:
            continue
        if tok.startswith("-"):
            skip_next = tok in VALUE_FLAGS  # `--flag=value` needs no skip
            continue
        ids.append(tok)
    return ids


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


NO_ID_REASON = (
    "bd close with no bead id closes the LAST-TOUCHED bead, which this "
    "gate cannot resolve (`bd show` requires an id), so its acceptance "
    "contract and 'VERIFIED: PASS' note cannot be checked -- rerun with "
    "an explicit bead id."
)


def emit_no_id_warn():
    sys.stderr.write(
        f"[contract-gate warn] {NO_ID_REASON} "
        "(CONTRACT_GATE_MODE=off to silence, =enforce to block.)\n"
    )


def bead_fails_check(bead_id):
    """True when this bead should trigger the gate. False when it is fine,
    exempt (CLASS: no-contract), or unknowable (bd failed -- fail open)."""
    issue = bd_show(bead_id)
    if issue is None:
        return False  # bd unavailable/failed/unparseable: fail open, silent

    acceptance = (issue.get("acceptance_criteria") or "").strip()
    notes = issue.get("notes") or ""

    if acceptance and CLASS_NO_CONTRACT_RE.search(acceptance):
        return False  # explicitly exempt: allowed silently

    has_contract = bool(acceptance)
    has_pass = bool(VERIFIED_PASS_RE.search(notes))
    return not (has_contract and has_pass)


def main():
    payload = json.load(sys.stdin)
    command = (payload.get("tool_input") or {}).get("command")

    segment = find_bd_close_segment(command)
    if not segment:
        return  # not a close of any shape: ignored entirely, no bd call

    mode = get_mode()
    if mode == "off":
        return  # silent allow, no bd call made

    bead_ids = extract_bead_ids(segment)

    if not bead_ids:
        # Bare close: targets the last-touched bead, which cannot be
        # resolved. Conservative, deliberately not silent.
        if mode == "enforce":
            emit_deny(f"[contract-gate enforce] {NO_ID_REASON}")
        else:
            emit_no_id_warn()
        return

    failing = [bead_id for bead_id in bead_ids if bead_fails_check(bead_id)]
    if not failing:
        return  # every named bead has a contract and a recorded PASS

    if mode == "enforce":
        # One decision object, naming every failing bead: any one of them
        # is enough to deny the whole command.
        emit_deny(
            f"[contract-gate enforce] bd close {' '.join(failing)}: no "
            "acceptance contract or no recorded 'VERIFIED: PASS' note. "
            "Register a CHECK/PASS-IF contract before dispatch and record "
            "the verifier's PASS via `bd update --append-notes` before "
            "closing, or set CLASS: no-contract on the acceptance field "
            "at registration time if this bead has no observable check."
        )
        return

    # mode == "warn": one line per failing bead.
    for bead_id in failing:
        emit_warn(bead_id)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # fail silent and open: a broken gate must never block a close
    sys.exit(0)
