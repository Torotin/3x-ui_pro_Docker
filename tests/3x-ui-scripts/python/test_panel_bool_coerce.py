import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.apply.panel import (  # noqa: E402
    panel_current_managed_json,
    panel_desired_json,
    panel_settings_json,
)
from xui_runtime.common import json_equal  # noqa: E402


class PanelBoolCoerce(unittest.TestCase):
    def test_exposed_bool_fields_coerce_from_env_strings(self) -> None:
        current = {
            "webPort": 2053,
            "smtpPort": 587,
            "ldapPort": 389,
            "tgBotEnable": False,
            "panelOutbound": "direct",
            "subShowInfo": False,
            "tgBotLoginNotify": False,
            "remarkModel": "",
        }
        env = {
            "subShowInfo": "true",
            "tgBotLoginNotify": "true",
            "remarkModel": "-io",
        }
        body = panel_settings_json(current, env)
        self.assertIs(body["subShowInfo"], True)
        self.assertIs(body["tgBotLoginNotify"], True)
        self.assertEqual(body["remarkModel"], "-io")

    def test_null_unexposed_fields_do_not_churn(self) -> None:
        current = {
            "webPort": 2053,
            "smtpPort": 587,
            "ldapPort": 389,
            "tgBotEnable": False,
            "panelOutbound": "direct",
            "subShowInfo": None,
            "tgBotLoginNotify": None,
            "remarkModel": None,
        }
        env = {
            "subShowInfo": "true",
            "tgBotLoginNotify": "true",
            "remarkModel": "-io",
        }
        body = panel_settings_json(current, env)
        self.assertIsNone(body["subShowInfo"])
        self.assertIsNone(body["tgBotLoginNotify"])
        self.assertIsNone(body["remarkModel"])
        desired = panel_desired_json(current, env)
        projected = panel_current_managed_json(current)
        self.assertTrue(json_equal(projected, desired))


if __name__ == "__main__":
    unittest.main()
