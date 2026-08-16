#!/usr/bin/env python3
"""End-to-end tests for the read-only Web Panel foundation.

The fixture deliberately includes all four supported protocols and server-only
credentials.  The assertions ensure that the HTTP boundary never returns the
private fields while the core and panel still expose the common model.
"""

from __future__ import annotations

import base64
import fcntl
import http.client
import json
import os
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.parse
from pathlib import Path
from typing import Dict, Optional, Tuple


ROOT = Path(__file__).resolve().parents[1]
WEB = ROOT / "web"
sys.path.insert(0, str(WEB))


class WebPanelTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="rem-panel-test-")
        base = Path(self.temp.name)
        self.config = base / "etc"
        self.data = base / "data"
        self.runtime = base / "run"
        self.panel_runtime = base / "panel-run"
        for path in (self.config, self.data, self.runtime, self.panel_runtime):
            path.mkdir(mode=0o700)
        self.socket_path = self.panel_runtime / "core.sock"
        self.env = os.environ.copy()
        self.env.update(
            {
                "SS_MANAGER_CONFIG_DIR": str(self.config),
                "SS_MANAGER_DATA_DIR": str(self.data),
                "SS_MANAGER_RUNTIME_DIR": str(self.runtime),
                "SS_MANAGER_PANEL_RUNTIME_DIR": str(self.panel_runtime),
                "SS_MANAGER_PANEL_CORE_SOCKET": str(self.socket_path),
                "SS_MANAGER_PANEL_CONFIG": str(self.config / "panel.json"),
                "SS_MANAGER_PANEL_PUBLIC_CONFIG": str(self.panel_runtime / "public.json"),
                "SS_MANAGER_LOCK": str(self.runtime / "manager.lock"),
                "SS_MANAGER_MANAGER_STATE": str(self.config / "manager.json"),
                "SS_MANAGER_NODES_FILE": str(self.data / "nodes.json"),
                "SS_MANAGER_TRAFFIC_FILE": str(self.data / "traffic.json"),
                "SS_MANAGER_HISTORY_FILE": str(self.data / "traffic-history.json"),
                "SS_MANAGER_SUBSCRIPTION_CONFIG": str(self.config / "subscription.json"),
                "PYTHONPATH": str(WEB),
            }
        )
        self._write_fixtures()
        self.core = subprocess.Popen(
            [sys.executable, str(WEB / "panel_core.py"), "--socket", str(self.socket_path)],
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self._wait_socket()
        self.panel_port = self._free_port()
        self.panel = subprocess.Popen(
            [sys.executable, str(WEB / "panel_server.py"), "--port", str(self.panel_port)],
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        for _ in range(50):
            if self.panel.poll() is not None:
                error = self.panel.stderr.read() if self.panel.stderr else ""
                raise RuntimeError(f"panel_server exited during startup: {error}")
            try:
                probe = socket.create_connection(("127.0.0.1", self.panel_port), timeout=0.1)
                probe.close()
                break
            except OSError:
                time.sleep(0.05)
        else:
            error = self.panel.stderr.read() if self.panel.stderr else ""
            raise RuntimeError(f"panel_server did not listen: {error}")

    def tearDown(self) -> None:
        for process in (getattr(self, "panel", None), getattr(self, "core", None)):
            if process is not None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                for stream in (process.stdout, process.stderr):
                    if stream is not None:
                        stream.close()
        self.temp.cleanup()

    def _write_json(self, path: Path, value: object, mode: int = 0o600) -> None:
        path.write_text(json.dumps(value), encoding="utf-8")
        path.chmod(mode)

    def _write_fixtures(self) -> None:
        node_common = {
            "port": 20001,
            "address": "198.51.100.10",
            "address_type": "ipv4",
            "status": "enabled",
            "status_reason": "",
            "subscription_enabled": True,
            "quota_bytes": 0,
            "reset_day": 1,
            "upload_limit_mbps": 0,
            "download_limit_mbps": 0,
            "created_at": "2026-08-16T00:00:00Z",
            "updated_at": "2026-08-16T00:00:00Z",
            "last_reset_at": "2026-08-01T00:00:00Z",
            "next_reset_at": "2026-09-01T00:00:00Z",
        }
        nodes = [
            {**node_common, "node_id": "a" * 32, "name": "SS", "protocol": "shadowsocks", "method": "2022-blake3-aes-256-gcm", "password": "server-secret"},
            {**node_common, "node_id": "b" * 32, "name": "VLESS", "protocol": "vless", "uuid": "00000000-0000-4000-8000-000000000001", "flow": "xtls-rprx-vision", "reality_private_key": "private-reality-key", "reality_public_key": "public-reality-key", "reality_short_id": "0123456789abcdef", "reality_server_name": "example.com", "reality_handshake_server": "example.com", "reality_handshake_port": 443, "port": 20002},
            {**node_common, "node_id": "c" * 32, "name": "HY2", "protocol": "hysteria2", "password": "hy2-secret", "tls_server_name": "hy2.example.com", "certificate_sha256": "0" * 64, "port_hopping_enabled": False, "hop_port_start": None, "hop_port_end": None, "hop_interval": "30s", "port": 20003},
            {**node_common, "node_id": "d" * 32, "name": "TUIC", "protocol": "tuic", "uuid": "00000000-0000-4000-8000-000000000002", "password": "tuic-secret", "congestion_control": "bbr", "auth_timeout": "3s", "zero_rtt_handshake": False, "heartbeat": "10s", "tls_server_name": "tuic.example.com", "certificate_sha256": "1" * 64, "port": 20004},
        ]
        self._write_json(self.data / "nodes.json", {"schema_version": 5, "nodes": nodes})
        self._write_json(
            self.data / "traffic.json",
            {
                "schema_version": 1,
                "nodes": {
                    node["node_id"]: {
                        "current_upload_bytes": 10,
                        "current_download_bytes": 20,
                        "total_upload_bytes": 100,
                        "total_download_bytes": 200,
                        "quota_bytes": 0,
                        "reset_day": 1,
                    }
                    for node in nodes
                },
            },
        )
        self._write_json(self.data / "traffic-history.json", {"schema_version": 1, "cycles": {}})
        self._write_json(
            self.config / "manager.json",
            {
                "schema_version": 1,
                "manager_version": "1.3.0-dev.1",
                "instance_id": "rem-00000000-0000-4000-8000-000000000001",
                "instance_name": "test-rem",
                "init_system": "systemd",
                "sing_box_version": "1.13.18",
                "time_sync": {"system_sync_enabled": True, "singbox_ntp_enabled": True, "provider": "chrony", "last_status": "synchronized", "ntp_server": "time.apple.com", "ntp_port": 123, "ntp_interval": "30m"},
            },
        )
        self._write_json(self.config / "subscription.json", {"schema_version": 1, "enabled": False, "listen_address": "127.0.0.1", "listen_port": 18080, "public_base_url": None, "token": "A" * 43})
        # Import after the test environment is prepared; constants are bound
        # from the isolated paths and never point at a real host.
        os.environ.update(self.env)
        sys.modules.pop("panel_common", None)
        import panel_common

        private, public = panel_common.build_panel_configs("admin", "correct horse battery staple", enabled=True, instance_name="test-rem")
        panel_common.write_panel_configs(private, public)
        self.token = private["panel_path_token"]

    def _wait_socket(self) -> None:
        for _ in range(50):
            if self.socket_path.exists():
                return
            if self.core.poll() is not None:
                self.fail(self.core.stderr.read())
            time.sleep(0.05)
        self.fail("Manager Core socket did not start")

    @staticmethod
    def _free_port() -> int:
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
        sock.close()
        return port

    def _request(self, method: str, path: str, body: bytes = b"", headers: Optional[Dict[str, str]] = None) -> Tuple[int, dict, http.client.HTTPResponse]:
        connection = http.client.HTTPConnection("127.0.0.1", self.panel_port, timeout=5)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        raw = response.read()
        if raw and "application/json" in (response.getheader("Content-Type") or ""):
            value = json.loads(raw.decode("utf-8"))
        else:
            value = {}
        return response.status, value, response

    def test_gate_login_api_and_no_secret_leak(self) -> None:
        status, _, _ = self._request("GET", "/")
        self.assertEqual(status, 404)
        status, _, _ = self._request("GET", "/wrong-token/")
        self.assertEqual(status, 404)
        status, _, _ = self._request("GET", f"/{self.token}/")
        self.assertEqual(status, 200)

        form = urllib.parse.urlencode({"username": "admin", "password": "wrong"}).encode()
        status, value, _ = self._request("POST", f"/{self.token}/api/v1/login", form, {"Content-Type": "application/x-www-form-urlencoded"})
        self.assertEqual(status, 401)
        self.assertFalse(value["ok"])
        time.sleep(2.1)
        form = urllib.parse.urlencode({"username": "admin", "password": "correct horse battery staple"}).encode()
        status, value, response = self._request("POST", f"/{self.token}/api/v1/login", form, {"Content-Type": "application/x-www-form-urlencoded"})
        self.assertEqual(status, 200)
        self.assertTrue(value["ok"])
        cookie = response.getheader("Set-Cookie").split(";", 1)[0]
        self.assertIn("HttpOnly", response.getheader("Set-Cookie"))
        self.assertIn("Secure", response.getheader("Set-Cookie"))
        status, value, _ = self._request("GET", f"/{self.token}/api/v1/dashboard", headers={"Cookie": cookie})
        self.assertEqual(status, 200)
        text = json.dumps(value, ensure_ascii=False)
        for secret in ("server-secret", "private-reality-key", "hy2-secret", "tuic-secret", "reality_private_key", "password"):
            self.assertNotIn(secret, text)
        self.assertEqual(value["data"]["nodes"]["total"], 4)
        self.assertEqual(value["data"]["nodes"]["by_protocol"]["vless"], 1)

        status, value, _ = self._request("GET", f"/{self.token}/api/v1/capabilities", headers={"Cookie": cookie})
        self.assertEqual(status, 200)
        self.assertFalse(value["data"]["features"]["write_api"])
        status, _, _ = self._request("GET", f"/{self.token}/api/v1/exec", headers={"Cookie": cookie})
        self.assertEqual(status, 404)

    def test_panel_init_cli_uses_stdin_and_preserves_existing_state(self) -> None:
        base = Path(self.temp.name) / "cli"
        for path in (base / "etc", base / "data", base / "run", base / "panel-run"):
            path.mkdir(parents=True, mode=0o700)
        env = self.env.copy()
        env.update(
            {
                "SS_MANAGER_CONFIG_DIR": str(base / "etc"),
                "SS_MANAGER_DATA_DIR": str(base / "data"),
                "SS_MANAGER_RUNTIME_DIR": str(base / "run"),
                "SS_MANAGER_PANEL_RUNTIME_DIR": str(base / "panel-run"),
                "SS_MANAGER_PANEL_CONFIG": str(base / "etc" / "panel.json"),
                "SS_MANAGER_PANEL_PUBLIC_CONFIG": str(base / "panel-run" / "public.json"),
            }
        )
        command = [sys.executable, str(WEB / "panel_init.py"), "--username", "admin", "--password-stdin", "--enable", "--print-token"]
        first = subprocess.run(command, input="PanelTestPassword-123!\n", text=True, capture_output=True, env=env, check=False)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(len(first.stdout.strip()), 43)
        self.assertEqual((base / "etc" / "panel.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual((base / "panel-run" / "public.json").stat().st_mode & 0o777, 0o640)
        self.assertNotIn("PanelTestPassword-123!", (base / "etc" / "panel.json").read_text(encoding="utf-8"))
        second = subprocess.run(command, input="PanelTestPassword-123!\n", text=True, capture_output=True, env=env, check=False)
        self.assertNotEqual(second.returncode, 0)

    def test_manager_lock_is_shared_and_returns_busy(self) -> None:
        lock_path = Path(self.env["SS_MANAGER_LOCK"])
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            import panel_common

            result = panel_common.json_response(True, data={})
            # Use the core socket directly to exercise the exact lock path.
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(str(self.socket_path))
            sock.sendall(b'{"method":"dashboard","params":{}}\n')
            value = json.loads(sock.recv(4096).decode())
            sock.close()
            self.assertFalse(value["ok"])
            self.assertEqual(value["error"]["code"], "BUSY")
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)


if __name__ == "__main__":
    unittest.main(verbosity=2)
