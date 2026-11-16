import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
FIXTURES = ROOT / "tests" / "3x-ui-scripts" / "fixtures" / "builders"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.apply.sub_routing import (  # noqa: E402
    _mihomo_fill_marker_block,
    admin_sub_hostnames,
    build_admin_sub_clash_rules,
    build_admin_sub_json_dns,
    build_admin_sub_json_rules,
    build_admin_sub_json_routing_rules,
    build_mihomo_client_sub_clash_rules,
    clash_subscription_proxy_name_for_kind,
    discover_clash_proxy_node_names_from_clash_body,
    mihomo_client_routing_file,
    subscription_panel_env_overrides,
)
from xui_runtime.parity import assert_parity, build_python_builder  # noqa: E402


class TestAdminSubJsonBuilders(unittest.TestCase):
    def test_json_rules_admin_then_direct(self) -> None:
        rules = build_admin_sub_json_rules("example.test")
        self.assertIsInstance(rules, list)
        self.assertEqual(rules[0]["type"], "field")
        self.assertEqual(rules[0]["outboundTag"], "proxy")
        self.assertEqual(rules[0]["domain"][0], "full:arcane.example.test")
        self.assertEqual(rules[1]["port"], "9443")
        self.assertEqual(rules[1]["network"], "tcp")
        self.assertEqual(rules[1]["outboundTag"], "proxy")
        self.assertEqual(rules[-1]["outboundTag"], "direct")
        self.assertEqual(rules[-1]["network"], "tcp,udp")

    def test_json_rules_empty_without_domain(self) -> None:
        self.assertEqual(build_admin_sub_json_rules(""), "")
        self.assertEqual(build_admin_sub_json_routing_rules(), "")

    def test_json_dns_hosts(self) -> None:
        self.assertEqual(build_admin_sub_json_dns("example.test", ""), "")
        dns = build_admin_sub_json_dns("example.test", "198.51.100.10")
        self.assertEqual(dns["tag"], "dns_out")
        self.assertEqual(dns["queryStrategy"], "UseIP")
        self.assertEqual(dns["hosts"]["lampac-admin.example.test"], "198.51.100.10")
        self.assertEqual(len(dns["hosts"]), 8)

    def test_clash_rules_proxy_mode(self) -> None:
        yaml = build_admin_sub_clash_rules("example.test", "203.0.113.9", "rules-proxy")
        self.assertIn("hosts:", yaml)
        self.assertIn("example.test: 203.0.113.9", yaml)
        self.assertIn("fake-ip-filter:", yaml)
        self.assertIn("rules:", yaml)
        self.assertIn("DOMAIN,arcane.example.test,PROXY", yaml)
        self.assertIn("MATCH,DIRECT", yaml)

    def test_clash_rules_with_nodes_emits_auto(self) -> None:
        yaml = build_admin_sub_clash_rules(
            "example.test",
            "198.51.100.10",
            "rules-proxy",
            ["node-a", "node-b"],
        )
        self.assertIn("AUTO-example.test", yaml)
        self.assertIn("PROXY-example.test", yaml)
        self.assertIn("hidden: true", yaml)
        self.assertIn("DOMAIN,arcane.example.test,PROXY-example.test", yaml)

    def test_clash_rules_without_nodes_omits_groups(self) -> None:
        yaml = build_admin_sub_clash_rules("example.test", "", "rules-proxy")
        self.assertNotIn("proxy-groups:", yaml)
        self.assertIn("MATCH,DIRECT", yaml)

    def test_parity_registry_admin_sub_json_rules(self) -> None:
        env = {"WEBDOMAIN": "example.test"}
        python_obj = build_admin_sub_json_rules("example.test")
        built = build_python_builder(
            "admin_sub_json_rules",
            env,
            {"webdomain": "example.test"},
            bash_obj=python_obj,
        )
        assert_parity(python_obj, built, label="registry_admin_sub_json_rules")


