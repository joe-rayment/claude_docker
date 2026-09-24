"""Helpers the Python hooks share (contract_gate, delegation_gate,
cost_mirror). Standard library only; imported, so its bytecode is cached."""
import os
import re

# Where one Bash command line splits into separate commands: `&&`, `||`,
# `|`, `;` and newlines. Deliberately not quote-aware (see contract_gate).
BASH_SPLIT_RE = re.compile(r"&&|\|\||\||;|\n")

_UNSAFE_ID_RE = re.compile(r"[^A-Za-z0-9._-]+")


def claude_config_dir():
    """$CLAUDE_CONFIG_DIR if set, else the default under the user's home
    (spelled via expanduser, never as a literal -- see scripts/lib/paths.sh
    and the grep gate in tests/config-sync.bats)."""
    override = os.environ.get("CLAUDE_CONFIG_DIR")
    if override:
        return override
    return os.path.join(os.path.expanduser("~"), ".claude")


def safe_session_id(raw):
    """raw with everything outside [A-Za-z0-9._-] removed, the same allowlist
    as lane.sh's sanitize_id(), so a hostile id can never leave the state
    directory; "" for anything that isn't a string."""
    if not isinstance(raw, str):
        return ""
    return _UNSAFE_ID_RE.sub("", raw)
