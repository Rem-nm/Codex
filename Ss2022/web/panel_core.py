#!/usr/bin/env python3
"""Root-owned REM Manager Core read API over a Unix socket.

Every request takes the same non-blocking ``manager.lock`` used by the Bash
manager.  This first slice intentionally has no write method: a future write
must call the existing candidate/config/health/rollback transaction rather than
editing manager files here.
"""

from __future__ import annotations

import argparse
import fcntl
import grp
import json
import os
import socket
import socketserver
import stat
import sys
import threading
from typing import Any, Dict, Mapping

from panel_common import (
    CORE_SOCKET,
    MANAGER_LOCK,
    PanelError,
    capabilities,
    dashboard,
    json_response,
    load_private_config,
    public_nodes,
    public_traffic,
    read_manager_state,
    sanitized_subscription,
    sanitized_time_sync,
    system_status,
    verify_password,
)


MAX_LINE_BYTES = 256 * 1024


def _safe_socket_path(path: str) -> None:
    parent = os.path.dirname(path) or "."
    if os.path.lexists(parent):
        info = os.lstat(parent)
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise PanelError("SOCKET_UNSAFE", "Panel Core 运行目录不是安全目录")
    else:
        os.makedirs(parent, mode=0o750, exist_ok=False)
    os.chmod(parent, 0o750)
    if os.path.lexists(path):
        info = os.lstat(path)
        if not stat.S_ISSOCK(info.st_mode):
            raise PanelError("SOCKET_UNSAFE", "Panel Core socket 路径不是 Unix socket")
        os.unlink(path)


def with_manager_lock(callback):
    parent = os.path.dirname(MANAGER_LOCK) or "."
    os.makedirs(parent, mode=0o700, exist_ok=True)
    if os.path.lexists(MANAGER_LOCK):
        info = os.lstat(MANAGER_LOCK)
        if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise PanelError("LOCK_UNSAFE", "manager 锁路径不是安全常规文件")
    fd = os.open(MANAGER_LOCK, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        os.fchmod(fd, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise PanelError("BUSY", "已有 ss-manager 操作正在执行，请稍后重试。") from exc
        try:
            return callback()
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def _auth_verify(params: Mapping[str, Any]) -> Dict[str, Any]:
    username = params.get("username")
    password = params.get("password")
    if not isinstance(username, str) or not isinstance(password, str):
        raise PanelError("AUTH_FAILED", "用户名或密码错误")
    config = load_private_config()
    if username != config.get("admin_username") or not verify_password(
        password, str(config.get("admin_password_hash", ""))
    ):
        raise PanelError("AUTH_FAILED", "用户名或密码错误")
    return {"username": username}


def dispatch(request: Mapping[str, Any]) -> Any:
    method = request.get("method")
    params = request.get("params", {})
    if not isinstance(method, str) or not isinstance(params, dict):
        raise PanelError("BAD_REQUEST", "Manager Core 请求格式无效")

    def action() -> Any:
        if method == "auth.verify":
            return _auth_verify(params)
        if method == "dashboard":
            return dashboard()
        if method == "nodes":
            return public_nodes()
        if method == "traffic":
            return public_traffic()
        if method == "system":
            return system_status()
        if method == "subscription":
            return sanitized_subscription()
        if method == "time_sync":
            return sanitized_time_sync(read_manager_state())
        if method == "capabilities":
            return capabilities()
        raise PanelError("NOT_FOUND", "Manager Core 方法不存在")

    return with_manager_lock(action)


class CoreHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        try:
            raw = self.rfile.readline(MAX_LINE_BYTES + 1)
            if not raw or len(raw) > MAX_LINE_BYTES:
                raise PanelError("BAD_REQUEST", "Manager Core 请求过大")
            request = json.loads(raw.decode("utf-8"))
            if not isinstance(request, dict):
                raise PanelError("BAD_REQUEST", "Manager Core 请求格式无效")
            result = dispatch(request)
            self.wfile.write(json_response(True, data=result))
        except PanelError as exc:
            self.wfile.write(json_response(False, code=exc.code, message=exc.message))
        except (OSError, UnicodeError, json.JSONDecodeError):
            self.wfile.write(json_response(False, code="BAD_REQUEST", message="Manager Core 请求失败"))
        except Exception:
            # Never send traceback or filesystem details over the management
            # socket.  The service manager remains the diagnostic channel.
            self.wfile.write(json_response(False, code="INTERNAL", message="Manager Core 内部错误"))


class CoreServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    allow_reuse_address = False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="REM Manager Core read API")
    parser.add_argument("--socket", default=CORE_SOCKET)
    parser.add_argument("--socket-group", default="ss-manager-panel")
    return parser.parse_args()


def main() -> int:
    if hasattr(os, "geteuid") and os.geteuid() != 0:
        print("[ERROR] panel_core 必须以 root 身份运行。", file=sys.stderr)
        return 1
    args = parse_args()
    try:
        _safe_socket_path(args.socket)
        server = CoreServer(args.socket, CoreHandler)
        os.chmod(args.socket, 0o660)
        try:
            gid = grp.getgrnam(args.socket_group).gr_gid
            os.chown(os.path.dirname(args.socket) or ".", 0, gid)
            os.chown(args.socket, 0, gid)
        except KeyError:
            # Test and development environments may not have the optional
            # account yet; the service installer creates it before enabling
            # the non-root HTTP process.
            pass
    except (OSError, PanelError) as exc:
        print(f"[ERROR] Panel Core 启动失败：{exc}", file=sys.stderr)
        return 1
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        try:
            os.unlink(args.socket)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
