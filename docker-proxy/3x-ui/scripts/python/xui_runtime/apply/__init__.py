"""Apply orchestration package (library-only until Task 12)."""

from xui_runtime.apply.panel import (
    DESIRED_PANEL_KEYS,
    PanelApplyError,
    desired_panel_keys,
    ensure_panel_settings,
    panel_current_managed_json,
    panel_desired_json,
    panel_settings_json,
    restart_panel_if_needed,
    update_admin_credentials_if_needed,
)
from xui_runtime.apply.xray import ApplyXrayStats, XrayApplyProbes, apply_managed_xray

__all__ = [
    "ApplyXrayStats",
    "DESIRED_PANEL_KEYS",
    "PanelApplyError",
    "XrayApplyProbes",
    "apply_managed_xray",
    "desired_panel_keys",
    "ensure_panel_settings",
    "panel_current_managed_json",
    "panel_desired_json",
    "panel_settings_json",
    "restart_panel_if_needed",
    "update_admin_credentials_if_needed",
]