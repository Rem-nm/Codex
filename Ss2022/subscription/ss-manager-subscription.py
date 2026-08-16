#!/usr/bin/env python3
"""Small read-only subscription server.

It intentionally consumes only root-generated derived JSON.  No shell, jq,
sing-box, node database, certificate directory or manager transaction is
available from this process.
"""

import hmac
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


RUNTIME_PATH = os.environ.get(
    "SS_MANAGER_SUBSCRIPTION_RUNTIME",
    "/var/lib/ss-manager/subscription/subscription-runtime.json",
)
EXPORT_PATH = os.environ.get(
    "SS_MANAGER_SUBSCRIPTION_EXPORT",
    "/var/lib/ss-manager/subscription/subscription-export.json",
)
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")
NO_STORE_HEADERS = (
    ("Cache-Control", "no-store"),
    ("X-Content-Type-Options", "nosniff"),
    ("Referrer-Policy", "no-referrer"),
)


def regular_json(path):
    st = os.lstat(path)
    if not os.path.isfile(path) or os.path.islink(path):
        raise ValueError("not a regular file")
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def load_snapshot():
    runtime = regular_json(RUNTIME_PATH)
    token = runtime.get("token")
    export_path = runtime.get("export_path")
    if not isinstance(token, str) or not TOKEN_RE.fullmatch(token):
        raise ValueError("invalid token")
    if not isinstance(export_path, str) or export_path != EXPORT_PATH:
        raise ValueError("invalid export path")
    snapshot = regular_json(export_path)
    if snapshot.get("schema_version") != 1 or not isinstance(snapshot.get("available"), bool):
        raise ValueError("invalid export")
    return token, snapshot


def safe_path(raw_path):
    # Reject encoded separators/dots before decoding.  We never map a request
    # to a filesystem path, but rejecting ambiguous spellings keeps proxies
    # from interpreting the same bearer URL differently.
    if not isinstance(raw_path, str) or len(raw_path) > 512:
        return None
    if any(ch in raw_path for ch in ("\x00", "\\")):
        return None
    lowered = raw_path.lower()
    if any(marker in lowered for marker in ("%2f", "%5c", "%2e", "%00")):
        return None
    parsed = urlsplit(raw_path)
    if parsed.query or parsed.fragment or parsed.scheme or parsed.netloc:
        return None
    if parsed.path != raw_path:
        return None
    return raw_path


class Handler(BaseHTTPRequestHandler):
    server_version = "Ss2022Subscription/1"

    def log_message(self, _format, *_args):
        # Bearer tokens live in the URL.  Do not write request paths to logs.
        return

    def _headers(self, content_type, length):
        for key, value in NO_STORE_HEADERS:
            self.send_header(key, value)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))

    def _error(self, status=404, allow=None):
        body = b"not found\n" if status == 404 else b"method not allowed\n"
        self.send_response(status)
        self._headers("text/plain; charset=utf-8", len(body))
        if allow:
            self.send_header("Allow", allow)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _respond(self, status, content_type, body):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        self._headers(content_type, len(body))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_POST(self):
        self._error(405, "GET, HEAD")

    do_PUT = do_POST
    do_PATCH = do_POST
    do_DELETE = do_POST
    do_OPTIONS = do_POST

    def do_HEAD(self):
        self._handle(True)

    def do_GET(self):
        self._handle(False)

    def _handle(self, _head):
        raw = safe_path(self.path)
        if raw is None:
            self._error(404)
            return
        if raw == "/healthz":
            try:
                load_snapshot()
            except Exception:
                self._respond(503, "text/plain; charset=utf-8", "unavailable\n")
                return
            self._respond(200, "text/plain; charset=utf-8", "ok\n")
            return
        parts = raw.split("/")
        if len(parts) not in (3, 4) or parts[1] != "sub" or not parts[2]:
            self._error(404)
            return
        token = parts[2]
        suffix = parts[3] if len(parts) == 4 else ""
        if not TOKEN_RE.fullmatch(token):
            self._error(404)
            return
        try:
            expected, snapshot = load_snapshot()
        except Exception:
            self._respond(503, "text/plain; charset=utf-8", "unavailable\n")
            return
        if not hmac.compare_digest(token, expected):
            self._error(404)
            return
        if suffix not in ("", "base64", "raw", "sing-box"):
            self._error(404)
            return
        if not snapshot.get("available"):
            self._respond(503, "text/plain; charset=utf-8", "unavailable\n")
            return
        if suffix == "sing-box":
            if not snapshot.get("profile_available") or not isinstance(snapshot.get("profile"), dict):
                self._respond(503, "application/json; charset=utf-8", "{\"error\":\"unavailable\"}\n")
                return
            body = (json.dumps(snapshot["profile"], ensure_ascii=False, separators=(",", ":")) + "\n")
            self._respond(200, "application/json; charset=utf-8", body)
            return
        if suffix == "raw":
            body = snapshot.get("raw")
        else:
            body = snapshot.get("base64")
        if not isinstance(body, str):
            self._respond(503, "text/plain; charset=utf-8", "unavailable\n")
            return
        self._respond(200, "text/plain; charset=utf-8", body)


def main():
    try:
        runtime = regular_json(RUNTIME_PATH)
        listen_port = int(runtime.get("listen_port", 0))
        if not 1 <= listen_port <= 65535:
            raise ValueError("invalid listen port")
    except Exception:
        print("subscription runtime unavailable", file=sys.stderr)
        raise SystemExit(1)
    server = ThreadingHTTPServer(("127.0.0.1", listen_port), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
