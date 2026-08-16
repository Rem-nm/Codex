#!/usr/bin/env python3
"""Shared, dependency-free primitives for the REM Web Panel.

This module intentionally contains no shell execution and no protocol share
generation.  The privileged core only reads already validated manager state;
the HTTP process only reads the public panel descriptor and talks to the core
over a Unix socket.
"""

from __future__ import annotations

import base64
import datetime as _dt
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import socket
import stat
import uuid
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Tuple


API_VERSION = "v1"
PANEL_SCHEMA_VERSION = 1
DEFAULT_LISTEN_ADDRESS = "127.0.0.1"
DEFAULT_LISTEN_PORT = 18081
DEFAULT_SESSION_TIMEOUT = 1800
PASSWORD_ITERATIONS = 310_000
MAX_JSON_BYTES = 4 * 1024 * 1024

PROGRAM_DIR = os.environ.get("SS_MANAGER_PROGRAM_DIR", "/opt/ss-manager")
CONFIG_DIR = os.environ.get("SS_MANAGER_CONFIG_DIR", "/etc/ss-manager")
DATA_DIR = os.environ.get("SS_MANAGER_DATA_DIR", "/var/lib/ss-manager")
RUNTIME_DIR = os.environ.get("SS_MANAGER_RUNTIME_DIR", "/run/ss-manager")
PANEL_RUNTIME_DIR = os.environ.get("SS_MANAGER_PANEL_RUNTIME_DIR", "/run/ss-manager-panel")
CORE_SOCKET = os.environ.get(
    "SS_MANAGER_PANEL_CORE_SOCKET", f"{PANEL_RUNTIME_DIR}/core.sock"
)
PANEL_CONFIG = os.environ.get(
    "SS_MANAGER_PANEL_CONFIG", f"{CONFIG_DIR}/panel.json"
)
PANEL_PUBLIC_CONFIG = os.environ.get(
    "SS_MANAGER_PANEL_PUBLIC_CONFIG", f"{PANEL_RUNTIME_DIR}/public.json"
)
PANEL_GROUP = os.environ.get("SS_MANAGER_PANEL_GROUP", "ss-manager-panel")
MANAGER_LOCK = os.environ.get(
    "SS_MANAGER_LOCK", f"{RUNTIME_DIR}/manager.lock"
)
MANAGER_STATE = os.environ.get(
    "SS_MANAGER_MANAGER_STATE", f"{CONFIG_DIR}/manager.json"
)
NODES_FILE = os.environ.get("SS_MANAGER_NODES_FILE", f"{DATA_DIR}/nodes.json")
TRAFFIC_FILE = os.environ.get(
    "SS_MANAGER_TRAFFIC_FILE", f"{DATA_DIR}/traffic.json"
)
HISTORY_FILE = os.environ.get(
    "SS_MANAGER_HISTORY_FILE", f"{DATA_DIR}/traffic-history.json"
)
SUBSCRIPTION_CONFIG = os.environ.get(
    "SS_MANAGER_SUBSCRIPTION_CONFIG", f"{CONFIG_DIR}/subscription.json"
)

USERNAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")
INSTANCE_ID_RE = re.compile(r"^rem-[0-9a-f-]{36}$")


class PanelError(Exception):
    """A safe error that can cross the core/socket boundary."""

    def __init__(self, code: str, message: str = "请求失败") -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def local_time_info() -> Dict[str, str]:
    now = _dt.datetime.now().astimezone()
    utc = now.astimezone(_dt.timezone.utc)
    timezone_name = now.tzname() or "unknown"
    try:
        timezone_name = _dt.datetime.now().astimezone().tzinfo.tzname(now) or timezone_name
    except Exception:
        pass
    return {
        "local_time": now.isoformat(timespec="seconds"),
        "utc_time": utc.isoformat(timespec="seconds").replace("+00:00", "Z"),
        "timezone": timezone_name,
        "unix_timestamp": str(int(utc.timestamp())),
    }


def _is_regular(path: str, *, allow_missing: bool = False) -> bool:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return allow_missing
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode)


def _read_json(path: str, default: Optional[Any] = None) -> Any:
    if not _is_regular(path):
        if default is not None and not os.path.lexists(path):
            return default
        raise PanelError("STATE_UNAVAILABLE", "管理状态不可读取")
    try:
        size = os.path.getsize(path)
        if size > MAX_JSON_BYTES:
            raise PanelError("STATE_UNAVAILABLE", "管理状态过大")
        with open(path, "rb") as stream:
            raw = stream.read(MAX_JSON_BYTES + 1)
        if len(raw) > MAX_JSON_BYTES:
            raise PanelError("STATE_UNAVAILABLE", "管理状态过大")
        return json.loads(raw.decode("utf-8"))
    except PanelError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise PanelError("STATE_UNAVAILABLE", "管理状态无效")


