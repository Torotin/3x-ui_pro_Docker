"""Stream/TLS JSON builders matching bash desired_state.bash."""

from __future__ import annotations

import copy
from collections.abc import Mapping, Sequence
from typing import Any

from xui_runtime.common import json_equal

_TLS_FINGERPRINTS = ("random", "firefox", "safari")


def _env_bool(env: Mapping[str, str], key: str, default: bool = False) -> bool:
    raw = env.get(key)
    if raw is None or raw == "":
        return default
    return str(raw).strip().lower() in ("1", "true", "yes", "on")


def canonicalize_xhttp_settings(settings: Mapping[str, Any]) -> dict[str, Any]:
    out = dict(settings)
    for key in (
        "scMaxBufferedPosts",
        "scMaxEachPostBytes",
        "scStreamUpServerSecs",
        "xPaddingBytes",
    ):
        if key in out and out[key] is not None:
            out[key] = str(out[key]).strip()
    if "noSSEHeader" in out:
        val = out["noSSEHeader"]
        if isinstance(val, str):
            out["noSSEHeader"] = val.strip().lower() in ("1", "true", "yes", "on")
        else:
            out["noSSEHeader"] = bool(val)
    return out


def managed_xhttp_headers(env: Mapping[str, str]) -> dict[str, str]:
    headers = {
        "Cache-Control": "no-store",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST",
    }
    ua = (env.get("XHTTP_HEADERS_UA") or "").strip().lower()
    if ua:
        headers["User-Agent"] = ua
    return headers


def apply_managed_xhttp_settings(
    path: str,
    host: str,
    env: Mapping[str, str],
) -> dict[str, Any]:
    mode = (env.get("XHTTP_MODE") or "packet-up").strip() or "packet-up"
    buffered = (env.get("XHTTP_SC_MAX_BUFFERED_POSTS") or "50").strip()
    each_post = (env.get("XHTTP_SC_MAX_EACH_POST_BYTES") or "5000000").strip()
    stream_secs = (env.get("XHTTP_SC_STREAM_UP_SERVER_SECS") or "5-20").strip()
    padding = (env.get("XHTTP_X_PADDING_BYTES") or "100-1000").strip()
    xhttp: dict[str, Any] = {
        "path": path,
        "mode": mode,
        "headers": managed_xhttp_headers(env),
        "scMaxBufferedPosts": int(buffered) if buffered.isdigit() else buffered,
        "scMaxEachPostBytes": each_post,
        "scStreamUpServerSecs": stream_secs,
        "noSSEHeader": _env_bool(env, "XHTTP_NO_SSE_HEADER", True),
        "xPaddingBytes": padding,
    }
    if _env_bool(env, "XHTTP_SET_HOST", True):
        xhttp["host"] = host
    return xhttp


def xhttp_stream_equal(
    left_stream: Mapping[str, Any],
    right_stream: Mapping[str, Any],
) -> bool:
    left = dict(left_stream)
    right = dict(right_stream)
    left_xhttp = canonicalize_xhttp_settings(left.pop("xhttpSettings", {}) or {})
    right_xhttp = canonicalize_xhttp_settings(right.pop("xhttpSettings", {}) or {})
    left["xhttpSettings"] = left_xhttp
    right["xhttpSettings"] = right_xhttp
    return json_equal(left, right)


def tls_fingerprint_allowed(value: str) -> bool:
    return value in _TLS_FINGERPRINTS


def select_tls_fingerprint(fingerprint: str | None = None) -> str:
    """Return explicit fingerprint or default ``random`` (bash picks at random)."""
    if fingerprint and tls_fingerprint_allowed(fingerprint):
        return fingerprint
    return "random"


def xray_trusted_xff_header(env: Mapping[str, str] | None = None) -> str:
    if env is None:
        import os

        env = os.environ
    return env.get("XRAY_TRUSTED_XFF_HEADER") or "X-Xray-Trusted-Proxy"


def build_trusted_xff_headers_json(env: Mapping[str, str] | None = None) -> list[str]:
    return [xray_trusted_xff_header(env)]


