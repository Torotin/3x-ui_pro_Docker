"""Inbound client sync: shared/VLESS/gRPC/Hysteria (library-only)."""

from __future__ import annotations

import json
import uuid
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from xui_runtime import log
from xui_runtime.api import PanelApi
from xui_runtime.builders.inbounds import (
    _normalize_tg_id,
    build_hysteria2_settings_json,
    new_client_secret,
)
from xui_runtime.common import ApplyStats, api_obj_json, json_equal, plan_or_apply

from xui_runtime.apply.inbound.db_repair import repair_shared_client_db
from xui_runtime.apply.inbound.ensure import (
    InboundApplyError,
    build_inbound_stream_json,
    json_field_object,
    normalize_uuid,
)

@dataclass
class SharedClientSecrets:
    client_id: str = ""
    password: str = ""
    auth: str = ""


def client_vless_uuid(client: Mapping[str, Any], *, include_auth: bool = True) -> str | None:
    fields = ("uuid", "id", "password", "auth") if include_auth else ("uuid", "id")
    for field in fields:
        normalized = normalize_uuid(str(client.get(field) or ""))
        if normalized:
            return normalized
    return None


def inbound_vless_client_uuid(
    api: PanelApi,
    inbound_id: str | int,
    email: str,
) -> str | None:
    if not inbound_id or not email:
        return None
    api.get_inbound(inbound_id)
    if not api.session.success_json():
        return None
    inbound = api_obj_json(api.session)
    settings = json_field_object(inbound, "settings")
    for client in settings.get("clients") or []:
        if client.get("email") != email:
            continue
        for field in ("uuid", "id", "auth", "password"):
            normalized = normalize_uuid(str(client.get(field) or ""))
            if normalized:
                return normalized
    return None


_MANAGED_VLESS_CLIENT_KEYS = (
    "id",
    "uuid",
    "email",
    "subId",
    "flow",
    "enable",
    "limitIp",
    "totalGB",
    "expiryTime",
    "tgId",
)


def _normalize_empty_default(value: Any) -> Any:
    if value is None:
        return ""
    return value


def managed_vless_client_projection(client: Mapping[str, Any]) -> dict[str, Any]:
    """Project fields AfterStart owns; drop empty panel defaults that cause churn."""
    out: dict[str, Any] = {}
    for key in _MANAGED_VLESS_CLIENT_KEYS:
        if key in client:
            out[key] = client.get(key)
    for key in ("password", "auth"):
        raw = _normalize_empty_default(client.get(key))
        if str(raw).strip() != "":
            out[key] = raw
    # XHTTP/gRPC omit empty flow; desired builders often set flow="". Treat as absent.
    if "flow" in out and str(out.get("flow") or "").strip() == "":
        out.pop("flow", None)
    if "uuid" not in out and "id" in out:
        out["uuid"] = out["id"]
    if "id" not in out and "uuid" in out:
        out["id"] = out["uuid"]
    out["tgId"] = _normalize_tg_id(out.get("tgId", 0))
    return out


