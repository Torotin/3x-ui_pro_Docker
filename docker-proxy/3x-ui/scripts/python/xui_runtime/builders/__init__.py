"""JSON builders for inbound/stream settings (bash parity)."""

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
    extract_stream_fingerprint,
)

BUILDER_NAMES = frozenset(
    {
        "vision_stream",
        "xhttp_stream",
        "grpc_stream",
        "hysteria2_stream",
        "amneziawg_settings",
        "tls_settings",
        "external_proxy",
        "sockopt",
        "hysteria2_settings",
    }
)

__all__ = [
    "BUILDER_NAMES",
    "build_amneziawg_settings_json",
    "build_external_proxy_json",
    "build_grpc_stream_json",
    "build_hysteria2_settings_json",
    "build_hysteria2_stream_json",
    "build_sockopt_json",
    "build_tls_settings_json",
    "build_vision_stream_json",
    "build_xhttp_stream_json",
    "extract_stream_fingerprint",
]