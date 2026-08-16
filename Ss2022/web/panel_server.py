#!/usr/bin/env python3
"""Low-privilege REM Web Panel HTTP front-end.

The server never opens nodes.json, traffic.json, manager.json or config.json.
It only reads the non-sensitive public panel descriptor and calls the
root-owned Manager Core socket for authenticated business data.
"""

from __future__ import annotations

import argparse
import base64
import http.server
import json
import secrets
import socket
import sys
import threading
import time
from dataclasses import dataclass
from http import HTTPStatus
from typing import Any, Dict, Mapping, Optional, Tuple
from urllib.parse import parse_qs, urlsplit

from panel_common import (
    CORE_SOCKET,
    MAX_JSON_BYTES,
    PanelError,
    allowed_client_ip,
    load_public_config,
)


SESSION_COOKIE = "rem_session"
MAX_BODY_BYTES = 16 * 1024


@dataclass
class Session:
    username: str
    expires_at: float


class SessionStore:
    def __init__(self, timeout: int = 1800) -> None:
        self.timeout = timeout
        self._items: Dict[str, Session] = {}
        self._lock = threading.Lock()

    def create(self, username: str) -> str:
        token = secrets.token_urlsafe(32)
        with self._lock:
            self._items[token] = Session(username, time.time() + self.timeout)
        return token

    def get(self, token: Optional[str]) -> Optional[Session]:
        if not token:
            return None
        now = time.time()
        with self._lock:
            session = self._items.get(token)
            if session is None:
                return None
            if session.expires_at <= now:
                self._items.pop(token, None)
                return None
            session.expires_at = now + self.timeout
            return session

    def remove(self, token: Optional[str]) -> None:
        if token:
            with self._lock:
                self._items.pop(token, None)


class LoginLimiter:
    def __init__(self) -> None:
        self._items: Dict[Tuple[str, str], Tuple[int, float]] = {}
        self._lock = threading.Lock()

    def before(self, key: Tuple[str, str]) -> float:
        now = time.time()
        with self._lock:
            failures, blocked_until = self._items.get(key, (0, 0.0))
            if blocked_until > now:
                return blocked_until - now
            return 0.0

    def failure(self, key: Tuple[str, str]) -> None:
        now = time.time()
        with self._lock:
            failures, _ = self._items.get(key, (0, 0.0))
            failures += 1
            blocked_until = now + min(60.0, 2.0 ** min(failures, 5))
            self._items[key] = (failures, blocked_until)

    def success(self, key: Tuple[str, str]) -> None:
        with self._lock:
            self._items.pop(key, None)


