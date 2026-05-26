#!/usr/bin/env python3
import importlib.util
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen


ROOT_DIR = Path(__file__).resolve().parents[2]
SERVER_PATH = ROOT_DIR / "docker-proxy/3x-ui/sub-json-processor/server.py"


def load_server():
    spec = importlib.util.spec_from_file_location("sub_json_processor", SERVER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class UpstreamHandler(BaseHTTPRequestHandler):
    status = 200
    body = b"[]"
    headers_to_send = {}
    seen_methods = []
    expected_host = None

    def do_GET(self):
        type(self).seen_methods.append("GET")
        if type(self).expected_host and self.headers.get("Host") != type(self).expected_host:
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(type(self).status)
        for key, value in type(self).headers_to_send.items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(type(self).body)))
        self.end_headers()
        self.wfile.write(type(self).body)

    def do_HEAD(self):
        type(self).seen_methods.append("HEAD")
        if type(self).expected_host and self.headers.get("Host") != type(self).expected_host:
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(type(self).status)
        for key, value in type(self).headers_to_send.items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(type(self).body)))
        self.end_headers()

    def log_message(self, _format, *_args):
        return


class ProcessorTests(unittest.TestCase):
    def setUp(self):
        self.server = load_server()

    def test_adds_default_geodata_to_each_config_in_array(self):
        payload = [{"remarks": "a"}, {"remarks": "b", "geodata": {"old": True}}]
        geodata = self.server.build_geodata({})

        result = self.server.apply_geodata(payload, geodata)

        self.assertEqual("0 4 * * *", result[0]["geodata"]["cron"])
        self.assertEqual("proxy", result[1]["geodata"]["outbound"])
        self.assertEqual(
            [
                {
                    "url": "https://github.com/1andrevich/Re-filter-lists/releases/latest/download/geosite.dat",
                    "file": "geosite_refilter.dat",
                },
                {
                    "url": "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat",
                    "file": "geosite_v2fly.dat",
                },
                {
                    "url": "https://github.com/jameszeroX/zkeen-domains/releases/latest/download/zkeen.dat",
                    "file": "geosite_zkeen.dat",
                },
                {
                    "url": "https://github.com/jameszeroX/zkeen-ip/releases/latest/download/zkeenip.dat",
                    "file": "geoip_zkeenip.dat",
                },
                {
                    "url": "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat",
                    "file": "geoip_v2fly.dat",
                },
                {
                    "url": "https://github.com/1andrevich/Re-filter-lists/releases/latest/download/geoip.dat",
                    "file": "geoip_refilter.dat",
                },
                {
                    "url": "https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.dat",
                    "file": "adlist.dat",
                },
            ],
            result[0]["geodata"]["assets"],
        )
        self.assertNotIn("old", result[1]["geodata"])

    def test_adds_geodata_to_single_config_object(self):
        result = self.server.apply_geodata({"outbounds": []}, self.server.build_geodata({}))

        self.assertEqual("proxy", result["geodata"]["outbound"])

    def test_assets_override_must_be_valid_array(self):
        with self.assertRaises(ValueError):
            self.server.build_geodata({"SUB_JSON_GEODATA_ASSETS_JSON": '{"url":"bad"}'})

        result = self.server.build_geodata(
            {
                "SUB_JSON_GEODATA_ASSETS_JSON": json.dumps(
                    [{"url": "https://example.test/geo.dat", "file": "geo.dat"}]
                )
            }
        )

        self.assertEqual([{"url": "https://example.test/geo.dat", "file": "geo.dat"}], result["assets"])

    def test_http_get_transforms_json_and_preserves_subscription_headers(self):
        upstream, upstream_thread = self.start_upstream(
            body=json.dumps([{"remarks": "managed"}]).encode(),
            headers={
                "Content-Type": "application/json",
                "subscription-userinfo": "upload=1; download=2",
                "profile-title": "base64:dGVzdA==",
            },
            expected_host="screenhub.linkpc.net",
        )
        processor, processor_thread = self.start_processor(upstream, extra_env={"WEBDOMAIN": "screenhub.linkpc.net"})
        self.add_server_cleanup(upstream, upstream_thread)
        self.add_server_cleanup(processor, processor_thread)

        request = Request(
            f"http://127.0.0.1:{processor.server_port}/json/sub-id",
            headers={"Host": "screenhub.linkpc.net"},
        )
        response = urlopen(request, timeout=5)
        body = json.loads(response.read())

        self.assertEqual("upload=1; download=2", response.headers["subscription-userinfo"])
        self.assertEqual("base64:dGVzdA==", response.headers["profile-title"])
        self.assertEqual("proxy", body[0]["geodata"]["outbound"])

    def test_http_head_proxies_without_body(self):
        upstream, upstream_thread = self.start_upstream(body=b'[{"remarks":"managed"}]')
        processor, processor_thread = self.start_processor(upstream)
        self.add_server_cleanup(upstream, upstream_thread)
        self.add_server_cleanup(processor, processor_thread)

        request = Request(f"http://127.0.0.1:{processor.server_port}/json/sub-id", method="HEAD")
        response = urlopen(request, timeout=5)

        self.assertEqual(200, response.status)
        self.assertEqual(b"", response.read())
        self.assertIn("HEAD", UpstreamHandler.seen_methods)

    def test_upstream_error_is_passed_through(self):
        upstream, upstream_thread = self.start_upstream(status=500, body=b"upstream error")
        processor, processor_thread = self.start_processor(upstream)
        self.add_server_cleanup(upstream, upstream_thread)
        self.add_server_cleanup(processor, processor_thread)

        with self.assertRaises(HTTPError) as raised:
            urlopen(f"http://127.0.0.1:{processor.server_port}/json/sub-id", timeout=5)

        self.assertEqual(500, raised.exception.code)
        self.assertEqual(b"upstream error", raised.exception.read())

    def test_invalid_json_fail_open_and_fail_closed(self):
        upstream, upstream_thread = self.start_upstream(body=b"not-json")
        processor, processor_thread = self.start_processor(upstream, fail_open=True)
        self.add_server_cleanup(upstream, upstream_thread)
        self.add_server_cleanup(processor, processor_thread)

        response = urlopen(f"http://127.0.0.1:{processor.server_port}/json/sub-id", timeout=5)
        self.assertEqual(b"not-json", response.read())
        self.assertIn("invalid-json", response.headers["x-sub-json-processor-warning"])

        upstream_closed, upstream_closed_thread = self.start_upstream(body=b"not-json")
        processor_closed, processor_closed_thread = self.start_processor(upstream_closed, fail_open=False)
        self.add_server_cleanup(upstream_closed, upstream_closed_thread)
        self.add_server_cleanup(processor_closed, processor_closed_thread)

        with self.assertRaises(HTTPError) as raised:
            urlopen(f"http://127.0.0.1:{processor_closed.server_port}/json/sub-id", timeout=5)
        self.assertEqual(502, raised.exception.code)

    def start_upstream(self, status=200, body=b"[]", headers=None, expected_host=None):
        UpstreamHandler.status = status
        UpstreamHandler.body = body
        UpstreamHandler.headers_to_send = headers or {}
        UpstreamHandler.seen_methods = []
        UpstreamHandler.expected_host = expected_host
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), UpstreamHandler)
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        return httpd, thread

    def add_server_cleanup(self, httpd, thread):
        def cleanup():
            httpd.shutdown()
            thread.join(2)
            httpd.server_close()

        self.addCleanup(cleanup)

    def start_processor(self, upstream, fail_open=True, extra_env=None):
        env = {
            "SUB_JSON_UPSTREAM_BASE": f"http://127.0.0.1:{upstream.server_port}",
            "SUB_JSON_PROCESSOR_FAIL_OPEN": "true" if fail_open else "false",
        }
        if extra_env:
            env.update(extra_env)
        handler = self.server.make_handler(env)
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        return httpd, thread


if __name__ == "__main__":
    unittest.main()
