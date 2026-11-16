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

from xui_runtime.http_client import HttpResult  # noqa: E402
from xui_runtime.main import (  # noqa: E402
    panel_egress_endpoint,
    update_builtin_geofiles_if_enabled,
    wait_panel_egress_ready,
)


class PanelEgressHelpers(unittest.TestCase):
    def test_panel_egress_endpoint_reads_loopback_socks(self) -> None:
        cfg = {
            "inbounds": [
                {"tag": "vision", "protocol": "vless", "port": 20604},
                {
                    "tag": "panel-egress",
                    "protocol": "socks",
                    "listen": "127.0.0.1",
                    "port": 62790,
                },
            ]
        }
        self.assertEqual(panel_egress_endpoint(cfg), ("127.0.0.1", 62790))

    def test_wait_panel_egress_ready_ok_when_absent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cfg_path = Path(tmp) / "config.json"
            cfg_path.write_text(json.dumps({"inbounds": []}), encoding="utf-8")
            ok = wait_panel_egress_ready(
                {"XRAY_RUNNING_CONFIG": str(cfg_path)},
                timeout=0.2,
                sleep_fn=lambda _s: None,
            )
        self.assertTrue(ok)


class UpdateBuiltinGeofiles(unittest.TestCase):
    def test_retries_until_success_json(self) -> None:
        api = MagicMock()
        session = MagicMock()
        api.session = session
        api.update_geofiles.side_effect = [
            HttpResult(code="200", body_path=None, error="", last_url="", ok=True),
            HttpResult(code="200", body_path=None, error="", last_url="", ok=True),
        ]
        session.success_json.side_effect = [False, True]
        session.body.return_value = '{"success":false}'

        with (
            patch("xui_runtime.main.wait_panel_egress_ready", return_value=True),
            patch("xui_runtime.main.time.sleep"),
        ):
            update_builtin_geofiles_if_enabled(
                api,
                {
                    "GEOFILES_UPDATE_ON_START": "true",
                    "GEOFILES_UPDATE_ATTEMPTS": "3",
                    "GEOFILES_UPDATE_RETRY_SECONDS": "0",
                },
                "apply",
            )

        self.assertEqual(api.update_geofiles.call_count, 2)


if __name__ == "__main__":
    unittest.main()
