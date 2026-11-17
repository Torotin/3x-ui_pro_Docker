import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.apply.panel import panel_current_managed_json, panel_desired_json  # noqa: E402
from xui_runtime.apply.xray import ApplyXrayStats  # noqa: E402
from xui_runtime.desired import build_desired_state  # noqa: E402
from xui_runtime.http_client import HttpResult  # noqa: E402
from xui_runtime.main import run_managed_runtime  # noqa: E402


def _base_env(mode: str) -> dict[str, str]:
    return {
        "MODE": mode,
        "XUI_RUNTIME_ENGINE": "python",
        "WEBDOMAIN": "example.test",
        "PUBLIC_IPV4": "203.0.113.10",
        "UDP443_BACKEND": "off",
        "ENABLE_VLESS_GRPC": "false",
        "ENABLE_HYSTERIA2": "false",
        "ENABLE_AMNEZIAWG": "false",
        "ENABLE_TELEMT": "false",
        "ENABLE_MIHOMO": "false",
        "XRAY_MANAGED_DNS": "false",
        "XRAY_MANAGED_WARP": "false",
        "XRAY_MANAGED_TOR": "false",
        "GEOFILES_UPDATE_ON_START": "false",
        "XRAY_TLS_CERT_FILE": "",
        "XRAY_TLS_KEY_FILE": "",
    }


class _RecordingPanelApi:
    """Minimal PanelApi stand-in for orchestrator integration tests."""

    def __init__(self, env: dict[str, str]) -> None:
        self.env = env
        self.session = MagicMock()
        self.session.success_json.return_value = True
        self.post_paths: list[str] = []

    def _ok(self) -> HttpResult:
        return HttpResult(code="200", body_path=None, error="", last_url="", ok=True)

    def resolve_panel_base(self) -> bool:
        self.env["URL_BASE_RESOLVED"] = "http://127.0.0.1:2053"
        self.env["USERNAME"] = self.env.get("USERNAME", "admin")
        self.env["PASSWORD"] = self.env.get("PASSWORD", "admin")
        return True

    def get_panel_settings(self) -> HttpResult:
        current = {
            "webPort": 2053,
            "smtpPort": 587,
            "ldapPort": 389,
            "tgBotEnable": False,
            "panelOutbound": "direct",
            "subJsonRoutingRules": "",
        }
        desired = panel_desired_json(current, self.env)
        merged = dict(current)
        for key, value in desired.items():
            merged[key] = value
        self.session.body.return_value = json.dumps({"success": True, "obj": merged})
        return self._ok()

    def update_panel_settings(self, body: object) -> HttpResult:
        self.post_paths.append("/panel/api/setting/update")
        self.session.success_json.return_value = True
        return self._ok()

    def update_admin_credentials(self) -> HttpResult | None:
        return None

    def get_xray_settings(self) -> HttpResult:
        payload = {
            "success": True,
            "obj": json.dumps({"xraySetting": {"outbounds": [], "routing": {"rules": []}}}),
        }
        self.session.body.return_value = json.dumps(payload)
        return self._ok()

    def update_xray_settings(self, path: str) -> HttpResult:
        self.post_paths.append("/panel/api/xray/update")
        return self._ok()

    def list_inbounds(self) -> HttpResult:
        desired = build_desired_state(self.env)
        rows = [
            {
                "id": 11,
                "port": desired["inbounds"]["vision"]["port"],
                "protocol": "vless",
                "remark": desired["inbounds"]["vision"]["remark"],
                "settings": {"clients": []},
                "streamSettings": {},
            },
            {
                "id": 12,
                "port": desired["inbounds"]["xhttp"]["port"],
                "protocol": "vless",
                "remark": desired["inbounds"]["xhttp"]["remark"],
                "settings": {"clients": []},
                "streamSettings": {},
            },
        ]
        self.session.body.return_value = json.dumps({"success": True, "obj": rows})
        return self._ok()

    def get_inbound(self, inbound_id: int | str) -> HttpResult:
        self.session.body.return_value = json.dumps(
            {"success": True, "obj": {"id": inbound_id, "settings": {}, "streamSettings": {}}}
        )
        return self._ok()

    def add_inbound(self, body: object) -> HttpResult:
        self.post_paths.append("/panel/api/inbounds/add")
        return self._ok()

    def update_inbound(self, inbound_id: int | str, body: object) -> HttpResult:
        self.post_paths.append(f"/panel/api/inbounds/update/{inbound_id}")
        return self._ok()

    def del_inbound(self, inbound_id: int | str) -> HttpResult:
        self.post_paths.append(f"/panel/api/inbounds/del/{inbound_id}")
        return self._ok()

    def list_clients(self) -> HttpResult:
        desired = build_desired_state(self.env)
        email = desired["clients"]["shared"]["email"]
        self.session.body.return_value = json.dumps(
            {
                "success": True,
                "obj": [
                    {
                        "email": email,
                        "id": "fixture-client",
                        "subId": desired["clients"]["shared"]["subId"],
                        "inboundIds": [11, 12],
                    }
                ],
            }
        )
        return self._ok()

    def add_client(self, payload: object) -> HttpResult:
        self.post_paths.append("/panel/api/clients/add")
        return self._ok()

    def update_client(self, email: str, payload: dict) -> HttpResult:
        self.post_paths.append(f"/panel/api/clients/update/{email}")
        return self._ok()

    def list_sub_balancers(self) -> HttpResult:
        remark = f"AUTO-{self.env.get('WEBDOMAIN', '')}"
        self.session.body.return_value = json.dumps(
            {
                "success": True,
                "obj": [
                    {
                        "remark": remark,
                        "strategy": "leastPing",
                        "inboundIds": [11, 12],
                    }
                ],
            }
        )
        return self._ok()

    def add_sub_balancer(self, form: object) -> HttpResult:
        self.post_paths.append("/panel/api/sub-balancers")
        return self._ok()

    def restart_xray(self) -> HttpResult:
        self.post_paths.append("/panel/api/server/restartXrayService")
        return self._ok()

    def restart_panel(self) -> HttpResult:
        self.post_paths.append("/panel/api/setting/restartPanel")
        return self._ok()

    def update_geofiles(self) -> HttpResult:
        self.post_paths.append("/panel/api/server/updateGeofile")
        return self._ok()


