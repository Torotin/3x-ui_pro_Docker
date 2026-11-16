import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.apply.xray import (  # noqa: E402
    default_tor_proxy_available,
    default_warp_proxy_available,
    socks_proxy_get,
)
from xui_runtime.main import _default_xray_probes  # noqa: E402


class ProxyProbeTests(unittest.TestCase):
    def test_socks_proxy_get_invokes_curl_socks5_hostname(self) -> None:
        with patch("xui_runtime.apply.xray.subprocess.run") as run:
            run.return_value = Mock(returncode=0, stdout="warp=on\n", stderr="")
            body = socks_proxy_get("usque", 1080, "https://www.cloudflare.com/cdn-cgi/trace", timeout=7)
        self.assertEqual(body, "warp=on\n")
        argv = run.call_args.args[0]
        self.assertEqual(argv[0], "curl")
        self.assertIn("--socks5-hostname", argv)
        self.assertIn("usque:1080", argv)
        self.assertIn("--max-time", argv)
        self.assertIn("7", argv)

    def test_warp_proxy_available_requires_warp_on_line(self) -> None:
        with patch(
            "xui_runtime.apply.xray.socks_proxy_get",
            return_value="fl=1\nwarp=on\n",
        ):
            self.assertTrue(default_warp_proxy_available("usque", 1080))
        with patch(
            "xui_runtime.apply.xray.socks_proxy_get",
            return_value="fl=1\nwarp=off\n",
        ):
            self.assertFalse(default_warp_proxy_available("usque", 1080))

    def test_tor_proxy_available_requires_is_tor_true(self) -> None:
        with patch(
            "xui_runtime.apply.xray.socks_proxy_get",
            return_value='{"IsTor":true,"IP":"1.2.3.4"}\n',
        ):
            self.assertTrue(default_tor_proxy_available("tor-proxy", 1080))
        with patch(
            "xui_runtime.apply.xray.socks_proxy_get",
            return_value='{"IsTor":false}\n',
        ):
            self.assertFalse(default_tor_proxy_available("tor-proxy", 1080))

    def test_default_xray_probes_use_real_socks_checks(self) -> None:
        probes = _default_xray_probes(
            {
                "EXTERNAL_PROXY_PROBE_TIMEOUT": "10",
                "WARP_PROXY_PROBE_URL": "https://www.cloudflare.com/cdn-cgi/trace",
                "TOR_PROXY_PROBE_URL": "https://check.torproject.org/api/ip",
            }
        )
        with patch(
            "xui_runtime.apply.xray.socks_proxy_get",
            return_value="warp=on\n",
        ):
            self.assertTrue(probes.warp_proxy_available("usque", 1080))
        with patch(
            "xui_runtime.apply.xray.socks_proxy_get",
            return_value='{"IsTor":true}\n',
        ):
            self.assertTrue(probes.tor_proxy_available("tor-proxy", 1080))


if __name__ == "__main__":
    unittest.main()
