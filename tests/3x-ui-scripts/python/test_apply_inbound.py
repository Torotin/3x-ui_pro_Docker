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

from xui_runtime.apply.inbound import (  # noqa: E402
    SharedClientSecrets,
    build_inbound_components_json,
    delete_managed_inbound_kind,
    ensure_inbound,
    ensure_shared_client,
)
from xui_runtime.common import ApplyStats  # noqa: E402
from xui_runtime.desired import build_desired_state  # noqa: E402


def _env_fixture() -> dict[str, str]:
    return {
        "WEBDOMAIN": "fixture.example.test",
        "CLIENT_EMAIL_PREFIX": "autogen",
        "CLIENT_SUB_ID": "stable-sub",
        "EMOJI_FLAG": "\u26a0",
    }


def _api_with_inbounds(rows: list[dict[str, object]]) -> MagicMock:
    api = MagicMock()
    session = MagicMock()
    session.success_json.return_value = True
    session.body.return_value = json.dumps({"success": True, "obj": rows})
    api.session = session
    return api


class TestAmneziawgSettingsShape(unittest.TestCase):
    def test_build_components_include_subnet_ip_and_cidr(self) -> None:
        env = _env_fixture()
        desired = build_desired_state(env)
        components = build_inbound_components_json("amneziawg", desired, env)
        settings = components["settings"]
        self.assertEqual(settings["subnetIp"], "10.8.1.0")
        self.assertEqual(settings["subnetCidr"], 24)
        self.assertEqual(settings["server"]["subnetIp"], "10.8.1.0")
        self.assertEqual(settings["server"]["subnetCidr"], 24)


class TestDeleteManagedInboundPlan(unittest.TestCase):
    def test_plan_records_delete_without_api_call(self) -> None:
        env = _env_fixture()
        desired = build_desired_state(env)
        remark = desired["inbounds"]["amneziawg"]["remark"]
        api = _api_with_inbounds(
            [
                {
                    "id": 42,
                    "remark": remark,
                    "port": desired["inbounds"]["amneziawg"]["port"],
                    "protocol": "amneziawg",
                    "enable": True,
                }
            ]
        )
        stats = ApplyStats()
        delete_managed_inbound_kind("amneziawg", desired, api, "plan", stats)
        api.del_inbound.assert_not_called()
        self.assertEqual(stats.change_count, 1)


class TestEnsureInboundVision(unittest.TestCase):
    def test_existing_vision_skips_create(self) -> None:
        env = _env_fixture()
        desired = build_desired_state(env)
        api = _api_with_inbounds(
            [
                {
                    "id": 7,
                    "remark": desired["inbounds"]["vision"]["remark"],
                    "port": desired["inbounds"]["vision"]["port"],
                    "protocol": "vless",
                }
            ]
        )
        stats = ApplyStats()
        inbound_id = ensure_inbound("vision", desired, api, env, "apply", stats)
        api.add_inbound.assert_not_called()
        self.assertEqual(inbound_id, "7")
        self.assertEqual(stats.change_count, 0)


class TestEnsureSharedClient(unittest.TestCase):
    def _api_clients(self, clients: list[dict[str, object]]) -> MagicMock:
        api = MagicMock()
        session = MagicMock()
        session.success_json.return_value = True

        def _body() -> str:
            if api.list_inbounds.called and not api.list_clients.called:
                return json.dumps({"success": True, "obj": []})
            if api.list_clients.called:
                return json.dumps({"success": True, "obj": clients})
            return json.dumps({"success": True, "obj": {}})

        session.body.side_effect = _body
        api.session = session
        return api

    def test_plan_create_records_without_post(self) -> None:
        env = _env_fixture()
        desired = build_desired_state(env)
        api = MagicMock()
        session = MagicMock()
        session.success_json.return_value = True
        session.body.return_value = json.dumps({"success": True, "obj": []})
        api.session = session
        stats = ApplyStats()
        with patch(
            "xui_runtime.apply.inbound.ensure_vless_inbound_client"
        ), patch("xui_runtime.apply.inbound.ensure_vless_stream"):
            secrets = ensure_shared_client(
                "1",
                "2",
                "",
                "4",
                "",
                desired,
                api,
                env,
                "plan",
                stats,
            )
        api.list_clients.assert_called_once()
        api.add_client.assert_not_called()
        api.attach_client.assert_not_called()
        self.assertEqual(stats.change_count, 1)
        self.assertTrue(secrets.client_id)

    def test_apply_attach_missing_inbound(self) -> None:
        env = _env_fixture()
        desired = build_desired_state(env)
        email = desired["clients"]["shared"]["email"]
        api = MagicMock()
        session = MagicMock()
        session.success_json.return_value = True
        bodies = [
            json.dumps(
                {
                    "success": True,
                    "obj": [
                        {
                            "email": email,
                            "subId": desired["clients"]["shared"]["subId"],
                            "uuid": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                            "password": "p" * 32,
                            "auth": "a" * 32,
                            "flow": desired["clients"]["shared"]["flow"],
                            "inboundIds": [1, 2],
                        }
                    ],
                }
            ),
            json.dumps({"success": True, "obj": {"id": 1, "settings": {}}}),
            json.dumps({"success": True, "obj": {"id": 2, "settings": {}}}),
            json.dumps({"success": True, "obj": {"id": 1, "streamSettings": {}}}),
            json.dumps({"success": True, "obj": {"id": 2, "streamSettings": {}}}),
        ]

        def _next_body() -> str:
            if not bodies:
                return json.dumps({"success": True, "obj": {}})
            return bodies.pop(0)

        session.body.side_effect = _next_body
        api.session = session
        stats = ApplyStats()
        with patch(
            "xui_runtime.apply.inbound.ensure_vless_inbound_client"
        ), patch("xui_runtime.apply.inbound.ensure_vless_stream"):
            secrets = ensure_shared_client(
                "1",
                "2",
                "",
                "4",
                "",
                desired,
                api,
                env,
                "apply",
                stats,
                SharedClientSecrets(
                    client_id="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                    password="p" * 32,
                    auth="a" * 32,
                ),
            )
        api.attach_client.assert_called_once()
        attach_payload = api.attach_client.call_args[0][1]
        self.assertEqual(attach_payload["inboundIds"], [4])
        self.assertEqual(
            secrets.client_id,
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        )


if __name__ == "__main__":
    unittest.main()