class TestMihomoOverlay(unittest.TestCase):
    def test_marker_block_replacement(self) -> None:
        src = "# >>> ADMIN_RULES\nold\n# <<< ADMIN_RULES\n"
        out = _mihomo_fill_marker_block("ADMIN_RULES", "  - DOMAIN,x,PROXY", src)
        self.assertIn("  - DOMAIN,x,PROXY", out)
        self.assertNotIn("old", out)

    def test_mihomo_client_rules_injects_admin(self) -> None:
        routing = mihomo_client_routing_file({})
        self.assertIsNotNone(routing)
        yaml = build_mihomo_client_sub_clash_rules(
            routing,
            "example.test",
            "203.0.113.9",
        )
        self.assertIn("DOMAIN,example.test,PROXY", yaml)
        self.assertIn("DOMAIN,arcane.example.test,PROXY", yaml)
        self.assertIn("DOMAIN,example.test,real-ip", yaml)
        self.assertIn("'telemt.example.test': 203.0.113.9", yaml)

    def test_routing_file_env_override(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False, encoding="utf-8") as handle:
            handle.write("# >>> ADMIN_RULES\n# <<< ADMIN_RULES\n")
            override = handle.name
        try:
            resolved = mihomo_client_routing_file({"MIHOMO_CLIENT_ROUTING_FILE": override})
            self.assertEqual(resolved, Path(override))
        finally:
            Path(override).unlink(missing_ok=True)

    def test_mihomo_parity_registry(self) -> None:
        routing = mihomo_client_routing_file({})
        self.assertIsNotNone(routing)
        built = build_mihomo_client_sub_clash_rules(routing, "example.test", "203.0.113.9")
        parity = build_python_builder(
            "mihomo_client_sub_clash_rules",
            {"WEBDOMAIN": "example.test", "PUBLIC_IPV4": "203.0.113.9"},
            {
                "routing_file": str(routing),
                "webdomain": "example.test",
                "public_ipv4": "203.0.113.9",
            },
            bash_obj=built,
        )
        assert_parity(built, parity, label="registry_mihomo")


class TestClashDiscovery(unittest.TestCase):
    def test_discover_proxy_names_from_clash_body(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False, encoding="utf-8") as handle:
            handle.write(
                "proxies:\n  - name: node-a\n  - name: DIRECT\nother: x\n  - name: ignored\n"
            )
            body = handle.name
        try:
            names = discover_clash_proxy_node_names_from_clash_body(body)
            self.assertEqual(names, ["node-a"])
        finally:
            Path(body).unlink(missing_ok=True)

    def test_clash_subscription_proxy_name_for_kind(self) -> None:
        self.assertEqual(
            clash_subscription_proxy_name_for_kind(
                "vision",
                "vless-tcp-reality",
                "example.test",
                "example.test-autogen",
            ),
            "vless-tcp-reality-example.test-autogen",
        )
        self.assertEqual(
            clash_subscription_proxy_name_for_kind("xhttp", "vless-xhttp", "", ""),
            "vless-xhttp",
        )


class TestSubscriptionPanelExports(unittest.TestCase):
    def test_panel_overrides_include_observatory(self) -> None:
        env = {
            "WEBDOMAIN": "example.test",
            "PUBLIC_IPV4": "198.51.100.10",
        }
        overrides = subscription_panel_env_overrides(env, routing_file=None)
        self.assertIn("subJsonRules", overrides)
        self.assertIn("subJsonDns", overrides)
        self.assertIn("subJsonObservatory", overrides)
        self.assertEqual(overrides["subClashEnableRouting"], "true")
        self.assertIn("MATCH,DIRECT", overrides["subClashRules"])


class TestHostnames(unittest.TestCase):
    def test_admin_hostnames_count(self) -> None:
        self.assertEqual(len(admin_sub_hostnames()), 7)


if __name__ == "__main__":
    unittest.main()