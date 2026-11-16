"""Apply orchestration package (panel, xray, inbound, subscription builders)."""

from xui_runtime.apply.panel import (
    ensure_panel_settings,
    restart_panel_if_needed,
    update_admin_credentials_if_needed,
)
from xui_runtime.apply.sub_balancer import (
    build_admin_sub_json_observatory,
    ensure_auto_sub_balancer,
    sub_balancer_form_args,
    sub_balancer_ids_csv,
    sub_balancer_ids_json,
)
from xui_runtime.apply.sub_routing import (
    build_admin_sub_clash_rules,
    build_admin_sub_json_dns,
    build_admin_sub_json_rules,
    build_mihomo_client_sub_clash_rules,
    mihomo_client_routing_file,
    subscription_panel_env_overrides,
)
from xui_runtime.apply.xray import ApplyXrayStats, XrayApplyProbes, apply_managed_xray

__all__ = [
    "ApplyXrayStats",
    "XrayApplyProbes",
    "apply_managed_xray",
    "build_admin_sub_clash_rules",
    "build_admin_sub_json_dns",
    "build_admin_sub_json_observatory",
    "build_admin_sub_json_rules",
    "build_mihomo_client_sub_clash_rules",
    "ensure_auto_sub_balancer",
    "ensure_panel_settings",
    "mihomo_client_routing_file",
    "restart_panel_if_needed",
    "sub_balancer_form_args",
    "sub_balancer_ids_csv",
    "sub_balancer_ids_json",
    "subscription_panel_env_overrides",
    "update_admin_credentials_if_needed",
]
