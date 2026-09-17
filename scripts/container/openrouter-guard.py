#!/usr/bin/env python3
"""openrouter-guard -- the in-VM chokepoint between every agent-side client
and openrouter.ai (claude-orca-qa2.20).

The user's rule: their data never routes to China. On OpenRouter the model
decides nothing -- GLM is served by China-based hosts as well as US/EU ones --
so the *provider set* has to be pinned, and pinned somewhere a client cannot
edit. That place is here.

The guard is the only process in the VM that holds the real OPENROUTER_API_KEY.
Clients (OpenCode, Codex, delegate.sh) get a random guard token and the guard's
loopback base URL instead. It is handed the key over a mode-600 file it reads
once and unlinks (see read_api_key), because the guard runs as the same uid as
every agent terminal here: a key in argv or in the environment is a key
`ps -ef` and /proc/<pid>/environ give away for as long as the guard is up,
which is this whole design inverted (claude-orca-qa2.25). For every completion request it:

  * refuses anything that does not carry the guard token (401), so a leaked
    or guessed client config cannot reach OpenRouter at all;
  * rewrites the JSON body's `provider` object to
        {only: <config/provider-policy.json .allow[].slug>,
         allow_fallbacks: false,
         data_collection: "deny"}
    keeping a client-supplied `order` only when every entry is allowlisted
    (anything else is dropped and logged);
  * swaps the token for the real key and forwards to openrouter.ai, streaming
    the answer (SSE included) straight back;
  * appends one JSON line per request to <run-dir>/openrouter-guard.log.

Standard library only -- this runs in the image with no pip install.

Usage:
    openrouter-guard.py [--port 4141] [--policy <file>] [--run-dir <dir>]

Environment:
    CLAUDE_ORCA_GUARD_KEY_FILE  a mode-600 file holding the real key. This is
                           how the entrypoint and provision.d hand it over:
                           the guard reads it once and unlinks it, so the key
                           is on disk for the guard's startup rather than in
                           /proc/<pid>/environ for its whole uptime
                           (claude-orca-qa2.25). Named-but-missing, or empty,
                           is a refusal to start -- never a silent fallback.
    OPENROUTER_API_KEY     the real key, for a guard started BY HAND with no
                           key file named. Scrubbed from os.environ at startup
                           either way, so nothing this process spawns sees it.
    OPENROUTER_GUARD_TOKEN the token clients must present; generated if unset
    OPENROUTER_UPSTREAM    upstream base (default https://openrouter.ai; the
                           test suite points this at a stub server)
    CLAUDE_ORCA_RUN_DIR    run dir (default $PROJECT_DIR/.claude-dev/run)
    PROJECT_DIR            the project root, when CLAUDE_ORCA_RUN_DIR is unset
    OPENROUTER_GUARD_RETRY_MAX
                           retries on an upstream 429/502/503/529 before
                           passing the failure through unchanged (default 4;
                           0 disables retries -- claude-orca-m57)
    OPENROUTER_GUARD_RETRY_BASE_S
                           exponential backoff base in seconds (default 2.0:
                           2,4,8,16); an upstream Retry-After header wins
                           over the backoff when present, capped at 30s
"""

import argparse
import hmac
import http.client
import json
import os
import secrets
import sys
import threading
import time
import urllib.parse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Paths whose POST bodies carry a provider preference worth forcing. Anything
# else (GET, an unknown path, a non-JSON body) is proxied untouched -- the
# guard is a policy chokepoint, not a rewriter of traffic it does not model.
COMPLETION_PATHS = (
    "/api/v1/chat/completions",
    "/api/v1/completions",
    "/api/v1/responses",
    "/api/v1/messages",
)

# RFC 7230 6.1: never forwarded in either direction.
HOP_BY_HOP = frozenset(
    (
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailers",
        "transfer-encoding",
        "upgrade",
    )
)

DEFAULT_UPSTREAM = "https://openrouter.ai"
DEFAULT_PORT = 4141
LOG_LOCK = threading.Lock()

# claude-orca-m57: a transient upstream failure the client cannot see past --
# a 429 an agent's own TUI just prints and stops on -- is absorbed here
# instead, with exponential backoff, since this is the one place every
# request already passes through.
RETRYABLE_STATUSES = frozenset((429, 502, 503, 529))
DEFAULT_RETRY_MAX = 4
DEFAULT_RETRY_BASE_S = 2.0
RETRY_AFTER_CAP_S = 30.0


