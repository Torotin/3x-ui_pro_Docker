import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
FIXTURES = ROOT / "tests" / "3x-ui-scripts" / "fixtures" / "builders"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.builders.inbounds import (  # noqa: E402
    build_amneziawg_settings_json,
    build_hysteria2_settings_json,
)
from xui_runtime.builders.streams import (  # noqa: E402
    build_external_proxy_json,
    build_grpc_stream_json,
    build_hysteria2_stream_json,
    build_sockopt_json,
    build_tls_settings_json,
    build_vision_stream_json,
    build_xhttp_stream_json,
)
from xui_runtime.desired import build_desired_state  # noqa: E402
from xui_runtime.parity import assert_parity, build_python_builder, canonical_json  # noqa: E402


def _load(name: str) -> object:
    return json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))


class TestStreamBuildersVsFixtures(unittest.TestCase):
    _env_base = {
        "WEBDOMAIN": "fixture.example.test",
        "URI_VLESS_XHTTP": "/xhttp-fixture",
        "URI_VLESS_GRPC": "/grpc-fixture",
        "CLIENT_EMAIL_PREFIX": "autogen",
        "CLIENT_SUB_ID": "fixture-sub-id-01",
        "XRAY_TRUSTED_XFF_HEADER": "X-Xray-Trusted-Proxy",
    }

    def test_vision_stream(self) -> None:
        bash_obj = _load("vision_stream")
        fp = bash_obj["realitySettings"]["settings"]["fingerprint"]
        sockopt = build_sockopt_json(False, "AsIs", "off")
        python_obj = build_vision_stream_json(
            "telemt:9443",
            "fixture.example.test",
            "priv-key",
            "pub-key",
            ["aa11", "bb22"],
            sockopt,
            "",
            "",
            1,
            fingerprint=fp,
        )
        assert_parity(bash_obj, python_obj, label="vision_stream")

    def test_xhttp_stream(self) -> None:
        bash_obj = _load("xhttp_stream")
        fp = bash_obj["externalProxy"][0]["fingerprint"]
        python_obj = build_xhttp_stream_json(
            "/xhttp-fixture",
            "fixture.example.test",
            fingerprint=fp,
            env=self._env_base,
        )
        assert_parity(bash_obj, python_obj, label="xhttp_stream")

    def test_grpc_stream(self) -> None:
        bash_obj = _load("grpc_stream")
        fp = bash_obj["tlsSettings"]["settings"]["fingerprint"]
        python_obj = build_grpc_stream_json(
            "/grpc-fixture",
            "fixture.example.test",
            "/etc/fixture/cert.pem",
            "/etc/fixture/key.pem",
            fingerprint=fp,
            env=self._env_base,
        )
        assert_parity(bash_obj, python_obj, label="grpc_stream")

    def test_hysteria2_stream(self) -> None:
        bash_obj = _load("hysteria2_stream")
        fp = bash_obj["tlsSettings"]["settings"]["fingerprint"]
        env = dict(self._env_base)
        env.pop("HYSTERIA2_MASQ_URL", None)
        python_obj = build_hysteria2_stream_json(
            "fixture.example.test",
            "/etc/fixture/cert.pem",
            "/etc/fixture/key.pem",
            "h2-auth",
            fingerprint=fp,
            env=env,
        )
        assert_parity(bash_obj, python_obj, label="hysteria2_stream")

    def test_tls_settings(self) -> None:
        bash_obj = _load("tls_settings")
        fp = bash_obj["settings"]["fingerprint"]
        python_obj = build_tls_settings_json(
            "fixture.example.test",
            "/etc/fixture/cert.pem",
            "/etc/fixture/key.pem",
            ["h3"],
            fingerprint=fp,
        )
        assert_parity(bash_obj, python_obj, label="tls_settings")

    def test_external_proxy(self) -> None:
        bash_obj = _load("external_proxy")
        fp = bash_obj[0]["fingerprint"]
        python_obj = build_external_proxy_json(
            "fixture.example.test",
            force_tls="tls",
            alpn=["h2"],
            fingerprint=fp,
        )
        assert_parity(bash_obj, python_obj, label="external_proxy")

    def test_sockopt(self) -> None:
        bash_obj = _load("sockopt")
        python_obj = build_sockopt_json(
            False,
            "UseIP",
            "tproxy",
            trusted_xff=["X-Fixture-Trusted"],
        )
        assert_parity(bash_obj, python_obj, label="sockopt")


class TestInboundBuildersVsFixtures(unittest.TestCase):
    def test_amneziawg_settings(self) -> None:
        bash_obj = _load("amneziawg_settings")
        env = {
            "WEBDOMAIN": "fixture.example.test",
            "CLIENT_EMAIL_PREFIX": "autogen",
            "CLIENT_SUB_ID": "fixture-sub-id-01",
        }
        desired = build_desired_state(env)
        python_obj = build_amneziawg_settings_json(desired, env)
        assert_parity(bash_obj, python_obj, label="amneziawg_settings")

    def test_hysteria2_settings(self) -> None:
        bash_obj = _load("hysteria2_settings")
        env = {
            "WEBDOMAIN": "fixture.example.test",
            "CLIENT_EMAIL_PREFIX": "autogen",
            "CLIENT_SUB_ID": "fixture-sub-id-01",
        }
        desired = build_desired_state(env)
        python_obj = build_hysteria2_settings_json(
            None,
            desired,
            preferred_auth="fixed-hysteria-auth",
            env=env,
        )
        assert_parity(bash_obj, python_obj, label="hysteria2_settings")


class TestBuilderParityCli(unittest.TestCase):
    def test_cli_builder_vision(self) -> None:
        env = {
            **dict(os.environ),
            "PYTHONPATH": str(PYTHON_ROOT),
            "WEBDOMAIN": "fixture.example.test",
        }
        bash_obj = _load("vision_stream")
        args = {
            "target": "telemt:9443",
            "sni": "fixture.example.test",
            "private_key": "priv-key",
            "public_key": "pub-key",
            "short_ids": ["aa11", "bb22"],
            "sockopt": build_sockopt_json(False, "AsIs", "off"),
            "target_xver": 1,
        }
        bash_path = FIXTURES / "vision_stream.json"
        with tempfile.NamedTemporaryFile(
            mode="w",
            suffix=".json",
            delete=False,
            encoding="utf-8",
        ) as handle:
            json.dump(args, handle)
            args_path = handle.name
        proc = subprocess.run(
            [
                sys.executable,
                "-m",
                "xui_runtime.parity",
                "builder",
                "--name",
                "vision_stream",
                "--bash-json-file",
                str(bash_path),
                "--args-json",
                args_path,
            ],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_build_python_builder_registry(self) -> None:
        env = {
            "WEBDOMAIN": "fixture.example.test",
            "CLIENT_EMAIL_PREFIX": "autogen",
            "CLIENT_SUB_ID": "fixture-sub-id-01",
        }
        bash_obj = _load("amneziawg_settings")
        desired = build_desired_state(env)
        python_obj = build_python_builder(
            "amneziawg_settings",
            env,
            {"desired": desired},
            bash_obj=bash_obj,
        )
        self.assertEqual(canonical_json(bash_obj), canonical_json(python_obj))


if __name__ == "__main__":
    unittest.main()