def read_manager_state() -> Dict[str, Any]:
    value = _read_json(MANAGER_STATE, {})
    if not isinstance(value, dict):
        raise PanelError("STATE_UNAVAILABLE", "manager 状态无效")
    return value


def read_nodes() -> Dict[str, Any]:
    value = _read_json(NODES_FILE, {"schema_version": 5, "nodes": []})
    if not isinstance(value, dict) or not isinstance(value.get("nodes"), list):
        raise PanelError("STATE_UNAVAILABLE", "节点数据库无效")
    return value


def read_traffic() -> Dict[str, Any]:
    value = _read_json(TRAFFIC_FILE, {"schema_version": 1, "nodes": {}})
    if not isinstance(value, dict) or not isinstance(value.get("nodes"), dict):
        raise PanelError("STATE_UNAVAILABLE", "流量数据库无效")
    return value


def read_history() -> Dict[str, Any]:
    value = _read_json(HISTORY_FILE, {"schema_version": 1, "cycles": {}})
    if not isinstance(value, dict):
        raise PanelError("STATE_UNAVAILABLE", "流量历史无效")
    return value


def read_subscription() -> Dict[str, Any]:
    value = _read_json(SUBSCRIPTION_CONFIG, {})
    if not isinstance(value, dict):
        raise PanelError("STATE_UNAVAILABLE", "订阅设置无效")
    return value


def _atomic_write(path: str, payload: Mapping[str, Any], mode: int) -> None:
    parent = os.path.dirname(path) or "."
    os.makedirs(parent, mode=0o700, exist_ok=True)
    temporary = f"{path}.new.{os.getpid()}.{secrets.token_hex(4)}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    fd = os.open(temporary, flags, mode)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
        directory_fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def generate_panel_token() -> str:
    token = secrets.token_urlsafe(32)
    if not TOKEN_RE.fullmatch(token):
        raise PanelError("INTERNAL", "无法生成入口 Token")
    return token


def hash_password(password: str) -> str:
    if not isinstance(password, str) or not (12 <= len(password) <= 256):
        raise PanelError("INVALID_PASSWORD", "管理员密码长度必须为 12-256 个字符")
    if any(ord(char) < 0x20 or ord(char) == 0x7F for char in password):
        raise PanelError("INVALID_PASSWORD", "管理员密码不能包含控制字符")
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, PASSWORD_ITERATIONS
    )
    encode = lambda value: base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")
    return f"pbkdf2_sha256${PASSWORD_ITERATIONS}${encode(salt)}${encode(digest)}"


def verify_password(password: str, encoded: str) -> bool:
    try:
        algorithm, iterations_text, salt_text, digest_text = encoded.split("$", 3)
        if algorithm != "pbkdf2_sha256":
            return False
        iterations = int(iterations_text)
        if not (100_000 <= iterations <= 2_000_000):
            return False
        padding = lambda value: value + "=" * (-len(value) % 4)
        salt = base64.urlsafe_b64decode(padding(salt_text).encode("ascii"))
        expected = base64.urlsafe_b64decode(padding(digest_text).encode("ascii"))
        actual = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), salt, iterations
        )
        return hmac.compare_digest(actual, expected)
    except (ValueError, TypeError, UnicodeError):
        return False


def validate_username(username: str) -> None:
    if not isinstance(username, str) or not USERNAME_RE.fullmatch(username):
        raise PanelError("INVALID_USERNAME", "管理员用户名格式无效")


