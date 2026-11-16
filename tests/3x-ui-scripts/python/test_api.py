import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.api import PanelApi  # noqa: E402
from xui_runtime.http_client import HttpSession  # noqa: E402


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
        "HTTP_LONG_MAX_TIME": "180",
        **(env or {}),
    }
    return PanelApi(session, api_env), session, tmp


class _RecordingHandler(BaseHTTPRequestHandler):
    records: list[dict[str, object]] = []
    routes: dict[str, tuple[int, dict[str, object]]] = {}

    def _path_only(self) -> str:
        return urlparse(self.path).path

    def _route_response(self, path: str) -> tuple[int, dict[str, object]]:
        routes = type(self).routes
        if path in routes:
            return routes[path]
        for key, value in routes.items():
            if path.endswith(key):
                return value
        return 200, {"success": True}

    def _record(self, method: str) -> None:
        auth = self.headers.get("Authorization", "")
        csrf = self.headers.get("X-CSRF-Token", "")
        ctype = self.headers.get("Content-Type", "")
        body = b""
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length > 0:
            body = self.rfile.read(length)
        type(self).records.append(
            {
                "method": method,
                "path": self._path_only(),
                "authorization": auth,
                "csrf": csrf,
                "content_type": ctype,
                "body": body,
            }
        )
        route = self._path_only()
        status, payload = self._route_response(route)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode("utf-8"))

    def do_GET(self) -> None:
        self._record("GET")

    def do_POST(self) -> None:
        self._record("POST")

    def log_message(self, format: str, *args: object) -> None:
        return


