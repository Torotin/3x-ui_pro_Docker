import ast
import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.http_client import HttpSession  # noqa: E402


class _CookieHandler(BaseHTTPRequestHandler):
    visits = 0

    def do_GET(self) -> None:
        type(self).visits += 1
        cookie = self.headers.get("Cookie", "")
        if "session=abc" not in cookie:
            self.send_response(200)
            self.send_header("Set-Cookie", "session=abc; Path=/")
            self.end_headers()
            self.wfile.write(b'{"success":true,"pass":"first"}')
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"success":true,"pass":"cookie"}')

    def log_message(self, format: str, *args: object) -> None:
        return


class _FlakyHandler(BaseHTTPRequestHandler):
    fail_remaining: int = 0

    def do_GET(self) -> None:
        if type(self).fail_remaining > 0:
            type(self).fail_remaining -= 1
            self.connection.close()
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"success":true}')

    def log_message(self, format: str, *args: object) -> None:
        return


class TestHttpClientStdlibOnly(unittest.TestCase):
    def test_http_client_uses_stdlib_only(self) -> None:
        module_path = PYTHON_ROOT / "xui_runtime" / "http_client.py"
        tree = ast.parse(module_path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    root = alias.name.split(".", 1)[0]
                    self.assertIn(
                        root,
                        {
                            "__future__",
                            "json",
                            "os",
                            "ssl",
                            "tempfile",
                            "time",
                            "urllib",
                            "dataclasses",
                            "http",
                            "pathlib",
                            "xui_runtime",
                        },
                        msg=f"unexpected import {alias.name}",
                    )
            elif isinstance(node, ast.ImportFrom):
                if node.module and node.module.partition(".")[0] not in (
                    "__future__",
                    "dataclasses",
                    "http",
                    "pathlib",
                    "xui_runtime",
                ):
                    self.assertIn(
                        node.module.partition(".")[0],
                        {
                            "json",
                            "os",
                            "ssl",
                            "tempfile",
                            "time",
                            "urllib",
                        },
                        msg=f"unexpected from-import {node.module}",
                    )


class TestHttpSessionIntegration(unittest.TestCase):
    def test_get_stores_body_under_tmp_root_and_roundtrips_cookie(self) -> None:
        _CookieHandler.visits = 0
        server = ThreadingHTTPServer(("127.0.0.1", 0), _CookieHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        host, port = server.server_address
        url = f"http://127.0.0.1:{port}/"

        with tempfile.TemporaryDirectory() as tmp:
            session = HttpSession()
            session.init(tmp)
            first = session.request("GET", url)
            self.assertTrue(first.ok)
            self.assertEqual(first.code, "200")
            self.assertIsNotNone(first.body_path)
            assert first.body_path is not None
            self.assertTrue(str(first.body_path).startswith(tmp))
            self.assertEqual(json.loads(session.body())["pass"], "first")

            second = session.request("GET", url)
            self.assertTrue(second.ok)
            self.assertEqual(json.loads(session.body())["pass"], "cookie")
        server.shutdown()

    def test_retries_then_succeeds_with_backoff(self) -> None:
        _FlakyHandler.fail_remaining = 2
        server = ThreadingHTTPServer(("127.0.0.1", 0), _FlakyHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        host, port = server.server_address
        url = f"http://127.0.0.1:{port}/"

        sleeps: list[float] = []

        def fake_sleep(seconds: float) -> None:
            sleeps.append(seconds)

        with tempfile.TemporaryDirectory() as tmp:
            session = HttpSession(attempts=4, sleep_fn=fake_sleep)
            session.init(tmp)
            result = session.request("GET", url)
            self.assertTrue(result.ok)
            self.assertEqual(result.code, "200")
            self.assertEqual(sleeps, [1.0, 2.0])
        server.shutdown()

    def test_success_json(self) -> None:
        class JsonHandler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                if self.path == "/ok":
                    body = b'{"success":true}'
                else:
                    body = b'{"success":false}'
                self.send_response(200)
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format: str, *args: object) -> None:
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), JsonHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        host, port = server.server_address

        with tempfile.TemporaryDirectory() as tmp:
            session = HttpSession()
            session.init(tmp)
            session.request("GET", f"http://127.0.0.1:{port}/ok")
            self.assertTrue(session.success_json())
            session.request("GET", f"http://127.0.0.1:{port}/nope")
            self.assertFalse(session.success_json())
        server.shutdown()

    def test_http_error_still_counts_as_transport_ok(self) -> None:
        class NotFoundHandler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b'{"success":false}')

            def log_message(self, format: str, *args: object) -> None:
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), NotFoundHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        host, port = server.server_address

        with tempfile.TemporaryDirectory() as tmp:
            session = HttpSession(attempts=1)
            session.init(tmp)
            result = session.request("GET", f"http://127.0.0.1:{port}/")
            self.assertTrue(result.ok)
            self.assertEqual(result.code, "404")
            self.assertFalse(session.success_json())
        server.shutdown()


class TestHttpSessionFailure(unittest.TestCase):
    def test_exhausted_retries_return_not_ok(self) -> None:
        sleeps: list[float] = []

        def fake_sleep(seconds: float) -> None:
            sleeps.append(seconds)

        with tempfile.TemporaryDirectory() as tmp:
            session = HttpSession(attempts=3, log_failures=False, sleep_fn=fake_sleep)
            session.init(tmp)
            with patch("xui_runtime.http_client.log.log") as mock_log:
                result = session.request("GET", "http://127.0.0.1:1/")
            self.assertFalse(result.ok)
            self.assertEqual(result.code, "000")
            self.assertIsNone(result.body_path)
            self.assertEqual(sleeps, [1.0, 2.0])
            self.assertTrue(mock_log.called)


if __name__ == "__main__":
    unittest.main()