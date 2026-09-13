#!/usr/bin/env python3
"""delegation-gate — PreToolUse hook: a mechanical counter against the main
loop's inline-grinding habit (bead bd-arr, hardened by beads_claude_docker-sov).

Why: the delegation protocol (CLAUDE.md, project and user-global) asks the
orchestrator to push recon to scout, implementation to executor, and keep
its own tool calls to review/decide — but nothing enforces that; the main
loop can grind through reads/edits inline indefinitely and nothing in the
harness pushes back. This hook counts consecutive inline work-tool calls
made by the MAIN LOOP ONLY (never a subagent) and nudges once a streak
crosses a threshold. Calling the Agent (or Workflow) tool resets the
streak to zero — that is the "I delegated" signal.

ADVISORY ONLY (claude-orca, Sept 2026): this gate NEVER denies a tool
call, in any mode. Every path that used to emit a deny now emits the same
text as an allow + additionalContext note prefixed "[delegation-gate]".
The mode names below are kept (mode files and env overrides in the wild
still set them) and still decide WHICH note fires, but "guard" and
"enforce" are now differences of wording, not of permission. The
"denies" counter in the state file stays in the schema and stays 0.

Main-loop discriminator (empirical, scratchpad/gateprobe/ raw log,
harness v2.1.220): the obvious hypothesis — that a subagent's PreToolUse
payload carries a transcript_path under .../subagents/agent-*.jsonl — is
WRONG. That path does exist on disk, but the transcript_path FIELD
DELIVERED TO THE HOOK is byte-identical for a main-loop call and a
subagent's own call: both point at the top-level session's own
<session_id>.jsonl. What actually discriminates is agent_id/agent_type —
and on real main-loop payloads those keys are ABSENT ENTIRELY (not
present-with-null; an earlier report claimed null and shipped a gate that
never fired, caught only by behavioral evidence: zero state files across
real runs). Subagent-originated calls carry both keys populated (e.g.
agent_type "scout"). So: agent_id absent OR null/empty = main loop;
agent_id populated = subagent. See is_main_loop().

Mode: env DELEGATION_GATE_MODE, else $CLAUDE_CONFIG_DIR/delegation-gate.mode
(single word), else "guard". An unset OR unrecognized value is treated
as "guard" — the gate never silently degrades to a weaker mode on a typo.
  off        always silent allow (the streak is still counted, so
             switching modes mid-session picks up an accurate count).
  warn-only  (alias: "warn") allow everything, but fire the repeating
             warn note per the cadence below. Never denies.
  guard      (DEFAULT) Edit/Write/NotebookEdit in the main loop draw the
             executor's-seat note — unless the target path is exempt (see
             is_exempt_edit()) or the declared lane is "standard" or
             "express" (see "Lane awareness" below: the note fires only
             for lane "deep" or no lane declared). A NON-EXEMPT Bash call
             draws its own note once the streak reaches
             DELEGATION_GATE_DENY_AT, in every lane except express.
  enforce    guard, PLUS Read/Grep/Glob draw a note once the streak
             reaches DELEGATION_GATE_DENY_AT (default 8).
Every note names the exact alternative (spawn a scout / spawn an
executor) — never a dead end.

Repeating warn cadence: the original shipped gate warned once (at streak
DELEGATION_GATE_WARN_AT, default 8) and then fell silent for the rest of
the session — the one mechanism that fires mid-turn shut itself up after
a single use, which is self-defeating for a session that ignores it. The
fix is a watermark, not a boolean: warn again whenever
streak - warned_at >= DELEGATION_GATE_WARN_EVERY (default 8), and
escalate the wording with the streak (see emit_warn()) — first warn is a
plain nudge, 2x-warn_at adds the standing-authorization reminder, 6x-warn_at
adds the re-billing economics. Agent/Workflow calls clear the watermark
(and the streak) back to zero.

Edit exemptions (all modes): planning, memory and scratch ARE the
orchestrator's own seat, so an Edit/Write/NotebookEdit landing there is
not counted at all — no streak increment, no note. Exempt: any path
containing "/.claude/plans/" (covers $CLAUDE_CONFIG_DIR/plans/** and a
git-root-relative .claude/plans/ dir), $CLAUDE_CONFIG_DIR/projects/*/memory/**
(the harness auto-memory dir), and a scratchpad path — /tmp/claude-*/…
or anything containing "/scratchpad/". The exemption must be PROVEN from
an explicit, resolvable path: if tool_input carries no path, the edit
counts like any other. (The scratchpad used to be excluded deliberately,
as a smuggling hole for real edits; with the gate advisory there is
nothing left to smuggle past, and scratch files are not the grinding this
hook targets.)

Read-only half-counting: Read/Grep/Glob increment the streak by 1 only on
every SECOND such call (the odd one is held in state as "ro_pending"), so
a pure-recon stretch reaches WARN_AT=8 at about 16 calls while a stretch
of edits or non-exempt Bash still reaches it at 8. Reading is the cheapest
thing the orchestrator does inline and was over-weighted before.

State: $CLAUDE_CONFIG_DIR/cache/delegation-gate/<session_id>.json holds
{"streak": int, "warned_at": int, "max_streak": int, "warns": int,
"denies": int}. Only streak/warned_at reset on Agent/Workflow use;
max_streak/warns/denies persist for the life of the session as a drift
metric — scripts/cost-mirror.py reads this state file and appends an
"inline: max streak N · N warns · N denies" segment to its line. Legacy
state files degrade gracefully: {"warned": true}
with no "warned_at" migrates to warned_at = the loaded streak (so a
session upgraded mid-flight doesn't immediately re-warn); missing keys
default to 0. Missing/corrupt state starts fresh. Opportunistic GC
unlinks sibling state files untouched for 7+ days.

Output channel for warn (probed twice, v2.1.220 — resolved picture): a
DENY's permissionDecisionReason reaches the model ALWAYS (arrives as an
is_error tool_result; both probes showed unprompted compliance with the
reason text). An ALLOW's additionalContext/systemMessage is
HARNESS-DEPENDENT: in an interactive/agent session it lands in model
context (observed live — the session that shipped this hook read its own
streak-4 warn and delegated in response), but in headless `claude -p`
runs a full content-scan of every user/assistant message found the probe
strings only in sidecar attachment records, never model-visible. So warn
is effective in interactive sessions and inert in headless children. A
deny used to be the answer to that; it no longer is — the gate is
advisory, so a note that the harness drops is simply a note that was not
read, and no tool call is ever stopped.

Lane awareness (complexity router, scripts/lane.sh): the orchestrator
declares a lane per prompt and `lane` records it at
$LANE_STATE_DIR/<session_id>.json. An express lane means the task is small
by definition — a single mechanical edit or a one-lookup answer — so the
guard/enforce notes are exactly backwards there: spawning an executor to
change one line costs more than the change. Under express, main-loop
Edit/Write/NotebookEdit draw no note at all and the read/Bash streak note
is suspended; the streak is still counted, and a NEW warn (EXPRESS_WARN_AT, repeating
every EXPRESS_WARN_EVERY, sharing the same warned_at watermark) fires
instead of the delegation nudge — a long grind under express is the
mis-routing signal, and telling that session to delegate would contradict
the lane it declared.

Standard lane (beads_claude_docker-dl2) also suspends the guard/enforce
edit note: the standard rubric already allows a one-slice task to finish
inline, so nagging there asks for an executor spawn the rubric never
wanted. Unlike express, standard gets no dedicated warn — it falls
through to the ordinary streak warn cadence (WARN_AT/WARN_EVERY) below
like any other call, it just never hits the edit note. Because that check
is one shared branch (mode in ("guard", "enforce")), enforce inherits the
relaxation too. Deep and unset (which also covers any unrecognized lane
name or an unreadable/absent state file) are the two lane readings that
still draw the edit note.

Failure posture: fail SILENT AND OPEN. Any error — malformed stdin,
unreadable state, an unwritable cache dir — exits 0 with no output.
Exempt from all of this: a list of housekeeping Bash commands — `bd`,
every `git` and every `gh` invocation (not just the read-only ones: a
commit or a push is session steering, not inline work), bats, dev-log,
cost-mirror, tier-*, lane, run-tests, take-screenshot and delegation-gate
itself — which are bookkeeping, not the grinding this hook targets.
"""

