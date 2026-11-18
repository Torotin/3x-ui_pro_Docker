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



class TestAwgEnvDefaults(unittest.TestCase):
    def test_init_defaults_then_validate_awg_env_minimal_webdomain(self) -> None:
        env_map: dict[str, str] = {"WEBDOMAIN": "example.test"}
        env.init_defaults(env_map)
        env.validate_awg_env(env_map)

    def test_awg_defaults_match_current_shape(self) -> None:
        env_map: dict[str, str] = {"WEBDOMAIN": "example.test"}
        env.init_defaults(env_map)
        self.assertEqual(env_map.get("AWG_MTU"), "1280")
        self.assertEqual(env_map.get("AWG_MTU_OVERHEAD"), "96")
        self.assertEqual(env_map.get("AWG_S1"), "16")
        self.assertEqual(env_map.get("AWG_JC"), "4")
        self.assertEqual(env_map.get("AWG_JMIN"), "50")
        self.assertEqual(env_map.get("AWG_JMAX"), "120")
        self.assertEqual(env_map.get("AWG_CONTENT_PADDING"), "0-16")
        self.assertEqual(env_map.get("AWG_KEEPALIVE_TIMEOUT"), "9-17")
        self.assertEqual(env_map.get("AWG_RANDOM_TRAILERS"), "true")
        self.assertEqual(env_map.get("AWG_DISABLE_COOKIES"), "false")
        self.assertEqual(env_map.get("AWG_I1"), "<r 55>")
        self.assertEqual(env_map.get("AWG_I2"), "")
        self.assertEqual(env_map.get("AWG_CLIENT_KEEPALIVE"), "25")
        self.assertEqual(env_map.get("AWG_I1_MTU_HEADROOM"), "120")

    def test_validate_rejects_oversized_i1(self) -> None:
        with self.assertRaises(ValueError):
            env.validate_awg_env(
                {
                    "AWG_MTU": "1280",
                    "AWG_JMIN": "50",
                    "AWG_JMAX": "120",
                    "AWG_S1": "16",
                    "AWG_S2": "16",
                    "AWG_S3": "16",
                    "AWG_S4": "16",
                    "AWG_H1": "1",
                    "AWG_H2": "2",
                    "AWG_H3": "3",
                    "AWG_H4": "4",
                    "AWG_RANDOM_TRAILERS": "true",
                    "AWG_I1": "<r 2000>",
                }
            )

    def test_validate_awg_env_rejects_s1_below_12(self) -> None:
        with self.assertRaises(ValueError) as ctx:
            env.validate_awg_env(
                {
                    "AWG_MTU": "1280",
                    "AWG_JMIN": "50",
                    "AWG_JMAX": "120",
                    "AWG_S1": "8",
                    "AWG_S2": "16",
                    "AWG_S3": "16",
                    "AWG_S4": "16",
                    "AWG_H1": "1",
                    "AWG_H2": "2",
                    "AWG_H3": "3",
                    "AWG_H4": "4",
                    "AWG_RANDOM_TRAILERS": "true",
                    "AWG_I1": "<r 55>",
                }
            )
        self.assertIn("AWG_S1", str(ctx.exception))
        self.assertIn(">= 12", str(ctx.exception))

    def test_validate_awg_env_rejects_jmin_gt_jmax(self) -> None:
        with self.assertRaises(ValueError):
            env.validate_awg_env(
                {
                    "AWG_MTU": "1280",
                    "AWG_JMIN": "200",
                    "AWG_JMAX": "100",
                    "AWG_S1": "16",
                    "AWG_S2": "16",
                    "AWG_S3": "16",
                    "AWG_S4": "16",
                    "AWG_H1": "1",
                    "AWG_H2": "2",
                    "AWG_H3": "3",
                    "AWG_H4": "4",
                    "AWG_RANDOM_TRAILERS": "true",
                    "AWG_I1": "<r 55>",
                }
            )

    def test_validate_awg_env_rejects_rekey_max_ge_reject_min(self) -> None:
        with self.assertRaises(ValueError) as ctx:
            env.validate_awg_env(
                {
                    "AWG_MTU": "1280",
                    "AWG_JMIN": "50",
                    "AWG_JMAX": "120",
                    "AWG_S1": "16",
                    "AWG_S2": "16",
                    "AWG_S3": "16",
                    "AWG_S4": "16",
                    "AWG_H1": "1",
                    "AWG_H2": "2",
                    "AWG_H3": "3",
                    "AWG_H4": "4",
                    "AWG_RANDOM_TRAILERS": "true",
                    "AWG_I1": "<r 55>",
                    "AWG_REKEY_AFTER_TIME": "120-180",
                    "AWG_REJECT_AFTER_TIME": "180-240",
                }
            )
        self.assertIn("AWG_REKEY_AFTER_TIME", str(ctx.exception))
        self.assertIn("AWG_REJECT_AFTER_TIME", str(ctx.exception))

    def test_validate_awg_env_accepts_rekey_below_reject(self) -> None:
        env.validate_awg_env(
            {
                "AWG_MTU": "1280",
                "AWG_JMIN": "50",
                "AWG_JMAX": "120",
                "AWG_S1": "16",
                "AWG_S2": "16",
                "AWG_S3": "16",
                "AWG_S4": "16",
                "AWG_H1": "1",
                "AWG_H2": "2",
                "AWG_H3": "3",
                "AWG_H4": "4",
                "AWG_RANDOM_TRAILERS": "true",
                "AWG_I1": "<r 55>",
                "AWG_REKEY_AFTER_TIME": "120-170",
                "AWG_REJECT_AFTER_TIME": "180-240",
                "AWG_REKEY_TIMEOUT": "5-15",
                "AWG_MAX_HANDSHAKE_ATTEMPTS": "3-6",
            }
        )

    def test_resolve_awg_mtu_auto_from_host(self) -> None:
        self.assertEqual(
            env.resolve_awg_mtu(
                {
                    "AWG_MTU": "auto",
                    "AWG_HOST_MTU": "1500",
                    "AWG_MTU_OVERHEAD": "96",
                }
            ),
            1404,
        )
        self.assertEqual(
            env.resolve_awg_mtu(
                {
                    "AWG_MTU": "auto",
                    "AWG_HOST_MTU": "1476",
                    "AWG_MTU_OVERHEAD": "96",
                }
            ),
            1380,
        )
        self.assertEqual(env.resolve_awg_mtu({"AWG_MTU": "1280"}), 1280)