def build_sockopt_json(
    accept_proxy: bool = False,
    domain_strategy: str = "AsIs",
    tproxy: str = "off",
    trusted_xff: Sequence[str] | None = None,
) -> dict[str, Any]:
    obj: dict[str, Any] = {
        "V6Only": False,
        "acceptProxyProtocol": accept_proxy,
        "dialerProxy": "",
        "domainStrategy": domain_strategy,
        "interface": "",
        "mark": 0,
        "tcpFastOpen": True,
        "tcpKeepAliveIdle": 300,
        "tcpKeepAliveInterval": 0,
        "tcpMaxSeg": 1440,
        "tcpMptcp": False,
        "tcpUserTimeout": 10000,
        "tcpWindowClamp": 600,
        "tcpcongestion": "bbr",
        "tproxy": tproxy,
    }
    if trusted_xff:
        obj["trustedXForwardedFor"] = list(trusted_xff)
    return obj


def build_external_proxy_json(
    host: str,
    force_tls: str = "same",
    alpn: Sequence[str] | None = None,
    fingerprint: str | None = None,
) -> list[Any]:
    if not host:
        return []
    fp = select_tls_fingerprint(fingerprint)
    entry: dict[str, Any] = {
        "forceTls": force_tls,
        "dest": host,
        "port": 443,
        "remark": "",
        "sni": host,
        "fingerprint": fp,
    }
    if alpn:
        entry["alpn"] = list(alpn)
    return [entry]


def build_tls_settings_json(
    server_name: str,
    cert_file: str,
    key_file: str,
    alpn: Sequence[str],
    fingerprint: str | None = None,
) -> dict[str, Any]:
    fp = select_tls_fingerprint(fingerprint)
    return {
        "serverName": server_name,
        "minVersion": "1.2",
        "maxVersion": "1.3",
        "cipherSuites": "",
        "rejectUnknownSni": False,
        "disableSystemRoot": False,
        "enableSessionResumption": False,
        "certificates": [
            {
                "certificateFile": cert_file,
                "keyFile": key_file,
                "oneTimeLoading": False,
                "usage": "encipherment",
            }
        ],
        "alpn": list(alpn),
        "echServerKeys": "",
        "settings": {
            "fingerprint": fp,
            "echConfigList": "",
        },
    }


def build_vision_stream_json(
    target: str,
    sni: str,
    private_key: str,
    public_key: str,
    short_ids: Sequence[str] | None = None,
    sockopt: dict[str, Any] | None = None,
    mldsa_seed: str = "",
    mldsa_verify: str = "",
    target_xver: int | str = 0,
    fingerprint: str | None = None,
    external_proxy_fingerprint: str | None = None,
) -> dict[str, Any]:
    if short_ids is None:
        short_ids = [""]
    if sockopt is None:
        sockopt = {}
    # Match bash: build_external_proxy_json() and select_tls_fingerprint() are
    # independent calls, so the two fingerprints may differ.
    if fingerprint is None and external_proxy_fingerprint is None:
        ext_fp = select_tls_fingerprint()
        fp = select_tls_fingerprint()
    else:
        ext_fp = select_tls_fingerprint(
            external_proxy_fingerprint
            if external_proxy_fingerprint is not None
            else fingerprint
        )
        fp = select_tls_fingerprint(fingerprint)
    if isinstance(target_xver, str):
        target_xver = int(target_xver)
    return {
        "network": "tcp",
        "security": "reality",
        "externalProxy": build_external_proxy_json(
            sni, force_tls="same", fingerprint=ext_fp
        ),
        "realitySettings": {
            "show": False,
            "xver": target_xver,
            "target": target,
            "serverNames": [sni],
            "privateKey": private_key,
            "minClientVer": "",
            "maxClientVer": "",
            "maxTimeDiff": 0,
            "shortIds": list(short_ids),
            "mldsa65Seed": mldsa_seed,
            "settings": {
                "publicKey": public_key,
                "fingerprint": fp,
                "serverName": "",
                "spiderX": "/",
                "mldsa65Verify": mldsa_verify,
            },
        },
        "sockopt": copy.deepcopy(sockopt),
        "tcpSettings": {
            "acceptProxyProtocol": False,
            "header": {"type": "none"},
        },
    }


