#!/usr/bin/env python3
import copy
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, urlunsplit
from urllib.request import Request, urlopen


DEFAULT_ASSETS = [
    {
        "url": "https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.dat",
        "file": "zxc-rv-adlist.dat",
    },
    {
        "url": "https://github.com/jameszeroX/zkeen-ip/releases/latest/download/zkeenip.dat",
        "file": "zkeenip.dat",
    },
]

PRESERVED_RESPONSE_HEADERS = {
    "profile-title",
    "profile-update-interval",
    "profile-web-page-url",
    "routing-enable",
    "subscription-userinfo",
    "subcription-userinfo",
    "x-subscription-userinfo",
}

HOP_BY_HOP_HEADERS = {
    "connection",
    "content-encoding",
    "content-length",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


def env_bool(value, default=False):
    if value is None or value == "":
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def build_geodata(env):
    if not env_bool(env.get("SUB_JSON_GEODATA_ENABLE"), True):
        return None

    assets_raw = env.get("SUB_JSON_GEODATA_ASSETS_JSON", "")
    if assets_raw:
        try:
            assets = json.loads(assets_raw)
        except json.JSONDecodeError as exc:
            raise ValueError(f"invalid SUB_JSON_GEODATA_ASSETS_JSON: {exc}") from exc
        if not isinstance(assets, list):
            raise ValueError("SUB_JSON_GEODATA_ASSETS_JSON must be a JSON array")
        for asset in assets:
            if not isinstance(asset, dict) or not isinstance(asset.get("url"), str) or not isinstance(asset.get("file"), str):
                raise ValueError("each geodata asset must contain string url and file fields")
    else:
        assets = DEFAULT_ASSETS

    return {
        "cron": env.get("SUB_JSON_GEODATA_CRON") or "0 4 * * *",
        "outbound": env.get("SUB_JSON_GEODATA_OUTBOUND") or "proxy",
        "assets": copy.deepcopy(assets),
    }


def apply_geodata(payload, geodata):
    if geodata is None:
        return payload

    def with_geodata(item):
        if not isinstance(item, dict):
            raise ValueError("JSON subscription entries must be objects")
        updated = copy.deepcopy(item)
        updated["geodata"] = copy.deepcopy(geodata)
        return updated

    if isinstance(payload, list):
        return [with_geodata(item) for item in payload]
    if isinstance(payload, dict):
        return with_geodata(payload)
    raise ValueError("JSON subscription root must be an object or array")


def upstream_base_from_env(env):
    explicit = env.get("SUB_JSON_UPSTREAM_BASE")
    if explicit:
        return explicit.rstrip("/")
    port = env.get("PORT_LOCAL_VLESS_SUBSCRIBE") or "2096"
    return f"http://3x-ui:{port}"


def make_upstream_url(base, path, query):
    split = urlsplit(base)
    upstream_path = path
    if split.path and split.path != "/":
        upstream_path = f"{split.path.rstrip('/')}/{path.lstrip('/')}"
    return urlunsplit((split.scheme, split.netloc, upstream_path, query, ""))


def response_headers_for_transform(upstream_headers):
    headers = {}
    for key, value in upstream_headers.items():
        lower = key.lower()
        if lower in PRESERVED_RESPONSE_HEADERS:
            headers[key] = value
    headers["Content-Type"] = "application/json; charset=utf-8"
    headers["X-Sub-Json-Processor"] = "geodata"
    return headers


def response_headers_for_passthrough(upstream_headers):
    headers = {}
    for key, value in upstream_headers.items():
        if key.lower() not in HOP_BY_HOP_HEADERS:
            headers[key] = value
    return headers


def make_handler(env):
    config_env = dict(env)

    class SubJsonProcessorHandler(BaseHTTPRequestHandler):
        server_version = "sub-json-processor/1.0"

        def do_GET(self):
            if self.path == "/healthz":
                self.send_body(200, {"Content-Type": "text/plain; charset=utf-8"}, b"ok\n", include_body=True)
                return
            self.proxy_json(include_body=True)

        def do_HEAD(self):
            if self.path == "/healthz":
                self.send_body(200, {"Content-Type": "text/plain; charset=utf-8"}, b"", include_body=False)
                return
            self.proxy_json(include_body=False)

        def proxy_json(self, include_body):
            upstream_base = upstream_base_from_env(config_env)
            parsed_path = urlsplit(self.path)
            upstream_url = make_upstream_url(upstream_base, parsed_path.path, parsed_path.query)
            method = "GET" if include_body else "HEAD"
            request = Request(upstream_url, method=method, headers=self.forward_request_headers())

            try:
                with urlopen(request, timeout=float(config_env.get("SUB_JSON_UPSTREAM_TIMEOUT", "15"))) as response:
                    status = response.status
                    upstream_headers = response.headers
                    body = response.read() if include_body else b""
            except HTTPError as exc:
                body = exc.read() if include_body else b""
                self.send_body(exc.code, response_headers_for_passthrough(exc.headers), body, include_body=include_body)
                return
            except (TimeoutError, URLError, OSError):
                self.send_body(502, {"Content-Type": "text/plain; charset=utf-8"}, b"upstream unavailable\n", include_body=include_body)
                return

            if status < 200 or status >= 300 or not include_body:
                self.send_body(status, response_headers_for_passthrough(upstream_headers), body, include_body=include_body)
                return

            try:
                geodata = build_geodata(config_env)
                payload = json.loads(body.decode("utf-8"))
                transformed = apply_geodata(payload, geodata)
                out = json.dumps(transformed, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
                self.send_body(status, response_headers_for_transform(upstream_headers), out, include_body=True)
            except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
                if env_bool(config_env.get("SUB_JSON_PROCESSOR_FAIL_OPEN"), True):
                    headers = response_headers_for_passthrough(upstream_headers)
                    headers["X-Sub-Json-Processor-Warning"] = "invalid-json-fail-open"
                    self.send_body(status, headers, body, include_body=True)
                else:
                    self.send_body(502, {"Content-Type": "text/plain; charset=utf-8"}, b"invalid upstream json\n", include_body=True)

        def forward_request_headers(self):
            headers = {"Accept-Encoding": "identity"}
            host = self.headers.get("Host") or config_env.get("WEBDOMAIN")
            if host:
                headers["Host"] = host
            for key in ("Accept", "User-Agent"):
                value = self.headers.get(key)
                if value:
                    headers[key] = value
            return headers

        def send_body(self, status, headers, body, include_body):
            self.send_response(status)
            for key, value in headers.items():
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(body) if include_body else 0))
            self.end_headers()
            if include_body and body:
                self.wfile.write(body)

        def log_message(self, _format, *_args):
            return

    return SubJsonProcessorHandler


def main():
    port = int(os.environ.get("SUB_JSON_PROCESSOR_PORT", "8080"))
    handler = make_handler(os.environ)
    httpd = ThreadingHTTPServer(("0.0.0.0", port), handler)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
