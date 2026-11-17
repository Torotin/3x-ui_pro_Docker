from __future__ import annotations

import re
from collections.abc import Mapping
from typing import Any

_CPS_TAG_RE = re.compile(
    r"(?:<t>"
    r"|<r\s+\d+>"
    r"|<rd\s+\d+>"
    r"|<rc\s+\d+>"
    r"|<b\s+0x[0-9a-fA-F]+>)"
)

KEY_FIELDS = frozenset({"privateKey", "secretKey", "publicKey", "headerProtectionKey"})
MANAGED_AWG_TOP = frozenset({"mtu", "subnet", "subnetIp", "subnetCidr", "dns1", "dns2"})


def estimate_cps_bytes(cps: str) -> int:
    text = (cps or "").strip()
    if not text:
        return 0
    total = 0
    pos = 0
    while pos < len(text):
        match = _CPS_TAG_RE.match(text, pos)
        if not match:
            raise ValueError(f"invalid CPS tag near: {text[pos:]!r}")
        tag = match.group(0)
        if tag == "<t>":
            total += 4
        elif tag.startswith("<b "):
            hex_part = tag[3:-1].strip()
            if not hex_part.lower().startswith("0x"):
                raise ValueError(f"invalid CPS byte tag: {tag!r}")
            digits = hex_part[2:]
            if not digits or len(digits) % 2:
                raise ValueError(f"invalid CPS hex length: {tag!r}")
            total += len(digits) // 2
        else:
            num = int(tag[3:-1].strip())
            total += num
        pos = match.end()
    if pos != len(text):
        raise ValueError(f"invalid CPS trailing text: {text[pos:]!r}")
    return total


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


def _top_managed_value(settings: Mapping[str, Any], key: str) -> Any:
    """Resolve top-level managed field with server.* fallback (panel often nulls top)."""
    server = settings.get("server") or {}
    val = settings.get(key)
    if val is not None:
        return val
    if key == "mtu":
        return server.get("mtu")
    if key == "dns1":
        return server.get("primaryDns")
    if key == "dns2":
        return server.get("secondaryDns")
    if key == "subnetIp":
        return server.get("subnetIp")
    if key == "subnetCidr":
        return server.get("subnetCidr")
    if key == "subnet":
        sip = server.get("subnetIp")
        cidr = server.get("subnetCidr")
        if sip is not None and cidr is not None:
            return f"{sip}/{cidr}"
    return None


def awg_managed_equal(left: Mapping[str, Any], right: Mapping[str, Any]) -> bool:
    def top(m: Mapping[str, Any]) -> dict[str, Any]:
        out: dict[str, Any] = {}
        for key in MANAGED_AWG_TOP:
            val = _top_managed_value(m, key)
            if val is not None:
                out[key] = _canon_scalar(val)
        return out

    return top(left) == top(right) and canonicalize_awg_server(
        left.get("server")
    ) == canonicalize_awg_server(right.get("server"))