def validate_private_config(config: Mapping[str, Any]) -> None:
    if config.get("schema_version") != PANEL_SCHEMA_VERSION:
        raise PanelError("STATE_UNAVAILABLE", "Panel 状态版本不受支持")
    if not isinstance(config.get("enabled"), bool):
        raise PanelError("STATE_UNAVAILABLE", "Panel 启用状态无效")
    address = config.get("listen_address")
    port = config.get("listen_port")
    if address != DEFAULT_LISTEN_ADDRESS or not isinstance(port, int) or not 1 <= port <= 65535:
        raise PanelError("STATE_UNAVAILABLE", "Panel 监听设置无效")
    token = config.get("panel_path_token")
    if not isinstance(token, str) or not TOKEN_RE.fullmatch(token):
        raise PanelError("STATE_UNAVAILABLE", "Panel 入口 Token 无效")
    username = config.get("admin_username")
    validate_username(username)
    if not isinstance(config.get("admin_password_hash"), str):
        raise PanelError("STATE_UNAVAILABLE", "Panel 管理员凭据无效")
    instance_id = config.get("instance_id")
    if not isinstance(instance_id, str) or not INSTANCE_ID_RE.fullmatch(instance_id):
        raise PanelError("STATE_UNAVAILABLE", "REM Instance ID 无效")
    if not isinstance(config.get("ip_allowlist_enabled"), bool):
        raise PanelError("STATE_UNAVAILABLE", "IP 白名单设置无效")
    allowlist = config.get("ip_allowlist")
    if not isinstance(allowlist, list) or not all(isinstance(item, str) for item in allowlist):
        raise PanelError("STATE_UNAVAILABLE", "IP 白名单格式无效")
    for item in allowlist:
        try:
            ipaddress.ip_network(item, strict=False)
        except ValueError as exc:
            raise PanelError("STATE_UNAVAILABLE", "IP 白名单格式无效") from exc
    timeout = config.get("session_timeout_seconds")
    if not isinstance(timeout, int) or not 300 <= timeout <= 86_400:
        raise PanelError("STATE_UNAVAILABLE", "Session 超时设置无效")
    timeout = config.get("session_timeout_seconds")
    if not isinstance(timeout, int) or not 300 <= timeout <= 86_400:
        raise PanelError("STATE_UNAVAILABLE", "Session 超时设置无效")


def validate_public_config(config: Mapping[str, Any]) -> None:
    if config.get("schema_version") != PANEL_SCHEMA_VERSION:
        raise PanelError("STATE_UNAVAILABLE", "Panel 公共状态版本不受支持")
    if not isinstance(config.get("enabled"), bool):
        raise PanelError("STATE_UNAVAILABLE", "Panel 启用状态无效")
    if config.get("listen_address") != DEFAULT_LISTEN_ADDRESS:
        raise PanelError("STATE_UNAVAILABLE", "Panel 只允许本机监听")
    if not isinstance(config.get("listen_port"), int) or not 1 <= config["listen_port"] <= 65535:
        raise PanelError("STATE_UNAVAILABLE", "Panel 监听端口无效")
    token = config.get("panel_path_token")
    if not isinstance(token, str) or not TOKEN_RE.fullmatch(token):
        raise PanelError("STATE_UNAVAILABLE", "Panel 入口 Token 无效")
    allowlist = config.get("ip_allowlist")
    if not isinstance(config.get("ip_allowlist_enabled"), bool) or not isinstance(allowlist, list):
        raise PanelError("STATE_UNAVAILABLE", "IP 白名单设置无效")
    for item in allowlist:
        try:
            ipaddress.ip_network(item, strict=False)
        except ValueError as exc:
            raise PanelError("STATE_UNAVAILABLE", "IP 白名单格式无效") from exc


def build_panel_configs(
    username: str,
    password: str,
    *,
    enabled: bool = False,
    instance_name: Optional[str] = None,
) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    validate_username(username)
    token = generate_panel_token()
    instance_id = f"rem-{uuid.uuid4()}"
    timestamp = now_iso()
    private = {
        "schema_version": PANEL_SCHEMA_VERSION,
        "enabled": bool(enabled),
        "listen_address": DEFAULT_LISTEN_ADDRESS,
        "listen_port": DEFAULT_LISTEN_PORT,
        "panel_path_token": token,
        "instance_id": instance_id,
        "instance_name": instance_name or socket.gethostname() or "REM",
        "admin_username": username,
        "admin_password_hash": hash_password(password),
        "ip_allowlist_enabled": False,
        "ip_allowlist": [],
        "session_timeout_seconds": DEFAULT_SESSION_TIMEOUT,
        "created_at": timestamp,
        "updated_at": timestamp,
    }
    public = {
        "schema_version": PANEL_SCHEMA_VERSION,
        "enabled": bool(enabled),
        "listen_address": DEFAULT_LISTEN_ADDRESS,
        "listen_port": DEFAULT_LISTEN_PORT,
        "panel_path_token": token,
        "ip_allowlist_enabled": False,
        "ip_allowlist": [],
        "session_timeout_seconds": DEFAULT_SESSION_TIMEOUT,
    }
    validate_private_config(private)
    validate_public_config(public)
    return private, public


