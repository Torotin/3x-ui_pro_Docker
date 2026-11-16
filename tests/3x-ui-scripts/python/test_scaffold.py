import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

import xui_runtime  # noqa: E402
from xui_runtime.main import cli  # noqa: E402


class TestXuiRuntimeScaffold(unittest.TestCase):
    def test_python_runtime_not_ready(self) -> None:
        self.assertFalse(xui_runtime.PYTHON_RUNTIME_READY)

    def test_cli_exits_two_when_not_ready(self) -> None:
        with self.assertRaises(SystemExit) as ctx:
            cli(["--mode", "check"])
        self.assertEqual(ctx.exception.code, 2)

    def test_module_main_exits_two_subprocess(self) -> None:
        env = {**dict(__import__("os").environ), "PYTHONPATH": str(PYTHON_ROOT)}
        proc = subprocess.run(
            [sys.executable, "-m", "xui_runtime", "--mode", "check"],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        self.assertEqual(proc.returncode, 2)
        self.assertIn(
            "XUI_RUNTIME_ENGINE=python is not implemented until main orchestrator is ready",
            proc.stderr,
        )


if __name__ == "__main__":
    unittest.main()