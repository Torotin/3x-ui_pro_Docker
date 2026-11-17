from __future__ import annotations

from collections.abc import Mapping
from typing import Any

KEY_FIELDS = frozenset({"privateKey", "secretKey", "publicKey", "headerProtectionKey"})
MANAGED_AWG_TOP = frozenset({"mtu", "subnet", "subnetIp", "subnetCidr", "dns1", "dns2"})
MANAGED_AWG_SERVER_KEYS = frozenset({
    "mtu", "subnetIp", "subnetCidr", "primaryDns", "secondaryDns",
    "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4",
    "jc", "jmin", "jmax",
    "contentPaddingAddition", "keepaliveTimeout",
    "rekeyAfterTime", "rekeyTimeout", "rejectAfterTime", "maxHandshakeAttempts",
    "randomTrailers", "disableCookies",
    "i1", "i2", "i3", "i4", "i5",
})


def _as_bool(v: Any) -> bool:
    if isinstance(v, bool):
        return v
    return str(v).strip().lower() in {"1", "true", "yes", "on"}


def _canon_scalar(v: Any) -> Any:
    if v is None:
        return None
    if isinstance(v, bool):
        return v
    s = str(v).strip()
    if s.lower() in {"true", "false"}:
        return s.lower() == "true"
    if s.isdigit():
        return int(s)
    return s


def canonicalize_awg_server(server: Mapping[str, Any] | None) -> dict[str, Any]:
    raw = dict(server or {})
    out: dict[str, Any] = {}
    for key in MANAGED_AWG_SERVER_KEYS:
        if key not in raw or raw[key] is None or raw[key] == "":
            continue
        if key in {"randomTrailers", "disableCookies"}:
            out[key] = _as_bool(raw[key])
        else:
            out[key] = _canon_scalar(raw[key])
    return out


def awg_managed_equal(left: Mapping[str, Any], right: Mapping[str, Any]) -> bool:
    def top(m: Mapping[str, Any]) -> dict[str, Any]:
        out: dict[str, Any] = {}
        server = m.get("server") or {}
        for key in MANAGED_AWG_TOP:
            val = m.get(key)
            if key == "mtu" and val is None:
                val = server.get("mtu")
            if val is not None:
                out[key] = _canon_scalar(val)
        return out

    return top(left) == top(right) and canonicalize_awg_server(
        left.get("server")
    ) == canonicalize_awg_server(right.get("server"))