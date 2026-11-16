import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime import env  # noqa: E402


class TestNormalizeBoolValue(unittest.TestCase):
    def test_accepts_truthy_aliases(self) -> None:
        for token in ("1", "true", "YES", "on", "enabled"):
            self.assertEqual(env.normalize_bool_value("FLAG", token), "true")

    def test_accepts_false_aliases(self) -> None:
        for token in ("0", "false", "no", "OFF", "disabled"):
            self.assertEqual(env.normalize_bool_value("FLAG", token), "false")

    def test_rejects_garbage(self) -> None:
        with self.assertRaises(ValueError):
            env.normalize_bool_value("FLAG", "maybe")


class TestRequireMode(unittest.TestCase):
    def test_accepts_known_modes(self) -> None:
        for mode in ("apply", "plan", "check"):
            env.require_mode(mode)

    def test_rejects_unknown_mode(self) -> None:
        with self.assertRaises(ValueError):
            env.require_mode("destroy")


class TestDeterministicSubId(unittest.TestCase):
    def test_stable_across_calls(self) -> None:
        first = env.deterministic_sub_id("example.com", "example.com-autogen")
        second = env.deterministic_sub_id("example.com", "example.com-autogen")
        self.assertEqual(first, second)
        self.assertEqual(len(first), 16)

    def test_localhost_default_domain(self) -> None:
        empty = env.deterministic_sub_id("", "autogen")
        explicit = env.deterministic_sub_id("localhost", "autogen")
        self.assertEqual(empty, explicit)


class TestCheckDependencies(unittest.TestCase):
    def test_bash_engine_does_not_require_python3(self) -> None:
        def fake_which(cmd: str) -> str | None:
            if cmd == "python3":
                return None
            return f"/usr/bin/{cmd}"

        with patch.object(env.shutil, "which", side_effect=fake_which):
            env.check_dependencies("bash")

    def test_python_engine_requires_python3(self) -> None:
        def fake_which(cmd: str) -> str | None:
            if cmd == "python3":
                return None
            return f"/usr/bin/{cmd}"

        with patch.object(env.shutil, "which", side_effect=fake_which):
            with self.assertRaises(RuntimeError) as ctx:
                env.check_dependencies("python")
            self.assertIn("python3", str(ctx.exception))


class TestLoadRuntimeEnv(unittest.TestCase):
    def _run_in_tmp(
        self,
        dot_env: str,
        xui_env: str,
        script_env: dict[str, str],
    ) -> dict[str, str]:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            runtime = tmp_path / "runtime"
            xui_dir = tmp_path / "3x-ui"
            runtime.mkdir()
            xui_dir.mkdir()
            (tmp_path / ".env").write_text(dot_env + "\n", encoding="utf-8")
            (xui_dir / "3x-ui.env").write_text(xui_env + "\n", encoding="utf-8")
            old_cwd = Path.cwd()
            try:
                os.chdir(tmp)
                merged = dict(os.environ)
                merged.update(script_env)
                return env.load_runtime_env(str(runtime), environ=merged)
            finally:
                os.chdir(old_cwd)

    def test_runtime_env_normalizes_udp443_backend(self) -> None:
        result = self._run_in_tmp(
            "UDP443_BACKEND=off\n",
            'UDP443_BACKEND="${UDP443_BACKEND:-amneziawg}"\n',
            {},
        )
        self.assertEqual(result["UDP443_BACKEND"], "off")
        self.assertEqual(result["ENABLE_AMNEZIAWG"], "false")
        self.assertEqual(result["ENABLE_HYSTERIA2"], "false")

    def test_runtime_env_preserves_explicit_optional_inbound_flags(self) -> None:
        result = self._run_in_tmp(
            "ENABLE_VLESS_GRPC=true\nENABLE_HYSTERIA2=false\n",
            'ENABLE_VLESS_GRPC="${ENABLE_VLESS_GRPC:-true}"\n'
            'ENABLE_HYSTERIA2="${ENABLE_HYSTERIA2:-true}"\n',
            {"ENABLE_VLESS_GRPC": "false", "ENABLE_HYSTERIA2": "true"},
        )
        self.assertEqual(result["ENABLE_VLESS_GRPC"], "false")
        self.assertEqual(result["ENABLE_HYSTERIA2"], "true")

    def test_runtime_env_normalizes_explicit_optional_inbound_flags(self) -> None:
        result = self._run_in_tmp(
            "ENABLE_VLESS_GRPC=false\nENABLE_HYSTERIA2=true\n",
            'ENABLE_VLESS_GRPC="${ENABLE_VLESS_GRPC:-false}"\n'
            'ENABLE_HYSTERIA2="${ENABLE_HYSTERIA2:-true}"\n',
            {"ENABLE_VLESS_GRPC": "YES", "ENABLE_HYSTERIA2": "0"},
        )
        self.assertEqual(result["ENABLE_VLESS_GRPC"], "true")
        self.assertEqual(result["ENABLE_HYSTERIA2"], "false")


if __name__ == "__main__":
    unittest.main()