import json
import os
import re
import sys
import time


def _claude_config_dir():
    """Resolves the Claude config dir: $CLAUDE_CONFIG_DIR if set, else the
    default under the user's home directory (kept out of a single literal
    here on purpose -- see scripts/lib/paths.sh's header and the grep gate
    in tests/config-sync.bats)."""
    override = os.environ.get("CLAUDE_CONFIG_DIR")
    if override:
        return override
    return os.path.join(os.path.expanduser("~"), ".claude")

STATE_DIR = os.path.join(_claude_config_dir(), "cache", "delegation-gate")
MODE_FILE = os.path.join(_claude_config_dir(), "delegation-gate.mode")
LANE_STATE_DIR = os.path.join(_claude_config_dir(), "cache", "lane")
GC_AGE_SECONDS = 7 * 24 * 3600

# Lanes a state file may name. Anything else — including the "unset" that
# `lane --reset` writes at the top of every prompt — leaves the gate at
# exactly its pre-lane behavior.
KNOWN_LANES = {"express", "standard", "deep"}
EXPRESS_WARN_AT = 6
EXPRESS_WARN_EVERY = 4

# Tools that are unconditionally counted work. Bash is handled separately
# below since it is only counted when NOT an exempt housekeeping command.
COUNTED_TOOLS = {"Read", "Grep", "Glob", "Edit", "Write", "NotebookEdit"}
RESET_TOOLS = {"Agent", "Workflow"}
EDIT_TOOLS = {"Edit", "Write", "NotebookEdit"}
# Read-only recon: counted at half weight (one streak tick per two calls).
READONLY_TOOLS = {"Read", "Grep", "Glob"}
RECOGNIZED_MODES = {"off", "warn-only", "warn", "guard", "enforce"}

