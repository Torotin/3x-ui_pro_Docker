import json
import re
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.apply.panel import (  # noqa: E402
    DESIRED_PANEL_KEYS,
    clear_sub_json_routing_rules_requested,
    desired_panel_keys,
    ensure_panel_settings,
    panel_current_managed_json,
    panel_desired_json,
    panel_settings_json,
    restart_panel_if_needed,
    update_admin_credentials_if_needed,
)
from xui_runtime.common import ApplyStats, plan_or_apply  # noqa: E402


def _bash_desired_panel_keys() -> list[str]:
    script = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "lib" / "desired_state.bash"
    text = script.read_text(encoding="utf-8")
    block = re.search(
        r"desired_panel_keys\(\)\s*\{([\s\S]*?)\n\}",
        text,
    )
    if block is None:
        raise AssertionError("desired_panel_keys block missing in desired_state.bash")
    keys: list[str] = []
    for line in block.group(1).splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("printf"):
            continue
        keys.extend(stripped.rstrip("\\").strip().split())
    return keys


def _panel_fixture() -> dict[str, object]:
    return {
        "webPort": 2053,
        "smtpPort": 587,
        "ldapPort": 389,
        "tgBotEnable": False,
        "panelOutbound": "usque",
        "subJsonRoutingRules": '{"RouteOrder":"proxy-direct-block"}',
    }


class TestDesiredPanelKeys(unittest.TestCase):
    def test_python_keys_match_bash_allow_list(self) -> None:
        bash_keys = _bash_desired_panel_keys()
        python_keys = list(desired_panel_keys())
        self.assertEqual(python_keys, bash_keys)
        self.assertIn("subClashEnableRouting", DESIRED_PANEL_KEYS)
        self.assertIn("subJsonObservatory", DESIRED_PANEL_KEYS)


class TestPanelJsonHelpers(unittest.TestCase):
    def test_managed_projection_uses_only_allow_list(self) -> None:
        current = {**_panel_fixture(), "extraField": "noise"}
        projected = panel_current_managed_json(current)
        self.assertNotIn("extraField", projected)
        self.assertEqual(set(projected.keys()), set(DESIRED_PANEL_KEYS))
        self.assertEqual(projected["webPort"], "2053")
        self.assertEqual(projected["tgBotEnable"], "false")

    def test_clear_sub_json_routing_rules_in_desired_and_body(self) -> None:
        current = _panel_fixture()
        env = {"CLEAR_SUB_JSON_ROUTING_RULES": "true"}
        self.assertTrue(clear_sub_json_routing_rules_requested(env))
        desired = panel_desired_json(current, env)
        self.assertEqual(desired["subJsonRoutingRules"], "")
        body = panel_settings_json(current, env)
        self.assertEqual(body["subJsonRoutingRules"], "")

    def test_panel_outbound_defaults_to_direct_without_env(self) -> None:
        current = {**_panel_fixture(), "panelOutbound": ""}
        env: dict[str, str] = {}
        desired = panel_desired_json(current, env)
        self.assertEqual(desired["panelOutbound"], "direct")
        body = panel_settings_json(current, env)
        self.assertEqual(body["panelOutbound"], "direct")


class TestPlanOrApply(unittest.TestCase):
    def test_plan_records_without_allowing_apply(self) -> None:
        stats = ApplyStats()
        self.assertFalse(plan_or_apply("plan", stats, "panel settings updated"))
        self.assertEqual(stats.change_count, 1)

    def test_apply_allows_mutations(self) -> None:
        stats = ApplyStats()
        self.assertTrue(plan_or_apply("apply", stats, "panel settings updated"))
        self.assertEqual(stats.change_count, 1)


class TestEnsurePanelSettings(unittest.TestCase):
    def _mock_api(self, current: dict[str, object]) -> MagicMock:
        api = MagicMock()
        session = MagicMock()
        session.success_json.return_value = True
        session.body.return_value = json.dumps({"success": True, "obj": current})
        api.session = session
        api.env = {}
        return api

    def test_plan_fetches_settings_but_skips_update_post(self) -> None:
        stats = ApplyStats()
        api = self._mock_api(_panel_fixture())
        ensure_panel_settings(api, {"panelOutbound": "direct"}, stats, "plan")
        api.get_panel_settings.assert_called_once()
        api.update_panel_settings.assert_not_called()
        self.assertEqual(stats.change_count, 1)
        self.assertFalse(stats.restart_panel_required)

    def test_apply_calls_update_when_managed_keys_differ(self) -> None:
        stats = ApplyStats()
        api = self._mock_api(_panel_fixture())
        ensure_panel_settings(api, {"panelOutbound": "direct"}, stats, "apply")
        api.get_panel_settings.assert_called_once()
        api.update_panel_settings.assert_called_once()
        posted = api.update_panel_settings.call_args[0][0]
        self.assertEqual(posted["panelOutbound"], "direct")
        self.assertEqual(stats.change_count, 1)
        self.assertTrue(stats.restart_panel_required)

    def test_apply_skips_when_already_matching(self) -> None:
        stats = ApplyStats()
        current = {**_panel_fixture(), "panelOutbound": "direct"}
        api = self._mock_api(current)
        ensure_panel_settings(api, {}, stats, "apply")
        api.update_panel_settings.assert_not_called()
        self.assertEqual(stats.change_count, 0)


class TestUpdateAdminCredentials(unittest.TestCase):
    def test_plan_skips_credential_post(self) -> None:
        stats = ApplyStats()
        api = MagicMock()
        session = MagicMock()
        session.success_json.return_value = True
        api.session = session
        api.env = {"USERNAME": "admin", "PASSWORD": "old"}
        env = {
            "USERNAME": "admin",
            "PASSWORD": "old",
            "NEW_ADMIN_USERNAME": "root",
            "NEW_ADMIN_PASSWORD": "secret",
        }
        update_admin_credentials_if_needed(api, env, "plan", stats=stats)
        api.update_admin_credentials.assert_not_called()
        self.assertEqual(stats.change_count, 1)

    def test_apply_updates_credentials_and_session_env(self) -> None:
        stats = ApplyStats()
        api = MagicMock()
        session = MagicMock()
        session.success_json.return_value = True
        api.session = session
        api.env = {"USERNAME": "admin", "PASSWORD": "old"}
        api.update_admin_credentials.return_value = MagicMock()
        env = {
            "USERNAME": "admin",
            "PASSWORD": "old",
            "NEW_ADMIN_USERNAME": "root",
            "NEW_ADMIN_PASSWORD": "secret",
        }
        update_admin_credentials_if_needed(api, env, "apply", stats=stats)
        api.update_admin_credentials.assert_called_once()
        self.assertEqual(api.env["USERNAME"], "root")
        self.assertEqual(api.env["PASSWORD"], "secret")
        self.assertEqual(stats.change_count, 1)


class TestRestartPanelIfNeeded(unittest.TestCase):
    def test_plan_never_posts_restart(self) -> None:
        api = MagicMock()
        restart_panel_if_needed(api, {}, "plan", required=True)
        api.restart_panel.assert_not_called()

    def test_apply_posts_restart_when_required(self) -> None:
        api = MagicMock()
        session = MagicMock()
        session.success_json.return_value = True
        api.session = session
        restart_panel_if_needed(api, {}, "apply", required=True)
        api.restart_panel.assert_called_once()

    def test_apply_skips_when_not_required(self) -> None:
        api = MagicMock()
        restart_panel_if_needed(api, {}, "apply", required=False)
        api.restart_panel.assert_not_called()


if __name__ == "__main__":
    unittest.main()