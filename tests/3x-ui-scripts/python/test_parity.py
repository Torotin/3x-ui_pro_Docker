import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.desired import build_desired_state  # noqa: E402
from xui_runtime.parity import ParityError, assert_parity, canonical_json  # noqa: E402


class TestCanonicalJson(unittest.TestCase):
    def test_sorts_keys(self) -> None:
        text = canonical_json({"b": 1, "a": 2})
        self.assertEqual(text, '{"a":2,"b":1}')

    def test_preserves_unicode(self) -> None:
        obj = {"remark": "\u26a0 vless"}
        text = canonical_json(obj)
        self.assertIn("\u26a0", text)


class TestAssertParity(unittest.TestCase):
    def test_passes_on_equal(self) -> None:
        obj = build_desired_state({"CLIENT_SUB_ID": "x"})
        assert_parity(obj, dict(obj))

    def test_fails_on_drift(self) -> None:
        left = build_desired_state({"CLIENT_SUB_ID": "left"})
        right = build_desired_state({"CLIENT_SUB_ID": "right"})
        with self.assertRaises(ParityError):
            assert_parity(left, right)


class TestParityCli(unittest.TestCase):
    def test_cli_exits_zero_on_match(self) -> None:
        env = {
            **dict(__import__("os").environ),
            "PYTHONPATH": str(PYTHON_ROOT),
            "CLIENT_EMAIL_PREFIX": "autogen",
            "CLIENT_SUB_ID": "cli-test-sub",
        }
        bash_obj = build_desired_state(
            {
                "CLIENT_EMAIL_PREFIX": "autogen",
                "CLIENT_SUB_ID": "cli-test-sub",
            }
        )
        with tempfile.NamedTemporaryFile(
            mode="w",
            suffix=".json",
            delete=False,
            encoding="utf-8",
        ) as handle:
            json.dump(bash_obj, handle, ensure_ascii=False)
            path = handle.name
        proc = subprocess.run(
            [
                sys.executable,
                "-m",
                "xui_runtime.parity",
                "desired",
                "--bash-json-file",
                path,
            ],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_cli_exits_one_on_drift(self) -> None:
        env = {
            **dict(__import__("os").environ),
            "PYTHONPATH": str(PYTHON_ROOT),
            "CLIENT_SUB_ID": "from-env",
        }
        drift = build_desired_state({"CLIENT_SUB_ID": "from-file"})
        with tempfile.NamedTemporaryFile(
            mode="w",
            suffix=".json",
            delete=False,
            encoding="utf-8",
        ) as handle:
            json.dump(drift, handle, ensure_ascii=False)
            path = handle.name
        proc = subprocess.run(
            [
                sys.executable,
                "-m",
                "xui_runtime.parity",
                "desired",
                "--bash-json-file",
                path,
            ],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("parity failed", proc.stderr)


if __name__ == "__main__":
    unittest.main()