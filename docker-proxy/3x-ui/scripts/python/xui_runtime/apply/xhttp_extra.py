"""XHTTP client ``extra`` subscription delivery (subscription-side only)."""

from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
from typing import Any

from xui_runtime import log
from xui_runtime.api import PanelApi
from xui_runtime.builders.streams import build_xhttp_client_extra_json
from xui_runtime.common import ApplyStats

DeliveryBackend = Callable[
    [PanelApi, Mapping[str, str], str, ApplyStats, dict[str, Any]],
    bool,
]

_GAP_REASON = (
    "no verified subscription delivery channel registered "
    "(expected JSON sub outbounds[].streamSettings.xhttpSettings.extra)"
)

_DELIVERY_BACKENDS: list[DeliveryBackend] = []


def register_xhttp_extra_delivery_backend(backend: DeliveryBackend) -> None:
    """Register a delivery backend that returns True when apply/plan succeeded."""
    _DELIVERY_BACKENDS.append(backend)


def _env_enabled(env: Mapping[str, str]) -> bool:
    return (env.get("XHTTP_CLIENT_EXTRA_ENABLE") or "false").strip().lower() in (
        "1",
        "true",
        "yes",
        "on",
    )


def _resolve_backends(
    override: Sequence[DeliveryBackend] | None,
) -> Sequence[DeliveryBackend]:
    if override is not None:
        return override
    return tuple(_DELIVERY_BACKENDS)


def ensure_xhttp_client_extra(
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    stats: ApplyStats,
    *,
    delivery_backends: Sequence[DeliveryBackend] | None = None,
) -> str:
    """Return ``applied`` | ``noop`` | ``gap`` for XHTTP client extra delivery."""
    _ = api  # reserved for backends; default none leaves panel unchanged
    if not _env_enabled(env):
        return "noop"

    extra = build_xhttp_client_extra_json(env)
    backends = _resolve_backends(delivery_backends)
    for backend in backends:
        if backend(api, env, mode, stats, extra):
            log.log("INFO", "XHTTP client extra delivered via registered backend.")
            return "applied"

    log.log(
        "WARN",
        f"XHTTP client extra enabled but delivery impossible: {_GAP_REASON}",
    )
    return "gap"