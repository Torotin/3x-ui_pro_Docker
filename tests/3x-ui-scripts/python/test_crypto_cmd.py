import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime import crypto_cmd  # noqa: E402


class TestCryptoCmd(unittest.TestCase):
    @patch("xui_runtime.crypto_cmd.subprocess.run")
    def test_run_cmd_passes_argv_and_timeout(self, mock_run: object) -> None:
        mock_run.return_value = subprocess.CompletedProcess(["echo", "ok"], 0, "ok\n", "")
        result = crypto_cmd.run_cmd(["echo", "ok"], timeout=12)
        self.assertEqual(0, result.returncode)
        mock_run.assert_called_once_with(
            ["echo", "ok"],
            capture_output=True,
            text=True,
            timeout=12,
            check=False,
        )

    @patch("xui_runtime.crypto_cmd.subprocess.run")
    def test_xray_x25519_success(self, mock_run: object) -> None:
        mock_run.return_value = subprocess.CompletedProcess(
            ["xray", "x25519"],
            0,
            "Private key: aaa\nPassword: bbb\n",
            "",
        )
        out = crypto_cmd.xray_x25519("/usr/bin/xray")
        self.assertIn("Private key", out)
        mock_run.assert_called_once_with(
            ["/usr/bin/xray", "x25519"],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

    @patch("xui_runtime.crypto_cmd.subprocess.run")
    def test_xray_x25519_failure_raises(self, mock_run: object) -> None:
        mock_run.return_value = subprocess.CompletedProcess(
            ["xray", "x25519"],
            1,
            "",
            "boom",
        )
        with self.assertRaises(RuntimeError):
            crypto_cmd.xray_x25519("xray")

    @patch("xui_runtime.crypto_cmd.subprocess.run")
    def test_openssl_self_signed_cert_invocation(self, mock_run: object) -> None:
        mock_run.return_value = subprocess.CompletedProcess(["openssl"], 0, "", "")
        crypto_cmd.openssl_self_signed_cert(
            "/usr/bin/openssl",
            "/tmp/key.pem",
            "/tmp/cert.pem",
            days=90,
            cn="example.test",
        )
        mock_run.assert_called_once_with(
            [
                "/usr/bin/openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-keyout",
                "/tmp/key.pem",
                "-out",
                "/tmp/cert.pem",
                "-days",
                "90",
                "-subj",
                "/CN=example.test",
            ],
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )

    def test_no_cryptography_import(self) -> None:
        source = (PYTHON_ROOT / "xui_runtime" / "crypto_cmd.py").read_text(encoding="utf-8")
        self.assertNotIn("cryptography", source)


if __name__ == "__main__":
    unittest.main()