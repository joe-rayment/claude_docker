#!/usr/bin/env python3
"""A stub OpenAI (ChatGPT backend + auth server) for tests using real opencode.

Listens on 127.0.0.1 as an HTTP proxy. CONNECTs to chatgpt.com and
auth.openai.com are terminated with a generated test CA's leaf cert and
served by the routes below; every other host is tunnelled blind so the
rest of opencode's traffic keeps working. No traffic reaches OpenAI.

Usage: python3 tests/helpers/openai-stub.py --dir <D>

Writes into <D>: ca.key, ca.pem, leaf.key, leaf.pem, port, requests.jsonl.
Logs one JSON line per served request (the intercepted hosts only).
Env: STUB_REPLY -- assistant text the chat route answers with (STUB-OK).
python3 stdlib + the openssl CLI only.
"""
import argparse
import base64
import json
import os
import socket
import ssl
import subprocess
import threading
import time
from urllib.parse import parse_qsl, unquote

INTERCEPT_HOSTS = ("chatgpt.com", "auth.openai.com")
STUB_REPLY = os.environ.get("STUB_REPLY", "STUB-OK")

_log_lock = threading.Lock()
_token_lock = threading.Lock()
_token_calls = 0


def make_certs(d):
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048",
         "-keyout", os.path.join(d, "ca.key"),
         "-out", os.path.join(d, "ca.pem"),
         "-days", "2", "-nodes", "-subj", "/CN=claude-orca-test-ca"],
        check=True, capture_output=True)
    subprocess.run(
        ["openssl", "req", "-newkey", "rsa:2048",
         "-keyout", os.path.join(d, "leaf.key"),
         "-out", os.path.join(d, "leaf.csr"),
         "-nodes", "-subj", "/CN=chatgpt.com"],
        check=True, capture_output=True)
    ext = os.path.join(d, "san.ext")
    with open(ext, "w") as f:
        f.write("subjectAltName=DNS:chatgpt.com,DNS:auth.openai.com\n")
    subprocess.run(
        ["openssl", "x509", "-req",
         "-in", os.path.join(d, "leaf.csr"),
         "-CA", os.path.join(d, "ca.pem"),
         "-CAkey", os.path.join(d, "ca.key"),
         "-CAcreateserial",
         "-out", os.path.join(d, "leaf.pem"),
         "-days", "2", "-extfile", ext],
        check=True, capture_output=True)
    os.remove(os.path.join(d, "leaf.csr"))
    os.remove(ext)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def make_jwt(exp_epoch):
    header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    payload = b64url(json.dumps({
        "https://api.openai.com/auth": {"chatgpt_account_id": "acct-test"},
        "iat": int(time.time()),
        "exp": exp_epoch,
    }).encode())
    return f"{header}.{payload}.sig"


def log_request(d, host, method, path, headers, body_raw, content_type):
    if body_raw:
        if isinstance(body_raw, bytes):
            body_raw = body_raw.decode("utf-8", "replace")
        if content_type == "application/json" or \
                content_type and "json" in content_type:
            try:
                body = json.loads(body_raw)
            except ValueError:
                body = body_raw
        elif content_type == "application/x-www-form-urlencoded":
            body = {}
            for k, v in parse_qsl(body_raw, keep_blank_values=True):
                body[k] = v
        elif body_raw.lstrip()[:1] in ("{", "["):
            try:
                body = json.loads(body_raw)
            except ValueError:
                body = body_raw
        else:
            body = body_raw
    else:
        body = ""
    line = json.dumps({
        "host": host, "method": method, "path": path,
        "headers": headers, "body": body,
    })
    with _log_lock:
        with open(os.path.join(d, "requests.jsonl"), "a") as f:
            f.write(line + "\n")


class Request:
    def __init__(self, method, path, headers, body_raw):
        self.method = method
        self.path = path
        self.headers = headers
        self.body_raw = body_raw


