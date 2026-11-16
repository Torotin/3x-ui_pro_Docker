import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.apply.xray import generate_wg_keys, parse_xray_wg_output  # noqa: E402


class ParseXrayWgOutput(unittest.TestCase):
    def test_parses_modern_password_publickey_label(self) -> None:
        # Xray 26.x prints "Password (PublicKey): ..." instead of "PublicKey: ..."
        stdout = (
            "PrivateKey: SGqnAN8vvoR602D2R8RVbCqU3aq5jdggkNZn4WVL1GY=\n"
            "Password (PublicKey): KWQ5C3ihQgcAxA/CFsbKjele4NLCkKik8RcteE+lgG4=\n"
            "Hash32: j5e7nCX2E3DWDJHZWm2ul40nimMJtMUTC+GGhsWqGVg=\n"
        )
        private_key, public_key, reserved = parse_xray_wg_output(stdout)
        self.assertEqual(private_key, "SGqnAN8vvoR602D2R8RVbCqU3aq5jdggkNZn4WVL1GY=")
        self.assertEqual(public_key, "KWQ5C3ihQgcAxA/CFsbKjele4NLCkKik8RcteE+lgG4=")
        self.assertEqual(len(reserved), 3)

    def test_parses_legacy_publickey_label(self) -> None:
        stdout = (
            "PrivateKey: aaa=\n"
            "PublicKey: bbb=\n"
            "Hash32: AAAA\n"
        )
        private_key, public_key, _reserved = parse_xray_wg_output(stdout)
        self.assertEqual(private_key, "aaa=")
        self.assertEqual(public_key, "bbb=")


class GenerateWgKeys(unittest.TestCase):
    def test_generate_wg_keys_uses_parsed_stdout(self) -> None:
        stdout = (
            "PrivateKey: priv=\n"
            "Password (PublicKey): pub=\n"
            "Hash32: j5e7nCX2E3DWDJHZWm2ul40nimMJtMUTC+GGhsWqGVg=\n"
        )
        with (
            patch(
                "xui_runtime.apply.xray._find_xray_bin",
                return_value="/app/bin/xray-linux-amd64",
            ),
            patch("xui_runtime.apply.xray.subprocess.run") as run,
        ):
            run.return_value = Mock(returncode=0, stdout=stdout, stderr="")
            private_key, public_key, reserved = generate_wg_keys({})
        self.assertEqual(private_key, "priv=")
        self.assertEqual(public_key, "pub=")
        self.assertEqual(len(reserved), 3)


if __name__ == "__main__":
    unittest.main()
