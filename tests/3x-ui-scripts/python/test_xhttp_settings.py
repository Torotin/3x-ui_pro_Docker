import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.apply.inbound.ensure import sanitize_xhttp_stream_json  # noqa: E402
from xui_runtime.builders.streams import (  # noqa: E402
    apply_managed_xhttp_settings,
    build_xhttp_stream_json,
    canonicalize_xhttp_settings,
    xhttp_stream_equal,
)


class TestXhttpSettingsFromEnv(unittest.TestCase):
    def test_build_xhttp_default_mode_packet_up(self) -> None:
        obj = build_xhttp_stream_json("/xhttp", "example.test", env={})
        self.assertEqual(obj["xhttpSettings"]["mode"], "packet-up")
        self.assertNotIn("extra", obj["xhttpSettings"])

    def test_build_xhttp_mode_from_env_auto(self) -> None:
        obj = build_xhttp_stream_json(
            "/xhttp", "example.test", env={"XHTTP_MODE": "auto"}
        )
        self.assertEqual(obj["xhttpSettings"]["mode"], "auto")

    def test_sanitize_xhttp_updates_mode_only_from_env(self) -> None:
        stream = {
            "network": "xhttp",
            "security": "none",
            "xhttpSettings": {"path": "/old", "host": "old.test", "mode": "packet-up"},
        }
        out = sanitize_xhttp_stream_json(
            stream, "/xhttp", "example.test", {"XHTTP_MODE": "auto", "XHTTP_SET_HOST": "true"}
        )
        self.assertEqual(out["xhttpSettings"]["mode"], "auto")
        self.assertEqual(out["xhttpSettings"]["path"], "/xhttp")
        self.assertEqual(out["xhttpSettings"]["host"], "example.test")

    def test_canonicalize_sc_int_and_str_equal(self) -> None:
        a = canonicalize_xhttp_settings(
            {"scMaxBufferedPosts": 50, "scMaxEachPostBytes": 5000000}
        )
        b = canonicalize_xhttp_settings(
            {"scMaxBufferedPosts": "50", "scMaxEachPostBytes": "5000000"}
        )
        self.assertEqual(a["scMaxBufferedPosts"], b["scMaxBufferedPosts"])
        self.assertEqual(a["scMaxEachPostBytes"], b["scMaxEachPostBytes"])

    def test_sanitize_applies_sc_and_padding_from_env(self) -> None:
        env = {
            "XHTTP_MODE": "packet-up",
            "XHTTP_SET_HOST": "true",
            "XHTTP_SC_MAX_BUFFERED_POSTS": "50",
            "XHTTP_SC_MAX_EACH_POST_BYTES": "500000-1000000",
            "XHTTP_SC_STREAM_UP_SERVER_SECS": "5-20",
            "XHTTP_X_PADDING_BYTES": "100-1000",
            "XHTTP_NO_SSE_HEADER": "true",
            "XHTTP_HEADERS_UA": "",
        }
        stream = {
            "network": "xhttp",
            "security": "tls",
            "xhttpSettings": {"mode": "stream-up"},
        }
        out = sanitize_xhttp_stream_json(stream, "/xhttp", "example.test", env)
        self.assertEqual(out["security"], "none")
        self.assertEqual(out["xhttpSettings"]["scMaxEachPostBytes"], "500000-1000000")
        self.assertNotIn("extra", out["xhttpSettings"])

    def test_sanitize_strips_extra_from_xhttp_settings(self) -> None:
        stream = {
            "network": "xhttp",
            "security": "none",
            "xhttpSettings": {
                "mode": "packet-up",
                "extra": {"downloadSettings": {}},
            },
        }
        out = sanitize_xhttp_stream_json(stream, "/xhttp", "example.test", {})
        self.assertNotIn("extra", out["xhttpSettings"])

    def test_xhttp_stream_equal_ignores_sc_type_noise(self) -> None:
        left = {
            "network": "xhttp",
            "security": "none",
            "xhttpSettings": {"mode": "auto", "scMaxBufferedPosts": 50},
        }
        right = {
            "network": "xhttp",
            "security": "none",
            "xhttpSettings": {"mode": "auto", "scMaxBufferedPosts": "50"},
        }
        self.assertTrue(xhttp_stream_equal(left, right))

    def test_xhttp_stream_equal_ignores_unmanaged_panel_headers(self) -> None:
        managed = {
            "Cache-Control": "no-store",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST",
        }
        left = {
            "network": "xhttp",
            "security": "none",
            "xhttpSettings": {
                "mode": "packet-up",
                "headers": {**managed, "X-Panel-Noise": "ignored"},
            },
        }
        right = {
            "network": "xhttp",
            "security": "none",
            "xhttpSettings": {"mode": "packet-up", "headers": dict(managed)},
        }
        self.assertTrue(xhttp_stream_equal(left, right))

    def test_apply_managed_xhttp_settings_from_env(self) -> None:
        xhttp = apply_managed_xhttp_settings(
            "/xhttp",
            "example.test",
            {
                "XHTTP_SC_MAX_EACH_POST_BYTES": "500000-1000000",
                "XHTTP_HEADERS_UA": "Mozilla/5.0",
            },
        )
        self.assertEqual(xhttp["scMaxEachPostBytes"], "500000-1000000")
        self.assertEqual(xhttp["headers"]["User-Agent"], "mozilla/5.0")


if __name__ == "__main__":
    unittest.main()