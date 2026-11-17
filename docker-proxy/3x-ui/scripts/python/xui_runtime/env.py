"""Runtime environment loading and normalization for the Python xui_runtime."""

from __future__ import annotations

import hashlib
import os
import re
import shutil
from collections.abc import Mapping
from pathlib import Path

_PRESERVE_FROM_PROCESS = (
    "MODE",
    "ENABLE_VLESS_GRPC",
    "ENABLE_HYSTERIA2",
    "ENABLE_AMNEZIAWG",
    "ENABLE_MIHOMO",
    "UDP443_BACKEND",
    "PORT_LOCAL_UDP443",
)

_BOOL_RUNTIME_VARS = (
    "ENABLE_VLESS_GRPC",
    "ENABLE_HYSTERIA2",
    "ENABLE_AMNEZIAWG",
    "ENABLE_MIHOMO",
)

_ENV_ASSIGN_RE = re.compile(
    r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$"
)
_PARAM_EXPANSION_RE = re.compile(
    r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}"
)


def deterministic_sub_id(webdomain: str, shared_email: str) -> str:
    """Stable 16-char subId when CLIENT_SUB_ID is unset (matches bash sha256sum|cut)."""
    host = webdomain if webdomain else "localhost"
    digest = hashlib.sha256(f"{host}:{shared_email}".encode("ascii")).hexdigest()
    return digest[:16]


def normalize_bool_value(name: str, value: str) -> str:
    """Return ``true`` or ``false``; raise ValueError for invalid values."""
    token = (value or "").strip().lower()
    if token in ("1", "true", "yes", "y", "on", "enabled"):
        return "true"
    if token in ("0", "false", "no", "n", "off", "disabled"):
        return "false"
    raise ValueError(
        f"{name} must be boolean: true/false, yes/no, on/off, "
        f"enabled/disabled, or 1/0"
    )


def normalize_base_path(raw: str | None) -> str:
    """Normalize panel base path to ``''`` or ``/segment`` (bash parity)."""
    value = (raw or "").strip()
    if value.startswith("/"):
        value = value[1:]
    if value.endswith("/"):
        value = value[:-1]
    if not value:
        return ""
    return f"/{value}"


def require_mode(mode: str) -> None:
    """Reject unsupported MODE values (apply, plan, check only)."""
    if mode not in ("apply", "plan", "check"):
        raise ValueError(
            f"Unsupported MODE={mode}. Use MODE=apply, MODE=plan, or MODE=check."
        )


def require_apply_mode() -> None:
    """Alias reading MODE from the environment (bash ``require_apply_mode``)."""
    require_mode(os.environ.get("MODE", "apply"))


def _expand_param_refs(value: str, env: dict[str, str]) -> str:
    def repl(match: re.Match[str]) -> str:
        name = match.group(1)
        default = match.group(2)
        if default is not None:
            current = env.get(name)
            if current is None or current == "":
                return default
            return current
        return env.get(name, "")

    prev = None
    out = value
    while prev != out:
        prev = out
        out = _PARAM_EXPANSION_RE.sub(repl, out)
    return out


