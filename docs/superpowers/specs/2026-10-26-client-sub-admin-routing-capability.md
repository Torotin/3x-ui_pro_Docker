# Clash/JSON merge capability (live 3x-ui)

Date: 2026-10-26
Image/panel: `torotin/3x-ui:latest` (`sha256:01845634757f5fd6740facc9a8d7b3b7ee34781f876073abbafa0af803c2d198`, created 2026-10-24T22:59:45Z); live AllSetting API on `vps-vdsok-streambase-torotin`

Correction note: the original spike was a false negative because `container_apply_panel_settings` used stdin both for `bash -s` and the JSON body. The corrected spike passes the AllSetting body through a base64 environment variable, confirms persistence (`stored_enable=true`, `stored_rules_has_spike=true`), restarts `3x-ui`, then fetches native subscriptions.

Discovered live subscription settings:

- `WEBDOMAIN=streambase.linkpc.net`
- `subPort=34053`
- `subClashPath=/A1yh2uqDoMqw/`
- `subJsonPath=/Kr3AbtowEqom/`

| Capability | Result | Evidence |
|---|---|---|
| rules DOMAIN merge | yes | Corrected probe wrote `subClashEnableRouting=true` and `subClashRules` containing `DOMAIN,spike-rule.streambase.linkpc.net,ADMIN`; `/tmp/clash-spike-fixed.yaml` contained that rule. |
| proxy-groups override | yes | Corrected probe wrote custom `proxy-groups`; native Clash output contained the custom `ADMIN` group. This is a wholesale override, not an additive merge. |
| preserves node names in proxies | no | The probe's custom `PROXY` group replaced the generated live node list with `DIRECT` only. Do not ship a custom `PROXY` or `ADMIN` group unless node names are preserved by a separate strategy. |
| hidden ADMIN group | yes | Native Clash output contained `name: ADMIN` with `hidden: true`, but this is not safe for production with current merge semantics because adding the group also replaced `PROXY` nodes. |
| hosts merge | yes | Corrected probe wrote `hosts.spike-host.streambase.linkpc.net=203.0.113.10`; native Clash output contained `spike-host.streambase.linkpc.net`. |
| dns.fake-ip-filter merge | yes | Corrected probe wrote `dns.fake-ip-filter` with `spike-filter.streambase.linkpc.net`; native Clash output contained that value. |
| subJsonRoutingRules effective | no | Corrected probe wrote `subJsonRoutingRules` with `spike-json.streambase.linkpc.net`; native JSON output `/tmp/json-spike-fixed.json` did not contain that domain. |

Recommended builder mode: `rules-proxy` plus `hosts` and `dns.fake-ip-filter`.

Reasoning: `full` and `rules-admin` are not safe because custom `proxy-groups` replace the generated `PROXY` node list. Hidden `ADMIN` works syntactically, but not safely with the current wholesale replacement behavior. Later tasks should omit custom `proxy-groups`, emit admin `DOMAIN,...,PROXY` rules, and still include `hosts` plus `dns.fake-ip-filter` because those top-level keys do merge.

Restore confirmation: after the spike, the panel was restored from the AllSetting backup. `subClashEnableRouting=false`, `subClashRules=`, `subJsonRoutingRules=`, `subEnableRouting=false`, and `subRoutingRules=` were observed after restore; Happ-only `subEnableRouting` / `subRoutingRules` were not changed.
