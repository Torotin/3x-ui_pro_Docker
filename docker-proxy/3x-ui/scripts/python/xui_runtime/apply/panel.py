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


def _coerce_env_on_current(key: str, current_val: Any, env_val: str) -> Any:
    if isinstance(current_val, bool):
        lowered = env_val.lower()
        return lowered in ("true", "1", "yes", "on")
    if isinstance(current_val, int) and not isinstance(current_val, bool):
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
        outbound = merged.get("panelOutbound")
        if outbound is None or str(outbound).strip() == "":
            merged["panelOutbound"] = "direct"

    return merged


def panel_desired_json(current: Mapping[str, Any], env: Mapping[str, str]) -> dict[str, str]:
    desired: dict[str, str] = {}
    for key in DESIRED_PANEL_KEYS:
        env_val = _env_overlay_value(env, key)
        if env_val is not None:
            value = env_val
        else:
            value = _value_as_compare_string(current.get(key))
        desired[key] = value

    try:
        ldap = int(desired.get("ldapPort", "0") or "0")
    except ValueError:
        ldap = 0
    if ldap < 1:
        desired["ldapPort"] = "389"

    if not _env_overlay_value(env, "panelOutbound"):
        if not (desired.get("panelOutbound") or "").strip():
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
        merged[key] = _coerce_env_on_current(key, merged.get(key), env_val)

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