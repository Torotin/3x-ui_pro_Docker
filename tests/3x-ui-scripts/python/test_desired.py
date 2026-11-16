import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime import desired  # noqa: E402
from xui_runtime.env import deterministic_sub_id  # noqa: E402
from xui_runtime.parity import canonical_json  # noqa: E402


class TestRemarkHelpers(unittest.TestCase):
    def test_country_code_to_flag_de(self) -> None:
        self.assertEqual(desired.country_code_to_flag("de"), "\U0001f1e9\U0001f1ea")

    def test_inbound_remark_uses_flag(self) -> None:
        self.assertEqual(
            desired.inbound_remark("vision", "\U0001f1e9\U0001f1ea"),
            "\U0001f1e9\U0001f1ea vless-tcp-reality",
        )

    def test_default_warning_flag(self) -> None:
        self.assertEqual(
            desired.inbound_remark("xhttp"),
            "\u26a0 vless-xhttp",
        )


class TestBuildDesiredState(unittest.TestCase):
    def test_clients_are_deterministic(self) -> None:
        env = {
            "CLIENT_EMAIL_PREFIX": "autogen",
            "CLIENT_SUB_ID": "stable-sub",
        }
        state = desired.build_desired_state(env)
        shared = state["clients"]["shared"]
        self.assertEqual(shared["email"], "autogen")
        self.assertEqual(shared["subId"], "stable-sub")
        self.assertEqual(shared["flow"], "xtls-rprx-vision")
        self.assertEqual(shared["visionFlow"], "xtls-rprx-vision")
        self.assertEqual(shared["xhttpFlow"], "")
        self.assertEqual(shared["grpcFlow"], "")

    def test_sub_id_derived_when_unset(self) -> None:
        env = {"CLIENT_EMAIL_PREFIX": "autogen", "WEBDOMAIN": "example.com"}
        state = desired.build_desired_state(env)
        expected = deterministic_sub_id("example.com", "autogen")
        self.assertEqual(state["clients"]["shared"]["subId"], expected)

    def test_two_calls_same_env_identical_json(self) -> None:
        env = {
            "CLIENT_EMAIL_PREFIX": "autogen",
            "EMOJI_FLAG": "\U0001f1e9\U0001f1ea",
            "PORT_LOCAL_VISION": "443",
        }
        first = canonical_json(desired.build_desired_state(env))
        second = canonical_json(desired.build_desired_state(env))
        self.assertEqual(first, second)

    def test_inbound_remarks_use_country_flag(self) -> None:
        env = {"EMOJI_FLAG": "\U0001f1e9\U0001f1ea"}
        state = desired.build_desired_state(env)
        flag = "\U0001f1e9\U0001f1ea"
        self.assertEqual(state["inbounds"]["vision"]["remark"], f"{flag} vless-tcp-reality")
        self.assertEqual(state["inbounds"]["xhttp"]["remark"], f"{flag} vless-xhttp")
        self.assertEqual(state["inbounds"]["grpc"]["remark"], f"{flag} vless-grpc-tls")
        self.assertEqual(state["inbounds"]["hysteria2"]["remark"], f"{flag} hysteria2")
        self.assertEqual(state["inbounds"]["amneziawg"]["remark"], f"{flag} amneziawg")

    def test_amneziawg_udp443_port(self) -> None:
        env = {"PORT_LOCAL_UDP443": "5443"}
        state = desired.build_desired_state(env)
        self.assertEqual(state["inbounds"]["amneziawg"]["protocol"], "amneziawg")
        self.assertEqual(state["inbounds"]["amneziawg"]["port"], 5443)
        self.assertEqual(state["inbounds"]["hysteria2"]["port"], 5443)

    def test_inbound_ports_are_integers(self) -> None:
        state = desired.build_desired_state({})
        for kind in ("vision", "xhttp", "grpc", "hysteria2", "amneziawg", "mixed"):
            port = state["inbounds"][kind]["port"]
            self.assertIsInstance(port, int)


if __name__ == "__main__":
    unittest.main()