class TestXhttpEnvDefaults(unittest.TestCase):
    def test_xhttp_defaults_match_current_live_shape(self) -> None:
        env_map: dict[str, str] = {"WEBDOMAIN": "example.test"}
        env.init_defaults(env_map)
        self.assertEqual(env_map.get("XHTTP_MODE"), "packet-up")
        self.assertEqual(env_map.get("XHTTP_SC_MAX_BUFFERED_POSTS"), "50")
        self.assertEqual(env_map.get("XHTTP_SC_MAX_EACH_POST_BYTES"), "5000000")
        self.assertEqual(env_map.get("XHTTP_SC_STREAM_UP_SERVER_SECS"), "5-20")
        self.assertEqual(env_map.get("XHTTP_X_PADDING_BYTES"), "100-1000")
        self.assertEqual(env_map.get("XHTTP_NO_SSE_HEADER"), "true")
        self.assertEqual(env_map.get("XHTTP_SET_HOST"), "true")
        self.assertEqual(env_map.get("XHTTP_HEADERS_UA"), "")
        self.assertEqual(env_map.get("XHTTP_CLIENT_EXTRA_ENABLE"), "false")
        self.assertEqual(env_map.get("VLESS_GRPC_WHEN_DISABLED"), "disable")

    def test_validate_xhttp_env_rejects_bad_mode(self) -> None:
        with self.assertRaises(ValueError):
            env.validate_xhttp_env({"XHTTP_MODE": "nope"})

    def test_validate_xhttp_env_accepts_auto(self) -> None:
        env.validate_xhttp_env(
            {
                "XHTTP_MODE": "auto",
                "XHTTP_HEADERS_UA": "",
                "VLESS_GRPC_WHEN_DISABLED": "disable",
            }
        )


class TestPathResolve(unittest.TestCase):
    def test_resolve_afterstart_dir_prefers_repo_01_afterstart(self) -> None:
        path = env.resolve_afterstart_dir()
        self.assertTrue(path.is_dir())
        self.assertIn(path.name, ("01_AfterStart", "afterstart"))

    def test_resolve_xui_env_path_finds_repo_file(self) -> None:
        script_dir = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "01_AfterStart"
        found = env.resolve_xui_env_path(script_dir)
        self.assertIsNotNone(found)
        assert found is not None
        self.assertEqual(found.name, "3x-ui.env")
        self.assertTrue(found.is_file())

    def test_resolve_afterstart_dir_honors_explicit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            resolved = env.resolve_afterstart_dir(path)
            self.assertEqual(resolved, path.resolve())


if __name__ == "__main__":
    unittest.main()