EXEMPT_BASH_RE = re.compile(
    r"^\s*(bd|git|gh"
    r"|bats|dev-log|cost-mirror|tier-|lane|delegation-gate|run-tests"
    r"|take-screenshot)\b"
)

# Compound-command handling: a single Bash tool call is often several
# shell commands chained together (the session-close protocol commonly
# writes `cd /workspace && bd close ... && git push`). EXEMPT_BASH_RE
# alone only ever sees the whole string, so it anchors on the FIRST
# command -- a leading `cd` made an otherwise all-exempt line count.
BASH_SPLIT_RE = re.compile(r"&&|\|\||\||;|\n")
CD_SEGMENT_RE = re.compile(r"^cd\b")

# Edit exemption: the harness auto-memory dir is $CLAUDE_CONFIG_DIR/projects/<slug>/memory/.
MEMORY_DIR_RE = re.compile(r"/\.claude/projects/[^/]+/memory/")
# Scratchpad: the session scratch dir (/tmp/claude-<uid>/…/scratchpad) and
# any other path that names a scratchpad directory.
SCRATCHPAD_RE = re.compile(r"^/tmp/claude-[^/]*/|/scratchpad/")


def is_main_loop(payload):
    """True when this tool call originates in the top-level orchestrator
    loop, not a subagent. Real main-loop payloads carry NO agent_id key at
    all (v2.1.220, verified against the raw gateprobe log); subagent calls
    carry agent_id populated. Treating key-absence as "subagent" is the
    exact bug that shipped a never-firing gate — absence IS the main loop.
    A populated agent_id is the only positive subagent signal, so that —
    and only that — suppresses gating."""
    return not payload.get("agent_id")