def write_panel_configs(private: Mapping[str, Any], public: Mapping[str, Any]) -> None:
    validate_private_config(private)
    validate_public_config(public)
    if private["panel_path_token"] != public["panel_path_token"]:
        raise PanelError("STATE_UNAVAILABLE", "Panel Token 状态不一致")
    if os.path.lexists(PANEL_RUNTIME_DIR):
        info = os.lstat(PANEL_RUNTIME_DIR)
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise PanelError("STATE_UNAVAILABLE", "Panel 运行目录不是安全目录")
    else:
        os.makedirs(PANEL_RUNTIME_DIR, mode=0o750, exist_ok=False)
    os.chmod(PANEL_RUNTIME_DIR, 0o750)
    _atomic_write(PANEL_CONFIG, dict(private), 0o600)
    _atomic_write(PANEL_PUBLIC_CONFIG, dict(public), 0o640)
    try:
        import grp

        gid = grp.getgrnam(PANEL_GROUP).gr_gid
    except (ImportError, KeyError):
        gid = None
    if gid is not None:
        os.chown(PANEL_RUNTIME_DIR, 0, gid)
        os.chown(PANEL_PUBLIC_CONFIG, 0, gid)


def load_private_config() -> Dict[str, Any]:
    value = _read_json(PANEL_CONFIG)
    if not isinstance(value, dict):
        raise PanelError("STATE_UNAVAILABLE", "Panel 私有状态无效")
    validate_private_config(value)
    return value


def load_public_config() -> Dict[str, Any]:
    value = _read_json(PANEL_PUBLIC_CONFIG)
    if not isinstance(value, dict):
        raise PanelError("STATE_UNAVAILABLE", "Panel 公共状态无效")
    validate_public_config(value)
    return value


def allowed_client_ip(remote: str, config: Mapping[str, Any]) -> bool:
    if not config.get("ip_allowlist_enabled"):
        return True
    try:
        address = ipaddress.ip_address(remote)
    except ValueError:
        return False
    for item in config.get("ip_allowlist", []):
        try:
            if address in ipaddress.ip_network(item, strict=False):
                return True
        except ValueError:
            return False
    return False


def protocol_label(protocol: str) -> str:
    return {
        "shadowsocks": "SS2022",
        "vless": "VLESS",
        "hysteria2": "Hysteria2",
        "tuic": "TUIC",
    }.get(protocol, protocol)


def _number(value: Any) -> int:
    return value if isinstance(value, int) and value >= 0 else 0


def traffic_for_node(traffic: Mapping[str, Any], node_id: str) -> Dict[str, int]:
    entry = traffic.get("nodes", {}).get(node_id, {})
    if not isinstance(entry, dict):
        entry = {}
    upload = _number(entry.get("current_upload_bytes"))
    download = _number(entry.get("current_download_bytes"))
    total_upload = _number(entry.get("total_upload_bytes"))
    total_download = _number(entry.get("total_download_bytes"))
    return {
        "current_upload_bytes": upload,
        "current_download_bytes": download,
        "current_total_bytes": upload + download,
        "total_upload_bytes": total_upload,
        "total_download_bytes": total_download,
        "total_bytes": total_upload + total_download,
        "quota_bytes": _number(entry.get("quota_bytes")),
        "reset_day": _number(entry.get("reset_day")),
    }


def public_node(node: Mapping[str, Any], traffic: Mapping[str, Any]) -> Dict[str, Any]:
    protocol = str(node.get("protocol") or "shadowsocks")
    fields = (
        "node_id",
        "name",
        "port",
        "address",
        "address_type",
        "status",
        "status_reason",
        "subscription_enabled",
        "quota_bytes",
        "reset_day",
        "upload_limit_mbps",
        "download_limit_mbps",
        "created_at",
        "updated_at",
        "last_reset_at",
        "next_reset_at",
    )
    result: Dict[str, Any] = {field: node.get(field) for field in fields if field in node}
    result["protocol"] = protocol
    result["protocol_label"] = protocol_label(protocol)
    result["core"] = "sing-box"
    result["direction"] = "inbound"
    if protocol == "hysteria2":
        for field in ("port_hopping_enabled", "hop_port_start", "hop_port_end", "hop_interval"):
            if field in node:
                result[field] = node[field]
    elif protocol == "vless":
        result["flow"] = node.get("flow", "xtls-rprx-vision")
        result["reality_server_name"] = node.get("reality_server_name")
    elif protocol == "tuic":
        for field in ("congestion_control", "zero_rtt_handshake", "tls_server_name"):
            if field in node:
                result[field] = node[field]
    result["traffic"] = traffic_for_node(traffic, str(node.get("node_id", "")))
    return result


def public_nodes() -> Dict[str, Any]:
    nodes = read_nodes()
    traffic = read_traffic()
    return {
        "schema_version": nodes.get("schema_version"),
        "nodes": [public_node(node, traffic) for node in nodes.get("nodes", []) if isinstance(node, dict)],
    }