class TestPanelApiAuthAndRoutes(unittest.TestCase):
    def setUp(self) -> None:
        _RecordingHandler.records = []
        _RecordingHandler.routes = {
            "/csrf-token": (200, {"success": True, "obj": "csrf-fixture"}),
            "/login": (200, {"success": True}),
        }
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _RecordingHandler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.port}/panel-base"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def test_bearer_token_on_panel_api_routes(self) -> None:
        api, _session, tmp = _make_api(
            {
                "XUI_API_TOKEN": "test-token",
                "URL_BASE_RESOLVED": self.base,
            }
        )
        self.addCleanup(tmp.cleanup)
        api.list_inbounds()
        api.add_inbound(
            {
                "remark": "test",
                "port": 443,
                "protocol": "vless",
                "settings": {},
                "streamSettings": {},
                "sniffing": {},
            }
        )
        api.restart_xray()
        api.get_panel_settings()

        bearer_hits = [r for r in _RecordingHandler.records if r["authorization"] == "Bearer test-token"]
        self.assertEqual(4, len(bearer_hits))
        def ends(path_suffix: str) -> bool:
            return any(str(r["path"]).endswith(path_suffix) for r in _RecordingHandler.records)

        paths = [r["path"] for r in _RecordingHandler.records]
        self.assertTrue(ends("/panel/api/inbounds/list"))
        self.assertTrue(ends("/panel/api/server/restartXrayService"))
        settings_calls = [
            r for r in _RecordingHandler.records if str(r["path"]).endswith("/panel/api/setting/all")
        ]
        self.assertEqual(1, len(settings_calls))
        self.assertEqual("Bearer test-token", settings_calls[0]["authorization"])
        legacy_settings = [
            r for r in _RecordingHandler.records if str(r["path"]).endswith("/panel/setting/all")
        ]
        self.assertEqual(0, len(legacy_settings))

    def test_no_bearer_when_token_unset(self) -> None:
        api, _session, tmp = _make_api({"URL_BASE_RESOLVED": self.base})
        self.addCleanup(tmp.cleanup)
        api.list_inbounds()
        bearer = [r for r in _RecordingHandler.records if str(r["authorization"]).startswith("Bearer")]
        self.assertEqual(0, len(bearer))

    def test_login_replays_csrf_token(self) -> None:
        api, _session, tmp = _make_api()
        self.addCleanup(tmp.cleanup)
        ok = api.login(self.base, "admin", "admin")
        self.assertTrue(ok)
        login_rows = [r for r in _RecordingHandler.records if str(r["path"]).endswith("/login")]
        self.assertEqual(1, len(login_rows))
        self.assertEqual("csrf-fixture", login_rows[0]["csrf"])
        self.assertIn("application/json", str(login_rows[0]["content_type"]))

    def test_non_bearer_post_replays_csrf_token(self) -> None:
        api, _session, tmp = _make_api({"URL_BASE_RESOLVED": self.base})
        self.addCleanup(tmp.cleanup)
        api.get_panel_settings()
        settings_rows = [
            r
            for r in _RecordingHandler.records
            if str(r["path"]).endswith("/panel/api/setting/all")
            or str(r["path"]).endswith("/panel/setting/all")
        ]
        self.assertGreaterEqual(len(settings_rows), 1)
        self.assertEqual("csrf-fixture", settings_rows[0]["csrf"])

    def test_settings_fallback_to_legacy_on_404(self) -> None:
        _RecordingHandler.records = []
        _RecordingHandler.routes = {
            "/csrf-token": (200, {"success": True, "obj": "csrf-fixture"}),
            "/panel/api/setting/all": (404, {}),
            "/panel/setting/all": (200, {"success": True, "obj": {"webPort": 2053}}),
        }
        api, session, tmp = _make_api({"URL_BASE_RESOLVED": self.base})
        self.addCleanup(tmp.cleanup)
        api.get_panel_settings()
        self.assertTrue(session.success_json())
        canonical = [
            r for r in _RecordingHandler.records if str(r["path"]).endswith("/panel/api/setting/all")
        ]
        legacy = [
            r for r in _RecordingHandler.records if str(r["path"]).endswith("/panel/setting/all")
        ]
        self.assertEqual(1, len(canonical))
        self.assertEqual(1, len(legacy))

    def test_client_json_routes(self) -> None:
        _RecordingHandler.records = []
        _RecordingHandler.routes = {
            "/csrf-token": (200, {"success": True, "obj": "csrf-fixture"}),
            "/panel/api/clients/get/a%40example.test": (
                200,
                {
                    "success": True,
                    "obj": {
                        "email": "a@example.test",
                        "subId": "old",
                        "limitIp": 0,
                        "totalGB": 0,
                        "expiryTime": 0,
                        "reset": 0,
                        "tgId": 0,
                        "comment": "",
                        "enable": True,
                        "security": "auto",
                        "group": "",
                    },
                },
            ),
        }
        api, _session, tmp = _make_api(
            {"XUI_API_TOKEN": "test-token", "URL_BASE_RESOLVED": self.base}
        )
        self.addCleanup(tmp.cleanup)
        api.add_client({"client": {"email": "a@example.test"}, "inboundIds": [1]})
        api.update_client(
            "a@example.test",
            {"email": "a@example.test", "id": "11111111-2222-3333-8444-555555555555"},
        )
        api.list_clients()
        api.attach_client("a@example.test", {"inboundIds": [2]})

        paths = [str(r["path"]) for r in _RecordingHandler.records]
        self.assertTrue(any(p.endswith("/panel/api/clients/add") for p in paths))
        self.assertTrue(any(p.endswith("/panel/api/clients/update/a%40example.test") for p in paths))
        self.assertTrue(any(p.endswith("/panel/api/clients/get/a%40example.test") for p in paths))
        self.assertTrue(any(p.endswith("/panel/api/clients/list") for p in paths))
        self.assertTrue(any(p.endswith("/panel/api/clients/a%40example.test/attach") for p in paths))

        add_json = [
            r
            for r in _RecordingHandler.records
            if str(r["path"]).endswith("/panel/api/clients/add")
            and "application/json" in str(r["content_type"])
        ]
        update_json = [
            r
            for r in _RecordingHandler.records
            if str(r["path"]).endswith("/panel/api/clients/update/a%40example.test")
            and "application/json" in str(r["content_type"])
        ]
        self.assertEqual(1, len(add_json))
        self.assertEqual(1, len(update_json))

    def test_create_mutations_use_single_long_request(self) -> None:
        observed: list[tuple[int, float, str]] = []

        api, session, tmp = _make_api({"URL_BASE_RESOLVED": f"http://127.0.0.1:{self.port}"})
        self.addCleanup(tmp.cleanup)

        original_csrf = api.csrf_token
        api.csrf_token = lambda: ""  # type: ignore[method-assign]

        original_request = session.request

        def recording_request(method: str, url: str, **kwargs: object):
            if url.endswith("/panel/api/inbounds/add") or url.endswith("/panel/api/clients/add"):
                observed.append((session.attempts, session.max_time, url))
            return original_request(method, url, **kwargs)

        session.request = recording_request  # type: ignore[method-assign]
        self.addCleanup(lambda: setattr(api, "csrf_token", original_csrf))
        api.add_inbound(
            {
                "port": 62093,
                "protocol": "vless",
                "remark": "test",
                "settings": {},
                "streamSettings": {},
                "sniffing": {},
            }
        )
        api.add_client({"client": {"email": "a@example.test"}, "inboundIds": [1]})

        self.assertEqual(
            (1, 180.0, f"http://127.0.0.1:{self.port}/panel/api/inbounds/add"),
            observed[0],
        )
        self.assertEqual(
            (1, 180.0, f"http://127.0.0.1:{self.port}/panel/api/clients/add"),
            observed[1],
        )
        self.assertEqual(4, session.attempts)
        self.assertEqual(8.0, session.max_time)


if __name__ == "__main__":
    unittest.main()