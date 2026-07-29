#!/usr/bin/env python3
"""delegation-gate — PreToolUse hook: a mechanical counter against the main
loop's inline-grinding habit (bead bd-arr).

Why: the delegation protocol (CLAUDE.md, project and user-global) asks the
orchestrator to push recon to scout, implementation to executor, and keep
its own tool calls to review/decide — but nothing enforces that; the main
loop can grind through reads/edits inline indefinitely and nothing in the
harness pushes back. This hook counts consecutive inline work-tool calls
made by the MAIN LOOP ONLY (never a subagent) and, depending on mode,
either nudges (warn) or blocks (enforce) once a streak crosses a threshold.
Calling the Agent (or Workflow) tool resets the streak to zero — that is
the "I delegated" signal.

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

Mode: env DELEGATION_GATE_MODE, else ~/.claude/delegation-gate.mode
(single word), else "warn".
  off      always silent allow (the streak is still counted, so switching
           modes mid-session picks up an accurate count).
  warn     allow, but a one-shot additionalContext note fires the first
           time the streak reaches DELEGATION_GATE_WARN_AT (default 4).
  enforce  Edit/Write/NotebookEdit are ALWAYS denied — an implementation
           edit is the executor's seat, streak or no. Read/Grep/Glob/Bash
           are denied once the streak reaches DELEGATION_GATE_DENY_AT
           (default 8). Every denial names the exact alternative (spawn a
           scout / spawn an executor) — never a dead end.

State: ~/.claude/cache/delegation-gate/<session_id>.json holds
{"streak": int, "warned": bool}. Missing/corrupt state starts fresh.
Opportunistic GC unlinks sibling state files untouched for 7+ days.

Output channel for warn (STEP 0): a channel probe (gateprobe/) fed a Read
call both hookSpecificOutput.additionalContext and a top-level
systemMessage from an ALLOW decision. Both showed up in the resulting
transcript only as inert "attachment" metadata (types
hook_additional_context / hook_system_message) — neither string was ever
folded into any actual user/assistant message content in that run, so
which channel an interactive session's model actually reads stayed
unproven either way (the probe necessarily ran headless via `claude -p`;
an interactive session may assemble context differently). Per the probe
brief's own fallback for exactly this ambiguity, this hook emits
additionalContext, the documented field for this purpose — revisit if
live interactive use shows the warn note never lands.

Failure posture: fail SILENT AND OPEN. Any error — malformed stdin,
unreadable state, an unwritable cache dir — exits 0 with no output.
Exempt from all of this: a short list of housekeeping Bash commands
(bd/git read-only/bats/dev-log/cost-mirror/tier-*/delegation-gate itself)
that are recon-adjacent bookkeeping, not the grinding this hook targets.
"""

import json
import os
import re
import sys
import time

STATE_DIR = "~/.claude/cache/delegation-gate"
MODE_FILE = "~/.claude/delegation-gate.mode"
GC_AGE_SECONDS = 7 * 24 * 3600

# Tools that are unconditionally counted work. Bash is handled separately
# below since it is only counted when NOT an exempt housekeeping command.
COUNTED_TOOLS = {"Read", "Grep", "Glob", "Edit", "Write", "NotebookEdit"}
RESET_TOOLS = {"Agent", "Workflow"}

EXEMPT_BASH_RE = re.compile(
    r"^\s*(bd|git (status|log|diff|show|add|commit|push|pull|restore|stash)"
    r"|bats|dev-log|cost-mirror|tier-|delegation-gate|run-tests|take-screenshot)\b"
)

# Compound-command handling: a single Bash tool call is often several
# shell commands chained together (the session-close protocol commonly
# writes `cd /workspace && bd close ... && git push`). EXEMPT_BASH_RE
# alone only ever sees the whole string, so it anchors on the FIRST
# command -- a leading `cd` made an otherwise all-exempt line count.
BASH_SPLIT_RE = re.compile(r"&&|\|\||\||;|\n")
CD_SEGMENT_RE = re.compile(r"^cd\b")


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
    if mode:
        return mode.strip()
    try:
        with open(mode_file()) as fh:
            m = fh.read().strip()
        if m:
            return m
    except Exception:
        pass
    return "warn"


def _int_env(name, default):
    try:
        return int(os.environ.get(name, default))
    except Exception:
        return default


def warn_at():
    return _int_env("DELEGATION_GATE_WARN_AT", 4)


def deny_at():
    return _int_env("DELEGATION_GATE_DENY_AT", 8)


def load_state(path):
    try:
        with open(path) as fh:
            state = json.load(fh)
        if not isinstance(state, dict):
            return {"streak": 0, "warned": False}
        return {
            "streak": int(state.get("streak", 0)),
            "warned": bool(state.get("warned", False)),
        }
    except Exception:
        return {"streak": 0, "warned": False}


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


def emit_deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))


def emit_warn(streak):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "additionalContext": (
                f"[delegation-gate] {streak} consecutive inline tool calls in the main "
                "loop — batch remaining recon into a scout (Agent tool, "
                "subagent_type=scout), or hand edits to an executor slice. Streak "
                "resets when you use the Agent tool."
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
        save_state(state_path, {"streak": 0, "warned": False})
        return  # no output at all for Agent/Workflow -- never contend with tier-gate

    if tool_name == "Bash":
        command = (payload.get("tool_input") or {}).get("command")
        if is_exempt_bash(command):
            return  # exempt housekeeping: no count, no deny
    elif tool_name not in COUNTED_TOOLS:
        return  # not a tool this gate tracks

    state = load_state(state_path)
    state["streak"] += 1
    streak = state["streak"]

    mode = get_mode()

    if mode == "off":
        save_state(state_path, state)
        return

    if mode == "enforce":
        if tool_name in ("Edit", "Write", "NotebookEdit"):
            save_state(state_path, state)
            emit_deny(
                "[delegation-gate enforce] Implementation edits are the executor's "
                "seat — spawn Agent(subagent_type=executor) with a slice spec "
                "(objective, files in scope, output contract, boundaries). The "
                "orchestrator reviews the diff instead of writing it."
            )
            return
        if streak >= deny_at():
            save_state(state_path, state)
            emit_deny(
                f"[delegation-gate enforce] {streak} inline calls — batch the "
                "remaining reads into a scout (Agent tool, subagent_type=scout) and "
                "work from its summary. Streak resets on Agent use."
            )
            return
        save_state(state_path, state)
        return

    # warn (default), and any unrecognized mode value, fall through here
    if streak == warn_at() or (streak > warn_at() and not state["warned"]):
        state["warned"] = True
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
