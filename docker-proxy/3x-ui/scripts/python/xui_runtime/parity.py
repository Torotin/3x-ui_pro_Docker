"""Bash/Python desired-state and builder parity checks."""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from xui_runtime.builders import BUILDER_NAMES, extract_stream_fingerprint
from xui_runtime.builders.inbounds import (
    build_amneziawg_settings_json,
    build_hysteria2_settings_json,
)
from xui_runtime.builders.streams import (
    build_external_proxy_json,
    build_grpc_stream_json,
    build_hysteria2_stream_json,
    build_sockopt_json,
    build_tls_settings_json,
    build_vision_stream_json,
    build_xhttp_stream_json,
)
from xui_runtime.desired import build_desired_state


def canonical_json(obj: Any) -> str:
    """Stable JSON serialization for cross-language comparison."""
    return json.dumps(
        obj,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )


class ParityError(Exception):
    """JSON does not match between bash and Python."""


def assert_parity(bash_obj: Any, python_obj: Any, label: str = "desired-state") -> None:
    """Raise ``ParityError`` when canonical JSON differs."""
    bash_text = canonical_json(bash_obj)
    python_text = canonical_json(python_obj)
    if bash_text != python_text:
        raise ParityError(
            f"{label} parity failed:\n"
            f"  bash  : {bash_text}\n"
            f"  python: {python_text}"
        )


def _env_str(env: Mapping[str, str], key: str, default: str = "") -> str:
    value = env.get(key)
    if value is None or value == "":
        return default
    return value


def _default_tls_paths(env: Mapping[str, str]) -> tuple[str, str]:
    domain = _env_str(env, "WEBDOMAIN", "localhost") or "localhost"
    cert = _env_str(
        env,
        "XRAY_TLS_CERT_FILE",
        f"/etc/traefik/pem/{domain}-cert.pem",
    )
    key = _env_str(
        env,
        "XRAY_TLS_KEY_FILE",
        f"/etc/traefik/pem/{domain}-key.pem",
    )
    return cert, key


def build_python_builder(
    name: str,
    env: Mapping[str, str],
    args: dict[str, Any],
    bash_obj: Any | None = None,
) -> Any:
    """Rebuild JSON from env/args; optional bash_obj supplies nondeterministic fields."""
    if name == "vision_stream":
        fp = args.get("fingerprint")
        if fp is None and isinstance(bash_obj, dict):
            fp = extract_stream_fingerprint(bash_obj, name)
        target = args.get(
            "target",
            f"{_env_str(env, 'REALITY_TARGET_HOST', 'telemt')}:"
            f"{_env_str(env, 'REALITY_TARGET_PORT', _env_str(env, 'PORT_LOCAL_TELEMT_PROXY', '9443'))}",
        )
        sni = args.get("sni", _env_str(env, "WEBDOMAIN"))
        sockopt = args.get("sockopt")
        if sockopt is None:
            sockopt = build_sockopt_json(False, "AsIs", "off")
        xver = args.get(
            "target_xver",
            _env_str(env, "REALITY_TARGET_XVER", "1"),
        )
        return build_vision_stream_json(
            target=target,
            sni=sni,
            private_key=args.get("private_key", ""),
            public_key=args.get("public_key", ""),
            short_ids=args.get("short_ids", [""]),
            sockopt=sockopt,
            mldsa_seed=args.get("mldsa_seed", ""),
            mldsa_verify=args.get("mldsa_verify", ""),
            target_xver=xver,
            fingerprint=fp,
        )
    if name == "xhttp_stream":
        fp = args.get("fingerprint")
        if fp is None and isinstance(bash_obj, dict):
            fp = extract_stream_fingerprint(bash_obj, name)
        path = args.get(
            "path",
            _env_str(env, "URI_VLESS_XHTTP", "/xhttp") or "/xhttp",
        )
        host = args.get("host", _env_str(env, "WEBDOMAIN"))
        return build_xhttp_stream_json(path, host, fingerprint=fp, env=env)
    if name == "grpc_stream":
        fp = args.get("fingerprint")
        if fp is None and isinstance(bash_obj, dict):
            fp = extract_stream_fingerprint(bash_obj, name)
        path = args.get(
            "path",
            _env_str(env, "URI_VLESS_GRPC", "/grpc") or "/grpc",
        )
        host = args.get("host", _env_str(env, "WEBDOMAIN"))
        cert, key = _default_tls_paths(env)
        cert_file = args.get("cert_file", cert)
        key_file = args.get("key_file", key)
        return build_grpc_stream_json(
            path, host, cert_file, key_file, fingerprint=fp, env=env
        )
    if name == "hysteria2_stream":
        fp = args.get("fingerprint")
        if fp is None and isinstance(bash_obj, dict):
            fp = extract_stream_fingerprint(bash_obj, name)
        host = args.get("host", _env_str(env, "WEBDOMAIN"))
        cert, key = _default_tls_paths(env)
        return build_hysteria2_stream_json(
            host,
            args.get("cert_file", cert),
            args.get("key_file", key),
            auth=args.get("auth", _env_str(env, "HYSTERIA2_STREAM_AUTH")),
            fingerprint=fp,
            env=env,
        )
    if name == "amneziawg_settings":
        desired = args.get("desired")
        if desired is None:
            desired = build_desired_state(env)
        return build_amneziawg_settings_json(desired, env)
    if name == "hysteria2_settings":
        desired = args.get("desired")
        if desired is None:
            desired = build_desired_state(env)
        preferred_auth = args.get("preferred_auth", "")
        if not preferred_auth and isinstance(bash_obj, dict):
            clients = bash_obj.get("clients") or []
            if clients:
                preferred_auth = str(clients[0].get("auth") or "")
        current = args.get("current")
        return build_hysteria2_settings_json(
            current,
            desired,
            preferred_auth=preferred_auth,
            env=env,
        )
    if name == "tls_settings":
        fp = args.get("fingerprint")
        if fp is None and isinstance(bash_obj, dict):
            settings = (bash_obj.get("settings") or {}) if isinstance(bash_obj, dict) else {}
            fp = settings.get("fingerprint")
        host = args.get("server_name", _env_str(env, "WEBDOMAIN"))
        cert, key = _default_tls_paths(env)
        alpn = args.get("alpn", ["h3"])
        return build_tls_settings_json(
            host,
            args.get("cert_file", cert),
            args.get("key_file", key),
            alpn,
            fingerprint=fp,
        )
    if name == "external_proxy":
        fp = args.get("fingerprint")
        if fp is None and isinstance(bash_obj, list) and bash_obj:
            fp = bash_obj[0].get("fingerprint")
        host = args.get("host", _env_str(env, "WEBDOMAIN"))
        return build_external_proxy_json(
            host,
            force_tls=args.get("force_tls", "same"),
            alpn=args.get("alpn"),
            fingerprint=fp,
        )
    if name == "sockopt":
        trusted = args.get("trusted_xff")
        return build_sockopt_json(
            args.get("accept_proxy", False),
            args.get("domain_strategy", "AsIs"),
            args.get("tproxy", "off"),
            trusted_xff=trusted,
        )
    raise ValueError(f"unknown builder name: {name}")


