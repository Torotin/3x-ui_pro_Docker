"""3x-ui panel API client (mirrors scripts/lib/3xui_api.bash)."""

from __future__ import annotations

import json
import urllib.parse
from collections.abc import Mapping
from typing import Any

from xui_runtime import log
from xui_runtime.env import normalize_base_path
from xui_runtime.http_client import HttpResult, HttpSession

_MANAGED_CLIENT_KEYS = (
    "id",
    "uuid",
    "password",
    "auth",
    "flow",
    "email",
    "subId",
    "enable",
    "security",
    "comment",
    "limitIp",
    "totalGB",
    "expiryTime",
    "reset",
    "tgId",
    "group",
)

_ROUTE_CACHE_PREFIX = "XUI_ROUTE_"


class PanelApi:
    def __init__(self, session: HttpSession, env: Mapping[str, str] | dict[str, str]) -> None:
        self.session = session
        self.env: dict[str, str] = dict(env)
        resolved = self.env.get("URL_BASE_RESOLVED", "")
        self.base_url = resolved.rstrip("/") if resolved else ""

    def url(self, path: str) -> str:
        return f"{self.base_url.rstrip('/')}{path}"

    def api_token(self) -> str:
        token = (self.env.get("XUI_API_TOKEN") or "").strip()
        if token:
            return token
        return (self.env.get("XUI_API_TOKEN_RESOLVED") or "").strip()

    def _bearer_headers(self, path: str) -> dict[str, str]:
        if not path.startswith("/panel/api/"):
            return {}
        token = self.api_token()
        if not token:
            return {}
        return {"Authorization": f"Bearer {token}"}

    def _ajax_headers(self, *, json_body: bool) -> dict[str, str]:
        headers = {
            "Accept": "application/json",
            "X-Requested-With": "XMLHttpRequest",
        }
        if json_body:
            headers["Content-Type"] = "application/json"
        else:
            headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        return headers

    def csrf_token(self) -> str:
        result = self.session.request(
            "GET",
            self.url("/csrf-token"),
            headers={
                "Accept": "application/json",
                "X-Requested-With": "XMLHttpRequest",
            },
        )
        if result.code != "200" or not result.body_path:
            return ""
        try:
            payload = json.loads(result.body_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return ""
        if payload.get("success") is True and isinstance(payload.get("obj"), str):
            return payload["obj"]
        return ""

    def _csrf_headers(self) -> dict[str, str]:
        token = self.csrf_token()
        if not token:
            return {}
        return {"X-CSRF-Token": token}

    def api_get(self, path: str) -> HttpResult:
        headers = {**self._ajax_headers(json_body=False), **self._bearer_headers(path)}
        return self.session.request("GET", self.url(path), headers=headers)

    def api_post(
        self,
        path: str,
        *,
        form: list[tuple[str, str]] | None = None,
        data: bytes | None = None,
    ) -> HttpResult:
        headers = {
            **self._ajax_headers(json_body=False),
            **self._bearer_headers(path),
            **self._csrf_headers(),
        }
        return self.session.request(
            "POST",
            self.url(path),
            headers=headers,
            form=form,
            data=data,
        )

    def api_post_json(self, path: str, body: str | dict[str, Any]) -> HttpResult:
        if isinstance(body, dict):
            payload = json.dumps(body, separators=(",", ":"))
        else:
            payload = body
        headers = {
            **self._ajax_headers(json_body=True),
            **self._bearer_headers(path),
            **self._csrf_headers(),
        }
        return self.session.request(
            "POST",
            self.url(path),
            headers=headers,
            data=payload.encode("utf-8"),
        )

    def _route_cache_key(self, cache_var: str) -> str:
        if cache_var.startswith(_ROUTE_CACHE_PREFIX):
            return cache_var
        return f"{_ROUTE_CACHE_PREFIX}{cache_var}"

    def _cached_route(self, cache_var: str) -> str | None:
        key = self._route_cache_key(cache_var)
        value = self.env.get(key, "").strip()
        return value or None

    def _set_cached_route(self, cache_var: str, path: str) -> None:
        self.env[self._route_cache_key(cache_var)] = path

    def api_post_dual_path(
        self,
        cache_var: str,
        canonical: str,
        legacy: str,
        *,
        form: list[tuple[str, str]] | None = None,
        data: bytes | None = None,
    ) -> HttpResult:
        resolved = self._cached_route(cache_var)
        if resolved:
            return self.api_post(resolved, form=form, data=data)

        result = self.api_post(canonical, form=form, data=data)
        if result.code != "404":
            self._set_cached_route(cache_var, canonical)
            return result

        log.log("DEBUG", f"Panel API route fallback: {canonical} -> {legacy}")
        result = self.api_post(legacy, form=form, data=data)
        if result.code != "404":
            self._set_cached_route(cache_var, legacy)
        return result

    def api_post_json_dual_path(
        self,
        cache_var: str,
        canonical: str,
        legacy: str,
        body: str | dict[str, Any],
    ) -> HttpResult:
        resolved = self._cached_route(cache_var)
        if resolved:
            return self.api_post_json(resolved, body)

        result = self.api_post_json(canonical, body)
        if result.code != "404":
            self._set_cached_route(cache_var, canonical)
            return result

        log.log("DEBUG", f"Panel API route fallback: {canonical} -> {legacy}")
        result = self.api_post_json(legacy, body)
        if result.code != "404":
            self._set_cached_route(cache_var, legacy)
        return result

    def _long_max_time(self) -> float:
        raw = self.env.get("HTTP_LONG_MAX_TIME", "180")
        try:
            return float(raw)
        except ValueError:
            return 180.0

    def _with_long_timeout(self):
        from contextlib import contextmanager

        @contextmanager
        def _ctx():
            old_max = self.session.max_time
            self.session.max_time = self._long_max_time()
            try:
                yield
            finally:
                self.session.max_time = old_max

        return _ctx()

    def _with_once_long(self):
        from contextlib import contextmanager

        @contextmanager
        def _ctx():
            old_max = self.session.max_time
            old_attempts = self.session.attempts
            self.session.max_time = self._long_max_time()
            self.session.attempts = 1
            try:
                yield
            finally:
                self.session.max_time = old_max
                self.session.attempts = old_attempts

        return _ctx()

    def api_post_long(
        self,
        path: str,
        *,
        form: list[tuple[str, str]] | None = None,
        data: bytes | None = None,
    ) -> HttpResult:
        with self._with_long_timeout():
            return self.api_post(path, form=form, data=data)

    def api_post_once_long(
        self,
        path: str,
        *,
        form: list[tuple[str, str]] | None = None,
        data: bytes | None = None,
    ) -> HttpResult:
        with self._with_once_long():
            return self.api_post(path, form=form, data=data)

    def api_post_json_once_long(self, path: str, body: str | dict[str, Any]) -> HttpResult:
        with self._with_once_long():
            return self.api_post_json(path, body)

    def api_post_dual_path_long(
        self,
        cache_var: str,
        canonical: str,
        legacy: str,
        *,
        form: list[tuple[str, str]] | None = None,
        data: bytes | None = None,
    ) -> HttpResult:
        with self._with_long_timeout():
            resolved = self._cached_route(cache_var)
            if resolved:
                return self.api_post(resolved, form=form, data=data)
            result = self.api_post(canonical, form=form, data=data)
            if result.code == "404":
                log.log("DEBUG", f"Panel API route fallback: {canonical} -> {legacy}")
                result = self.api_post(legacy, form=form, data=data)
                if result.code != "404":
                    self._set_cached_route(cache_var, legacy)
            else:
                self._set_cached_route(cache_var, canonical)
            return result

    def login(self, base: str, username: str, password: str) -> bool:
        self.base_url = base.rstrip("/")
        csrf = self.csrf_token()
        headers: dict[str, str] = {
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-Requested-With": "XMLHttpRequest",
        }
        if csrf:
            headers["X-CSRF-Token"] = csrf
        body: dict[str, str] = {"username": username, "password": password}
        two_factor = (self.env.get("TWO_FACTOR_CODE") or "").strip()
        if two_factor:
            body["twoFactorCode"] = two_factor
        payload = json.dumps(body, separators=(",", ":"))
        self.session.request(
            "POST",
            self.url("/login"),
            headers=headers,
            data=payload.encode("utf-8"),
        )
        if self.session.success_json():
            self.env["URL_BASE_RESOLVED"] = self.base_url
            return True
        return False

    def resolve_panel_base(self) -> bool:
        bp = normalize_base_path(self.env.get("webBasePath"))
        credentials: list[tuple[str, str]] = [
            (self.env.get("USERNAME", ""), self.env.get("PASSWORD", "")),
        ]
        new_user = (self.env.get("NEW_ADMIN_USERNAME") or "").strip()
        new_pass = (self.env.get("NEW_ADMIN_PASSWORD") or "").strip()
        if new_user and new_pass:
            credentials.append((new_user, new_pass))

        bases: list[str] = []
        existing = self.env.get("URL_BASE_RESOLVED", "").strip()
        if existing:
            bases.append(existing.rstrip("/"))

        web_port = (self.env.get("webPort") or "").strip()
        if web_port:
            bases.extend(
                [
                    f"https://127.0.0.1:{web_port}{bp}",
                    f"http://127.0.0.1:{web_port}{bp}",
                    f"https://localhost:{web_port}{bp}",
                    f"http://localhost:{web_port}{bp}",
                    f"https://127.0.0.1:{web_port}",
                    f"http://127.0.0.1:{web_port}",
                    f"https://localhost:{web_port}",
                    f"http://localhost:{web_port}",
                ]
            )

        webdomain = (self.env.get("WEBDOMAIN") or "").strip()
        if webdomain:
            bases.append(f"https://{webdomain}{bp}")
            bases.append(f"http://{webdomain}{bp}")
        if web_port and web_port != "2053" and webdomain:
            bases.append(f"https://{webdomain}:{web_port}{bp}")
            bases.append(f"http://{webdomain}:{web_port}{bp}")

        bases.extend(
            [
                f"https://127.0.0.1:2053{bp}",
                f"http://127.0.0.1:2053{bp}",
                f"https://localhost:2053{bp}",
                f"http://localhost:2053{bp}",
                f"https://127.0.0.1:2053",
                f"http://127.0.0.1:2053",
                f"https://localhost:2053",
                f"http://localhost:2053",
            ]
        )

        old_attempts = self.session.attempts
        old_connect = self.session.connect_timeout
        old_max = self.session.max_time
        old_log = self.session.log_failures
        self.session.attempts = 1
        self.session.connect_timeout = 1.0
        self.session.max_time = 3.0
        self.session.log_failures = False

        try:
            for base in bases:
                if not base:
                    continue
                for user, password in credentials:
                    if not user or not password:
                        continue
                    log.log("DEBUG", f"Trying panel login base={base} username={user}")
                    if self.login(base, user, password):
                        self.env["USERNAME"] = user
                        self.env["PASSWORD"] = password
                        log.log("INFO", f"Panel login succeeded at {self.base_url}")
                        return True
        finally:
            self.session.attempts = old_attempts
            self.session.connect_timeout = old_connect
            self.session.max_time = old_max
            self.session.log_failures = old_log

        return False

    @staticmethod
    def client_email_path(email: str) -> str:
        return urllib.parse.quote(email, safe="")

    def get_panel_settings(self) -> HttpResult:
        return self.api_post_dual_path(
            "setting_all",
            "/panel/api/setting/all",
            "/panel/setting/all",
        )

    def update_panel_settings(self, body: str | dict[str, Any]) -> HttpResult:
        return self.api_post_json_dual_path(
            "setting_update",
            "/panel/api/setting/update",
            "/panel/setting/update",
            body,
        )

    def update_admin_credentials(self) -> HttpResult | None:
        new_user = (self.env.get("NEW_ADMIN_USERNAME") or "").strip()
        new_pass = (self.env.get("NEW_ADMIN_PASSWORD") or "").strip()
        if not new_user or not new_pass:
            return None
        body = {
            "oldUsername": self.env.get("USERNAME", ""),
            "oldPassword": self.env.get("PASSWORD", ""),
            "newUsername": new_user,
            "newPassword": new_pass,
        }
        return self.api_post_json_dual_path(
            "setting_update_user",
            "/panel/api/setting/updateUser",
            "/panel/setting/updateUser",
            body,
        )

    def list_inbounds(self) -> HttpResult:
        return self.api_get("/panel/api/inbounds/list")

    def get_inbound(self, inbound_id: int | str) -> HttpResult:
        return self.api_get(f"/panel/api/inbounds/get/{inbound_id}")

    def add_inbound(self, body: str | dict[str, Any]) -> HttpResult:
        return self.api_post_json_once_long("/panel/api/inbounds/add", body)

    def del_inbound(self, inbound_id: int | str) -> HttpResult:
        return self.api_post(f"/panel/api/inbounds/del/{inbound_id}")

    def update_inbound(self, inbound_id: int | str, body: str | dict[str, Any]) -> HttpResult:
        return self.api_post_json(f"/panel/api/inbounds/update/{inbound_id}", body)

    def add_client(self, payload: str | dict[str, Any]) -> HttpResult:
        return self.api_post_json_once_long("/panel/api/clients/add", payload)

    def get_client(self, email: str) -> HttpResult:
        path = self.client_email_path(email)
        return self.api_get(f"/panel/api/clients/get/{path}")

    def list_clients(self) -> HttpResult:
        return self.api_get("/panel/api/clients/list")

    def attach_client(self, email: str, payload: str | dict[str, Any]) -> HttpResult:
        path = self.client_email_path(email)
        return self.api_post_json_once_long(f"/panel/api/clients/{path}/attach", payload)

    def update_client(self, email: str, payload: dict[str, Any]) -> HttpResult:
        get_result = self.get_client(email)
        if get_result.code != "200" or not self.session.success_json():
            return get_result
        current: dict[str, Any] = {}
        try:
            parsed = json.loads(self.session.body())
            if isinstance(parsed.get("obj"), dict):
                current = dict(parsed["obj"])
        except json.JSONDecodeError:
            return get_result
        merged = dict(current)
        for key in _MANAGED_CLIENT_KEYS:
            if key in payload:
                merged[key] = payload[key]
        path = self.client_email_path(email)
        return self.api_post_json(f"/panel/api/clients/update/{path}", merged)

    def get_xray_settings(self) -> HttpResult:
        return self.api_post_dual_path(
            "xray_read",
            "/panel/api/xray/",
            "/panel/xray/",
        )

    def update_xray_settings(self, xray_setting_file: str) -> HttpResult:
        with open(xray_setting_file, encoding="utf-8") as handle:
            xray_setting = handle.read()
        return self.api_post_dual_path(
            "xray_update",
            "/panel/api/xray/update",
            "/panel/xray/update",
            form=[("xraySetting", xray_setting)],
        )

    def restart_panel(self) -> HttpResult:
        return self.api_post_dual_path(
            "setting_restart_panel",
            "/panel/api/setting/restartPanel",
            "/panel/setting/restartPanel",
        )

    def restart_xray(self) -> HttpResult:
        return self.api_post("/panel/api/server/restartXrayService")

    def update_geofiles(self) -> HttpResult:
        return self.api_post_long("/panel/api/server/updateGeofile")

    def warp_config(self) -> HttpResult:
        return self.api_post_dual_path(
            "xray_warp_config",
            "/panel/api/xray/warp/config",
            "/panel/xray/warp/config",
        )

    def warp_register(self, public_key: str, private_key: str) -> HttpResult:
        return self.api_post_dual_path_long(
            "xray_warp_reg",
            "/panel/api/xray/warp/reg",
            "/panel/xray/warp/reg",
            form=[
                ("publicKey", public_key),
                ("privateKey", private_key),
            ],
        )

    def get_x25519(self) -> HttpResult:
        return self.api_get("/panel/api/server/getNewX25519Cert")

    def get_vless_enc(self) -> HttpResult:
        return self.api_get("/panel/api/server/getNewVlessEnc")

    def list_sub_balancers(self) -> HttpResult:
        return self.api_get("/panel/api/sub-balancers")

    def add_sub_balancer(self, form: list[tuple[str, str]]) -> HttpResult:
        return self.api_post("/panel/api/sub-balancers", form=form)

    def update_sub_balancer(self, balancer_id: str | int, form: list[tuple[str, str]]) -> HttpResult:
        return self.api_post(f"/panel/api/sub-balancers/{balancer_id}", form=form)