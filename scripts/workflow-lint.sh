#!/bin/sh
# workflow-lint — PreToolUse hook (matcher: Workflow): deny workflow scripts
# whose agent() calls omit an explicit model.
#
# Why here: Workflow's internal agent() spawns run as the built-in
# workflow-subagent type, which has no model binding and inherits the
# main-loop model — the single largest measured misroute on this machine
# (18.1M cache-read tokens at the top tier; bead mi9). Those internal spawns
# are not reliably reachable by an Agent-matched hook, but the SCRIPT is: the
# orchestrator authors it and it arrives in tool_input.script, so the model
# requirement is enforced at the only boundary we own with certainty. A deny
# costs one round trip against the fan-out it guards — the orchestrator
# rewrites the script it wrote one message earlier.
#
# Best-effort BY DESIGN (a guardrail, not a JS parser): the scanner masks out
# string/template/regex literals and comments (a small char-by-char lexer)
# so an `agent(` token inside prose or a string is ignored, then walks from
# each real call's opening paren forward (bounded by WORKFLOW_LINT_WINDOW
# lines), collecting the call's OWN argument list. Only a nested `agent(...)`
# call's parenthesised group is skipped; every other nested group — a plain
# helper call, an object/array literal, a ternary, a spread, Object.assign —
# is walked and collected like the rest of the call. So a nested call's
# `model:` does NOT satisfy an outer, modelless call (it must appear in that
# call's own opts), while opts assembled inline via a spread, a ternary,
# Object.assign, or a helper call that itself returns opts still count,
# since none of those route through a nested agent(. A multi-line prompt
# argument ahead of the opts object still doesn't hide it, since the whole
# argument span is scanned regardless of line count. An opts object a scan
# genuinely cannot see into — passed as a bare variable, with no `model:`
# token anywhere in the call (e.g. `agent(p, opts)`) — can be annotated with
#     /* workflow-lint: model-ok */
# on the call line through 2 lines past the line holding the matching close
# paren, to suppress. If a call runs past WORKFLOW_LINT_WINDOW, the forward
# walk stops early and the annotation window is measured from that
# truncation point rather than the true close paren, so an annotation for
# such a call belongs near the call itself, not after its distant close
# paren. Saved workflows invoked by {name} and unreadable scriptPath files
# pass through (fail open).
#
# WORKFLOW_LINT_MAX_PER_LINE (default 64) caps how many agent( call sites
# are examined per source line. Each match triggers a bounded forward walk;
# without a cap, a single pathological line packed with tens of thousands
# of agent( tokens forces that many walks over the same line, which is
# quadratic and can stall the hook for tens of seconds — a PreToolUse hook
# stall wedges the tool call it's guarding. Ordinary hand-written scripts
# never approach the cap; lines beyond it are simply not linted further
# (fail open for the excess, not a false deny).
#
# WORKFLOW_LINT_MAX_BYTES (default 500000) guards a companion hazard in the
# masking lexer itself: it builds each masked line via `out = out c`, one
# character at a time, which is quadratic in the length of a SINGLE line
# under mawk (measured on this container: ~118s for a ~3MB one-line
# script). Multi-line scripts are unaffected — the pathology needs one
# enormous line — but a script over the byte cap is skipped before the
# lexer ever runs and passes through untouched (fail open): no legitimate
# hand-written workflow script comes anywhere near half a megabyte, and a
# two-minute hook stall risking a harness hook timeout is worse than not
# linting an outlier that size.
#
# Known limit: an unterminated template literal or block comment masks
# everything after it to EOF (there's no closing delimiter to resync on),
# so any agent() calls past that point are not checked. Such a script is
# not valid JavaScript and cannot run anyway, so failing open there is
# preferable to emitting a misleading "missing model" deny.
#
# Env (mainly for tests): WORKFLOW_LINT_DISABLE=1 bypasses entirely.
# WORKFLOW_LINT_WINDOW (default 200) bounds the forward scan for a call's
# matching close paren, in lines from the call line. WORKFLOW_LINT_MAX_PER_LINE
# (default 64) bounds how many agent( calls are examined per line.
# WORKFLOW_LINT_MAX_BYTES (default 500000) is the size cap above which a
# script is not scanned at all (fail open).