def is_exempt_bash(command):
    """A compound line is exempt iff, after dropping leading pure `cd`
    navigation segments (a bare directory change carries no work), every
    remaining segment matches EXEMPT_BASH_RE. Splits on &&, ||, |, ;, and
    newlines. A line that is ONLY leading cd segments is exempt (pure
    navigation). A mixed line -- an exempt segment plus a non-exempt one,
    in any position -- stays NOT exempt: partial exemption must not
    become a smuggling hole."""
    if not command or not command.strip():
        return False
    segments = [s.strip() for s in BASH_SPLIT_RE.split(command) if s.strip()]
    i = 0
    while i < len(segments) and CD_SEGMENT_RE.match(segments[i]):
        i += 1
    segments = segments[i:]
    if not segments:
        return True  # pure cd navigation: no work performed
    return all(EXEMPT_BASH_RE.match(s) for s in segments)


def state_dir():
    return os.path.expanduser(STATE_DIR)


def mode_file():
    return os.path.expanduser(MODE_FILE)


def get_mode():
    mode = os.environ.get("DELEGATION_GATE_MODE")
    if not mode:
        try:
            with open(mode_file()) as fh:
                mode = fh.read().strip()
        except Exception:
            mode = None
    mode = (mode or "").strip()
    if mode not in RECOGNIZED_MODES:
        return "guard"  # unset or unrecognized never silently weakens the gate
    return mode


def lane_state_dir():
    return os.path.expanduser(os.environ.get("LANE_STATE_DIR") or LANE_STATE_DIR)


def get_lane(session_id):
    """The lane declared for this session, or "unset" when there is no
    readable declaration. Anything unexpected — missing dir, absent file,
    truncated JSON, a lane name this gate doesn't know — reads as "unset",
    which is the pre-lane behavior and therefore never the weaker one.
    Session ids are sanitized the same way lane.sh sanitizes them so both
    sides agree on the filename."""
    try:
        sid = re.sub(r"[^A-Za-z0-9._-]", "", session_id)
        if not sid:
            return "unset"
        with open(os.path.join(lane_state_dir(), f"{sid}.json")) as fh:
            state = json.load(fh)
        if isinstance(state, dict) and state.get("lane") in KNOWN_LANES:
            return state["lane"]
    except Exception:
        pass
    return "unset"


def _int_env(name, default):
    try:
        return int(os.environ.get(name, default))
    except Exception:
        return default


def warn_at():
    return _int_env("DELEGATION_GATE_WARN_AT", 8)


def warn_every():
    return _int_env("DELEGATION_GATE_WARN_EVERY", 8)


def deny_at():
    """Streak at which the Bash/read notes fire. Historically the deny
    threshold -- the env var keeps its name, the gate no longer denies."""
    return _int_env("DELEGATION_GATE_DENY_AT", 8)


def _empty_state():
    return {
        "streak": 0,
        "warned_at": 0,
        "max_streak": 0,
        "warns": 0,
        "denies": 0,  # advisory gate: kept in the schema, never incremented
        "ro_pending": 0,
    }


def load_state(path):
    try:
        with open(path) as fh:
            state = json.load(fh)
        if not isinstance(state, dict):
            return _empty_state()
        streak = int(state.get("streak", 0))
        if "warned_at" in state:
            warned_at = int(state.get("warned_at", 0))
        elif state.get("warned"):
            # Legacy one-shot boolean, no watermark recorded: treat the
            # loaded streak as the last-warned point so an upgraded
            # session doesn't immediately re-warn.
            warned_at = streak
        else:
            warned_at = 0
        return {
            "streak": streak,
            "warned_at": warned_at,
            "max_streak": int(state.get("max_streak", 0)),
            "warns": int(state.get("warns", 0)),
            "denies": int(state.get("denies", 0)),
            "ro_pending": int(state.get("ro_pending", 0)),
        }
    except Exception:
        return _empty_state()


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, path)


def gc_old_state(directory, keep_path):
    """Best-effort: unlink sibling *.json state files untouched for 7+
    days. Never allowed to fail the hook — any error here is swallowed."""
    try:
        cutoff = time.time() - GC_AGE_SECONDS
        for name in os.listdir(directory):
            if not name.endswith(".json"):
                continue
            path = os.path.join(directory, name)
            if path == keep_path:
                continue
            try:
                if os.path.getmtime(path) < cutoff:
                    os.unlink(path)
            except OSError:
                pass
    except Exception:
        pass