def core_request(method: str, params: Optional[Mapping[str, Any]] = None) -> Dict[str, Any]:
    request = {"method": method, "params": dict(params or {})}
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5.0)
    try:
        sock.connect(CORE_SOCKET)
        sock.sendall((json.dumps(request, ensure_ascii=False, separators=(",", ":")) + "\n").encode())
        chunks = []
        total = 0
        while True:
            chunk = sock.recv(64 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > MAX_JSON_BYTES:
                raise PanelError("CORE_ERROR", "Manager Core 响应过大")
            if b"\n" in chunk:
                break
        raw = b"".join(chunks).split(b"\n", 1)[0]
        value = json.loads(raw.decode("utf-8"))
        if not isinstance(value, dict) or not value.get("ok"):
            error = value.get("error", {}) if isinstance(value, dict) else {}
            raise PanelError(str(error.get("code", "CORE_ERROR")), str(error.get("message", "Manager Core 请求失败")))
        return value.get("data")
    except PanelError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise PanelError("CORE_UNAVAILABLE", "Manager Core 暂时不可用") from exc
    finally:
        sock.close()


def parse_cookie(header: str) -> Optional[str]:
    for item in header.split(";"):
        name, separator, value = item.strip().partition("=")
        if separator and name == SESSION_COOKIE:
            return value
    return None


def html_page(authenticated: bool, token: str) -> bytes:
    if not authenticated:
        body = """<!doctype html><meta charset=utf-8><title>REM Proxy Manager</title>
<h1>REM Proxy Manager</h1><form method=post action="__TOKEN__/api/v1/login">
<label>用户名 <input name=username autocomplete=username></label><br>
<label>密码 <input type=password name=password autocomplete=current-password></label><br>
<button>登录</button></form>""".replace("__TOKEN__", token)
    else:
        body = """<!doctype html><meta charset=utf-8><title>REM Proxy Manager</title>
<h1>REM Proxy Manager</h1><p>已登录。只读面板基础 API 已就绪。</p>
<pre id=dashboard>正在读取...</pre><script>
fetch('./api/v1/dashboard').then(r=>r.json()).then(v=>{
document.getElementById('dashboard').textContent=JSON.stringify(v,null,2)
})</script>"""
    return body.encode("utf-8")


class PanelHandler(http.server.BaseHTTPRequestHandler):
    server_version = "REMPanel/1"
    sys_version = ""

    @property
    def panel(self) -> "PanelHTTPServer":
        return self.server  # type: ignore[return-value]

    def log_message(self, _format: str, *args: Any) -> None:
        # No access history or credential-bearing request logs.
        return

    def _public_config(self) -> Optional[Dict[str, Any]]:
        try:
            return load_public_config()
        except PanelError:
            return None

    def _gate(self) -> Optional[Tuple[Dict[str, Any], str, str]]:
        config = self._public_config()
        if config is None or not config.get("enabled"):
            self._not_found()
            return None
        remote = self.client_address[0]
        if not allowed_client_ip(remote, config):
            self._not_found()
            return None
        path = urlsplit(self.path).path
        parts = path.split("/")
        token = config["panel_path_token"]
        if len(parts) < 2 or parts[1] != token:
            self._not_found()
            return None
        rest = "/".join(parts[2:])
        return config, token, rest

    def _not_found(self) -> None:
        self.send_response(HTTPStatus.NOT_FOUND)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def _headers(self, content_type: str = "application/json; charset=utf-8") -> None:
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'")

    def _json(self, status: int, value: Mapping[str, Any], *, cookie: Optional[str] = None, clear: bool = False) -> None:
        payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self._headers()
        if cookie is not None:
            token = self.panel.current_token
            self.send_header(
                "Set-Cookie",
                f"{SESSION_COOKIE}={cookie}; Path=/{token}/; Max-Age={self.panel.sessions.timeout}; HttpOnly; Secure; SameSite=Strict",
            )
        if clear:
            token = self.panel.current_token
            self.send_header(
                "Set-Cookie",
                f"{SESSION_COOKIE}=; Path=/{token}/; Max-Age=0; HttpOnly; Secure; SameSite=Strict",
            )
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _html(self, content: bytes) -> None:
        self.send_response(HTTPStatus.OK)
        self._headers("text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def _session(self) -> Optional[Session]:
        return self.panel.sessions.get(parse_cookie(self.headers.get("Cookie", "")))

    def _body(self) -> Dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise PanelError("BAD_REQUEST", "请求体无效") from exc
        if length < 0 or length > MAX_BODY_BYTES:
            raise PanelError("BAD_REQUEST", "请求体过大")
        raw = self.rfile.read(length)
        content_type = self.headers.get("Content-Type", "")
        if "application/x-www-form-urlencoded" in content_type:
            values = parse_qs(raw.decode("utf-8"), keep_blank_values=True)
            return {key: values.get(key, [""])[0] for key in values}
        value = json.loads(raw.decode("utf-8")) if raw else {}
        if not isinstance(value, dict):
            raise PanelError("BAD_REQUEST", "请求体格式无效")
        return value

    def do_GET(self) -> None:
        gated = self._gate()
        if gated is None:
            return
        _config, token, rest = gated
        if rest in ("",):
            self._html(html_page(self._session() is not None, token))
            return
        if not rest.startswith("api/v1/"):
            self._not_found()
            return
        if self._session() is None:
            self._json(HTTPStatus.UNAUTHORIZED, {"ok": False, "error": {"code": "AUTH_REQUIRED", "message": "需要登录"}})
            return
        method = rest[len("api/v1/") :].rstrip("/")
        methods = {
            "dashboard": "dashboard",
            "nodes": "nodes",
            "traffic": "traffic",
            "system": "system",
            "subscription": "subscription",
            "time-sync": "time_sync",
            "capabilities": "capabilities",
        }
        if method not in methods:
            self._not_found()
            return
        try:
            data = core_request(methods[method])
            self._json(HTTPStatus.OK, {"ok": True, "data": data})
        except PanelError as exc:
            status = HTTPStatus.CONFLICT if exc.code == "BUSY" else HTTPStatus.SERVICE_UNAVAILABLE
            self._json(status, {"ok": False, "error": {"code": exc.code, "message": exc.message}})

    def do_POST(self) -> None:
        gated = self._gate()
        if gated is None:
            return
        _config, _token, rest = gated
        if not rest.startswith("api/v1/"):
            self._not_found()
            return
        method = rest[len("api/v1/") :].rstrip("/")
        try:
            body = self._body()
        except PanelError as exc:
            self._json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": {"code": exc.code, "message": exc.message}})
            return
        if method == "login":
            username = body.get("username", "")
            password = body.get("password", "")
            if not isinstance(username, str) or not isinstance(password, str):
                self._json(HTTPStatus.UNAUTHORIZED, {"ok": False, "error": {"code": "AUTH_FAILED", "message": "用户名或密码错误"}})
                return
            key = (self.client_address[0], username[:64])
            delay = self.panel.limiter.before(key)
            if delay > 0:
                self._json(HTTPStatus.TOO_MANY_REQUESTS, {"ok": False, "error": {"code": "RATE_LIMITED", "message": "登录尝试过于频繁，请稍后重试"}})
                return
            try:
                data = core_request("auth.verify", {"username": username, "password": password})
            except PanelError as exc:
                if exc.code == "AUTH_FAILED":
                    self.panel.limiter.failure(key)
                    self._json(HTTPStatus.UNAUTHORIZED, {"ok": False, "error": {"code": "AUTH_FAILED", "message": "用户名或密码错误"}})
                    return
                status = HTTPStatus.CONFLICT if exc.code == "BUSY" else HTTPStatus.SERVICE_UNAVAILABLE
                self._json(status, {"ok": False, "error": {"code": exc.code, "message": exc.message}})
                return
            self.panel.limiter.success(key)
            session = self.panel.sessions.create(str(data["username"]))
            self._json(HTTPStatus.OK, {"ok": True, "data": {"username": data["username"]}}, cookie=session)
            return
        if method == "logout":
            self.panel.sessions.remove(parse_cookie(self.headers.get("Cookie", "")))
            self._json(HTTPStatus.OK, {"ok": True, "data": {}}, clear=True)
            return
        self._not_found()


class PanelHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, address: Tuple[str, int], handler, sessions: SessionStore, limiter: LoginLimiter) -> None:
        super().__init__(address, handler)
        self.sessions = sessions
        self.limiter = limiter

    @property
    def current_token(self) -> str:
        try:
            return load_public_config()["panel_path_token"]
        except PanelError:
            return "invalid"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="REM low-privilege Web Panel")
    parser.add_argument("--address", default=None)
    parser.add_argument("--port", type=int, default=None)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        config = load_public_config()
    except PanelError as exc:
        print(f"[ERROR] Panel 公共状态不可用：{exc.message}", file=sys.stderr)
        return 1
    address = args.address or config["listen_address"]
    port = args.port or config["listen_port"]
    if address != "127.0.0.1" or not (1 <= port <= 65535):
        print("[ERROR] Panel 只允许监听 127.0.0.1。", file=sys.stderr)
        return 1
    if hasattr(__import__("os"), "geteuid") and __import__("os").geteuid() == 0:
        print("[WARN] panel_server 当前以 root 运行；生产部署应使用 ss-manager-panel 用户。", file=sys.stderr)
    server = PanelHTTPServer(
        (address, port),
        PanelHandler,
        SessionStore(int(config.get("session_timeout_seconds", 1800))),
        LoginLimiter(),
    )
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