set -u

[ "${WORKFLOW_LINT_DISABLE:-}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
# lib/hook.sh sits next to this file's directory whether it runs as
# scripts/workflow-lint.sh or through bin/workflow-lint (bin/lib links to
# scripts/lib).
case "$0" in
    (*/*) . "${0%/*}/lib/hook.sh" ;;
    (*)   . ./lib/hook.sh ;;
esac

IN=$(cat 2>/dev/null) || exit 0
[ -n "$IN" ] || exit 0

TOOL=$(printf '%s' "$IN" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL" = "Workflow" ] || exit 0

SCRIPT=$(printf '%s' "$IN" | jq -r '.tool_input.script // empty' 2>/dev/null)
if [ -z "$SCRIPT" ]; then
    SP=$(printf '%s' "$IN" | jq -r '.tool_input.scriptPath // empty' 2>/dev/null)
    [ -n "$SP" ] && [ -r "$SP" ] || exit 0   # named/saved workflow or unreadable: fail open
    SCRIPT=$(cat "$SP" 2>/dev/null) || exit 0
fi
[ -n "$SCRIPT" ] || exit 0

# Bounded-cost bail-out: the masking lexer below is quadratic in the length
# of a single line (see WORKFLOW_LINT_MAX_BYTES above). No legitimate
# workflow script comes anywhere near half a megabyte, and stalling this
# hook is worse than not scanning a script that size, so fail open here
# without ever reaching the lexer.
[ "${#SCRIPT}" -le "${WORKFLOW_LINT_MAX_BYTES:-500000}" ] || exit 0

OFFENDERS=$(printf '%s\n' "$SCRIPT" | awk -v WINDOW="${WORKFLOW_LINT_WINDOW:-200}" -v MAXPERLINE="${WORKFLOW_LINT_MAX_PER_LINE:-64}" '
function isagentparen(s, k,   q, w) {
    q = k - 1
    while (q >= 1 && (substr(s, q, 1) == " " || substr(s, q, 1) == "\t")) q--
    if (q < 5) return 0
    if (substr(s, q - 4, 5) != "agent") return 0
    w = (q - 5 >= 1) ? substr(s, q - 5, 1) : ""
    if (w == "") return 1
    return (w !~ /[A-Za-z0-9_$.]/)
}
function scancall(li, ci,   d, l, s, k, c, lim, buf, skip) {
    lim = li + WINDOW; if (lim > NLINES) lim = NLINES
    d = 0; skip = 0; TXT = ""
    for (l = li; l <= lim; l++) {
        s = M[l]; buf = ""
        for (k = (l == li) ? ci : 1; k <= length(s); k++) {
            c = substr(s, k, 1)
            if (c == "(") {
                d++
                if (skip) continue
                if (d > 1 && isagentparen(s, k)) { skip = d; continue }
                buf = buf c
                continue
            }
            if (c == ")") {
                if (skip) {
                    if (d == skip) skip = 0
                    d--
                    if (d <= 0) { TXT = TXT " " buf; EL = l; return }
                    continue
                }
                d--
                if (d <= 0) { TXT = TXT " " buf; EL = l; return }
                buf = buf c
                continue
            }
            if (!skip) buf = buf c
        }
        TXT = TXT " " buf
    }
    EL = lim
}
{ raw[NR] = $0 }
END {
    NLINES = NR
    st = "code"; sp = 0; brace[0] = 0; prev = ""
    for (i = 1; i <= NLINES; i++) {
        line = raw[i]; len = length(line); out = ""; ctext = ""; j = 1
        while (j <= len) {
            c = substr(line, j, 1)
            c2 = (j < len) ? substr(line, j + 1, 1) : ""
            if (st == "code") {
                if (c == "/" && c2 == "/") { st = "lc"; out = out "  "; j += 2; continue }
                if (c == "/" && c2 == "*") { st = "bc"; out = out "  "; j += 2; continue }
                if (c == "/" && (prev == "" || index("+-*/%=<>!&|^~?:;,({[", prev) > 0)) { st = "re"; cls = 0; out = out " "; j++; continue }
                if (c == "\047") { st = "sq"; out = out " "; j++; continue }
                if (c == "\"")   { st = "dq"; out = out " "; j++; continue }
                if (c == "`")    { st = "tpl"; out = out " "; j++; continue }
                if (c == "{") brace[sp]++
                else if (c == "}") {
                    if (brace[sp] > 0) brace[sp]--
                    else if (sp > 0) { sp--; st = "tpl"; out = out " "; j++; continue }
                }
                out = out c
                if (c != " " && c != "\t") prev = c
                j++; continue
            }
            if (st == "sq" || st == "dq") {
                if (c == "\\") { out = out "  "; j += 2; continue }
                if ((st == "sq" && c == "\047") || (st == "dq" && c == "\"")) { st = "code"; prev = "x"; out = out " "; j++; continue }
                out = out " "; j++; continue
            }
            if (st == "tpl") {
                if (c == "\\") { out = out "  "; j += 2; continue }
                if (c == "`") { st = "code"; prev = "x"; out = out " "; j++; continue }
                if (c == "$" && c2 == "{") { sp++; brace[sp] = 0; st = "code"; out = out "  "; j += 2; continue }
                out = out " "; j++; continue
            }
            if (st == "re") {
                if (c == "\\") { out = out "  "; j += 2; continue }
                if (c == "[") cls = 1
                else if (c == "]") cls = 0
                else if (c == "/" && !cls) { st = "code"; prev = "x"; out = out " "; j++; continue }
                out = out " "; j++; continue
            }
            if (st == "bc") {
                if (c == "*" && c2 == "/") { st = "code"; out = out "  "; j += 2; continue }
                ctext = ctext c; out = out " "; j++; continue
            }
            ctext = ctext c; out = out " "; j++          # line comment
        }
        M[i] = out
        if (ctext ~ /workflow-lint:[[:space:]]*model-ok/) annot[i] = 1
        if (st == "sq" || st == "dq" || st == "lc" || st == "re") st = "code"   # unterminated: resync at EOL
    }
    for (i = 1; i <= NLINES; i++) {
        s = M[i]; base = 0; rest = s; bad = 0; seen = 0
        while (match(rest, /(^|[^A-Za-z0-9_$.])agent[[:space:]]*\(/)) {
            if (++seen > MAXPERLINE) break
            p = base + RSTART + RLENGTH - 1        # column of the opening "("
            scancall(i, p)
            good = (TXT ~ /(^|[^A-Za-z0-9_$])model[[:space:]]*:/)      # require a word boundary before "model" so a key like remodel: cannot satisfy the guard
            if (!good) { for (l = i; l <= EL + 2 && l <= NLINES; l++) if (annot[l]) { good = 1; break } }
            if (!good) bad = 1
            base = p; rest = substr(s, p + 1)
        }
        if (bad) printf "  line %d: %s\n", i, substr(raw[i], 1, 100)
    }
}')

[ -n "$OFFENDERS" ] || exit 0

REASON="workflow-lint: every agent() call in a workflow script must set an explicit model, or the spawn inherits the orchestrator's (most expensive) model — the largest measured token leak on this machine. Offending call sites:
$OFFENDERS
Fix: add model: to each call's opts, choosing the cheapest capable tier (recon/mechanical -> the scout tier, implementation -> the worker tier; run tier-derive for the session's concrete ids). If a call's model is genuinely set dynamically, add /* workflow-lint: model-ok */ anywhere from the call line through 2 lines past the line holding its closing paren. Then re-issue the Workflow call with the revised script."

hook_deny "$REASON"
exit 0
