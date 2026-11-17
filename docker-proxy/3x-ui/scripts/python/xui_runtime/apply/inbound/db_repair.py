"""SQLite repair helpers for inbound apply (library-only)."""

from __future__ import annotations

import json
import os
import sqlite3
import time
from collections.abc import Mapping
from typing import Any

from xui_runtime import log

def _db_path(env: Mapping[str, str]) -> str:
    return env.get("XUI_DB_PATH") or "/etc/x-ui/x-ui.db"


def _sqlite_commit_with_checkpoint(con: sqlite3.Connection) -> None:
    con.commit()
    con.execute("PRAGMA wal_checkpoint(TRUNCATE)")


def _invoke_sqlite_commit_with_checkpoint(con: sqlite3.Connection) -> None:
    from xui_runtime.apply import inbound as inbound_pkg

    inbound_pkg._sqlite_commit_with_checkpoint(con)


def repair_shared_client_db(
    email: str,
    client_id: str,
    sub_id: str,
    flow: str,
    password: str,
    auth: str,
    *,
    env: Mapping[str, str],
    mode: str,
) -> None:
    if mode != "apply":
        return
    db_path = _db_path(env)
    if not os.path.isfile(db_path) or os.path.getsize(db_path) == 0:
        return
    for _attempt in range(5):
        try:
            con = sqlite3.connect(db_path, timeout=10.0)
            try:
                con.execute("pragma busy_timeout=5000")
                cur = con.execute(
                    "update clients set uuid=?, password=?, auth=?, flow=?, sub_id=? "
                    "where email=?",
                    (client_id, password, auth, flow, sub_id, email),
                )
                if cur.rowcount > 0:
                    _invoke_sqlite_commit_with_checkpoint(con)
                else:
                    con.commit()
                return
            finally:
                con.close()
        except sqlite3.Error:
            time.sleep(0.2)
    log.log("WARN", f"Managed client DB repair skipped email={email}; sqlite update failed.")


def repair_inbound_client_tg_ids_db(
    *,
    env: Mapping[str, str],
    mode: str,
) -> int:
    if mode != "apply":
        return 0
    db_path = _db_path(env)
    if not os.path.isfile(db_path) or os.path.getsize(db_path) == 0:
        return 0
    changed = 0
    con = sqlite3.connect(db_path, timeout=10.0)
    try:
        cur = con.cursor()
        for inbound_id, settings_text in cur.execute("select id, settings from inbounds"):
            if not settings_text:
                continue
            try:
                obj = json.loads(settings_text)
            except json.JSONDecodeError:
                continue
            dirty = False
            for client in obj.get("clients") or []:
                tg = client.get("tgId", 0)
                if isinstance(tg, str):
                    text = tg.strip()
                    client["tgId"] = int(text) if text.lstrip("-").isdigit() else 0
                    dirty = True
                elif tg is None:
                    client["tgId"] = 0
                    dirty = True
            if dirty:
                cur.execute(
                    "update inbounds set settings=? where id=?",
                    (json.dumps(obj, separators=(",", ":")), inbound_id),
                )
                changed += 1
        if changed:
            _invoke_sqlite_commit_with_checkpoint(con)
        else:
            con.commit()
    finally:
        con.close()
    if changed:
        log.log(
            "INFO",
            f"Normalized string tgId values in {changed} inbound settings row(s).",
        )
    return changed


def repair_inbound_vless_client_flows_db(
    vision_id: str,
    xhttp_id: str,
    grpc_id: str,
    desired: Mapping[str, Any],
    *,
    env: Mapping[str, str],
    mode: str,
) -> int:
    if mode != "apply":
        return 0
    db_path = _db_path(env)
    if not os.path.isfile(db_path) or os.path.getsize(db_path) == 0:
        return 0
    email = desired["clients"]["shared"]["email"]
    targets: list[tuple[int, str]] = []
    flows = {
        "vision": desired["clients"]["shared"]["visionFlow"],
        "xhttp": desired["clients"]["shared"]["xhttpFlow"],
        "grpc": desired["clients"]["shared"].get("grpcFlow", ""),
    }
    for inbound_id, flow_key in (
        (vision_id, flows["vision"]),
        (xhttp_id, flows["xhttp"]),
        (grpc_id, flows["grpc"]),
    ):
        text = (inbound_id or "").strip()
        if not text:
            continue
        targets.append((int(text), flow_key))
    changed = 0
    con = sqlite3.connect(db_path, timeout=10.0)
    try:
        cur = con.cursor()
        for inbound_id, flow in targets:
            row = cur.execute(
                "select settings from inbounds where id=?", (inbound_id,)
            ).fetchone()
            if not row or not row[0]:
                continue
            try:
                obj = json.loads(row[0])
            except json.JSONDecodeError:
                continue
            dirty = False
            for client in obj.get("clients") or []:
                if client.get("email") != email:
                    continue
                if (client.get("flow") or "") != flow:
                    client["flow"] = flow
                    dirty = True
            if dirty:
                cur.execute(
                    "update inbounds set settings=? where id=?",
                    (json.dumps(obj, separators=(",", ":")), inbound_id),
                )
                changed += 1
        if changed:
            _invoke_sqlite_commit_with_checkpoint(con)
        else:
            con.commit()
    finally:
        con.close()
    if changed:
        log.log("INFO", f"Repaired VLESS client flow in {changed} inbound settings row(s).")
    return changed


def repair_shared_client_after_inbound_sync(
    desired: Mapping[str, Any],
    vision_id: str,
    xhttp_id: str,
    grpc_id: str,
    secrets: SharedClientSecrets,
    *,
    env: Mapping[str, str],
    mode: str,
) -> None:
    if not secrets.client_id:
        return
    email = desired["clients"]["shared"]["email"]
    sub_id = desired["clients"]["shared"]["subId"]
    flow = desired["clients"]["shared"]["flow"]
    repair_shared_client_db(
        email,
        secrets.client_id,
        sub_id,
        flow,
        secrets.password,
        secrets.auth,
        env=env,
        mode=mode,
    )
    repair_inbound_vless_client_flows_db(
        vision_id,
        xhttp_id,
        grpc_id,
        desired,
        env=env,
        mode=mode,
    )