def read_http_message(conn):
    """Read one HTTP request head + body. None when the peer closed."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        try:
            chunk = conn.recv(65536)
        except (socket.timeout, OSError):
            return None
        if not chunk:
            return None
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    parts = lines[0].split()
    if len(parts) < 2:
        return None
    method, path = parts[0].decode(), unquote(parts[1].decode())
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(b":")
        name = name.strip().lower().decode()
        headers[name] = value.strip().decode()
    if headers.get("transfer-encoding", "").lower() == "chunked":
        body, rest = read_chunked(conn, rest)
    else:
        length = int(headers.get("content-length", "0") or "0")
        while len(rest) < length:
            chunk = conn.recv(65536)
            if not chunk:
                break
            rest += chunk
        body, rest = rest[:length], rest[length:]
    return Request(method, path, headers, body), rest


def read_chunked(conn, rest):
    body = b""
    while True:
        while b"\r\n" not in rest:
            rest += conn.recv(65536)
        size_line, _, rest = rest.partition(b"\r\n")
        size = int(size_line.split(b";")[0], 16)
        if size == 0:
            # trailers until an empty line
            while b"\r\n" not in rest:
                rest += conn.recv(65536)
            _, _, rest = rest.partition(b"\r\n")
            return body, rest
        while len(rest) < size + 2:
            rest += conn.recv(65536)
        body += rest[:size]
        rest = rest[size + 2:]  # chunk + CRLF


def write_response(conn, status, reason, headers, body):
    lines = [f"HTTP/1.1 {status} {reason}"]
    hdrs = dict(headers)
    if hdrs.get("Connection") != "close":
        hdrs.setdefault("Connection", "keep-alive")
    hdrs.setdefault("Content-Length", str(len(body)))
    for k, v in hdrs.items():
        lines.append(f"{k}: {v}")
    head = ("\r\n".join(lines) + "\r\n\r\n").encode()
    conn.sendall(head + body)
    if hdrs.get("Connection") == "close":
        # opencode (bun's fetch) ends an SSE body on connection close;
        # without it the client waits a full socket timeout after the
        # last event.
        try:
            conn.shutdown(socket.SHUT_WR)
            conn.close()
        except OSError:
            pass


def sse_body(model, text):
    rid = f"resp_{int(time.time() * 1000)}"
    item = {"id": "msg_0", "type": "message", "role": "assistant"}
    created = {
        "type": "response.created",
        "response": {"id": rid, "object": "response", "created_at": int(time.time()),
                     "status": "in_progress", "model": model, "output": []},
    }
    events = [
        created,
        {"type": "response.output_item.added", "output_index": 0,
         "item": dict(item, status="in_progress", content=[])},
        {"type": "response.content_part.added", "item_id": "msg_0",
         "output_index": 0, "content_index": 0,
         "part": {"type": "output_text", "text": "", "annotations": []}},
        {"type": "response.output_text.delta", "item_id": "msg_0",
         "output_index": 0, "content_index": 0, "delta": text},
        {"type": "response.output_text.done", "item_id": "msg_0",
         "output_index": 0, "content_index": 0, "text": text},
        {"type": "response.content_part.done", "item_id": "msg_0",
         "output_index": 0, "content_index": 0,
         "part": {"type": "output_text", "text": text, "annotations": []}},
        {"type": "response.output_item.done", "output_index": 0,
         "item": dict(item, status="completed",
                      content=[{"type": "output_text", "text": text,
                                "annotations": []}])},
        {"type": "response.completed",
         "response": {"id": rid, "object": "response",
                      "created_at": created["response"]["created_at"],
                      "status": "completed", "model": model,
                      "output": [dict(item, status="completed",
                                      content=[{"type": "output_text",
                                                "text": text,
                                                "annotations": []}])],
                      "usage": {"input_tokens": 11, "output_tokens": 3,
                                "total_tokens": 14,
                                "input_tokens_details": {"cached_tokens": 0},
                                "output_tokens_details": {"reasoning_tokens": 2}}}},
    ]
    chunks = []
    for ev in events:
        chunks.append(f"event: {ev['type']}\n".encode())
        chunks.append(b"data: " + json.dumps(ev).encode() + b"\n\n")
    return b"".join(chunks)


def route(d, req, host):
    ct = req.headers.get("content-type", "").split(";")[0].strip()
    if host == "chatgpt.com" and req.method == "POST" and \
            req.path == "/backend-api/codex/responses":
        model = ""
        try:
            model = json.loads(req.body_raw).get("model", "")
        except (ValueError, AttributeError):
            pass
        return 200, "OK", {"Content-Type": "text/event-stream",
                           "Cache-Control": "no-cache",
                           "Connection": "close"}, sse_body(model, STUB_REPLY)
    if host == "auth.openai.com" and req.method == "POST" and \
            req.path == "/oauth/token":
        global _token_calls
        with _token_lock:
            _token_calls += 1
            n = _token_calls
        now = int(time.time())
        token = {
            "access_token": make_jwt(now + 3600),
            "id_token": make_jwt(now + 3600),
            "refresh_token": f"rt-{n}",
            "expires_in": 3600,
            "token_type": "Bearer",
        }
        return 200, "OK", {"Content-Type": "application/json"}, \
            json.dumps(token).encode()
    if host == "auth.openai.com" and req.method == "POST" and \
            req.path == "/api/accounts/deviceauth/usercode":
        return 200, "OK", {"Content-Type": "application/json"}, json.dumps(
            {"device_auth_id": "dev-1", "user_code": "TEST-CODE",
             "interval": "1"}).encode()
    if host == "auth.openai.com" and req.method == "POST" and \
            req.path == "/api/accounts/deviceauth/token":
        return 200, "OK", {"Content-Type": "application/json"}, json.dumps(
            {"authorization_code": "ac-test",
             "code_verifier": "cv-test"}).encode()
    return 404, "Not Found", {"Content-Type": "application/json"}, \
        json.dumps({"error": "stub: no route"}).encode()


def pipe(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    finally:
        try:
            b.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def tunnel(client, host, port):
    try:
        upstream = socket.create_connection((host, int(port)), timeout=30)
    except OSError:
        try:
            client.close()
        except OSError:
            pass
        return
    client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
    t = threading.Thread(target=pipe, args=(client, upstream), daemon=True)
    t.start()
    pipe(upstream, client)
    t.join(timeout=5)
    for s in (client, upstream):
        try:
            s.close()
        except OSError:
            pass


def handle(client):
    try:
        client.settimeout(60)
        parsed = read_http_message(client)
        if parsed is None:
            return
        req, _ = parsed
        if req.method != "CONNECT":
            write_response(client, 405, "Method Not Allowed",
                           {"Content-Type": "text/plain"}, b"CONNECT only\n")
            return
        target = req.path
        host, _, port = target.partition(":")
        port = port or "443"
        if host in INTERCEPT_HOSTS:
            client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.set_alpn_protocols(["http/1.1"])
            ctx.load_cert_chain(os.path.join(D, "leaf.pem"),
                                os.path.join(D, "leaf.key"))
            try:
                tls = ctx.wrap_socket(client, server_side=True)
            except (ssl.SSLError, OSError):
                return
            tls.sni_host = host
            try:
                serve_tls_session(d=D, tls=tls, host=host)
            finally:
                try:
                    tls.close()
                except OSError:
                    pass
        else:
            tunnel(client, host, port)
    except (OSError, ValueError):
        pass


def serve_tls_session(d, tls, host):
    keep_open = True
    try:
        while keep_open:
            parsed = read_http_message(tls)
            if parsed is None:
                return
            req, _ = parsed
            keep_open = req.headers.get("connection", "").lower() != "close"
            ct = req.headers.get("content-type", "").split(";")[0].strip()
            log_request(d, host, req.method, req.path, req.headers,
                        req.body_raw, ct)
            status, reason, hdrs, body = route(d, req, host)
            write_response(tls, status, reason, hdrs, body)
    except (ssl.SSLError, OSError, ValueError):
        pass


def main():
    global D
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    args = ap.parse_args()
    D = args.dir
    os.makedirs(D, exist_ok=True)
    make_certs(D)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(64)
    port = server.getsockname()[1]
    with open(os.path.join(D, "pid"), "w") as f:
        f.write(str(os.getpid()))
    with open(os.path.join(D, "port"), "w") as f:
        f.write(str(port))

    while True:
        try:
            client, _ = server.accept()
        except OSError:
            return
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
