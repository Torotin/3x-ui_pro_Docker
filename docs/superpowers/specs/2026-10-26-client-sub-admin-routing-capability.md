# Clash/JSON merge capability (live 3x-ui)

Date: 2026-10-26
Image/panel: `torotin/3x-ui:latest` (`sha256:01845634757f5fd6740facc9a8d7b3b7ee34781f876073abbafa0af803c2d198`, created 2026-10-24T22:59:45Z); live AllSetting API on `vps-vdsok-streambase-torotin`

Discovered live subscription settings:

- `WEBDOMAIN=streambase.linkpc.net`
- `subPort=34053`
- `subClashPath=/A1yh2uqDoMqw/`
- `subJsonPath=/Kr3AbtowEqom/`

| Capability | Result | Evidence |
|---|---|---|
| rules DOMAIN merge | no | Probe wrote `subClashEnableRouting=true` and `subClashRules` containing `DOMAIN,spike-rule.streambase.linkpc.net,ADMIN`; native Clash output `/tmp/clash-spike.yaml` did not contain `spike-rule.streambase.linkpc.net`. |
| proxy-groups override | no | Probe wrote `proxy-groups` with hidden `ADMIN`; native Clash output did not contain `name: ADMIN`. |
| preserves node names in proxies | yes | Native Clash output kept the generated `PROXY` group with live nodes `vless-tcp-reality-streambase.linkpc.net-autogen`, `vless-xhttp`, `vless-grpc-tls`, `hysteria2`, plus `DIRECT`. |
| hidden ADMIN group | no | Native Clash output did not contain `hidden: true` or `name: ADMIN`. |
| hosts merge | no | Probe wrote `hosts.spike-host.streambase.linkpc.net=203.0.113.10`; native Clash output did not contain `spike-host.streambase.linkpc.net`. |
| dns.fake-ip-filter merge | no | Probe wrote `dns.fake-ip-filter` with `spike-filter.streambase.linkpc.net`; native Clash output did not contain that value. |
| subJsonRoutingRules effective | no | Probe wrote `subJsonRoutingRules` with `spike-json.streambase.linkpc.net`; native JSON output `/tmp/json-spike.json` did not contain that domain. |

Recommended builder mode: `rules-proxy`.

Reasoning: `full` is not viable because `hosts` and hidden `ADMIN` do not merge. `rules-admin` is not viable because the `ADMIN` group does not merge. Among the allowed builder modes, `rules-proxy` is the least risky fallback because the native `PROXY` group and node list are preserved; however, this live spike did not observe `subClashRules` rule merging either, so later tasks should keep the builder minimal and recheck the exact field/payload if they depend on custom DOMAIN rules appearing in the native subscription.

Restore confirmation: after the spike, the panel was restored from the AllSetting backup. `subClashEnableRouting=false`, `subClashRules=`, `subJsonRoutingRules=`, `subEnableRouting=false`, and `subRoutingRules=` were observed after restore; Happ-only `subEnableRouting` / `subRoutingRules` were not changed.