def build_grpc_stream_json(
    path: str,
    host: str,
    cert_file: str,
    key_file: str,
    fingerprint: str | None = None,
    env: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    service_name = path.lstrip("/").rstrip("/")
    fp = select_tls_fingerprint(fingerprint)
    trusted = build_trusted_xff_headers_json(env)
    return {
        "network": "grpc",
        "security": "tls",
        "externalProxy": build_external_proxy_json(
            host, force_tls="tls", alpn=["h2"], fingerprint=fp
        ),
        "tlsSettings": build_tls_settings_json(
            host, cert_file, key_file, ["h2"], fingerprint=fp
        ),
        "sockopt": build_sockopt_json(
            False, "AsIs", "off", trusted_xff=trusted
        ),
        "grpcSettings": {
            "serviceName": service_name,
            "authority": "",
            "multiMode": False,
        },
    }


def build_xhttp_stream_json(
    path: str,
    host: str,
    fingerprint: str | None = None,
    env: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    env = env or {}
    fp = select_tls_fingerprint(fingerprint)
    trusted = build_trusted_xff_headers_json(env)
    xhttp = apply_managed_xhttp_settings(path, host, env)
    return {
        "network": "xhttp",
        "security": "none",
        "externalProxy": build_external_proxy_json(
            host,
            force_tls="tls",
            alpn=["h2", "http/1.1"],
            fingerprint=fp,
        ),
        "sockopt": build_sockopt_json(
            False, "UseIP", "tproxy", trusted_xff=trusted
        ),
        "xhttpSettings": xhttp,
    }


def hysteria2_masquerade_url(env: Mapping[str, str]) -> str:
    masq = env.get("HYSTERIA2_MASQ_URL") or ""
    if masq:
        return masq
    webdomain = env.get("WEBDOMAIN") or ""
    if webdomain:
        return f"https://{webdomain}:4443/"
    return "https://172.18.0.6:4443/"


def build_hysteria2_stream_json(
    host: str,
    cert_file: str,
    key_file: str,
    auth: str = "",
    fingerprint: str | None = None,
    env: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    if env is None:
        import os

        env = os.environ
    fp = select_tls_fingerprint(fingerprint)
    masq_url = hysteria2_masquerade_url(env)
    return {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": build_tls_settings_json(
            host, cert_file, key_file, ["h3"], fingerprint=fp
        ),
        "hysteriaSettings": {
            "version": 2,
            "auth": auth,
            "udpIdleTimeout": 60,
            "masquerade": {
                "type": "proxy",
                "url": masq_url,
                "rewriteHost": True,
                "insecure": True,
            },
        },
    }


def extract_stream_fingerprint(bash_obj: dict[str, Any], name: str) -> str | None:
    """Pull primary TLS fingerprint from bash-built JSON for parity rebuild."""
    if name == "vision_stream":
        path = bash_obj.get("realitySettings", {}).get("settings", {})
        return path.get("fingerprint") or None
    if name in ("xhttp_stream", "grpc_stream"):
        proxy = bash_obj.get("externalProxy") or []
        if proxy and isinstance(proxy[0], dict):
            return proxy[0].get("fingerprint")
        return None
    if name == "hysteria2_stream":
        tls = bash_obj.get("tlsSettings") or {}
        settings = tls.get("settings") or {}
        return settings.get("fingerprint")
    return None


def extract_vision_external_proxy_fingerprint(
    bash_obj: dict[str, Any],
) -> str | None:
    """Vision externalProxy fingerprint (independent of realitySettings in bash)."""
    proxy = bash_obj.get("externalProxy") or []
    if proxy and isinstance(proxy[0], dict):
        return proxy[0].get("fingerprint")
    return None