def env_int(name, default):
    raw = (os.environ.get(name, "") or "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def env_float(name, default):
    raw = (os.environ.get(name, "") or "").strip()
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def compute_sleep_s(attempt, base_s, retry_after_header):
    """Seconds to sleep before retry number `attempt + 1`.

    An upstream Retry-After wins outright when present and parseable --
    the server told us exactly how long, so guessing with backoff instead
    would ignore it. Otherwise: base_s * 2**attempt (2, 4, 8, 16 at the
    defaults). Either way, capped at RETRY_AFTER_CAP_S so a bad/huge header
    or a runaway attempt count cannot stall a request indefinitely.
    """
    if retry_after_header:
        try:
            return min(float(retry_after_header), RETRY_AFTER_CAP_S)
        except ValueError:
            pass
    return min(base_s * (2 ** attempt), RETRY_AFTER_CAP_S)


def default_run_dir():
    run = os.environ.get("CLAUDE_ORCA_RUN_DIR", "")
    if run:
        return run
    project = os.environ.get("PROJECT_DIR", "") or os.getcwd()
    return os.path.join(project, ".claude-dev", "run")


def default_policy_file():
    # ../../config/provider-policy.json relative to this script, i.e. the
    # template's own copy -- the same file config-sync ships.
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(os.path.dirname(here), "..", "config", "provider-policy.json")


def load_policy(path):
    with open(path, "r", encoding="utf-8") as fh:
        policy = json.load(fh)
    allow = [entry["slug"] for entry in policy.get("allow", []) if entry.get("slug")]
    if not allow:
        raise SystemExit(
            "openrouter-guard: %s has an empty allowlist -- refusing to start "
            "(a guard with nothing allowed is a guard that forwards nothing)" % path
        )
    missing = [e.get("slug", "?") for e in policy.get("allow", []) if not e.get("country")]
    if missing:
        raise SystemExit(
            "openrouter-guard: %s allows providers with no country note (%s) -- "
            "refusing to start" % (path, ", ".join(missing))
        )
    force = policy.get("force", {})
    return {
        "allow": allow,
        "allow_fallbacks": bool(force.get("allow_fallbacks", False)),
        "data_collection": force.get("data_collection", "deny"),
    }


def read_api_key():
    """The real key, off disk and gone again (claude-orca-qa2.25).

    Returns (key, problem). `problem` is the sentence to print when there is
    no key; it always names the key file, because the file is the supported
    way in and an operator staring at run/openrouter-guard.log needs to know
    which path to look at.

    Two scrubs, and they are not the same scrub. Popping OPENROUTER_API_KEY
    out of os.environ keeps the key out of anything this process later spawns
    or dumps -- but it does NOT rewrite /proc/<pid>/environ, which the kernel
    fixed at exec and hands to any same-uid reader forever. Only the caller
    can do that, by never putting the key there: entrypoint.sh and
    provision.d/70-openrouter-guard start us with `env -u OPENROUTER_API_KEY`
    and a key file instead.
    """
    env_key = (os.environ.pop("OPENROUTER_API_KEY", "") or "").strip()
    path = (os.environ.pop("CLAUDE_ORCA_GUARD_KEY_FILE", "") or "").strip()

    if not path:
        if env_key:
            return env_key, ""
        return "", (
            "openrouter-guard: no key file (CLAUDE_ORCA_GUARD_KEY_FILE) and no "
            "OPENROUTER_API_KEY -- the guard is the only holder of the real key "
            "and has nothing to forward with; not starting."
        )

    # Named: authoritative. A guard that cannot read the file its starter
    # promised must not quietly fall back to an environment every terminal in
    # this container can read.
    try:
        with open(path, "r", encoding="utf-8") as fh:
            key = fh.read().strip()
    except OSError as exc:
        return "", (
            "openrouter-guard: cannot read the key file %s (%s) -- the guard is "
            "the only holder of the real key and has nothing to forward with; "
            "not starting." % (path, exc)
        )
    finally:
        # Read once. Gone whether it parsed or not: a key file left behind is
        # the exposure this indirection exists to close.
        try:
            os.unlink(path)
        except OSError:
            pass

    if not key:
        return "", (
            "openrouter-guard: the key file %s is empty -- the guard is the only "
            "holder of the real key and has nothing to forward with; not "
            "starting." % path
        )
    return key, ""


def resolve_token(run_dir):
    token = os.environ.get("OPENROUTER_GUARD_TOKEN", "").strip()
    if not token:
        token = secrets.token_urlsafe(32)
    os.makedirs(run_dir, exist_ok=True)
    path = os.path.join(run_dir, "openrouter-guard.token")
    # Written before anyone can read it: create 600, then fill.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(token + "\n")
    os.chmod(path, 0o600)
    return token, path


def presented_token(headers):
    auth = headers.get("Authorization", "") or ""
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    if auth:
        return auth.strip()
    return (headers.get("x-api-key", "") or "").strip()


def force_provider(body_bytes, policy):
    """Rewrite the request body. Returns (bytes, model, forced, order_dropped)."""
    try:
        payload = json.loads(body_bytes.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return body_bytes, None, False, False
    if not isinstance(payload, dict):
        return body_bytes, None, False, False

    client = payload.get("provider")
    client = client if isinstance(client, dict) else {}
    order = client.get("order")
    keep_order = None
    order_dropped = False
    if isinstance(order, list) and order:
        if all(isinstance(p, str) and p in policy["allow"] for p in order):
            keep_order = list(order)
        else:
            order_dropped = True

    provider = {
        "only": list(policy["allow"]),
        "allow_fallbacks": policy["allow_fallbacks"],
        "data_collection": policy["data_collection"],
    }
    if keep_order is not None:
        provider["order"] = keep_order
    payload["provider"] = provider

    model = payload.get("model")
    return (
        json.dumps(payload).encode("utf-8"),
        model if isinstance(model, str) else None,
        True,
        order_dropped,
    )


class Guard(BaseHTTPRequestHandler):
    server_version = "openrouter-guard/1"
    protocol_version = "HTTP/1.1"

    # -- plumbing ---------------------------------------------------------
    def log_message(self, fmt, *args):  # noqa: A003 -- BaseHTTPRequestHandler API
        pass

    @property
    def cfg(self):
        return self.server.guard_cfg

    def audit(self, **fields):
        entry = {"ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
        entry.update(fields)
        line = json.dumps(entry, sort_keys=True)
        with LOG_LOCK:
            try:
                with open(self.cfg["log_file"], "a", encoding="utf-8") as fh:
                    fh.write(line + "\n")
            except OSError:
                pass
        sys.stderr.write(line + "\n")
        sys.stderr.flush()

    def refuse(self, code, message):
        body = json.dumps({"error": {"code": code, "message": message}}).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    # -- verbs ------------------------------------------------------------
    def do_GET(self):
        self.proxy("GET")

    def do_POST(self):
        self.proxy("POST")

    def do_DELETE(self):
        self.proxy("DELETE")

    def proxy(self, method):
        cfg = self.cfg
        if not hmac.compare_digest(presented_token(self.headers), cfg["token"]):
            self.audit(
                path=self.path,
                model=None,
                providers_forced=False,
                client_order_dropped=False,
                status=401,
                refused="bad or missing guard token",
            )
            self.refuse(
                401,
                "openrouter-guard: this request did not carry the guard token. "
                "Agent terminals get the token in OPENROUTER_API_KEY and reach "
                "OpenRouter only through this guard; the real key is not "
                "available in the VM.",
            )
            return

        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""

        model = None
        forced = False
        order_dropped = False
        path = urllib.parse.urlsplit(self.path).path
        if method == "POST" and path in COMPLETION_PATHS:
            body, model, forced, order_dropped = force_provider(body, cfg["policy"])

        headers = {}
        for key, value in self.headers.items():
            low = key.lower()
            if low in HOP_BY_HOP or low in ("host", "content-length", "authorization", "x-api-key"):
                continue
            headers[key] = value
        headers["Authorization"] = "Bearer " + cfg["api_key"]
        headers["Host"] = cfg["upstream_host_header"]
        if body:
            headers["Content-Length"] = str(len(body))

        retry_max = cfg["retry_max"]
        retry_base_s = cfg["retry_base_s"]
        attempt = 0
        while True:
            try:
                conn = cfg["connect"]()
                conn.request(method, self.path, body=body or None, headers=headers)
                response = conn.getresponse()
            except Exception as exc:  # upstream unreachable / TLS failure / ...
                self.audit(
                    path=self.path,
                    model=model,
                    providers_forced=forced,
                    client_order_dropped=order_dropped,
                    status=502,
                    error=str(exc),
                )
                self.refuse(502, "openrouter-guard: upstream request failed: %s" % exc)
                return

            if response.status not in RETRYABLE_STATUSES or attempt >= retry_max:
                break

            # Nothing has reached the client yet -- send_response has not
            # been called -- so retrying here, streaming request or not,
            # never double-delivers a byte of a partial body.
            sleep_s = compute_sleep_s(attempt, retry_base_s, response.getheader("Retry-After"))
            try:
                response.read()
            except Exception:
                pass
            conn.close()
            attempt += 1
            self.audit(
                path=self.path,
                model=model,
                providers_forced=forced,
                client_order_dropped=order_dropped,
                retry=attempt,
                status=response.status,
                sleep_s=sleep_s,
            )
            time.sleep(sleep_s)

        exhausted = attempt > 0 and attempt >= retry_max and response.status in RETRYABLE_STATUSES
        audit_fields = dict(
            path=self.path,
            model=model,
            providers_forced=forced,
            client_order_dropped=order_dropped,
            status=response.status,
        )
        if exhausted:
            audit_fields["retries_exhausted"] = True
        self.audit(**audit_fields)

        # Same status, same headers (minus hop-by-hop), body streamed through
        # in chunks so an SSE answer reaches the client as it arrives rather
        # than after the last token.
        self.send_response(response.status)
        for key, value in response.getheaders():
            if key.lower() in HOP_BY_HOP or key.lower() == "content-length":
                continue
            self.send_header(key, value)
        content_length = response.getheader("Content-Length")
        if content_length is not None:
            self.send_header("Content-Length", content_length)
        # No keep-alive: without a Content-Length the body is delimited by the
        # close, which is what makes a chunked/SSE upstream safe to relay.
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            while True:
                chunk = response.read(4096)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            try:
                conn.close()
            except Exception:
                pass


def make_connector(upstream):
    parts = urllib.parse.urlsplit(upstream)
    host = parts.hostname or "openrouter.ai"
    port = parts.port
    if parts.scheme == "http":
        def connect():
            return http.client.HTTPConnection(host, port, timeout=600)
    else:
        def connect():
            return http.client.HTTPSConnection(host, port, timeout=600)
    host_header = host if port is None else "%s:%d" % (host, port)
    return connect, host_header


def main(argv):
    parser = argparse.ArgumentParser(prog="openrouter-guard")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--policy", default=default_policy_file())
    parser.add_argument("--run-dir", default=default_run_dir())
    args = parser.parse_args(argv)

    api_key, problem = read_api_key()
    if not api_key:
        sys.stderr.write(problem + "\n")
        sys.stderr.flush()
        return 2

    try:
        policy = load_policy(args.policy)
    except FileNotFoundError:
        sys.stderr.write("openrouter-guard: policy file not found: %s\n" % args.policy)
        return 2
    except ValueError as exc:
        sys.stderr.write("openrouter-guard: policy file %s is not valid JSON: %s\n" % (args.policy, exc))
        return 2

    token, token_file = resolve_token(args.run_dir)
    upstream = os.environ.get("OPENROUTER_UPSTREAM", DEFAULT_UPSTREAM).rstrip("/")
    connect, host_header = make_connector(upstream)
    retry_max = env_int("OPENROUTER_GUARD_RETRY_MAX", DEFAULT_RETRY_MAX)
    retry_base_s = env_float("OPENROUTER_GUARD_RETRY_BASE_S", DEFAULT_RETRY_BASE_S)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Guard)
    server.daemon_threads = True
    server.guard_cfg = {
        "api_key": api_key,
        "token": token,
        "policy": policy,
        "connect": connect,
        "upstream_host_header": host_header,
        "log_file": os.path.join(args.run_dir, "openrouter-guard.log"),
        "retry_max": retry_max,
        "retry_base_s": retry_base_s,
    }

    sys.stderr.write(
        "openrouter-guard: listening on http://127.0.0.1:%d/api/v1 -> %s; "
        "%d providers allowed, fallbacks %s, data_collection %s; token in %s\n"
        % (
            args.port,
            upstream,
            len(policy["allow"]),
            policy["allow_fallbacks"],
            policy["data_collection"],
            token_file,
        )
    )
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
