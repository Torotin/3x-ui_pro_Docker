"""HTTP session client mirroring scripts/lib/http.bash (stdlib only)."""

from __future__ import annotations

import json
import os
import ssl
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from http import cookiejar
from pathlib import Path

from xui_runtime import log

HTTP_CONNECT_TIMEOUT = 2
HTTP_MAX_TIME = 8
HTTP_ATTEMPTS = 4
HTTP_LOG_FAILURES = 1

_SSL_CONTEXT = ssl._create_unverified_context()


@dataclass
class HttpResult:
    code: str
    body_path: Path | None
    error: str
    last_url: str
    ok: bool


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return int(raw)


def _env_bool01(name: str, default: int) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return bool(default)
    return raw.strip() not in ("0", "false", "False", "no", "NO")


def _normalize_headers(
    headers: list[str] | dict[str, str] | None,
) -> dict[str, str]:
    if headers is None:
        return {}
    if isinstance(headers, dict):
        return dict(headers)
    out: dict[str, str] = {}
    for item in headers:
        if ":" not in item:
            continue
        name, value = item.split(":", 1)
        out[name.strip()] = value.strip()
    return out


class HttpSession:
    def __init__(
        self,
        *,
        connect_timeout: float | None = None,
        max_time: float | None = None,
        attempts: int | None = None,
        log_failures: bool | None = None,
        sleep_fn=time.sleep,
    ) -> None:
        self.connect_timeout = (
            connect_timeout
            if connect_timeout is not None
            else float(_env_int("HTTP_CONNECT_TIMEOUT", HTTP_CONNECT_TIMEOUT))
        )
        self.max_time = (
            max_time
            if max_time is not None
            else float(_env_int("HTTP_MAX_TIME", HTTP_MAX_TIME))
        )
        self.attempts = (
            attempts
            if attempts is not None
            else _env_int("HTTP_ATTEMPTS", HTTP_ATTEMPTS)
        )
        self.log_failures = (
            log_failures
            if log_failures is not None
            else _env_bool01("HTTP_LOG_FAILURES", HTTP_LOG_FAILURES)
        )
        self._sleep = sleep_fn

        self._tmp_root: Path | None = None
        self._cookie_jar_path: Path | None = None
        self._cookie_jar: cookiejar.MozillaCookieJar | None = None
        self._opener: urllib.request.OpenerDirector | None = None

        self._code = "000"
        self._body_path: Path | None = None
        self._error = ""
        self._last_url = ""

    def init(self, tmp_root: str) -> None:
        self._tmp_root = Path(tmp_root)
        self._tmp_root.mkdir(parents=True, exist_ok=True)
        self._cookie_jar_path = self._tmp_root / "cookies.txt"
        self._cookie_jar_path.write_text(
            "# Netscape HTTP Cookie File\n",
            encoding="utf-8",
        )
        self._cookie_jar = cookiejar.MozillaCookieJar(str(self._cookie_jar_path))
        self._cookie_jar.load(ignore_discard=True, ignore_expires=True)
        self._opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self._cookie_jar),
            urllib.request.HTTPSHandler(context=_SSL_CONTEXT),
        )

    def _mktemp(self, name: str) -> Path:
        if self._tmp_root is None:
            fd, raw = tempfile.mkstemp(prefix=f"{name}.")
            os.close(fd)
            return Path(raw)
        fd, raw = tempfile.mkstemp(prefix=f"{name}.", dir=self._tmp_root)
        os.close(fd)
        return Path(raw)

    def _save_cookies(self) -> None:
        if self._cookie_jar is not None:
            self._cookie_jar.save(ignore_discard=True, ignore_expires=True)

    def request(
        self,
        method: str,
        url: str,
        *,
        headers: list[str] | dict[str, str] | None = None,
        data: bytes | None = None,
        form: list[tuple[str, str]] | None = None,
        **_ignored: object,
    ) -> HttpResult:
        if self._opener is None or self._tmp_root is None:
            raise RuntimeError("HttpSession.init(tmp_root) must be called before request")

        self._last_url = url
        self._code = "000"
        self._error = ""
        self._body_path = None

        header_map = _normalize_headers(headers)
        body_data = data
        if form is not None:
            body_data = urllib.parse.urlencode(form, doseq=True).encode("utf-8")
            header_map.setdefault(
                "Content-Type",
                "application/x-www-form-urlencoded; charset=UTF-8",
            )

        attempts_left = self.attempts
        delay = 1
        last_error = ""

        while attempts_left > 0:
            body_path = self._mktemp("http-body")
            try:
                req = urllib.request.Request(
                    url,
                    data=body_data,
                    headers=header_map,
                    method=method.upper(),
                )
                with self._opener.open(
                    req,
                    timeout=max(self.connect_timeout, self.max_time),
                ) as resp:
                    code = str(resp.getcode() or resp.status)
                    payload = resp.read()
                if not code or code == "None":
                    raise urllib.error.URLError("empty http status code")
                body_path.write_bytes(payload)
                self._save_cookies()
                self._code = code
                self._body_path = body_path
                self._error = last_error
                return HttpResult(
                    code=code,
                    body_path=body_path,
                    error=last_error,
                    last_url=url,
                    ok=True,
                )
            except urllib.error.HTTPError as exc:
                code = str(exc.code)
                payload = exc.read()
                if not code or code == "None":
                    last_error = str(exc).replace("\n", " ")
                else:
                    body_path.write_bytes(payload)
                    self._save_cookies()
                    self._code = code
                    self._body_path = body_path
                    self._error = last_error
                    return HttpResult(
                        code=code,
                        body_path=body_path,
                        error=last_error,
                        last_url=url,
                        ok=True,
                    )
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                last_error = str(exc).replace("\n", " ")
                self._error = last_error
                self._code = "000"

            if body_path.exists():
                body_path.unlink()

            attempts_left -= 1
            if attempts_left > 0:
                log.log(
                    "DEBUG",
                    f"curl failed for {method} {url} attempts_left={attempts_left} "
                    f"error={last_error}",
                )
                self._sleep(delay)
                delay *= 2

        if self.log_failures:
            log.log(
                "ERROR",
                f"curl failed for {method} {url} after {self.attempts} attempts: "
                f"{last_error}",
            )
        else:
            log.log(
                "DEBUG",
                f"curl failed for {method} {url} after {self.attempts} attempts: "
                f"{last_error}",
            )

        self._body_path = None
        return HttpResult(
            code=self._code,
            body_path=None,
            error=last_error,
            last_url=url,
            ok=False,
        )

    def body(self) -> str:
        if self._body_path is None or not self._body_path.is_file():
            return ""
        return self._body_path.read_text(encoding="utf-8", errors="replace")

    def success_json(self) -> bool:
        if self._code != "200" or self._body_path is None or not self._body_path.is_file():
            return False
        try:
            payload = json.loads(self._body_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return False
        return payload.get("success") is True