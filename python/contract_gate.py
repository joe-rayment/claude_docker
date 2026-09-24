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

Contracts are opt-in since Sept 2026 (config/claude-user-memory.md
§ Tests): the agent registers one only when the user asks for it. So a
bead with NO acceptance field is not gated at all; only a bead that
carries a contract must have its verifier's PASS recorded before it
closes.

Mode: env CONTRACT_GATE_MODE, else $CLAUDE_CONFIG_DIR/contract-gate.mode (single
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
                           issue. The gate resolves that bead with `bd show
                           --current --json` and checks it exactly like a
                           named one (bead beads_claude_docker-bh6); only
                           when that resolution fails does it fall back to
                           the older conservative branch -- warn (or, in
                           enforce mode, deny) asking for an explicit bead
                           id. That fallback is a deliberate conservative
                           decision, not a fail-open path -- the fail-open
                           paths below are strictly the error paths.
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

Transcript corroboration (bead beads_claude_docker-4y6)
-------------------------------------------------------
A "VERIFIED: PASS" line used to be believed on its face, so anyone who
could write bead notes could self-certify with one appended line and no
verifier need ever have run. The note must now read

    VERIFIED: PASS - verifier <agentId>

(any separator/wording; what matters is a plausible agent id token), and
the gate corroborates that id against the harness's own subagent
transcript store:

    <root>/<project>/<session>/subagents/agent-<agentId>.jsonl

root = env CONTRACT_GATE_TRANSCRIPT_ROOT, else $CLAUDE_CONFIG_DIR/projects.
Corroborated means all three of: the transcript file exists, it
references this bead id anywhere, and the AGENT's own output carries a
PASS verdict. That last part reads only `type == "assistant"` records'
text blocks -- never the raw file -- because every verifier spawn prompt
recites the four verdicts ("PASS / FAIL / TAMPERED / NO-CONTRACT"), so a
raw grep for "PASS" would let a FAILing verifier run corroborate a
wishful note.

NOT a security boundary, and the docs say so: the transcript store is an
ordinary user-writable path and the executor's scout-only Agent grant is
a prompt contract, not a harness-enforced one, so a determined agent can
forge a transcript. What this buys is that self-certification stops being
one appended line and becomes deliberate multi-step forgery -- tamper-
resistant against laziness and accident, nothing stronger.

Fail open, deliberately: if the store root is missing, is not a
directory, or contains no `subagents/` directory anywhere, corroboration
is not merely failed but *impossible*, and the gate falls back to the old
text-only behaviour (a bare "VERIFIED: PASS" allows). Other machines,
fresh containers and headless runs must never be blocked by a store that
was never there -- and no already-closed bead whose note predates this
format is retroactively condemned, since the gate only ever runs on a
close happening now.

Lane awareness (beads_claude_docker-mcuw)
------------------------------------------
This gate's whole premise -- register a CHECK/PASS-IF contract, corroborate
a VERIFIED: PASS note -- is a DEEP-lane concept: express and standard
explicitly carry no contract per the rulebook ($CLAUDE_CONFIG_DIR/CLAUDE.md §
Lanes). When the session that is closing the bead declared "express" or
"standard" (read from the same per-session state file `scripts/lane.sh`
writes, LANE_STATE_DIR/<session_id>.json, key "lane"), the gate is
entirely silent -- allowed, and not even a `bd show` call is made, the
same posture as mode=off. "deep" and "no resolvable lane" (missing state
dir/file, unreadable/malformed JSON, no session_id in the hook payload)
both keep today's behaviour unchanged: this is a narrowing of WHEN the
gate speaks, never a new way for a genuinely deep-lane close to go
unchecked.

Resolving a bare close (bead beads_claude_docker-bh6)
-----------------------------------------------------
A bare `bd close` used to be un-checkable: the gate could only ask for an
explicit id. It is checkable, because bd exposes the very pointer it is
about to close. Probed empirically on bd 1.0.4 (commands and output
recorded in bh6's notes):

  * bd keeps the pointer in the gitignored file `.beads/last-touched`,
    per database, and `bd close --help` says a no-id close targets "the
    last touched issue (from most recent create, update, show, or close
    operation)".
  * `bd show --current --json` returned exactly that pointer after every
    one of those four operations. Its help ("in-progress, hooked, or last
    touched") suggests it might out-vote the pointer with an unrelated
    in-progress bead -- it does not: with bead C in_progress and the
    pointer on B, --current answered B, and with the pointer file removed
    while C was still in_progress it errored instead of naming C, exactly
    where a bare close also errors.
  * Reading --current does NOT move the pointer, which matters here: this
    hook runs at PreToolUse, i.e. before the close, so a resolution that
    re-pointed the pointer would change the very target it reports.
  * A bare `bd close` was then observed closing precisely the bead
    --current had just named -- on a throwaway database and again on the
    real tracker.

So the bare branch resolves the id and checks that bead through the same
path as a named one. Resolution is believed only when it yields a
non-empty, non-flag-shaped id: a `bd` that does not know --current (or
that echoes the flag back as an id) must not make the gate report on a
phantom bead named "--current". Any other outcome -- non-zero exit,
unparseable output, empty list, missing/hung bd -- keeps the conservative
ask. That is deliberately NOT the silent fail-open used for a NAMED bead:
there the gate knows which bead it failed to check and can let a possibly
fine close through, whereas here it does not even know what is at stake,
and Branch A of the contract says an unresolvable --current must fall back
to the conservative ask "rather than allowing".
"""

import json
import os
import re
import sys
# glob and subprocess are imported inside the few functions that use them:
# they are only reached when the command really is a `bd close`, and
# loading them up front cost ~8 ms on every other Bash call.


def _claude_config_dir():
    """Resolves the Claude config dir: $CLAUDE_CONFIG_DIR if set, else the
    default under the user's home directory (kept out of a single literal
    here on purpose -- see scripts/lib/paths.sh's header and the grep gate
    in tests/config-sync.bats)."""
    override = os.environ.get("CLAUDE_CONFIG_DIR")
    if override:
        return override
    return os.path.join(os.path.expanduser("~"), ".claude")

MODE_FILE = os.path.join(_claude_config_dir(), "contract-gate.mode")
RECOGNIZED_MODES = {"off", "warn", "enforce"}
BD_SHOW_TIMEOUT_SECONDS = 5

# Lane awareness: same env var, default dir, and per-session file shape as
# scripts/lane.sh (LANE_STATE_DIR/<session_id>.json, key "lane"). Express and
# standard are the lanes where this gate's whole premise (a contract, a
# corroborated VERIFIED: PASS) does not apply, so they suppress the gate
# entirely; every other lane word, and "no resolvable lane", is unaffected.
LANE_STATE_DIR_ENV = "LANE_STATE_DIR"
DEFAULT_LANE_STATE_DIR = os.path.join(_claude_config_dir(), "cache", "lane")
LIGHT_LANES = {"express", "standard"}
SESSION_ID_SAFE_RE = re.compile(r"[^A-Za-z0-9._-]+")

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
# Same anchor, but capturing the rest of the line: that remainder is where
# the verifier attribution ("- verifier <agentId>") lives.
VERIFIED_PASS_LINE_RE = re.compile(r"^\s*VERIFIED:\s*PASS\b(.*)$", re.MULTILINE)

# --- transcript corroboration ----------------------------------------------
TRANSCRIPT_ROOT_ENV = "CONTRACT_GATE_TRANSCRIPT_ROOT"
DEFAULT_TRANSCRIPT_ROOT = os.path.join(_claude_config_dir(), "projects")
TRANSCRIPT_READ_LIMIT_BYTES = 32 * 1024 * 1024  # transcripts run to ~2.5 MB

# A candidate agent id: >= 8 chars of [0-9A-Za-z_-], optionally written with
# the "agent-" filename prefix, and containing a run of >= 8 hex digits.
# Real ids are either 17 hex chars (a51ceb8cf23d0e21d) or, when the Agent
# call passed a name, "a<name>-<16 hex>" (averifier-opus-5-resume-90365b...).
# The hex-run requirement is what keeps ordinary prose words out; every
# candidate on the line is tried, because keyword-anchored extraction breaks
# on exactly the named ids that contain the word "verifier" themselves.
AGENT_ID_TOKEN_RE = re.compile(r"(?:agent-)?[0-9A-Za-z][0-9A-Za-z_-]{7,}")
HEX_RUN_RE = re.compile(r"[0-9a-f]{8,}")

# The verifier's own verdict, matched against DECODED assistant text only.
# Line-anchored with a prefix class of spaces/tabs/markdown punctuation --
# never \s, which would span newlines and turn the anchor into a substring
# match. Validated against the real transcripts on this machine: it finds
# "Contract verdict: PASS" and "Verdict: PASS", and does not fire on a
# "Verdict: PARTIAL"/"FAIL" run or on a prompt reciting the four verdicts.
VERDICT_PASS_RES = (
    re.compile(
        r"(?im)^[ \t>*_#\-]*(?:contract[ \t]+)?\**[ \t]*verdict\**"
        r"[ \t]*[:\-]?[ \t]*\**[ \t]*PASS(?![-\w])"
    ),
    re.compile(r"(?im)^[ \t>*_#\-]*\**[ \t]*VERIFIED:[ \t]*PASS(?![-\w])"),
)


def transcript_root():
    root = os.environ.get(TRANSCRIPT_ROOT_ENV) or DEFAULT_TRANSCRIPT_ROOT
    return os.path.expanduser(root)


def transcript_store_discoverable():
    """True only when this machine actually has a subagent transcript store.
    Absent root, a root that is not a directory, or a tree with no
    `subagents/` directory anywhere means corroboration is impossible rather
    than failed -- the caller then falls back to text-only behaviour."""
    import glob

    root = transcript_root()
    if not os.path.isdir(root):
        return False
    for depth in ("*/*/subagents", "*/subagents", "subagents", "**/subagents"):
        for path in glob.iglob(os.path.join(root, depth), recursive=True):
            if os.path.isdir(path):
                return True
    return False


def transcript_paths(agent_id):
    """Every transcript file for this agent id, at any depth under root."""
    import glob

    root = transcript_root()
    name = "agent-%s.jsonl" % agent_id
    seen, paths = set(), []
    for pattern in (
        os.path.join(root, "*", "*", "subagents", name),
        os.path.join(root, "**", "subagents", name),
    ):
        for path in glob.iglob(pattern, recursive=True):
            if path not in seen and os.path.isfile(path):
                seen.add(path)
                paths.append(path)
    return paths


def assistant_text(raw):
    """The decoded text the AGENT itself emitted: `type == "assistant"`
    records' text blocks, joined. Unparseable lines are skipped. Reading
    this instead of the raw JSONL is the whole point -- the spawn prompt
    (a `type == "user"` record) recites "PASS / FAIL / TAMPERED /
    NO-CONTRACT" in every real verifier run."""
    chunks = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except Exception:
            continue
        if not isinstance(record, dict) or record.get("type") != "assistant":
            continue
        content = (record.get("message") or {}).get("content")
        if isinstance(content, str):
            chunks.append(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    chunks.append(block.get("text") or "")
    return "\n".join(chunks)


def transcript_corroborates(agent_id, bead_id):
    """True when some transcript for this agent id both references the bead
    and records a PASS verdict in the agent's own output."""
    for path in transcript_paths(agent_id):
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                raw = fh.read(TRANSCRIPT_READ_LIMIT_BYTES)
        except Exception:
            continue
        if bead_id not in raw:
            continue
        text = assistant_text(raw)
        if any(pattern.search(text) for pattern in VERDICT_PASS_RES):
            return True
    return False


def attributed_agent_ids(notes):
    """Every plausible agent id token appearing on a `VERIFIED: PASS` line."""
    ids = []
    for remainder in VERIFIED_PASS_LINE_RE.findall(notes):
        for token in AGENT_ID_TOKEN_RE.findall(remainder):
            if not HEX_RUN_RE.search(token):
                continue
            if token.startswith("agent-"):
                token = token[len("agent-"):]
            if token not in ids:
                ids.append(token)
    return ids


def lane_state_dir():
    return os.path.expanduser(os.environ.get(LANE_STATE_DIR_ENV) or DEFAULT_LANE_STATE_DIR)


def sanitize_session_id(raw):
    """Same character allowlist as lane.sh's sanitize_id(): strip everything
    outside [A-Za-z0-9._-] so a hostile session_id can never escape the
    state directory."""
    if not isinstance(raw, str):
        return ""
    return SESSION_ID_SAFE_RE.sub("", raw)


def current_lane(session_id):
    """The lane declared for this session, read from the same state file
    scripts/lane.sh writes (<LANE_STATE_DIR>/<session_id>.json, key
    "lane"). None on any failure -- no session id, missing/unreadable/
    unparsable file, non-dict JSON, non-string lane value -- so the caller
    falls through to today's behaviour exactly as if lane-awareness did not
    exist, the same fail-open posture as every other branch in this file."""
    if not session_id:
        return None
    path = os.path.join(lane_state_dir(), "%s.json" % session_id)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    lane = data.get("lane")
    return lane if isinstance(lane, str) else None


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
    import subprocess

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


def resolve_current_bead_id():
    """The id of the last-touched bead -- the one a bare `bd close` would
    close -- via `bd show --current --json`, or None when it cannot be
    trusted (bd missing, non-zero exit, timeout, unparseable output, empty
    result, empty id, or a flag-shaped id from a bd that does not know the
    flag). None means: keep the conservative branch."""
    import subprocess

    try:
        result = subprocess.run(
            ["bd", "show", "--current", "--json"],
            capture_output=True,
            text=True,
            timeout=BD_SHOW_TIMEOUT_SECONDS,
        )
        if result.returncode != 0:
            return None
        data = json.loads(result.stdout)
    except Exception:
        return None
    if isinstance(data, list):
        data = data[0] if data else None
    if not isinstance(data, dict):
        return None
    bead_id = (data.get("id") or "").strip()
    # A flag-shaped or empty id is never a bead: an older `bd` that ignores
    # --current and echoes it back must not be believed.
    if not bead_id or bead_id.startswith("-"):
        return None
    return bead_id


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
        f"[contract-gate warn] bd close {bead_id}: this bead carries an "
        "acceptance contract but no recorded 'VERIFIED: PASS' note -- run "
        "the verifier and record its PASS via `bd update --append-notes` "
        "before closing. "
        "(CONTRACT_GATE_MODE=off to silence, =enforce to block.)\n"
    )


NO_ID_REASON = (
    "bd close with no bead id closes the LAST-TOUCHED bead, and this gate "
    "could not resolve which one that is (`bd show --current --json` "
    "failed, is unsupported, or named nothing), so its acceptance contract "
    "and 'VERIFIED: PASS' note cannot be checked -- rerun with an explicit "
    "bead id."
)


def emit_no_id_warn():
    sys.stderr.write(
        f"[contract-gate warn] {NO_ID_REASON} "
        "(CONTRACT_GATE_MODE=off to silence, =enforce to block.)\n"
    )


# Two distinct failure kinds, so the message can name what is actually
# missing: MISSING is the original "no contract or no PASS note" case (its
# wording is unchanged), UNCORROBORATED is a PASS note the transcript store
# does not back up.
FAIL_MISSING = "missing"
FAIL_UNCORROBORATED = "uncorroborated"


def corroboration_detail(bead_id, agent_ids):
    if not agent_ids:
        return (
            "the note names no verifier agentId; write it as "
            "\"VERIFIED: PASS - verifier <agentId>\", naming the subagent "
            f"whose transcript under {transcript_root()} records the verdict"
        )
    return (
        f"no transcript under {transcript_root()} for agentId "
        f"{', '.join(agent_ids)} both references {bead_id} and records a "
        "PASS verdict in the agent's own output"
    )


def emit_corroboration_warn(bead_id, detail):
    sys.stderr.write(
        f"[contract-gate warn] bd close {bead_id}: the 'VERIFIED: PASS' "
        f"note is not corroborated by a verifier transcript -- {detail}. "
        "(CONTRACT_GATE_MODE=off to silence, =enforce to block.)\n"
    )


def bead_failure(bead_id):
    """(kind, detail) when this bead should trigger the gate, else None.
    None also covers fine, exempt (CLASS: no-contract) and unknowable (bd
    failed -- fail open)."""
    issue = bd_show(bead_id)
    if issue is None:
        return None  # bd unavailable/failed/unparseable: fail open, silent

    acceptance = (issue.get("acceptance_criteria") or "").strip()
    notes = issue.get("notes") or ""

    if not acceptance:
        return None  # contracts are opt-in: a bead without one is not gated

    if CLASS_NO_CONTRACT_RE.search(acceptance):
        return None  # explicitly exempt: allowed silently

    if not VERIFIED_PASS_RE.search(notes):
        return (FAIL_MISSING, None)

    # A PASS note is present. Believe it on its face only where the
    # transcript store does not exist to be consulted at all.
    if not transcript_store_discoverable():
        return None  # fail open: text-only fallback, exactly as before

    agent_ids = attributed_agent_ids(notes)
    for agent_id in agent_ids:
        if transcript_corroborates(agent_id, bead_id):
            return None
    return (FAIL_UNCORROBORATED, corroboration_detail(bead_id, agent_ids))


def main():
    payload = json.load(sys.stdin)
    command = (payload.get("tool_input") or {}).get("command")

    segment = find_bd_close_segment(command)
    if not segment:
        return  # not a close of any shape: ignored entirely, no bd call

    mode = get_mode()
    if mode == "off":
        return  # silent allow, no bd call made

    lane = current_lane(sanitize_session_id(payload.get("session_id")))
    if lane in LIGHT_LANES:
        return  # deep-lane-only ceremony: silent allow, no bd call made

    bead_ids = extract_bead_ids(segment)

    if not bead_ids:
        # Bare close: targets the last-touched bead. Resolve it and check it
        # like any named bead; only an untrustworthy resolution falls back to
        # the conservative ask (deliberately not silent).
        resolved = resolve_current_bead_id()
        if resolved is None:
            if mode == "enforce":
                emit_deny(f"[contract-gate enforce] {NO_ID_REASON}")
            else:
                emit_no_id_warn()
            return
        bead_ids = [resolved]

    failing = []
    for bead_id in bead_ids:
        failure = bead_failure(bead_id)
        if failure is not None:
            failing.append((bead_id, failure[0], failure[1]))
    if not failing:
        return  # every named bead has a contract and a corroborated PASS

    if mode == "enforce":
        # One decision object, naming every failing bead: any one of them
        # is enough to deny the whole command.
        missing = [b for b, kind, _ in failing if kind == FAIL_MISSING]
        reason = ""
        if missing:
            reason = (
                f"[contract-gate enforce] bd close {' '.join(missing)}: the "
                "bead carries an acceptance contract but no recorded "
                "'VERIFIED: PASS' note. Run the verifier and record its PASS "
                "via `bd update --append-notes` before closing."
            )
        for bead_id, kind, detail in failing:
            if kind != FAIL_UNCORROBORATED:
                continue
            if reason:
                reason += " "
            reason += (
                f"[contract-gate enforce] bd close {bead_id}: the "
                "'VERIFIED: PASS' note is not corroborated by a verifier "
                f"transcript -- {detail}."
            )
        emit_deny(reason)
        return

    # mode == "warn": one line per failing bead.
    for bead_id, kind, detail in failing:
        if kind == FAIL_UNCORROBORATED:
            emit_corroboration_warn(bead_id, detail)
        else:
            emit_warn(bead_id)



def run():
    """The hook entry: main(), failing open, always exit 0."""
    try:
        main()
    except Exception:
        pass  # fail silent and open: a broken gate must never block a close
    sys.exit(0)


if __name__ == "__main__":
    run()