def _vless_settings_without_clients(settings: Mapping[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in settings.items() if key != "clients"}


def _sorted_vless_client_projections(
    settings: Mapping[str, Any],
) -> list[dict[str, Any]]:
    clients = settings.get("clients") or []
    projected = [managed_vless_client_projection(client) for client in clients]
    return sorted(projected, key=lambda row: str(row.get("email") or ""))


def vless_inbound_settings_match(
    current: Mapping[str, Any],
    desired: Mapping[str, Any],
) -> bool:
    if not json_equal(
        _vless_settings_without_clients(current),
        _vless_settings_without_clients(desired),
    ):
        return False
    return json_equal(
        _sorted_vless_client_projections(current),
        _sorted_vless_client_projections(desired),
    )


def _vless_client_field_for_compare(
    secrets: SharedClientSecrets | None,
    inbound_client: Mapping[str, Any] | None,
    field: str,
) -> str:
    if inbound_client is not None and field in inbound_client:
        return str(inbound_client.get(field) or "")
    if secrets:
        value = getattr(secrets, field, "") or ""
        if str(value).strip():
            return str(value)
    return ""


def _vless_client_field_for_write(
    secrets: SharedClientSecrets | None,
    inbound_client: Mapping[str, Any] | None,
    field: str,
) -> str:
    if secrets:
        value = getattr(secrets, field, "") or ""
        if str(value).strip():
            return str(value)
    if inbound_client is not None:
        value = str(inbound_client.get(field) or "").strip()
        if value:
            return value
    return new_client_secret()


def vless_client_api_json(
    client_id: str,
    email: str,
    sub_id: str,
    flow: str,
    password: str = "",
    auth: str = "",
) -> dict[str, Any]:
    return {
        "id": client_id,
        "uuid": client_id,
        "password": password,
        "auth": auth,
        "flow": flow,
        "security": "auto",
        "email": email,
        "limitIp": 0,
        "totalGB": 0,
        "expiryTime": 0,
        "reset": 0,
        "tgId": 0,
        "group": "",
        "comment": "",
        "enable": True,
        "subId": sub_id,
    }


def vless_client_create_payload_json(
    inbound_ids: Sequence[int],
    client: Mapping[str, Any],
) -> dict[str, Any]:
    return {"client": dict(client), "inboundIds": [int(x) for x in inbound_ids]}


def current_inbound_components_json(inbound: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "up": inbound.get("up") or 0,
        "down": inbound.get("down") or 0,
        "total": inbound.get("total") or 0,
        "remark": inbound.get("remark") or "",
        "enable": inbound.get("enable", True),
        "expiryTime": inbound.get("expiryTime") or 0,
        "listen": inbound.get("listen") or "",
        "port": int(inbound.get("port", 0)),
        "protocol": inbound.get("protocol") or "",
        "settings": json_field_object(inbound, "settings"),
        "streamSettings": json_field_object(inbound, "streamSettings"),
        "sniffing": json_field_object(inbound, "sniffing"),
        "allocate": json_field_object(inbound, "allocate"),
    }


def _list_clients(api: PanelApi) -> list[dict[str, Any]]:
    api.list_clients()
    if not api.session.success_json():
        raise InboundApplyError(f"Client list API failed: {api.session.body()}")
    try:
        payload = json.loads(api.session.body())
    except json.JSONDecodeError as exc:
        raise InboundApplyError("Client list response is not JSON.") from exc
    obj = payload.get("obj")
    if isinstance(obj, list):
        return [dict(item) for item in obj if isinstance(item, dict)]
    return []


def _target_inbound_ids(
    vision_id: str,
    xhttp_id: str,
    grpc_id: str,
    hysteria2_id: str,
    amneziawg_id: str,
) -> list[int]:
    ids: list[int] = []
    for value in (vision_id, xhttp_id, grpc_id, hysteria2_id, amneziawg_id):
        text = (value or "").strip()
        if not text:
            continue
        ids.append(int(text))
    return ids


def _client_needs_update(
    current: Mapping[str, Any],
    sub_id: str,
    flow: str,
    password: str,
    auth: str,
) -> bool:
    return not (
        str(current.get("subId") or "") == sub_id
        and str(current.get("flow") or "") == flow
        and str(current.get("password") or "") == password
        and str(current.get("auth") or "") == auth
    )


def ensure_shared_client(
    vision_id: str,
    xhttp_id: str,
    grpc_id: str,
    hysteria2_id: str,
    amneziawg_id: str,
    desired: Mapping[str, Any],
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    stats: ApplyStats,
    secrets: SharedClientSecrets | None = None,
) -> SharedClientSecrets:
    bucket = secrets if secrets is not None else SharedClientSecrets()
    email = desired["clients"]["shared"]["email"]
    sub_id = desired["clients"]["shared"]["subId"]
    flow = desired["clients"]["shared"]["flow"]
    target_ids = _target_inbound_ids(
        vision_id, xhttp_id, grpc_id, hysteria2_id, amneziawg_id
    )
    clients = _list_clients(api)
    current = next((row for row in clients if row.get("email") == email), None)

    created = False
    if current is None:
        client_id = str(uuid.uuid4())
        password = new_client_secret()
        auth = new_client_secret()
        client = vless_client_api_json(client_id, email, sub_id, flow, password, auth)
        bucket.client_id, bucket.password, bucket.auth = client_id, password, auth
        target_text = ",".join(str(x) for x in target_ids)
        if mode == "plan":
            plan_or_apply(mode, stats, f"shared client created email={email} inbounds={target_text}")
            return bucket
        plan_or_apply(mode, stats, f"shared client created email={email} inbounds={target_text}")
        api.add_client(vless_client_create_payload_json(target_ids, client))
        if not api.session.success_json():
            raise InboundApplyError(f"shared client add failed: {api.session.body()}")
        repair_shared_client_db(
            email,
            client_id,
            sub_id,
            flow,
            password,
            auth,
            env=env,
            mode=mode,
        )
        stats.restart_xray_required = True
        current = {
            "email": email,
            "subId": sub_id,
            "sub_id": sub_id,
            "uuid": client_id,
            "id": client_id,
            "password": password,
            "auth": auth,
            "flow": flow,
            "inboundIds": target_ids,
        }
        created = True
    else:
        client_id = client_vless_uuid(current, include_auth=False) or ""
        if not client_id:
            client_id = (
                inbound_vless_client_uuid(api, vision_id, email)
                or inbound_vless_client_uuid(api, xhttp_id, email)
                or ""
            )
        if not client_id:
            client_id = client_vless_uuid(current) or ""
        if not client_id:
            client_id = str(uuid.uuid4())
            log.log(
                "WARN",
                f"Existing shared client email={email} has no valid VLESS UUID; "
                "generating a replacement.",
            )
        password = str(current.get("password") or "") or new_client_secret()
        auth = str(current.get("auth") or "") or new_client_secret()
        bucket.client_id, bucket.password, bucket.auth = client_id, password, auth
        client = vless_client_api_json(client_id, email, sub_id, flow, password, auth)
        if _client_needs_update(current, sub_id, flow, password, auth):
            if plan_or_apply(mode, stats, f"shared client updated email={email}"):
                api.update_client(email, client)
                if not api.session.success_json():
                    raise InboundApplyError(
                        f"shared client update failed: {api.session.body()}"
                    )
                repair_shared_client_db(
                    email, client_id, sub_id, flow, password, auth, env=env, mode=mode
                )
                stats.restart_xray_required = True
        repair_shared_client_db(
            email, client_id, sub_id, flow, password, auth, env=env, mode=mode
        )

    if not created:
        current_ids = {int(x) for x in (current.get("inboundIds") or [])}
        missing = [inbound_id for inbound_id in target_ids if inbound_id not in current_ids]
        if missing:
            attach_text = ",".join(str(x) for x in missing)
            if plan_or_apply(
                mode,
                stats,
                f"shared client attached email={email} inbounds={attach_text}",
            ):
                api.attach_client(email, {"inboundIds": missing})
                if not api.session.success_json():
                    raise InboundApplyError(
                        f"shared client attach failed: {api.session.body()}"
                    )
                stats.restart_xray_required = True
        else:
            attached = ",".join(str(x) for x in target_ids)
            log.log(
                "INFO",
                f"shared client already attached email={email} inbounds={attached}.",
            )

    vision_flow = desired["clients"]["shared"]["visionFlow"]
    xhttp_flow = desired["clients"]["shared"]["xhttpFlow"]
    ensure_vless_inbound_client(
        vision_id,
        bucket.client_id,
        desired,
        vision_flow,
        "Vision",
        api,
        env,
        mode,
        stats,
        secrets=bucket,
    )
    ensure_vless_inbound_client(
        xhttp_id,
        bucket.client_id,
        desired,
        xhttp_flow,
        "XHTTP",
        api,
        env,
        mode,
        stats,
        secrets=bucket,
    )
    ensure_vless_stream(vision_id, "vision", "Vision", api, env, mode, stats)
    ensure_vless_stream(xhttp_id, "xhttp", "XHTTP", api, env, mode, stats)
    return bucket


def _legacy_emails(env: Mapping[str, str]) -> tuple[str, str]:
    legacy = env.get("CLIENT_EMAIL_LEGACY", "autogen")
    hysteria_override = env.get("CLIENT_EMAIL_HYSTERIA2", "")
    legacy_hysteria = hysteria_override or f"{legacy}-hysteria2"
    return legacy, legacy_hysteria


def ensure_vless_inbound_client(
    inbound_id: str,
    client_id: str,
    desired: Mapping[str, Any],
    flow: str,
    label: str,
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    stats: ApplyStats,
    *,
    secrets: SharedClientSecrets | None = None,
) -> None:
    if not inbound_id:
        return
    if not client_id:
        log.log("WARN", f"Skipping {label} VLESS client sync because shared client id is unknown.")
        return
    api.get_inbound(inbound_id)
    if not api.session.success_json():
        raise InboundApplyError(f"Inbound get failed id={inbound_id}: {api.session.body()}")
    inbound = api_obj_json(api.session)
    current_settings = json_field_object(inbound, "settings")
    email = desired["clients"]["shared"]["email"]
    sub_id = desired["clients"]["shared"]["subId"]
    legacy, legacy_hysteria = _legacy_emails(env)
    existing_managed = next(
        (
            client
            for client in current_settings.get("clients") or []
            if client.get("email") == email
        ),
        None,
    )
    password = _vless_client_field_for_compare(secrets, existing_managed, "password")
    auth = _vless_client_field_for_compare(secrets, existing_managed, "auth")
    desired_client = vless_client_api_json(
        client_id, email, sub_id, "", password, auth
    )
    desired_client["flow"] = flow
    filtered: list[dict[str, Any]] = []
    for client in current_settings.get("clients") or []:
        client_email = client.get("email")
        if client_email in (email, legacy, legacy_hysteria):
            continue
        normalized = dict(client)
        normalized["tgId"] = _normalize_tg_id(client.get("tgId"))
        filtered.append(normalized)
    filtered.append(desired_client)
    desired_settings = {**current_settings, "decryption": "none", "encryption": "none", "clients": filtered}
    if vless_inbound_settings_match(current_settings, desired_settings):
        log.log("INFO", f"{label} VLESS inbound client already matches desired state.")
        return
    write_password = _vless_client_field_for_write(secrets, existing_managed, "password")
    write_auth = _vless_client_field_for_write(secrets, existing_managed, "auth")
    if write_password != password or write_auth != auth:
        desired_client = vless_client_api_json(
            client_id, email, sub_id, "", write_password, write_auth
        )
        desired_client["flow"] = flow
        filtered[-1] = desired_client
        desired_settings = {
            **current_settings,
            "decryption": "none",
            "encryption": "none",
            "clients": filtered,
        }
    components = current_inbound_components_json(inbound)
    components["settings"] = desired_settings
    if plan_or_apply(mode, stats, f"{label} VLESS inbound client synchronized"):
        api.update_inbound(inbound_id, components)
        if not api.session.success_json():
            raise InboundApplyError(f"Inbound update failed id={inbound_id}: {api.session.body()}")
        stats.restart_xray_required = True


def ensure_vless_stream(
    inbound_id: str,
    kind: str,
    label: str,
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    stats: ApplyStats,
) -> None:
    if not inbound_id:
        return
    api.get_inbound(inbound_id)
    if not api.session.success_json():
        raise InboundApplyError(f"Inbound get failed id={inbound_id}: {api.session.body()}")
    inbound = api_obj_json(api.session)
    desired_stream = build_inbound_stream_json(kind, env, current=inbound, api=api)
    components = current_inbound_components_json(inbound)
    desired_components = {**components, "streamSettings": desired_stream}
    if json_equal(components, desired_components):
        log.log("INFO", f"{label} stream already matches desired state.")
        return
    if plan_or_apply(mode, stats, f"{label} stream synchronized"):
        api.update_inbound(inbound_id, desired_components)
        if not api.session.success_json():
            raise InboundApplyError(f"Inbound update failed id={inbound_id}: {api.session.body()}")
        stats.restart_xray_required = True


def ensure_grpc_client(
    grpc_id: str,
    client_id: str,
    desired: Mapping[str, Any],
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    stats: ApplyStats,
    *,
    secrets: SharedClientSecrets | None = None,
) -> None:
    grpc_flow = desired["clients"]["shared"].get("grpcFlow", "")
    ensure_vless_inbound_client(
        grpc_id,
        client_id,
        desired,
        grpc_flow,
        "gRPC",
        api,
        env,
        mode,
        stats,
        secrets=secrets,
    )
    if not grpc_id:
        return
    api.get_inbound(grpc_id)
    if not api.session.success_json():
        raise InboundApplyError(f"Inbound get failed id={grpc_id}: {api.session.body()}")
    inbound = api_obj_json(api.session)
    desired_stream = build_inbound_stream_json("grpc", env, current=inbound, api=api)
    components = current_inbound_components_json(inbound)
    desired_components = {**components, "streamSettings": desired_stream}
    if json_equal(components, desired_components):
        log.log("INFO", "gRPC stream already matches desired state.")
        return
    if plan_or_apply(mode, stats, "gRPC stream synchronized"):
        api.update_inbound(grpc_id, desired_components)
        if not api.session.success_json():
            raise InboundApplyError(f"Inbound update failed id={grpc_id}: {api.session.body()}")
        stats.restart_xray_required = True


def ensure_hysteria2_client(
    hysteria2_id: str,
    desired: Mapping[str, Any],
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    stats: ApplyStats,
    *,
    shared_auth: str = "",
) -> None:
    if not hysteria2_id:
        return
    api.get_inbound(hysteria2_id)
    if not api.session.success_json():
        raise InboundApplyError(
            f"Inbound get failed id={hysteria2_id}: {api.session.body()}"
        )
    inbound = api_obj_json(api.session)
    desired_settings = build_hysteria2_settings_json(
        inbound, desired, preferred_auth=shared_auth, env=env
    )
    hysteria_auth = str((desired_settings.get("clients") or [{}])[0].get("auth") or "")
    desired_stream = build_inbound_stream_json(
        "hysteria2",
        env,
        current=inbound,
        hysteria_auth=hysteria_auth,
    )
    components = current_inbound_components_json(inbound)
    desired_components = {
        **components,
        "protocol": desired["inbounds"]["hysteria2"]["protocol"],
        "settings": desired_settings,
        "streamSettings": desired_stream,
    }
    if json_equal(components, desired_components):
        log.log("INFO", "Hysteria2 inbound client already matches desired state.")
        return
    if plan_or_apply(mode, stats, "Hysteria2 inbound client synchronized"):
        api.update_inbound(hysteria2_id, desired_components)
        if not api.session.success_json():
            raise InboundApplyError(
                f"Inbound update failed id={hysteria2_id}: {api.session.body()}"
            )
        stats.restart_xray_required = True