def public_traffic() -> Dict[str, Any]:
    nodes = public_nodes()["nodes"]
    totals = {
        "current_upload_bytes": sum(item["traffic"]["current_upload_bytes"] for item in nodes),
        "current_download_bytes": sum(item["traffic"]["current_download_bytes"] for item in nodes),
        "total_upload_bytes": sum(item["traffic"]["total_upload_bytes"] for item in nodes),
        "total_download_bytes": sum(item["traffic"]["total_download_bytes"] for item in nodes),
    }
    totals["current_total_bytes"] = totals["current_upload_bytes"] + totals["current_download_bytes"]
    totals["total_bytes"] = totals["total_upload_bytes"] + totals["total_download_bytes"]
    return {"totals": totals, "nodes": nodes}


def sanitized_time_sync(state: Mapping[str, Any]) -> Dict[str, Any]:
    value = state.get("time_sync")
    if not isinstance(value, dict):
        value = {}
    allowed = (
        "system_sync_enabled",
        "singbox_ntp_enabled",
        "ntp_server",
        "ntp_port",
        "ntp_interval",
        "provider",
        "service_name",
        "installed_by_rem",
        "last_status",
        "last_checked_at",
        "last_sync_at",
    )
    result = {field: value.get(field) for field in allowed if field in value}
    result.update(local_time_info())
    return result


def sanitized_subscription() -> Dict[str, Any]:
    value = read_subscription()
    allowed = ("schema_version", "enabled", "listen_address", "listen_port", "public_base_url")
    result = {field: value.get(field) for field in allowed if field in value}
    result["token_present"] = isinstance(value.get("token"), str) and bool(value.get("token"))
    return result


def panel_identity() -> Dict[str, Optional[str]]:
    try:
        config = load_private_config()
    except PanelError:
        return {"instance_id": None, "instance_name": None}
    return {
        "instance_id": config.get("instance_id"),
        "instance_name": config.get("instance_name"),
    }


def check_service_state() -> Dict[str, Any]:
    """Return a conservative service state without executing arbitrary input."""
    # The core deliberately does not expose a command runner.  A state of
    # unknown is safer than claiming a service is healthy when the host has no
    # init system available to this process.
    return {"name": "sing-box", "state": "unknown"}


def dashboard() -> Dict[str, Any]:
    state = read_manager_state()
    identity = panel_identity()
    node_items = public_nodes()["nodes"]
    counts: Dict[str, int] = {}
    for node in node_items:
        counts[node["protocol"]] = counts.get(node["protocol"], 0) + 1
    traffic = public_traffic()["totals"]
    return {
        "api_version": API_VERSION,
        "manager_version": state.get("manager_version", "unknown"),
        "instance_id": identity["instance_id"] or state.get("instance_id"),
        "instance_name": identity["instance_name"] or state.get("instance_name"),
        "sing_box": {
            "state": check_service_state(),
            "version": state.get("sing_box_version", ""),
        },
        "nodes": {
            "total": len(node_items),
            "enabled": sum(1 for node in node_items if node.get("status") == "enabled"),
            "disabled": sum(1 for node in node_items if node.get("status") != "enabled"),
            "by_protocol": counts,
        },
        "traffic": traffic,
        "time_sync": sanitized_time_sync(state),
    }


def system_status() -> Dict[str, Any]:
    state = read_manager_state()
    identity = panel_identity()
    return {
        "api_version": API_VERSION,
        "manager_version": state.get("manager_version", "unknown"),
        "instance_id": identity["instance_id"] or state.get("instance_id"),
        "instance_name": identity["instance_name"] or state.get("instance_name"),
        "init_system": state.get("init_system"),
        "sing_box_version": state.get("sing_box_version", ""),
        "time_sync": sanitized_time_sync(state),
    }


def capabilities() -> Dict[str, Any]:
    return {
        "api_version": API_VERSION,
        "manager_core": {"read": True, "write": False},
        "core": "sing-box",
        "protocols": ["shadowsocks", "vless", "hysteria2", "tuic"],
        "features": {
            "dashboard": True,
            "nodes_read": True,
            "traffic_read": True,
            "subscription_read": True,
            "time_sync_read": True,
            "write_api": False,
            "remote_pairing": False,
            "ip_allowlist_ui": False,
            "totp": False,
        },
    }


def json_response(ok: bool, *, data: Any = None, code: str = "", message: str = "") -> bytes:
    if ok:
        value = {"ok": True, "data": data}
    else:
        value = {"ok": False, "error": {"code": code or "ERROR", "message": message or "请求失败"}}
    return (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
