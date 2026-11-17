import unittest

from xui_runtime.builders.awg_settings import (
    awg_managed_equal,
    canonicalize_awg_server,
)


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