def _edit_target_path(payload, tool_name):
    tool_input = payload.get("tool_input") or {}
    if tool_name == "NotebookEdit":
        path = tool_input.get("notebook_path")
    else:
        path = tool_input.get("file_path")
    if not path:
        return None
    path = os.path.expanduser(path)
    if not os.path.isabs(path):
        path = os.path.abspath(path)
    return path


def is_exempt_edit(payload, tool_name):
    """True iff this Edit/Write/NotebookEdit targets the orchestrator's own
    seat -- a plan file, the harness auto-memory dir, or a scratchpad -- and
    is therefore not counted toward the streak at all. Must be PROVEN from
    an explicit, resolvable path: if no path can be determined, this returns
    False (counts like any other edit); the exemption is never the default."""
    path = _edit_target_path(payload, tool_name)
    if not path:
        return False
    if "/.claude/plans/" in path:
        return True
    if MEMORY_DIR_RE.search(path):
        return True
    if SCRATCHPAD_RE.search(path):
        return True
    return False


def emit_note(text):
    """The gate is advisory: what used to be a deny is this -- the same
    text, carried as an allow + additionalContext note. Nothing this hook
    emits can stop a tool call."""
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "additionalContext": text,
        }
    }))


def emit_warn(streak):
    base = (
        f"[delegation-gate] {streak} consecutive inline tool calls in the main "
        "loop — batch remaining recon into a scout (Agent tool, "
        "subagent_type=scout), or hand edits to an executor slice: "
        "`orca-dispatch <bead>` when Orca is reachable, Agent"
        "(subagent_type=executor, model=<worker rung>) otherwise. Streak "
        "resets when you use the Agent tool."
    )
    text = base
    if streak >= 2 * warn_at():
        text += (
            " Delegating per the tiering protocol IS the user's standing "
            "request — the harness's default \"only call the Agent tool "
            "when the user asks\" rule does not apply in this container."
        )
    if streak >= 6 * warn_at():
        text += (
            " Economics: every inline read here is re-billed at the "
            "orchestrator's rate on every later turn, while a scout's "
            "reads bill once at the recon tier and are discarded on return."
        )
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "additionalContext": text,
        }
    }))


def emit_express_warn(streak):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "additionalContext": (
                f"[delegation-gate] express lane, {streak} inline tool calls "
                "— express tasks are small by definition. Mis-routed? "
                "Escalate (`lane standard --why …`) or finish now."
            ),
        }
    }))


