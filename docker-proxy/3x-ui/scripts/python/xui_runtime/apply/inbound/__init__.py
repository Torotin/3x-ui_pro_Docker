"""Inbound apply (bash ``inbound_runtime.bash`` parity, library-only)."""

from __future__ import annotations

import sqlite3

from xui_runtime.apply.inbound.amneziawg import (
    amneziawg_client_api_json,
    amneziawg_client_email,
    ensure_amneziawg_client,
    sync_amneziawg_profile,
)
from xui_runtime.apply.inbound.clients import (
    SharedClientSecrets,
    client_vless_uuid,
    current_inbound_components_json,
    ensure_grpc_client,
    ensure_hysteria2_client,
    ensure_shared_client,
    ensure_vless_inbound_client,
    ensure_vless_stream,
    inbound_vless_client_uuid,
    managed_vless_client_projection,
    vless_client_api_json,
    vless_client_create_payload_json,
    vless_inbound_settings_match,
)
from xui_runtime.apply.inbound.clients import (
    _sorted_vless_client_projections,
)
from xui_runtime.apply.inbound.db_repair import (
    _sqlite_commit_with_checkpoint,
    repair_inbound_client_tg_ids_db,
    repair_inbound_vless_client_flows_db,
    repair_shared_client_after_inbound_sync,
    repair_shared_client_db,
)
from xui_runtime.apply.inbound.grpc_policy import ensure_grpc_when_disabled
from xui_runtime.apply.inbound.ensure import (
    InboundApplyError,
    build_inbound_components_json,
    build_inbound_stream_json,
    build_vless_settings_json,
    delete_managed_inbound_kind,
    ensure_inbound,
    ensure_xray_tls_certificate,
    find_inbound_by_port,
    generate_short_ids_json,
    json_field_object,
    legacy_managed_inbound_remark,
    managed_conflict_check,
    managed_inbound_remarks,
    new_uuid,
    normalize_uuid,
    sanitize_grpc_stream_json,
    sanitize_vision_stream_json,
    sanitize_xhttp_stream_json,
)
from xui_runtime.apply.inbound.ensure import _list_inbounds

__all__ = [
    "InboundApplyError",
    "SharedClientSecrets",
    "amneziawg_client_api_json",
    "amneziawg_client_email",
    "build_inbound_components_json",
    "build_inbound_stream_json",
    "build_vless_settings_json",
    "client_vless_uuid",
    "current_inbound_components_json",
    "delete_managed_inbound_kind",
    "ensure_amneziawg_client",
    "ensure_grpc_client",
    "ensure_grpc_when_disabled",
    "ensure_hysteria2_client",
    "ensure_inbound",
    "ensure_shared_client",
    "ensure_vless_inbound_client",
    "ensure_vless_stream",
    "ensure_xray_tls_certificate",
    "find_inbound_by_port",
    "generate_short_ids_json",
    "inbound_vless_client_uuid",
    "json_field_object",
    "legacy_managed_inbound_remark",
    "managed_conflict_check",
    "managed_inbound_remarks",
    "managed_vless_client_projection",
    "new_uuid",
    "normalize_uuid",
    "repair_inbound_client_tg_ids_db",
    "repair_inbound_vless_client_flows_db",
    "repair_shared_client_after_inbound_sync",
    "repair_shared_client_db",
    "sanitize_grpc_stream_json",
    "sanitize_vision_stream_json",
    "sanitize_xhttp_stream_json",
    "sync_amneziawg_profile",
    "vless_client_api_json",
    "vless_client_create_payload_json",
    "vless_inbound_settings_match",
]
