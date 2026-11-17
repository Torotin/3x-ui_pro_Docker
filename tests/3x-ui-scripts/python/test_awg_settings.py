import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime import env  # noqa: E402
from xui_runtime.builders.awg_settings import (  # noqa: E402
    awg_managed_equal,
    canonicalize_awg_server,
)
from xui_runtime.builders.inbounds import build_amneziawg_settings_json  # noqa: E402
from xui_runtime.desired import build_desired_state  # noqa: E402


class TestAwgBuilderFromEnv(unittest.TestCase):
    def test_builder_reads_jc_and_padding_from_env(self) -> None:
        env_map: dict[str, str] = {
            "WEBDOMAIN": "example.test",
            "ENABLE_AMNEZIAWG": "true",
            "UDP443_BACKEND": "amneziawg",
        }
        env.init_defaults(env_map)
        env_map["AWG_JC"] = "8"
        env_map["AWG_CONTENT_PADDING"] = "0-32"
        obj = build_amneziawg_settings_json(build_desired_state(env_map), env_map)
        self.assertEqual(obj["server"]["jc"], 8)
        self.assertEqual(obj["server"]["contentPaddingAddition"], "0-32")
        self.assertEqual(obj["mtu"], 1280)


class TestAwgCanonicalize(unittest.TestCase):
    def test_int_string_s_and_range_equal(self) -> None:
        a = canonicalize_awg_server(
            {
                "s1": 16,
                "jc": 4,
                "contentPaddingAddition": "0-16",
                "randomTrailers": True,
            }
        )
        b = canonicalize_awg_server(
            {
                "s1": "16",
                "jc": "4",
                "contentPaddingAddition": "0-16",
                "randomTrailers": "true",
            }
        )
        self.assertEqual(a["s1"], b["s1"])
        self.assertEqual(a["jc"], b["jc"])
        self.assertEqual(a["contentPaddingAddition"], b["contentPaddingAddition"])
        self.assertEqual(a["randomTrailers"], b["randomTrailers"])

    def test_managed_equal_ignores_keys(self) -> None:
        left = {
            "mtu": 1280,
            "server": {
                "s1": 16,
                "privateKey": "AAA",
                "headerProtectionKey": "HHH",
                "randomTrailers": True,
            },
        }
        right = {
            "mtu": 1280,
            "server": {
                "s1": "16",
                "privateKey": "BBB",
                "headerProtectionKey": "GGG",
                "randomTrailers": True,
            },
        }
        self.assertTrue(awg_managed_equal(left, right))

    def test_managed_unequal_on_jc(self) -> None:
        left = {
            "mtu": 1280,
            "server": {"s1": 16, "jc": 4, "randomTrailers": True},
        }
        right = {
            "mtu": 1280,
            "server": {"s1": 16, "jc": 8, "randomTrailers": True},
        }
        self.assertFalse(awg_managed_equal(left, right))

    def test_managed_equal_null_top_mtu_uses_server_mtu(self) -> None:
        left = {
            "mtu": None,
            "server": {"mtu": 1280, "s1": 16, "randomTrailers": True},
        }
        right = {
            "mtu": 1280,
            "server": {"mtu": 1280, "s1": 16, "randomTrailers": True},
        }
        self.assertTrue(awg_managed_equal(left, right))