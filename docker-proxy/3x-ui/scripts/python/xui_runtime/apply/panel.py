"""Panel settings apply (bash ``panel_runtime.bash`` parity)."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from xui_runtime import log
from xui_runtime.api import PanelApi
from xui_runtime.common import ApplyStats, api_obj_json, json_equal, plan_or_apply

# Mirrors ``desired_panel_keys`` in desired_state.bash (keep in sync with bash tests).
DESIRED_PANEL_KEYS: tuple[str, ...] = (
    "webListen",
    "webDomain",
    "webPort",
    "webCertFile",
    "webKeyFile",
    "webBasePath",
    "sessionMaxAge",
    "pageSize",
    "expireDiff",
    "trafficDiff",
    "remarkModel",
    "datepicker",
    "tgBotEnable",
    "tgBotToken",
    "tgBotProxy",
    "tgBotAPIServer",
    "tgBotChatId",
    "tgRunTime",
    "tgBotBackup",
    "tgBotLoginNotify",
    "tgCpu",
    "tgLang",
    "timeLocation",
    "twoFactorEnable",
    "twoFactorToken",
    "xrayTemplateConfig",
    "subEnable",
    "subJsonEnable",
    "subTitle",
    "subSupportUrl",
    "subProfileUrl",
    "subAnnounce",
    "subEnableRouting",
    "subRoutingRules",
    "subListen",
    "subPort",
    "subPath",
    "subDomain",
    "externalTrafficInformEnable",
    "externalTrafficInformURI",
    "subCertFile",
    "subKeyFile",
    "subUpdates",
    "subEncrypt",
    "subShowInfo",
    "subURI",
    "subJsonPath",
    "subJsonURI",
    "subClashEnable",
    "subClashPath",
    "subClashURI",
    "subClashEnableRouting",
    "subClashRules",
    "subJsonFragment",
    "subJsonNoises",
    "subJsonMux",
    "subJsonRules",
    "subJsonRoutingRules",
    "subJsonDns",
    "subJsonObservatory",
    "ldapEnable",
    "ldapHost",
    "ldapPort",
    "ldapUseTLS",
    "ldapBindDN",
    "ldapPassword",
    "ldapBaseDN",
    "ldapUserFilter",
    "ldapUserAttr",
    "ldapVlessField",
    "ldapSyncCron",
    "ldapFlagField",
    "ldapTruthyValues",
    "ldapInvertFlag",
    "ldapInboundTags",
    "ldapAutoCreate",
    "ldapAutoDelete",
    "ldapDefaultTotalGB",
    "ldapDefaultExpiryDays",
    "ldapDefaultLimitIP",
    "panelOutbound",
)

# When AllSetting returns null for these keys, still coerce env overlays to JSON bool/int.
_PANEL_BOOL_KEYS = frozenset(
    key
    for key in DESIRED_PANEL_KEYS
    if key.endswith("Enable")
    or key
    in {
        "tgBotBackup",
        "tgBotLoginNotify",
        "subEncrypt",
        "subShowInfo",
        "ldapUseTLS",
        "ldapInvertFlag",
        "ldapAutoCreate",
        "ldapAutoDelete",
        "twoFactorEnable",
        "externalTrafficInformEnable",
    }
)
_PANEL_INT_KEYS = frozenset(
    {
        "webPort",
        "sessionMaxAge",
        "pageSize",
        "expireDiff",
        "trafficDiff",
        "tgCpu",
        "subPort",
        "subUpdates",
        "ldapPort",
        "ldapDefaultTotalGB",
        "ldapDefaultExpiryDays",
        "ldapDefaultLimitIP",
    }
)


class PanelApplyError(RuntimeError):
    """Panel apply could not complete."""


def desired_panel_keys() -> tuple[str, ...]:
    return DESIRED_PANEL_KEYS


def clear_sub_json_routing_rules_requested(env: Mapping[str, str]) -> bool:
    return (env.get("CLEAR_SUB_JSON_ROUTING_RULES") or "false").strip().lower() == "true"


def _env_overlay_value(env: Mapping[str, str], key: str) -> str | None:
    if key not in env:
        return None
    value = env[key]
    if value is None or value == "":
        return None
    return value


def _value_as_compare_string(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return str(value).lower()
    return str(value).rstrip("\n")


def _coerce_env_bool(env_val: str) -> bool:
    return env_val.strip().lower() in ("true", "1", "yes", "on")


def _coerce_env_on_current(key: str, current_val: Any, env_val: str) -> Any:
    if isinstance(current_val, bool) or (
        current_val is None and key in _PANEL_BOOL_KEYS
    ):
        return _coerce_env_bool(env_val)
    if key in _PANEL_BOOL_KEYS and isinstance(current_val, str):
        # Panel sometimes stores booleans as strings; keep JSON bool on write.
        return _coerce_env_bool(env_val)
    if (isinstance(current_val, int) and not isinstance(current_val, bool)) or (
        current_val is None and key in _PANEL_INT_KEYS
    ):
        try:
            return int(env_val)
        except ValueError:
            try:
                return float(env_val)
            except ValueError:
                return env_val
    if isinstance(current_val, float):
        try:
            return float(env_val)
        except ValueError:
            return env_val
    return env_val


def _normalize_update_body(body: dict[str, Any], env: Mapping[str, str]) -> dict[str, Any]:
    merged = dict(body)

    def _port_at_least(field: str, default: int) -> None:
        raw = merged.get(field)
        try:
            num = int(raw) if raw is not None and raw != "" else 0
        except (TypeError, ValueError):
            num = 0
        if num < 1:
            merged[field] = default

    _port_at_least("smtpPort", 587)
    _port_at_least("ldapPort", 389)

    if not _env_overlay_value(env, "panelOutbound"):
        # Empty env → managed default direct (do not preserve stale DB usque).
        merged["panelOutbound"] = "direct"

    return merged


def panel_desired_json(current: Mapping[str, Any], env: Mapping[str, str]) -> dict[str, str]:
    desired: dict[str, str] = {}
    for key in DESIRED_PANEL_KEYS:
        current_val = current.get(key)
        env_val = _env_overlay_value(env, key)
        # Newer 3x-ui AllSetting builds omit retired keys as null (e.g. remarkModel,
        # subShowInfo, tgBotLoginNotify). Overlaying env onto null never persists and
        # causes perpetual panel APPLY churn — skip when the field is unexposed.
        if env_val is not None and current_val is not None:
            # Canonicalize like projected (rstrip trailing newlines) so Clash/YAML
            # builders that emit a final \\n do not force perpetual panel updates.
            value = _value_as_compare_string(env_val)
        else:
            value = _value_as_compare_string(current_val)
        desired[key] = value

    try:
        ldap = int(desired.get("ldapPort", "0") or "0")
    except ValueError:
        ldap = 0
    if ldap < 1:
        desired["ldapPort"] = "389"

    if not _env_overlay_value(env, "panelOutbound"):
        # Empty env → managed default direct (do not preserve stale DB usque).
        desired["panelOutbound"] = "direct"

    if clear_sub_json_routing_rules_requested(env):
        desired["subJsonRoutingRules"] = ""

    return desired


def panel_current_managed_json(current: Mapping[str, Any]) -> dict[str, str]:
    return {key: _value_as_compare_string(current.get(key)) for key in DESIRED_PANEL_KEYS}


def panel_settings_json(current: Mapping[str, Any], env: Mapping[str, str]) -> dict[str, Any]:
    merged = dict(current)
    for key in DESIRED_PANEL_KEYS:
        env_val = _env_overlay_value(env, key)
        if env_val is None:
            continue
        current_val = merged.get(key)
        if current_val is None:
            # Unexposed on this panel build — leave null; do not invent fields.
            continue
        merged[key] = _coerce_env_on_current(key, current_val, env_val)

    merged = _normalize_update_body(merged, env)
    if clear_sub_json_routing_rules_requested(env):
        merged["subJsonRoutingRules"] = ""
    return merged


def ensure_panel_settings(
    api: PanelApi,
    env: Mapping[str, str],
    stats: ApplyStats,
    mode: str,
) -> None:
    """Compare managed panel settings and update when they diverge from env."""
    api.get_panel_settings()
    if not api.session.success_json():
        raise PanelApplyError(f"Panel settings API failed: {api.session.body()}")

    current = api_obj_json(api.session)
    target = panel_desired_json(current, env)
    projected = panel_current_managed_json(current)

    if json_equal(projected, target):
        log.log("INFO", "Panel settings already match desired state.")
        return

    body = panel_settings_json(current, env)
    if not plan_or_apply(mode, stats, "panel settings updated"):
        return

    api.update_panel_settings(body)
    if not api.session.success_json():
        raise PanelApplyError(f"Panel settings update failed: {api.session.body()}")

    stats.restart_panel_required = True


def update_admin_credentials_if_needed(
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    *,
    stats: ApplyStats | None = None,
) -> None:
    """Rotate admin credentials when NEW_ADMIN_* differ from the active session."""
    new_user = (env.get("NEW_ADMIN_USERNAME") or "").strip()
    new_pass = (env.get("NEW_ADMIN_PASSWORD") or "").strip()
    if not new_user or not new_pass:
        log.log("INFO", "Admin credential update skipped.")
        return

    username = env.get("USERNAME", "")
    password = env.get("PASSWORD", "")
    if username == new_user and password == new_pass:
        log.log("INFO", "Admin credentials already match desired state.")
        return

    bucket = stats if stats is not None else ApplyStats()
    if not plan_or_apply(mode, bucket, "admin credentials updated"):
        return

    result = api.update_admin_credentials()
    if result is None:
        return
    if not api.session.success_json():
        raise PanelApplyError(f"Admin credential update failed: {api.session.body()}")

    api.env["USERNAME"] = new_user
    api.env["PASSWORD"] = new_pass
    if stats is not None:
        stats.change_count = bucket.change_count


def restart_panel_if_needed(
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    required: bool,
) -> None:
    """Restart the panel service when a prior step set ``required`` (apply only)."""
    _ = env
    if mode != "apply":
        log.log("INFO", f"Restart skipped in MODE={mode}.")
        return
    if not required:
        return

    api.restart_panel()
    if not api.session.success_json():
        log.log("WARN", f"Panel restart request failed: {api.session.body()}")