def _strip_quotes(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        return value[1:-1]
    return value


def load_env_file(path: str | Path, env: dict[str, str]) -> None:
    """Load ``KEY=VALUE`` lines from a file into ``env`` (subset of bash ``source``)."""
    file_path = Path(path)
    if not file_path.is_file():
        return
    for raw_line in file_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = _ENV_ASSIGN_RE.match(raw_line)
        if not match:
            continue
        key, raw_value = match.group(1), match.group(2).strip()
        raw_value = _strip_quotes(raw_value)
        env[key] = _expand_param_refs(raw_value, env)


def _set_default(env: dict[str, str], key: str, value: str) -> None:
    if key not in env or env[key] == "":
        env[key] = value


def init_defaults(env: dict[str, str]) -> None:
    """Apply bash ``init_defaults`` ``:=`` semantics."""
    _set_default(env, "MODE", "apply")
    _set_default(env, "USERNAME", "admin")
    _set_default(env, "PASSWORD", "admin")
    _set_default(env, "NEW_ADMIN_USERNAME", "")
    _set_default(env, "NEW_ADMIN_PASSWORD", "")
    _set_default(env, "XUI_API_TOKEN", "")
    _set_default(env, "TWO_FACTOR_CODE", "")
    _set_default(env, "panelOutbound", "")
    _set_default(env, "WEBDOMAIN", "")
    _set_default(env, "webListen", "0.0.0.0")
    _set_default(env, "webDomain", "")
    _set_default(env, "webPort", env.get("PORT_LOCAL_VLESS_PANEL", "2053"))
    _set_default(env, "webCertFile", "")
    _set_default(env, "webKeyFile", "")
    _set_default(env, "webBasePath", "")
    _set_default(env, "PORT_LOCAL_VISION", "443")
    _set_default(env, "PORT_LOCAL_XHTTP", "8443")
    _set_default(env, "PORT_LOCAL_TRAEFIK", "4443")
    _set_default(env, "PORT_LOCAL_TELEMT_PROXY", "9443")
    _set_default(env, "PORT_LOCAL_XRAY_MIXED", "10808")
    _set_default(env, "ENABLE_TELEMT", "false")
    _set_default(env, "VISION_FALLBACK_HOST", "telemt")
    _set_default(env, "VISION_FALLBACK_PORT", env.get("PORT_LOCAL_TELEMT_PROXY", "9443"))
    _set_default(env, "VISION_FALLBACK_XVER", "1")
    _set_default(env, "REALITY_TARGET_HOST", "telemt")
    _set_default(env, "REALITY_TARGET_PORT", env.get("PORT_LOCAL_TELEMT_PROXY", "9443"))
    _set_default(env, "REALITY_TARGET_XVER", "1")
    _set_default(env, "URI_VLESS_XHTTP", "")
    _set_default(env, "URI_CLASH_PATH", "")
    webdomain = env.get("WEBDOMAIN", "")
    prefix = f"{webdomain}-" if webdomain else ""
    _set_default(env, "CLIENT_EMAIL_PREFIX", f"{prefix}autogen")
    _set_default(env, "CLIENT_EMAIL_SHARED", env.get("CLIENT_EMAIL_PREFIX", "autogen"))
    _set_default(env, "CLIENT_EMAIL_VISION", f"{env.get('CLIENT_EMAIL_PREFIX', 'autogen')}-vision")
    _set_default(env, "CLIENT_EMAIL_XHTTP", f"{env.get('CLIENT_EMAIL_PREFIX', 'autogen')}-xhttp")
    _set_default(env, "CLIENT_SUB_ID", "")
    _set_default(env, "USE_VLESS_PQ", "true")
    _set_default(env, "USE_MLDSA65", "false")
    _set_default(env, "XRAY_LOCAL_RESTART", "true")
    _set_default(env, "XRAY_MANAGED_DNS", "true")
    _set_default(env, "XRAY_MANAGED_WARP", "true")
    _set_default(env, "XRAY_MANAGED_WARP_CONSOLE", "true")
    _set_default(env, "XRAY_MANAGED_TOR", "true")
    _set_default(env, "ENABLE_MIHOMO", "false")
    _set_default(env, "WARP_REUSE_PANEL_CONFIG", "false")
    _set_default(env, "WARP_ENDPOINT_HOST", "engage.cloudflareclient.com:2408")
    _set_default(env, "USQUE_HOST", "usque")
    _set_default(env, "USQUE_PORT", "1080")
    _set_default(env, "EXTERNAL_PROXY_PROBE_TIMEOUT", "10")
    _set_default(env, "WARP_PROXY_PROBE_URL", "https://www.cloudflare.com/cdn-cgi/trace")

    cert = env.get("XRAY_TLS_CERT_FILE", "")
    if cert in ("", "/etc/x-ui/xray-managed.crt"):
        domain = env.get("WEBDOMAIN", "localhost") or "localhost"
        env["XRAY_TLS_CERT_FILE"] = f"/etc/traefik/pem/{domain}-cert.pem"
    key = env.get("XRAY_TLS_KEY_FILE", "")
    if key in ("", "/etc/x-ui/xray-managed.key"):
        domain = env.get("WEBDOMAIN", "localhost") or "localhost"
        env["XRAY_TLS_KEY_FILE"] = f"/etc/traefik/pem/{domain}-key.pem"

    _set_default(env, "TOR_PROXY_PROBE_URL", "https://check.torproject.org/api/ip")
    _set_default(env, "TOR_PROXY_HOST", "tor-proxy")
    _set_default(env, "TOR_PROXY_PORT", "1080")
    _set_default(env, "CUSTOM_GEO_RESOURCES", "")
    _set_default(env, "GEODATA_CRON", "0 4 * * *")
    _set_default(env, "GEOFILES_UPDATE_ON_START", "true")
    _set_default(env, "GEOFILES_UPDATE_ATTEMPTS", "3")
    _set_default(env, "GEOFILES_UPDATE_RETRY_SECONDS", "5")
    _set_default(env, "GEOFILES_EGRESS_WAIT_SECONDS", "20")
    _set_default(env, "XRAY_RUNNING_CONFIG", "/app/bin/config.json")
    _set_default(env, "DOWNLOAD_GEO_DIRECT", "true")
    _set_default(env, "DOWNLOAD_TRANSPORTS", "")
    _set_default(env, "DOWNLOAD_URL_FALLBACKS", "")
    _set_default(env, "DOWNLOAD_CONNECT_TIMEOUT", "5")
    _set_default(env, "DOWNLOAD_MAX_TIME", "120")
    _set_default(env, "XRAY_RESTART_SETTLE_SECONDS", "5")
    _set_default(env, "XRAY_RESTART_PORT_TIMEOUT", "30")
    _set_default(env, "XHTTP_MODE", "packet-up")
    _set_default(env, "XHTTP_SC_MAX_BUFFERED_POSTS", "50")
    _set_default(env, "XHTTP_SC_MAX_EACH_POST_BYTES", "5000000")
    _set_default(env, "XHTTP_SC_STREAM_UP_SERVER_SECS", "5-20")
    _set_default(env, "XHTTP_X_PADDING_BYTES", "100-1000")
    _set_default(env, "XHTTP_NO_SSE_HEADER", "true")
    _set_default(env, "XHTTP_SET_HOST", "true")
    _set_default(env, "XHTTP_HEADERS_UA", "")
    _set_default(env, "XHTTP_CLIENT_EXTRA_ENABLE", "false")
    _set_default(env, "XHTTP_XMUX_MAX_CONCURRENCY", "16-32")
    _set_default(env, "XHTTP_XMUX_H_MAX_REQUEST_TIMES", "600-900")
    _set_default(env, "XHTTP_XMUX_H_MAX_REUSABLE_SECS", "1800-3000")
    _set_default(env, "VLESS_GRPC_WHEN_DISABLED", "disable")

    _set_default(env, "AWG_MTU", "1280")
    _set_default(env, "AWG_MTU_OVERHEAD", "96")
    _set_default(env, "AWG_HOST_MTU", "")
    for idx in range(1, 5):
        _set_default(env, f"AWG_S{idx}", "16")
        _set_default(env, f"AWG_H{idx}", str(idx))
    _set_default(env, "AWG_JC", "4")
    _set_default(env, "AWG_JMIN", "50")
    _set_default(env, "AWG_JMAX", "120")
    _set_default(env, "AWG_CONTENT_PADDING", "0-16")
    _set_default(env, "AWG_KEEPALIVE_TIMEOUT", "9-17")
    _set_default(env, "AWG_REKEY_AFTER_TIME", "")
    _set_default(env, "AWG_REKEY_TIMEOUT", "")
    _set_default(env, "AWG_REJECT_AFTER_TIME", "")
    _set_default(env, "AWG_MAX_HANDSHAKE_ATTEMPTS", "")
    _set_default(env, "AWG_RANDOM_TRAILERS", "true")
    _set_default(env, "AWG_DISABLE_COOKIES", "false")
    _set_default(env, "AWG_I1", "<r 55>")
    _set_default(env, "AWG_I1_MTU_HEADROOM", "120")
    for idx in range(2, 6):
        _set_default(env, f"AWG_I{idx}", "")
    _set_default(env, "AWG_DNS1", "8.8.8.8")
    _set_default(env, "AWG_DNS2", "8.8.4.4")
    _set_default(env, "AWG_CLIENT_KEEPALIVE", "25")


_AWG_MTU_MIN = 1280
_AWG_MTU_MAX = 1420


def _parse_uint16(name: str, raw: str, *, default: int | None = None) -> int:
    token = (raw or "").strip()
    if not token:
        if default is None:
            raise ValueError(f"{name} required")
        return default
    if not token.isdigit():
        raise ValueError(f"{name} invalid: {raw!r}")
    value = int(token)
    if value < 0 or value > 65535:
        raise ValueError(f"{name} out of uint16 range: {value}")
    return value


def _truthy_env(name: str, value: str, *, default: bool = False) -> bool:
    token = (value or "").strip()
    if not token:
        return default
    try:
        return normalize_bool_value(name, token) == "true"
    except ValueError as exc:
        raise ValueError(f"{name} invalid: {value!r}") from exc


def _estimate_cps_bytes(cps: str) -> int:
    from xui_runtime.builders.awg_settings import estimate_cps_bytes

    return estimate_cps_bytes(cps)


def _validate_awg_cps(field: str, value: str) -> None:
    text = (value or "").strip()
    if not text:
        return
    try:
        _estimate_cps_bytes(text)
    except ValueError as exc:
        raise ValueError(f"{field} {exc}") from exc


def resolve_awg_mtu(env: Mapping[str, str]) -> int:
    raw = (env.get("AWG_MTU") or "1280").strip().lower()
    if raw == "auto":
        host = (env.get("AWG_HOST_MTU") or "").strip()
        if not host.isdigit():
            return _AWG_MTU_MIN
        overhead = int((env.get("AWG_MTU_OVERHEAD") or "96").strip() or "96")
        return max(_AWG_MTU_MIN, min(_AWG_MTU_MAX, int(host) - overhead))
    if not raw.isdigit():
        raise ValueError(f"AWG_MTU invalid: {raw}")
    mtu = int(raw)
    if mtu < _AWG_MTU_MIN or mtu > _AWG_MTU_MAX:
        raise ValueError(f"AWG_MTU out of range: {mtu}")
    return mtu


def validate_awg_env(env: Mapping[str, str]) -> None:
    raw_mtu = (env.get("AWG_MTU") or "1280").strip().lower()
    if raw_mtu == "auto":
        overhead = (env.get("AWG_MTU_OVERHEAD") or "96").strip()
        if not overhead.isdigit() or int(overhead) <= 0:
            raise ValueError(f"AWG_MTU_OVERHEAD invalid for auto: {overhead!r}")
    elif raw_mtu.isdigit():
        mtu = int(raw_mtu)
        if mtu < _AWG_MTU_MIN or mtu > _AWG_MTU_MAX:
            raise ValueError(f"AWG_MTU out of range: {mtu}")
    else:
        raise ValueError(f"AWG_MTU invalid: {raw_mtu}")

    jmin = _parse_uint16("AWG_JMIN", env.get("AWG_JMIN") or "", default=50)
    jmax = _parse_uint16("AWG_JMAX", env.get("AWG_JMAX") or "", default=120)
    if jmin > jmax:
        raise ValueError(f"AWG_JMIN ({jmin}) must be <= AWG_JMAX ({jmax})")

    trailers = _truthy_env("AWG_RANDOM_TRAILERS", env.get("AWG_RANDOM_TRAILERS") or "true", default=True)
    s_values: list[int] = []
    for idx in range(1, 5):
        s_values.append(_parse_uint16(f"AWG_S{idx}", env.get(f"AWG_S{idx}") or "", default=16))
    if trailers and len(set(s_values)) != 1:
        raise ValueError(
            "AWG_S1..AWG_S4 must be equal when AWG_RANDOM_TRAILERS=true"
        )

    for idx in range(1, 5):
        expected = str(idx)
        actual = (env.get(f"AWG_H{idx}") or expected).strip()
        if actual != expected:
            raise ValueError(
                f"AWG_H{idx} must be {expected} in HP-compatible mode (got {actual!r})"
            )

    for idx in range(1, 6):
        _validate_awg_cps(f"AWG_I{idx}", env.get(f"AWG_I{idx}") or "")

    i1 = (env.get("AWG_I1") or "").strip()
    if i1:
        headroom = _parse_uint16(
            "AWG_I1_MTU_HEADROOM",
            env.get("AWG_I1_MTU_HEADROOM") or "",
            default=120,
        )
        mtu = resolve_awg_mtu(env)
        i1_bytes = _estimate_cps_bytes(i1)
        if i1_bytes + headroom > mtu:
            raise ValueError(
                f"AWG_I1 CPS size {i1_bytes} + headroom {headroom} exceeds AWG MTU {mtu}"
            )

    _truthy_env("AWG_DISABLE_COOKIES", env.get("AWG_DISABLE_COOKIES") or "false", default=False)


_XHTTP_MODES = frozenset({"auto", "packet-up", "stream-up", "stream-one"})
_XHTTP_UAS = frozenset({"", "firefox", "edge", "golang"})
_GRPC_WHEN_DISABLED = frozenset({"disable", "leave", "delete"})


def validate_xhttp_env(env: Mapping[str, str]) -> None:
    mode = (env.get("XHTTP_MODE") or "packet-up").strip()
    if mode not in _XHTTP_MODES:
        raise ValueError(f"XHTTP_MODE invalid: {mode}")
    ua = (env.get("XHTTP_HEADERS_UA") or "").strip().lower()
    if ua not in _XHTTP_UAS:
        raise ValueError(f"XHTTP_HEADERS_UA invalid: {ua}")
    policy = (env.get("VLESS_GRPC_WHEN_DISABLED") or "disable").strip()
    if policy not in _GRPC_WHEN_DISABLED:
        raise ValueError(f"VLESS_GRPC_WHEN_DISABLED invalid: {policy}")


def normalize_udp443_port_env(env: dict[str, str]) -> dict[str, str]:
    if not env.get("PORT_LOCAL_UDP443") and env.get("PORT_LOCAL_HYSTERIA"):
        env["PORT_LOCAL_UDP443"] = env["PORT_LOCAL_HYSTERIA"]
    if not env.get("PORT_LOCAL_UDP443"):
        env["PORT_LOCAL_UDP443"] = "443"
    env["PORT_LOCAL_HYSTERIA"] = env["PORT_LOCAL_UDP443"]
    return env


def normalize_runtime_bool_env(env: dict[str, str]) -> dict[str, str]:
    for name in _BOOL_RUNTIME_VARS:
        if name not in env:
            continue
        env[name] = normalize_bool_value(name, env[name])
    return env


def normalize_udp443_backend(env: dict[str, str]) -> dict[str, str]:
    raw = env.get("UDP443_BACKEND", "")
    if not raw:
        if "ENABLE_HYSTERIA2" in env:
            env["ENABLE_HYSTERIA2"] = normalize_bool_value(
                "ENABLE_HYSTERIA2", env["ENABLE_HYSTERIA2"]
            )
            if env["ENABLE_HYSTERIA2"] == "true":
                env["UDP443_BACKEND"] = "hysteria2"
            else:
                env["UDP443_BACKEND"] = "amneziawg"
        else:
            env["UDP443_BACKEND"] = "amneziawg"
    else:
        env["UDP443_BACKEND"] = raw.strip().lower()

    backend = env["UDP443_BACKEND"]
    if backend not in ("amneziawg", "hysteria2", "off"):
        raise ValueError(
            f"UDP443_BACKEND must be amneziawg|hysteria2|off (got: {backend})"
        )

    if backend == "amneziawg":
        env["ENABLE_AMNEZIAWG"] = "true"
        env["ENABLE_HYSTERIA2"] = "false"
    elif backend == "hysteria2":
        env["ENABLE_AMNEZIAWG"] = "false"
        env["ENABLE_HYSTERIA2"] = "true"
    else:
        env["ENABLE_AMNEZIAWG"] = "false"
        env["ENABLE_HYSTERIA2"] = "false"
    return env


def resolve_afterstart_dir(explicit: str | Path | None = None) -> Path:
    """Locate AfterStart dir under repo layout or container ``/mnt/sh`` mounts."""
    if explicit is not None:
        path = Path(explicit)
        if path.is_dir():
            return path.resolve()
    # Package lives at .../scripts/python/xui_runtime/env.py → parents[2] = scripts
    scripts_dir = Path(__file__).resolve().parents[2]
    candidates = (
        Path("/mnt/sh/afterstart"),
        scripts_dir / "01_AfterStart",
        scripts_dir / "afterstart",
    )
    for candidate in candidates:
        if candidate.is_dir():
            return candidate.resolve()
    return (scripts_dir / "01_AfterStart").resolve()


def resolve_xui_env_path(script_dir: str | Path) -> Path | None:
    """Find ``3x-ui.env`` for host checkout; container usually relies on compose env_file."""
    script = Path(script_dir).resolve()
    classic = script.parent.parent / "3x-ui.env"
    if classic.is_file():
        return classic.resolve()
    # Package-adjacent /opt fallbacks only for real AfterStart dirs — never for
    # arbitrary temp script_dir fixtures used by unit tests.
    if script.name in ("01_AfterStart", "afterstart") or script == Path(
        "/mnt/sh/afterstart"
    ):
        scripts_dir = Path(__file__).resolve().parents[2]
        for candidate in (
            scripts_dir.parent / "3x-ui.env",
            Path("/opt/docker-proxy/3x-ui/3x-ui.env"),
        ):
            if candidate.is_file():
                return candidate.resolve()
    return None


def load_runtime_env(
    script_dir: str,
    environ: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """Merge cwd/.env, mounted 3x-ui.env, defaults, and normalizers."""
    base = dict(environ if environ is not None else os.environ)
    env = {k: str(v) for k, v in base.items()}

    preserved: dict[str, str] = {}
    for name in _PRESERVE_FROM_PROCESS:
        if name in env:
            preserved[name] = env[name]

    load_env_file(Path.cwd() / ".env", env)
    xui_env = resolve_xui_env_path(script_dir)
    if xui_env is not None:
        load_env_file(xui_env, env)
    else:
        # Preserve classic relative lookup (and no-op when missing).
        load_env_file(Path(script_dir).resolve().parent.parent / "3x-ui.env", env)

    for name, value in preserved.items():
        env[name] = value

    init_defaults(env)
    normalize_udp443_port_env(env)
    normalize_runtime_bool_env(env)
    normalize_udp443_backend(env)
    return env


_BASH_DEPENDENCIES = (
    "bash",
    "curl",
    "jq",
    "grep",
    "mktemp",
    "sed",
    "tr",
    "sort",
    "head",
    "awk",
    "base64",
    "od",
)


def check_dependencies(engine: str) -> None:
    """Ensure required CLI tools exist for the chosen runtime engine."""
    engine_key = (engine or os.environ.get("XUI_RUNTIME_ENGINE", "python")).strip().lower()
    missing: list[str] = []
    for cmd in _BASH_DEPENDENCIES:
        if shutil.which(cmd) is None:
            missing.append(cmd)
    if engine_key == "python" and shutil.which("python3") is None:
        missing.append("python3")
    if missing:
        joined = " ".join(missing)
        raise RuntimeError(
            f"Missing required utilities: {joined}. Install them in the image/setup stage."
        )