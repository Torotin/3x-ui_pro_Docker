import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.apply.inbound.ensure import sanitize_xhttp_stream_json  # noqa: E402
from xui_runtime.builders.streams import build_xhttp_stream_json  # noqa: E402


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


if __name__ == "__main__":
    unittest.main()