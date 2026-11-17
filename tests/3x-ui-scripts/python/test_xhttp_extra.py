import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.builders.streams import (  # noqa: E402
    build_xhttp_client_extra_json,
    build_xhttp_stream_json,
)


class TestXhttpClientExtra(unittest.TestCase):
    def test_client_extra_xmux_shape(self) -> None:
        extra = build_xhttp_client_extra_json(
            {
                "XHTTP_X_PADDING_BYTES": "100-1000",
                "XHTTP_XMUX_MAX_CONCURRENCY": "16-32",
                "XHTTP_XMUX_H_MAX_REQUEST_TIMES": "600-900",
                "XHTTP_XMUX_H_MAX_REUSABLE_SECS": "1800-3000",
                "XHTTP_HEADERS_UA": "",
            }
        )
        self.assertEqual(extra["xPaddingBytes"], "100-1000")
        self.assertEqual(extra["xmux"]["maxConcurrency"], "16-32")
        self.assertEqual(extra["xmux"]["maxConnections"], 0)
        self.assertNotIn("headers", extra)

    def test_client_extra_includes_ua_when_set(self) -> None:
        extra = build_xhttp_client_extra_json({"XHTTP_HEADERS_UA": "firefox"})
        self.assertEqual(extra["headers"]["User-Agent"], "firefox")

    def test_build_xhttp_stream_has_no_extra_key(self) -> None:
        obj = build_xhttp_stream_json(
            "/xhttp",
            "example.test",
            env={
                "XHTTP_XMUX_MAX_CONCURRENCY": "16-32",
                "XHTTP_HEADERS_UA": "firefox",
            },
        )
        self.assertNotIn("extra", obj["xhttpSettings"])
        extra = build_xhttp_client_extra_json(
            {
                "XHTTP_XMUX_MAX_CONCURRENCY": "16-32",
                "XHTTP_HEADERS_UA": "firefox",
            }
        )
        self.assertIn("xmux", extra)


if __name__ == "__main__":
    unittest.main()