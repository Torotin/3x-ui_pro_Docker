import json
import sys
import tempfile
import threading
import unittest
from unittest import mock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.apply.xray import (  # noqa: E402
    XrayApplyProbes,
    apply_managed_xray,
    _xray_settings_effectively_equal,
)
from xui_runtime.api import PanelApi  # noqa: E402
from xui_runtime.http_client import HttpSession  # noqa: E402


def _empty_xray_obj() -> str:
    return json.dumps(
        {
            "xraySetting": {
                "outbounds": [],
                "routing": {"rules": []},
            }
        }
    )


class _XrayHandler(BaseHTTPRequestHandler):
    records: list[dict[str, object]] = []
    routes: dict[str, tuple[int, dict[str, object]]] = {}

    def _path_only(self) -> str:
        return urlparse(self.path).path

    def _respond(self, path: str) -> tuple[int, dict[str, object]]:
        routes = type(self).routes
        if path in routes:
            return routes[path]
        for key, value in routes.items():
            if path.endswith(key):
                return value
        return 200, {"success": True}

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def do_GET(self) -> None:
        path = self._path_only()
        type(self).records.append({"method": "GET", "path": path, "body": b""})
        status, payload = self._respond(path)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode("utf-8"))

    def do_POST(self) -> None:
        body = self._read_body()
        path = self._path_only()
        type(self).records.append(
            {
                "method": "POST",
                "path": path,
                "body": body,
            }
        )
        status, payload = self._respond(path)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode("utf-8"))

    def log_message(self, format: str, *args: object) -> None:
        return


def _make_api(env: dict[str, str]) -> tuple[PanelApi, HttpSession, tempfile.TemporaryDirectory]:
    tmp = tempfile.TemporaryDirectory()
    session = HttpSession(attempts=1, max_time=3, log_failures=False, sleep_fn=lambda _: None)
    session.init(tmp.name)
    return PanelApi(session, env), session, tmp



class TestXraySettingsEqual(unittest.TestCase):
    def test_routing_rules_order_only_is_noop(self) -> None:
        rule_api = {"type": "field", "inboundTag": ["api"], "outboundTag": "api"}
        rule_admin = {
            "type": "field",
            "outboundTag": "admin-traefik",
            "domain": ["full:a.example.test"],
        }
        current = {
            "xraySetting": {"routing": {"rules": [rule_api, rule_admin]}, "outbounds": []}
        }
        updated = {
            "xraySetting": {"routing": {"rules": [rule_admin, rule_api]}, "outbounds": []}
        }
        self.assertTrue(_xray_settings_effectively_equal(current, updated))
        updated["xraySetting"]["routing"]["rules"].append(
            {"type": "field", "outboundTag": "blocked", "ip": ["geoip:private"]}
        )
        self.assertFalse(_xray_settings_effectively_equal(current, updated))


