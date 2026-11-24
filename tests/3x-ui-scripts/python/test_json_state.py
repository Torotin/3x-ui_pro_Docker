import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.json_state import (  # noqa: E402
    apply_managed_xray_state,
    remove_managed_xray_artifacts,
    replace_dns_servers,
    upsert_outbound_by_tag,
)


class TestJsonState(unittest.TestCase):
    def test_upsert_outbound_by_tag_is_idempotent(self) -> None:
        base_path = ROOT / "tests" / "3x-ui-scripts" / "fixtures" / "xray-base.json"
        base = json.loads(base_path.read_text(encoding="utf-8"))
        ob = {
            "tag": "usque",
            "protocol": "socks",
            "settings": {"servers": [{"address": "usque", "port": 1080}]},
        }
        first = upsert_outbound_by_tag(base, ob)
        second = upsert_outbound_by_tag(first, ob)
        tags = [item["tag"] for item in second["xraySetting"]["outbounds"] if item["tag"] == "usque"]
        protocol = next(
            item["protocol"]
            for item in second["xraySetting"]["outbounds"]
            if item["tag"] == "usque"
        )
        self.assertEqual(1, len(tags))
        self.assertEqual("socks", protocol)

    def test_dns_replace_preserves_unknown_fields(self) -> None:
        base_path = ROOT / "tests" / "3x-ui-scripts" / "fixtures" / "xray-base.json"
        base = json.loads(base_path.read_text(encoding="utf-8"))
        updated = replace_dns_servers(
            base,
            [{"address": "adguard", "port": 53, "skipFallback": False}],
        )
        host = updated["xraySetting"]["dns"]["hosts"]["example.local"]
        warp_host = updated["xraySetting"]["dns"]["hosts"]["engage.cloudflareclient.com"]
        server_count = len(updated["xraySetting"]["dns"]["servers"])
        self.assertEqual("127.0.0.1", host)
        self.assertEqual("162.159.192.1", warp_host)
        self.assertEqual(1, server_count)

    def test_dns_peer_direct_rules_precede_geoip_private_block(self) -> None:
        from xui_runtime.json_state import ensure_dns_peer_direct_rules  # noqa: E402

        base = {
            "xraySetting": {
                "routing": {
                    "rules": [
                        {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
                        {
                            "type": "field",
                            "ip": ["geoip:private"],
                            "outboundTag": "blocked",
                        },
                        {
                            "type": "field",
                            "network": "tcp,udp",
                            "outboundTag": "mihomo",
                        },
                    ]
                }
            }
        }
        updated = ensure_dns_peer_direct_rules(
            base,
            [{"address": "adguard", "port": 53, "skipFallback": False}],
            peer_ipv4=["172.19.0.10"],
        )
        rules = updated["xraySetting"]["routing"]["rules"]
        remarks = [r.get("remark") for r in rules]
        self.assertIn("managed-dns-peer-direct", remarks)
        private_idx = next(
            i
            for i, r in enumerate(rules)
            if r.get("outboundTag") == "blocked"
            and "geoip:private" in str(r.get("ip"))
        )
        peer_idxs = [
            i for i, r in enumerate(rules) if r.get("remark") == "managed-dns-peer-direct"
        ]
        self.assertTrue(peer_idxs)
        self.assertTrue(all(i < private_idx for i in peer_idxs))
        ip_rule = next(r for r in rules if r.get("ip") == ["172.19.0.10"])
        self.assertEqual("53", ip_rule["port"])
        self.assertEqual("direct", ip_rule["outboundTag"])

    def test_remove_managed_xray_artifacts_only_removes_our_tags(self) -> None:
        payload = {
            "xraySetting": {
                "outbounds": [
                    {"tag": "direct"},
                    {"tag": "warp-retired"},
                    {"tag": "tor-proxy"},
                    {"tag": "mihomo"},
                    {"tag": "warp-custom"},
                    {"tag": "tor-custom"},
                ],
                "routing": {
                    "rules": [
                        {"outboundTag": "tor-proxy"},
                        {"balancerTag": "warp-balancer"},
                        {"outboundTag": "mihomo", "network": "tcp,udp"},
                        {"outboundTag": "blocked"},
                        {"balancerTag": "custom-balancer"},
                    ],
                    "balancers": [
                        {"tag": "warp-balancer"},
                        {"tag": "custom"},
                        {"tag": "warp-custom-balancer"},
                        {"tag": "tor-custom-balancer"},
                    ],
                },
                "burstObservatory": {
                    "subjectSelector": ["warp-custom", "tor-custom", "custom-out", "usque"]
                },
            }
        }
        cleaned = remove_managed_xray_artifacts(payload)

        def tag_like(value: str, doc: dict) -> int:
            count = 0
            stack = [doc]
            while stack:
                cur = stack.pop()
                if isinstance(cur, dict):
                    for key in ("tag", "outboundTag", "balancerTag"):
                        if cur.get(key) == value:
                            count += 1
                    stack.extend(cur.values())
                elif isinstance(cur, list):
                    stack.extend(cur)
            return count

        managed = sum(
            tag_like(t, cleaned)
            for t in ("warp-retired", "tor-proxy", "warp-balancer", "mihomo")
        )
        direct_count = tag_like("direct", cleaned)
        custom_count = sum(
            tag_like(t, cleaned)
            for t in (
                "warp-custom",
                "tor-custom",
                "custom-balancer",
                "custom",
                "warp-custom-balancer",
                "tor-custom-balancer",
            )
        )
        subjects = ",".join(
            sorted(cleaned["xraySetting"]["burstObservatory"]["subjectSelector"])
        )
        self.assertEqual(0, managed)
        self.assertEqual(1, direct_count)
        self.assertEqual(6, custom_count)
        self.assertEqual("custom-out,tor-custom,warp-custom", subjects)

    def test_managed_xray_restores_warp_tor_dns_without_missing_balancer_refs(self) -> None:
        base = {
            "xraySetting": {
                "outbounds": [
                    {"tag": "direct", "protocol": "freedom", "settings": {}},
                    {"tag": "blocked", "protocol": "blackhole", "settings": {}},
                ],
                "routing": {"rules": []},
                "dns": {"hosts": {"example.local": "127.0.0.1"}},
            }
        }
        dns = [{"address": "adguard", "port": 53, "skipFallback": False}]
        updated = apply_managed_xray_state(
            base,
            dns,
            True,
            True,
            True,
            [{"tag": "usque", "host": "usque", "port": 1080}],
            "screenhub.linkpc.net",
            [{"tag": "tor-proxy", "host": "tor-proxy", "port": 1080}],
        )
        xs = updated["xraySetting"]
        warp_balancer = next(b for b in xs["routing"]["balancers"] if b["tag"] == "warp-balancer")
        usque_refs = [s for s in warp_balancer["selector"] if s == "usque"]
        tor_port = next(
            ob["settings"]["servers"][0]["port"]
            for ob in xs["outbounds"]
            if ob["tag"] == "tor-proxy"
        )
        dns_first = xs["dns"]["servers"][0]["address"]
        warp_bootstrap = xs["dns"]["hosts"]["engage.cloudflareclient.com"]
        burst_destination = xs["burstObservatory"]["pingConfig"]["destination"]
        self.assertEqual(1, len(usque_refs))
        self.assertEqual(1080, tor_port)
        self.assertEqual("adguard", dns_first)
        self.assertEqual("162.159.192.1", warp_bootstrap)
        self.assertEqual(
            "https://connectivitycheck.gstatic.com/generate_204",
            burst_destination,
        )
        self.assertTrue(
            any(
                r.get("remark") == "managed-dns-peer-direct"
                and r.get("domain") == ["full:adguard"]
                for r in xs["routing"]["rules"]
            )
        )


if __name__ == "__main__":
    unittest.main()