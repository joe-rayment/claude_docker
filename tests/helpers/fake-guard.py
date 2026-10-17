#!/usr/bin/env python3
"""A fake OpenRouter guard for tests/activity-summarize.bats (claude-orca-7rk.2).

Serves the one route the activity summarizer calls, on a free 127.0.0.1 port,
records every request, and answers from a config file you can rewrite while
it runs. Nothing here reaches the network and no real key is ever involved:
the "Bearer" value it sees is whatever fake token the test planted.

Usage: python3 tests/helpers/fake-guard.py --dir D [--config FILE]

Writes into <D>:
  port            the port it bound (written once it is listening)
  requests.jsonl  one JSON line per request, in order:
                  {"n": 1, "method": "POST", "path": "/chat/completions",
                   "authorization": "Bearer fake...", "body": <parsed JSON or
                   the raw text if it was not JSON>}
The config (default <D>/config.json, re-read on every request) may hold:
  status    HTTP status to answer with (default 200)
  reply     the assistant text for a 200 (default "Fake page.")
  model     the "model" the response reports (default: echo the request's)
  usage     the "usage" object to return (default: none)
  delay_s   seconds to wait before answering (default 0)
  raw       a string sent verbatim as the body instead of the JSON reply
python3 stdlib only. SIGTERM stops it.
"""
import argparse
import json
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_lock = threading.Lock()


def make_handler(outdir, config_path):
    log_path = os.path.join(outdir, "requests.jsonl")

    def read_config():
        try:
            with open(config_path, encoding="utf-8") as fh:
                return json.load(fh)
        except (OSError, ValueError):
            return {}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):  # keep the test output quiet
            pass

        def _answer(self, status, payload, raw=None):
            data = raw.encode("utf-8") if raw is not None else json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            text = self.rfile.read(length).decode("utf-8", "replace") if length else ""
            try:
                body = json.loads(text)
            except ValueError:
                body = text
            with _lock:
                try:
                    with open(log_path, encoding="utf-8") as fh:
                        n = sum(1 for _ in fh) + 1
                except OSError:
                    n = 1
                with open(log_path, "a", encoding="utf-8") as fh:
                    fh.write(json.dumps({
                        "n": n, "method": "POST", "path": self.path,
                        "authorization": self.headers.get("Authorization", ""),
                        "body": body}) + "\n")
            cfg = read_config()
            if cfg.get("delay_s"):
                time.sleep(float(cfg["delay_s"]))
            status = int(cfg.get("status", 200))
            if cfg.get("raw") is not None:
                return self._answer(status, None, raw=cfg["raw"])
            if status != 200:
                return self._answer(status, {"error": {"message": "fake guard says no", "code": status}})
            asked = body.get("model") if isinstance(body, dict) else None
            payload = {"id": "gen-fake", "model": cfg.get("model", asked),
                       "choices": [{"index": 0, "finish_reason": "stop",
                                    "message": {"role": "assistant",
                                                "content": cfg.get("reply", "Fake page.")}}]}
            if cfg.get("usage") is not None:
                payload["usage"] = cfg["usage"]
            self._answer(200, payload)

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--config")
    args = ap.parse_args()
    os.makedirs(args.dir, exist_ok=True)
    config = args.config or os.path.join(args.dir, "config.json")
    srv = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(args.dir, config))
    srv.daemon_threads = True
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=srv.shutdown).start())
    with open(os.path.join(args.dir, "port.tmp"), "w", encoding="utf-8") as fh:
        fh.write(str(srv.server_address[1]))
    os.replace(os.path.join(args.dir, "port.tmp"), os.path.join(args.dir, "port"))
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