class TestApplyManagedXray(unittest.TestCase):
    def setUp(self) -> None:
        _XrayHandler.records = []
        _XrayHandler.routes = {
            "/csrf-token": (200, {"success": True, "obj": "csrf-fixture"}),
            "/panel/api/xray/": (200, {"success": True, "obj": _empty_xray_obj()}),
            "/panel/api/xray/update": (200, {"success": True}),
        }
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _XrayHandler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.port}/panel"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def test_plan_mode_does_not_post_update(self) -> None:
        env = {
            "URL_BASE_RESOLVED": self.base,
            "XRAY_MANAGED_WARP": "true",
            "XRAY_MANAGED_WARP_CONSOLE": "false",
            "XRAY_MANAGED_DNS": "false",
            "XRAY_MANAGED_TOR": "false",
            "ENABLE_MIHOMO": "true",
            "USQUE_HOST": "usque",
            "USQUE_PORT": "1080",
            "MIHOMO_PROXY_HOST": "mihomo",
            "MIHOMO_PROXY_PORT": "7890",
            "WEBDOMAIN": "screenhub.linkpc.net",
        }
        api, _session, tmp = _make_api(env)
        self.addCleanup(tmp.cleanup)
        probes = XrayApplyProbes(
            warp_proxy_available=lambda _h, _p: False,
            tcp_endpoint_available=lambda h, p, _t: h == "mihomo" and p == 7890,
        )
        stats = apply_managed_xray(api, env, None, "plan", probes=probes)
        updates = [r for r in _XrayHandler.records if r["path"].endswith("/xray/update")]
        self.assertTrue(stats.changed)
        self.assertFalse(stats.applied)
        self.assertEqual(0, len(updates))
        self.assertTrue(any("PLAN:" in msg for msg in stats.plan_messages))

    def test_mihomo_endpoint_only_when_reachable(self) -> None:
        env = {
            "URL_BASE_RESOLVED": self.base,
            "XRAY_MANAGED_DNS": "false",
            "XRAY_MANAGED_WARP": "true",
            "XRAY_MANAGED_WARP_CONSOLE": "false",
            "XRAY_MANAGED_TOR": "false",
            "ENABLE_MIHOMO": "true",
            "USQUE_HOST": "usque",
            "USQUE_PORT": "1080",
            "MIHOMO_PROXY_HOST": "mihomo",
            "MIHOMO_PROXY_PORT": "7890",
            "WEBDOMAIN": "screenhub.linkpc.net",
        }
        api, _session, tmp = _make_api(env)
        self.addCleanup(tmp.cleanup)

        from xui_runtime.json_state import apply_managed_xray_state  # noqa: E402

        def capture_mihomo(h: str, p: int, _t: float) -> bool:
            return h == "mihomo" and p == 7890

        probes = XrayApplyProbes(
            warp_proxy_available=lambda _h, _p: False,
            tcp_endpoint_available=capture_mihomo,
        )
        with mock.patch(
            "xui_runtime.apply.xray.apply_managed_xray_state",
            wraps=apply_managed_xray_state,
        ) as spy:
            apply_managed_xray(api, env, None, "apply", probes=probes)
            self.assertTrue(spy.called)
            self.assertEqual(
                [{"tag": "mihomo", "host": "mihomo", "port": 7890}],
                spy.call_args.args[10],
            )

        probes = XrayApplyProbes(
            warp_proxy_available=lambda _h, _p: False,
            tcp_endpoint_available=lambda _h, _p, _t: False,
        )
        with mock.patch(
            "xui_runtime.apply.xray.apply_managed_xray_state",
            wraps=apply_managed_xray_state,
        ) as spy:
            apply_managed_xray(api, env, None, "apply", probes=probes)
            self.assertTrue(spy.called)
            self.assertEqual([], spy.call_args.args[10])


    def test_console_warp_registration_failure_is_soft(self) -> None:
        env = {
            "URL_BASE_RESOLVED": self.base,
            "XRAY_MANAGED_DNS": "false",
            "XRAY_MANAGED_WARP": "true",
            "XRAY_MANAGED_WARP_CONSOLE": "true",
            "XRAY_MANAGED_TOR": "false",
            "ENABLE_MIHOMO": "false",
            "USQUE_HOST": "usque",
            "USQUE_PORT": "1080",
            "WEBDOMAIN": "screenhub.linkpc.net",
        }
        api, _session, tmp = _make_api(env)
        self.addCleanup(tmp.cleanup)
        probes = XrayApplyProbes(warp_proxy_available=lambda _h, _p: False)
        with mock.patch(
            "xui_runtime.apply.xray.ensure_warp_console_outbound",
            side_effect=RuntimeError("WARP registration API failed"),
        ):
            stats = apply_managed_xray(api, env, None, "apply", probes=probes)
        self.assertTrue(stats.changed)
        self.assertTrue(stats.applied)


if __name__ == "__main__":
    unittest.main()