def _cmd_desired(bash_json_file: Path) -> int:
    raw = bash_json_file.read_text(encoding="utf-8")
    bash_obj = json.loads(raw)
    python_obj = build_desired_state(os.environ)
    try:
        assert_parity(bash_obj, python_obj)
    except ParityError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


def _cmd_builder(name: str, bash_json_file: Path, args_file: Path | None) -> int:
    if name not in BUILDER_NAMES:
        print(f"unknown builder name: {name}", file=sys.stderr)
        return 2
    raw = bash_json_file.read_text(encoding="utf-8")
    bash_obj = json.loads(raw)
    args: dict[str, Any] = {}
    if args_file is not None:
        args = json.loads(args_file.read_text(encoding="utf-8"))
    try:
        python_obj = build_python_builder(name, os.environ, args, bash_obj=bash_obj)
        assert_parity(bash_obj, python_obj, label=f"builder:{name}")
    except ParityError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except (ValueError, KeyError, TypeError) as exc:
        print(f"builder:{name} failed: {exc}", file=sys.stderr)
        return 2
    return 0


def cli(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="xui_runtime.parity")
    sub = parser.add_subparsers(dest="command", required=True)

    desired_parser = sub.add_parser(
        "desired",
        help="Compare bash desired JSON file to Python build_desired_state",
    )
    desired_parser.add_argument(
        "--bash-json-file",
        required=True,
        type=Path,
        help="Path to JSON from bash build_desired_state",
    )

    builder_parser = sub.add_parser(
        "builder",
        help="Compare bash builder JSON file to Python builder output",
    )
    builder_parser.add_argument(
        "--name",
        required=True,
        choices=sorted(BUILDER_NAMES),
        help="Builder identifier",
    )
    builder_parser.add_argument(
        "--bash-json-file",
        required=True,
        type=Path,
        help="Path to JSON from bash builder function",
    )
    builder_parser.add_argument(
        "--args-json",
        type=Path,
        default=None,
        help="Optional JSON object with builder inputs",
    )

    args = parser.parse_args(argv)
    if args.command == "desired":
        code = _cmd_desired(args.bash_json_file)
        raise SystemExit(code)
    if args.command == "builder":
        code = _cmd_builder(args.name, args.bash_json_file, args.args_json)
        raise SystemExit(code)
    raise SystemExit(2)


if __name__ == "__main__":
    cli()