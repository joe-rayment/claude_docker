#!/usr/bin/env python3
"""A fake clipboard-bridge server for tests/clipboard-xclip.bats.

    clip-fake-server.py <socket> <log> <config.json>

Listens on a unix socket and answers one HTTP request per connection, like the
Mac's clip-serve behind clip-listen.  Every connection is logged to <log> as one
JSON line, so a test can prove which requests were made -- or that none were:

    {"t": <monotonic secs>, "method": "GET", "path": "/png", "length": 0, "body": "<utf-8 text>"}
    {"t": <monotonic secs>, "dropped": true}          (closed without an answer)

<config.json> is re-read on every connection:
    {"drop_first": 2,                       # close the first N connections unanswered
     "routes": {"GET /targets": [200, "image/png\\n"],
                "GET /png": [200, {"file": "/path/to.png"}],   # or a text body
                "POST /copy": [204, ""]}}
A route that is not listed answers 404.  The socket file is created before the
server says anything, so a test can wait for it to exist.
"""
import json
import os
import socket
import sys
import time


def read_request(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(65536)
        if not chunk:
            return None
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    method, path, _ = lines[0].split(" ", 2)
    length = 0
    for line in lines[1:]:
        name, _, value = line.partition(":")
        if name.strip().lower() == "content-length":
            length = int(value.strip())
    while len(rest) < length:
        chunk = conn.recv(65536)
        if not chunk:
            break
        rest += chunk
    return method, path, length, rest[:length]


def main():
    sock_path, log_path, cfg_path = sys.argv[1:4]
    if os.path.exists(sock_path):
        os.unlink(sock_path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(8)
    seen = 0
    while True:
        conn, _ = srv.accept()
        with conn:
            with open(cfg_path) as fh:
                cfg = json.load(fh)
            seen += 1
            if seen <= int(cfg.get("drop_first", 0)):
                with open(log_path, "a") as log:
                    log.write(json.dumps({"t": time.monotonic(), "dropped": True}) + "\n")
                continue
            req = read_request(conn)
            if req is None:
                continue
            method, path, length, body = req
            with open(log_path, "a") as log:
                log.write(json.dumps({"t": time.monotonic(), "method": method, "path": path,
                                      "length": length,
                                      "body": body.decode("utf-8", "replace")}) + "\n")
            status, payload = cfg.get("routes", {}).get("%s %s" % (method, path), [404, ""])
            if isinstance(payload, dict):
                with open(payload["file"], "rb") as fh:
                    payload = fh.read()
            elif isinstance(payload, str):
                payload = payload.encode()
            reason = {200: "OK", 204: "No Content", 404: "Not Found", 413: "Payload Too Large"}.get(status, "X")
            head = "HTTP/1.0 %d %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % (status, reason, len(payload))
            conn.sendall(head.encode() + payload)


if __name__ == "__main__":
    main()
