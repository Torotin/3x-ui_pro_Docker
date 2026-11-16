import json
import sys
import unittest
from pathlib import Path
from unittest.mock import ANY, MagicMock

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
FIXTURES = ROOT / "tests" / "3x-ui-scripts" / "fixtures" / "builders"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.apply.sub_balancer import (  # noqa: E402
    build_admin_sub_json_observatory,
    ensure_auto_sub_balancer,
    sub_balancer_form_args,
    sub_balancer_ids_csv,
    sub_balancer_ids_json,
)
from xui_runtime.common import ApplyStats  # noqa: E402
from xui_runtime.parity import assert_parity, build_python_builder  # noqa: E402


class TestSubBalancerBuilders(unittest.TestCase):
    def test_observatory_matches_fixture(self) -> None:
        fixture = json.loads(
            (FIXTURES / "admin_sub_json_observatory.json").read_text(encoding="utf-8")
        )
        python_obj = build_admin_sub_json_observatory()
        assert_parity(fixture, python_obj, label="admin_sub_json_observatory")
        self.assertEqual(python_obj["destination"], "https://www.gstatic.com/generate_204")
        self.assertEqual(python_obj["interval"], "300s")
        self.assertEqual(python_obj["timeout"], "5s")
        self.assertEqual(python_obj["httpMethod"], "HEAD")
        self.assertEqual(python_obj["sampling"], 2)

    def test_ids_helpers(self) -> None:
        self.assertEqual(sub_balancer_ids_csv(["1", "", "2"]), "1,2")
        self.assertEqual(sub_balancer_ids_json(["2", "1"]), [1, 2])
        form = sub_balancer_form_args("AUTO-example.test", ["1", "2"])
        self.assertEqual(
            form,
            [
                ("remark", "AUTO-example.test"),
                ("strategy", "leastPing"),
                ("sortOrder", "1"),
                ("enabled", "true"),
                ("inboundIds", "1"),
                ("inboundIds", "2"),
            ],
        )

    def test_parity_registry(self) -> None:
        fixture = build_admin_sub_json_observatory()
        python_obj = build_python_builder("admin_sub_json_observatory", {}, {}, bash_obj=fixture)
        assert_parity(fixture, python_obj, label="registry_observatory")


class TestEnsureAutoSubBalancer(unittest.TestCase):
    def _mock_api(self, body: str, *, ok: bool = True, success: bool = True) -> MagicMock:
        api = MagicMock()
        api.list_sub_balancers.return_value = MagicMock(ok=ok)
        api.add_sub_balancer.return_value = MagicMock(ok=True)
        api.update_sub_balancer.return_value = MagicMock(ok=True)
        api.session.body.return_value = body
        api.session.success_json.return_value = success
        return api

    def test_plan_mode_skips_api(self) -> None:
        api = self._mock_api("{}")
        stats = ApplyStats()
        ensure_auto_sub_balancer(api, {"WEBDOMAIN": "example.test"}, "plan", stats, "1", "2")
        api.list_sub_balancers.assert_not_called()
        self.assertEqual(stats.change_count, 1)

    def test_create_when_missing(self) -> None:
        body = json.dumps({"success": True, "obj": []})
        api = self._mock_api(body)
        stats = ApplyStats()
        ensure_auto_sub_balancer(api, {"WEBDOMAIN": "example.test"}, "apply", stats, "1", "2")
        api.add_sub_balancer.assert_called_once()
        form = api.add_sub_balancer.call_args.args[0]
        self.assertEqual(form[0], ("remark", "AUTO-example.test"))

    def test_update_legacy_auto_remark(self) -> None:
        body = json.dumps(
            {
                "success": True,
                "obj": [
                    {
                        "id": 7,
                        "remark": "AUTO",
                        "strategy": "random",
                        "enabled": False,
                        "inboundIds": [2],
                    }
                ],
            }
        )
        api = self._mock_api(body)
        stats = ApplyStats()
        ensure_auto_sub_balancer(api, {"WEBDOMAIN": "example.test"}, "apply", stats, "1", "2")
        api.update_sub_balancer.assert_called_once_with("7", ANY)
        api.add_sub_balancer.assert_not_called()

    def test_noop_when_matches(self) -> None:
        body = json.dumps(
            {
                "success": True,
                "obj": [
                    {
                        "id": 3,
                        "remark": "AUTO-example.test",
                        "strategy": "leastPing",
                        "enabled": True,
                        "inboundIds": [1, 2],
                    }
                ],
            }
        )
        api = self._mock_api(body)
        stats = ApplyStats()
        ensure_auto_sub_balancer(api, {"WEBDOMAIN": "example.test"}, "apply", stats, "1", "2")
        api.add_sub_balancer.assert_not_called()
        api.update_sub_balancer.assert_not_called()

    def test_skip_when_webdomain_missing(self) -> None:
        api = self._mock_api("{}")
        stats = ApplyStats()
        ensure_auto_sub_balancer(api, {}, "apply", stats, "1")
        api.list_sub_balancers.assert_not_called()
        self.assertEqual(stats.change_count, 0)


if __name__ == "__main__":
    unittest.main()