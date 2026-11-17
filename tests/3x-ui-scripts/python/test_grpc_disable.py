import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import MagicMock, patch
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.api import PanelApi  # noqa: E402
from xui_runtime.apply.inbound.grpc_policy import ensure_grpc_when_disabled  # noqa: E402
from xui_runtime.common import ApplyStats  # noqa: E402
from xui_runtime.desired import build_desired_state  # noqa: E402
from xui_runtime.http_client import HttpSession  # noqa: E402


def _env_fixture() -> dict[str, str]:
    return {
        "WEBDOMAIN": "fixture.example.test",
        "CLIENT_EMAIL_PREFIX": "autogen",
        "CLIENT_SUB_ID": "stable-sub",
        "EMOJI_FLAG": "\u26a0",
        "ENABLE_VLESS_GRPC": "false",
        "VLESS_GRPC_WHEN_DISABLED": "disable",
    }


def _grpc_row(desired: dict, *, inbound_id: int = 9, enable: bool = True) -> dict:
    grpc = desired["inbounds"]["grpc"]
    return {
        "id": inbound_id,
        "remark": grpc["remark"],
        "port": grpc["port"],
        "protocol": grpc["protocol"],
        "enable": enable,
        "settings": '{"clients":[{"id":"c1","email":"a@b.test"}]}',
    }


class TestEnsureGrpcWhenDisabled(unittest.TestCase):
    def setUp(self) -> None:
        self.env = _env_fixture()
        self.desired = build_desired_state(self.env)
        self.stats = ApplyStats()
        self.api = MagicMock()
        self.api.session.success_json.return_value = True

    def test_disable_policy_calls_set_enable_false(self) -> None:
        row = _grpc_row(self.desired)
        with patch(
            "xui_runtime.apply.inbound.grpc_policy._list_inbounds",
            return_value=[row],
        ):
            ensure_grpc_when_disabled(self.desired, self.api, self.env, "apply", self.stats)
        self.api.set_inbound_enable.assert_called_once_with("9", False)
        self.assertEqual(self.stats.change_count, 1)

    def test_leave_policy_does_not_set_enable(self) -> None:
        self.env["VLESS_GRPC_WHEN_DISABLED"] = "leave"
        row = _grpc_row(self.desired)
        with patch(
            "xui_runtime.apply.inbound.grpc_policy._list_inbounds",
            return_value=[row],
        ):
            ensure_grpc_when_disabled(self.desired, self.api, self.env, "apply", self.stats)
        self.api.set_inbound_enable.assert_not_called()
        self.api.del_inbound.assert_not_called()

    def test_already_disabled_is_noop(self) -> None:
        row = _grpc_row(self.desired, enable=False)
        with patch(
            "xui_runtime.apply.inbound.grpc_policy._list_inbounds",
            return_value=[row],
        ):
            ensure_grpc_when_disabled(self.desired, self.api, self.env, "apply", self.stats)
        self.api.set_inbound_enable.assert_not_called()
        self.assertEqual(self.stats.change_count, 0)

    def test_delete_policy_uses_delete_managed(self) -> None:
        self.env["VLESS_GRPC_WHEN_DISABLED"] = "delete"
        row = _grpc_row(self.desired)
        with patch(
            "xui_runtime.apply.inbound.ensure._list_inbounds",
            return_value=[row],
        ):
            ensure_grpc_when_disabled(self.desired, self.api, self.env, "apply", self.stats)
        self.api.del_inbound.assert_called_once_with("9")
        self.assertEqual(self.stats.change_count, 1)


def _make_api(env: dict[str, str] | None = None) -> tuple[PanelApi, HttpSession, tempfile.TemporaryDirectory]:
    tmp = tempfile.TemporaryDirectory()
    session = HttpSession(attempts=4, max_time=8, log_failures=False, sleep_fn=lambda _: None)
    session.init(tmp.name)
    api_env = {
        "USERNAME": "admin",
        "PASSWORD": "admin",
        "XUI_API_TOKEN": "",
        "XUI_API_TOKEN_RESOLVED": "",
        "URL_BASE_RESOLVED": "",
        **(env or {}),
    }
    return PanelApi(session, api_env), session, tmp


class _SetEnableHandler(BaseHTTPRequestHandler):
    records: list[dict[str, object]] = []
    inbound_obj: dict[str, object] = {}

    def _path_only(self) -> str:
        return urlparse(self.path).path

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _send_json(self, status: int, payload: dict[str, object]) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode("utf-8"))

    def do_GET(self) -> None:
        path = self._path_only()
        type(self).records.append({"method": "GET", "path": path})
        if path.endswith("/panel/api/inbounds/get/7"):
            self._send_json(200, {"success": True, "obj": dict(type(self).inbound_obj)})
            return
        self._send_json(404, {"success": False})

    def do_POST(self) -> None:
        path = self._path_only()
        body = self._read_body()
        type(self).records.append({"method": "POST", "path": path, "body": body})
        if path.endswith("/panel/api/inbounds/setEnable/7"):
            self._send_json(404, {"success": False})
            return
        if path.endswith("/panel/api/inbounds/update/7"):
            self._send_json(200, {"success": True, "obj": {"id": 7}})
            return
        self._send_json(404, {"success": False})

    def log_message(self, format: str, *args: object) -> None:
        return


class TestSetInboundEnableFallback(unittest.TestCase):
    def setUp(self) -> None:
        _SetEnableHandler.records = []
        _SetEnableHandler.inbound_obj = {
            "id": 7,
            "enable": True,
            "port": 9444,
            "protocol": "vless",
            "settings": {"clients": [{"id": "c1", "email": "keep@example.test"}]},
            "streamSettings": {},
            "sniffing": {},
        }
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _SetEnableHandler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.port}/panel-base"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def test_set_enable_404_falls_back_to_full_update_preserving_clients(self) -> None:
        api, session, tmp = _make_api({"URL_BASE_RESOLVED": self.base})
        self.addCleanup(tmp.cleanup)
        original_csrf = api.csrf_token
        api.csrf_token = lambda: ""  # type: ignore[method-assign]
        self.addCleanup(lambda: setattr(api, "csrf_token", original_csrf))

        result = api.set_inbound_enable(7, False)
        self.assertTrue(result.ok)
        self.assertTrue(session.success_json())

        update_posts = [
            r
            for r in _SetEnableHandler.records
            if r["method"] == "POST" and str(r["path"]).endswith("/panel/api/inbounds/update/7")
        ]
        self.assertEqual(1, len(update_posts))
        payload = json.loads(update_posts[0]["body"].decode("utf-8"))
        self.assertFalse(payload["enable"])
        clients = payload["settings"]["clients"]
        self.assertEqual(1, len(clients))
        self.assertEqual("keep@example.test", clients[0]["email"])


if __name__ == "__main__":
    unittest.main()