class TestMainOrchestrator(unittest.TestCase):
    def setUp(self) -> None:
        self.script_dir = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "01_AfterStart"
        self.tmp = tempfile.TemporaryDirectory()
        cert = Path(self.tmp.name) / "tls.crt"
        key = Path(self.tmp.name) / "tls.key"
        cert.write_bytes(b"fixture-cert")
        key.write_bytes(b"fixture-key")
        self.tls_cert = str(cert)
        self.tls_key = str(key)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    @patch("xui_runtime.main.check_dependencies")
    def test_check_mode_has_no_panel_mutations(self, _deps: MagicMock) -> None:
        env = _base_env("check")
        env["XRAY_TLS_CERT_FILE"] = self.tls_cert
        env["XRAY_TLS_KEY_FILE"] = self.tls_key
        api = _RecordingPanelApi(env)
        code = run_managed_runtime(env, self.script_dir, api=api)
        self.assertEqual(0, code)
        self.assertEqual([], api.post_paths)

    @patch("xui_runtime.main.detect_country_flag")
    @patch("xui_runtime.main.check_dependencies")
    @patch("xui_runtime.main.apply_managed_xray")
    def test_plan_mode_skips_mutating_posts(
        self,
        mock_apply_xray: MagicMock,
        _deps: MagicMock,
        _detect: MagicMock,
    ) -> None:
        mock_apply_xray.return_value = ApplyXrayStats()
        env = _base_env("plan")
        env["XRAY_TLS_CERT_FILE"] = self.tls_cert
        env["XRAY_TLS_KEY_FILE"] = self.tls_key
        env["XUI_DB_PATH"] = str(Path(self.tmp.name) / "missing.db")
        api = _RecordingPanelApi(env)
        api.get_panel_settings()
        current = json.loads(api.session.body.return_value)
        panel_obj = current["obj"]
        projected = panel_current_managed_json(panel_obj)
        desired_keys = panel_desired_json(panel_obj, env)
        self.assertEqual(projected, desired_keys)

        code = run_managed_runtime(env, self.script_dir, api=api)
        self.assertEqual(0, code)
        self.assertEqual([], api.post_paths)

    @patch("xui_runtime.main.detect_country_flag")
    @patch("xui_runtime.main.check_dependencies")
    @patch("xui_runtime.main.apply_managed_xray")
    def test_apply_fails_when_xhttp_client_extra_gap(
        self,
        mock_apply_xray: MagicMock,
        _deps: MagicMock,
        _detect: MagicMock,
    ) -> None:
        mock_apply_xray.return_value = ApplyXrayStats()
        env = _base_env("apply")
        env["XHTTP_CLIENT_EXTRA_ENABLE"] = "true"
        env["XRAY_TLS_CERT_FILE"] = self.tls_cert
        env["XRAY_TLS_KEY_FILE"] = self.tls_key
        env["XUI_DB_PATH"] = str(Path(self.tmp.name) / "missing.db")
        api = _RecordingPanelApi(env)
        code = run_managed_runtime(env, self.script_dir, api=api)
        self.assertEqual(1, code)


if __name__ == "__main__":
    unittest.main()