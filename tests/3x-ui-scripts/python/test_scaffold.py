import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

import xui_runtime  # noqa: E402
from xui_runtime.main import cli  # noqa: E402


class TestXuiRuntimeScaffold(unittest.TestCase):
    def test_python_runtime_ready(self) -> None:
        self.assertTrue(xui_runtime.PYTHON_RUNTIME_READY)

    def test_cli_check_mode_success(self) -> None:
        with patch("xui_runtime.main.run_managed_runtime", return_value=0) as run:
            with self.assertRaises(SystemExit) as ctx:
                cli(["--mode", "check"])
        self.assertEqual(ctx.exception.code, 0)
        run.assert_called_once()

    def test_module_main_check_subprocess(self) -> None:
        env = {
            **dict(__import__("os").environ),
            "PYTHONPATH": str(PYTHON_ROOT),
            "WEBDOMAIN": "example.test",
        }
        proc = subprocess.run(
            [sys.executable, "-m", "xui_runtime", "--mode", "check"],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)


if __name__ == "__main__":
    unittest.main()