def main():
    payload = json.load(sys.stdin)
    tool_name = payload.get("tool_name")

    if not is_main_loop(payload):
        return  # subagent (or unrecognized schema): never gate, never count

    session_id = payload.get("session_id")
    if not session_id:
        return

    sdir = state_dir()
    os.makedirs(sdir, exist_ok=True)
    state_path = os.path.join(sdir, f"{session_id}.json")
    gc_old_state(sdir, state_path)

    if tool_name in RESET_TOOLS:
        # Delegation happened: clear the streak and the warn watermark,
        # but keep the session's cumulative drift metrics.
        state = load_state(state_path)
        state["streak"] = 0
        state["warned_at"] = 0
        state["ro_pending"] = 0
        save_state(state_path, state)
        return  # no output at all for Agent/Workflow -- never contend with tier-gate

    if tool_name == "Bash":
        command = (payload.get("tool_input") or {}).get("command")
        if is_exempt_bash(command):
            return  # exempt housekeeping: no count, no note
    elif tool_name not in COUNTED_TOOLS:
        return  # not a tool this gate tracks
    elif tool_name in EDIT_TOOLS and is_exempt_edit(payload, tool_name):
        return  # plans / memory / scratchpad: the orchestrator's own seat

    state = load_state(state_path)

    if tool_name in READONLY_TOOLS:
        # Half weight: one streak tick per two read-only calls. The odd
        # call is held in ro_pending and produces nothing -- the streak
        # did not move, so no threshold can have been crossed.
        state["ro_pending"] += 1
        if state["ro_pending"] < 2:
            save_state(state_path, state)
            return
        state["ro_pending"] = 0

    state["streak"] += 1
    streak = state["streak"]
    if streak > state["max_streak"]:
        state["max_streak"] = streak

    mode = get_mode()

    if mode == "off":
        save_state(state_path, state)
        return

    is_edit_tool = tool_name in EDIT_TOOLS
    lane = get_lane(session_id)
    express = lane == "express"

    if express:
        # The lane already says this is a one-edit, few-lookup task: no
        # note in any mode, and its own warn instead of the delegation
        # nudge (which would tell the session to do the opposite of the
        # lane it declared). The watermark is shared with that nudge, so
        # escalating mid-prompt cannot double-warn.
        if streak >= EXPRESS_WARN_AT and (
            state["warned_at"] == 0 or streak - state["warned_at"] >= EXPRESS_WARN_EVERY
        ):
            state["warned_at"] = streak
            state["warns"] += 1
            save_state(state_path, state)
            emit_express_warn(streak)
            return
        save_state(state_path, state)
        return

    if (
        mode in ("guard", "enforce")
        and is_edit_tool
        and lane in ("deep", "unset")
        and (state["warned_at"] == 0 or streak - state["warned_at"] >= warn_every())
    ):
        # Advisory, and on the shared cadence: one note per WARN_EVERY
        # calls, never one per edit -- a note on every Write is the noise
        # this gate exists to cut.
        state["warns"] += 1
        state["warned_at"] = streak
        save_state(state_path, state)
        emit_note(
            "[delegation-gate] Implementation edits are the executor's "
            "seat — dispatch the slice: `orca-dispatch <bead>` when Orca is "
            "reachable, else Agent(subagent_type=executor, model=<worker "
            "rung>). Either way give it a slice spec (objective, files in "
            "scope, output contract, boundaries). The orchestrator reviews "
            "the diff instead of writing it."
        )
        return

    if mode in ("guard", "enforce") and tool_name == "Bash" and streak >= deny_at():
        # A non-exempt Bash call is inline work exactly like an Edit --
        # `cat` costs the orchestrator what Read costs, and a grep sweep
        # costs more. The exempt list above (bd/git/bats/lane/tier-…) is
        # how the session steers and is never counted, so what lands here
        # is recon or editing that belongs in a worker's context.
        # EVERY lane but express: unlike the edit note, this one fires in
        # lane standard too, because standard is where most sessions run
        # and eight inline shell calls is a streak in any lane. express
        # never reaches here -- its branch above returns first.
        state["warns"] += 1
        state["warned_at"] = streak
        save_state(state_path, state)
        emit_note(
            f"[delegation-gate] {streak} inline calls — this Bash "
            "call is recon or editing the orchestrator should not be doing "
            "itself. Recon: Agent(subagent_type=scout) with the question "
            "and the paths. Edits and builds: `orca-dispatch <bead>` when "
            "Orca is reachable, else Agent(subagent_type=executor, "
            "model=<worker rung>), with a slice spec (objective, files, "
            "contract, boundaries). Streak resets on Agent use; `bd`, "
            "`git`, `gh`, `bats`, `lane` and `tier-` calls never count."
        )
        return

    if mode == "enforce" and not is_edit_tool and streak >= deny_at():
        state["warns"] += 1
        state["warned_at"] = streak
        save_state(state_path, state)
        emit_note(
            f"[delegation-gate] {streak} inline calls — batch the "
            "remaining reads into a scout (Agent tool, subagent_type=scout) and "
            "work from its summary. Streak resets on Agent use."
        )
        return

    # warn-only/guard/enforce all share the same repeating warn cadence
    # for whatever did not already draw a note above.
    if streak >= warn_at() and (state["warned_at"] == 0 or streak - state["warned_at"] >= warn_every()):
        state["warned_at"] = streak
        state["warns"] += 1
        save_state(state_path, state)
        emit_warn(streak)
        return

    save_state(state_path, state)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # fail silent and open: a broken gate must never block a tool call
    sys.exit(0)
