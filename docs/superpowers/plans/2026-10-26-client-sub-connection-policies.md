# Client Subscription Connection Policies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add hybrid AUTO + manual PROXY connection policies to Clash and JSON subscriptions, with residual default DIRECT and unchanged admin→PROXY, via native panel only.

**Architecture:** Extend `sub_admin_routing.bash` so Clash emits `AUTO` (url-test) + full `PROXY` (select) when node names are known, ending with `MATCH,DIRECT`. JSON switches admin/default routing to `subJsonRules` + `subJsonDns`, clears `subJsonRoutingRules`, and ensures a Sub Balancer (`leastPing`) plus `subJsonObservatory`. Verify on VPS apply and in WSL with mihomo + xray-core.

**Tech Stack:** bash, jq, 3x-ui AllSetting + Sub Balancers API, Clash/Mihomo, xray-core, WSL, SSH `vps-vdsok-streambase-torotin`.

**Spec:** `docs/superpowers/specs/2026-10-26-client-sub-connection-policies-design.md`

## Global Constraints

- Branch: `feat/xray-admin-access`.
- **Native only:** no subscription post-processor / Traefik body rewriter.
- Do **not** set Happ headers `subEnableRouting` / `subRoutingRules` for this feature.
- Admin FQDNs (exact): `arcane`, `homepage`, `adguard`, `3x-ui`, `traefik`, `lampac-admin` → **PROXY**.
- AUTO membership: all managed inbounds present in the sub (Vision / XHTTP / gRPC / Hysteria2 as enabled).
- Residual default: **DIRECT** (`MATCH,DIRECT` / JSON `network → direct`).
- Clash custom `proxy-groups` wholesale-replace: emit full PROXY node list or omit groups.
- Clear managed `subJsonRoutingRules` (empty) so baked profile cannot force catch-all → proxy.
- Do not rename `URI_*` paths; do not change server admin-plane; do not flip `subEnable` here.
- `docs/` gitignored — `git add -f` for plans/specs.
- Live apply on `vps-vdsok-streambase-torotin`; client smokes in **WSL** (mihomo + xray-core).

## File map

| File | Role |
|---|---|
| `docker-proxy/3x-ui/scripts/lib/sub_admin_routing.bash` | Clash AUTO/PROXY/MATCH,DIRECT; JSON rules builder; node-name helpers |
| `docker-proxy/3x-ui/scripts/lib/sub_balancer.bash` (create) | Ensure AUTO Sub Balancer + observatory setting |
| `docker-proxy/3x-ui/scripts/lib/3xui_api.bash` | Sub Balancer API helpers if missing |
| `docker-proxy/3x-ui/scripts/lib/desired_state.bash` | Keys: `subJsonRules`, `subJsonObservatory`; manage empty `subJsonRoutingRules` |
| `docker-proxy/3x-ui/scripts/01_AfterStart/3x-ui-upd.sh` | Wire builders + balancer ensure |
| `docker-proxy/3x-ui/3x-ui.env` | Notes only (no multiline); observatory defaults if needed |
| `tests/3x-ui-scripts/test_libs.bash` | Unit tests |
| `tests/wsl-clients/` (create) | WSL mihomo + xray smoke scripts |
| `.project_context/02_state/last_changes.md` | Ops note after live apply |

## Resolved design choices

1. Clash probe URL: `https://www.gstatic.com/generate_204`, interval `300`.
2. PROXY select order: `AUTO`, then node names, then `DIRECT`.
3. JSON: `subJsonRules` for admin+DIRECT; stop exporting Happ-style `build_admin_sub_json_routing_rules` into `subJsonRoutingRules` (clear field instead).
4. Sub Balancer remark: `AUTO`, strategy `leastPing`.

---

### Task 1: Clash builder — MATCH,DIRECT + AUTO/PROXY groups (TDD)

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/lib/sub_admin_routing.bash`
- Modify: `tests/3x-ui-scripts/test_libs.bash`

**Interfaces:**
- Produces:
  - `build_admin_sub_clash_rules <webdomain> <public_ipv4> <mode> [node_names_file]`
  - When `node_names_file` non-empty: emit AUTO url-test + PROXY select; else omit `proxy-groups`
  - Always: admin DOMAIN→PROXY, **`MATCH,DIRECT`** (not PROXY)
- Consumes: existing `admin_sub_hostnames`, hosts/dns when IPv4 set

- [ ] **Step 1: Write failing tests**

```bash
test_build_admin_sub_clash_rules_match_direct() {
	. "$SCRIPTS_DIR/lib/sub_admin_routing.bash"
	local yaml
	yaml=$(build_admin_sub_clash_rules "example.test" "198.51.100.10" "rules-proxy")
	grep -Fq 'MATCH,DIRECT' <<<"$yaml" || fail "residual must be MATCH,DIRECT"
	grep -Fq 'MATCH,PROXY' <<<"$yaml" && fail "MATCH,PROXY must not remain"
	grep -Fq 'DOMAIN,arcane.example.test,PROXY' <<<"$yaml" || fail "admin still PROXY"
}

test_build_admin_sub_clash_rules_with_nodes_emits_auto() {
	. "$SCRIPTS_DIR/lib/sub_admin_routing.bash"
	local nodes yaml
	nodes=$(mktemp)
	printf '%s\n' 'node-a' 'node-b' >"$nodes"
	yaml=$(build_admin_sub_clash_rules "example.test" "198.51.100.10" "rules-proxy" "$nodes")
	rm -f "$nodes"
	grep -Fq 'name: AUTO' <<<"$yaml" || fail "missing AUTO group"
	grep -Fq 'type: url-test' <<<"$yaml" || fail "AUTO must be url-test"
	grep -Fq 'https://www.gstatic.com/generate_204' <<<"$yaml" || fail "missing probe URL"
	grep -Fq 'name: PROXY' <<<"$yaml" || fail "missing PROXY group"
	grep -Fq 'AUTO' <<<"$yaml" || fail "PROXY must list AUTO"
	grep -Fq 'node-a' <<<"$yaml" || fail "PROXY must list discovered nodes"
}

test_build_admin_sub_clash_rules_without_nodes_omits_groups() {
	. "$SCRIPTS_DIR/lib/sub_admin_routing.bash"
	local yaml
	yaml=$(build_admin_sub_clash_rules "example.test" "" "rules-proxy" "")
	grep -Fq 'proxy-groups:' <<<"$yaml" && fail "no nodes => no custom proxy-groups"
	grep -Fq 'MATCH,DIRECT' <<<"$yaml" || fail "still MATCH,DIRECT"
}
```

- [ ] **Step 2: Run tests — expect FAIL**

```bash
bash tests/3x-ui-scripts/test_libs.bash
```

Expected: FAIL on MATCH,DIRECT / AUTO assertions (current builder ends `MATCH,PROXY`, no AUTO).

- [ ] **Step 3: Implement builder changes**

Update `build_admin_sub_clash_rules` to accept optional 4th arg node list file; emit groups when file has ≥1 non-empty line; change final rule to `MATCH,DIRECT`.

- [ ] **Step 4: Run tests — expect PASS**

```bash
bash tests/3x-ui-scripts/test_libs.bash
```

- [ ] **Step 5: Commit**

```bash
git add docker-proxy/3x-ui/scripts/lib/sub_admin_routing.bash tests/3x-ui-scripts/test_libs.bash
git commit -m "$(cat <<'EOF'
feat(3x-ui): Clash AUTO url-test group and MATCH,DIRECT default

EOF
)"
```

---

### Task 2: Discover Clash node names at runtime

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/lib/sub_admin_routing.bash`
- Modify: `docker-proxy/3x-ui/scripts/01_AfterStart/3x-ui-upd.sh` (call site in Task 4; stub helper here)
- Modify: `tests/3x-ui-scripts/test_libs.bash`

**Interfaces:**
- Produces: `discover_clash_proxy_node_names` → prints one proxy name per line (no DIRECT)
- Strategy (prefer first that works):
  1. From panel inbound remarks for managed tags/kinds already known to AfterStart (`vision`/`xhttp`/`grpc`/`hysteria2` remark strings), **or**
  2. Parse a temporary Clash body if available after panel is up
- On failure: print nothing (empty)

- [ ] **Step 1: Failing unit test with fixture remarks**

```bash
test_discover_clash_proxy_node_names_from_remarks() {
	. "$SCRIPTS_DIR/lib/sub_admin_routing.bash"
	local out
	out=$(printf '%s\n' '🇩🇪 vless-tcp-reality-example-autogen' 'vless-xhttp' | discover_clash_proxy_node_names_from_lines)
	grep -Fq 'vless-xhttp' <<<"$out" || fail "must keep remark lines as node names"
	grep -Fq 'DIRECT' <<<"$out" && fail "must not invent DIRECT"
}
```

- [ ] **Step 2: Implement `discover_clash_proxy_node_names_from_lines` + `discover_clash_proxy_node_names` wrapping inbound remarks from env/API list helper**

Keep discovery pure where possible; AfterStart passes remark list.

- [ ] **Step 3: Tests PASS + commit**

```bash
git commit -m "$(cat <<'EOF'
feat(3x-ui): discover Clash proxy node names for AUTO/PROXY groups

EOF
)"
```

---

### Task 3: JSON — subJsonRules + clear subJsonRoutingRules (TDD)

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/lib/sub_admin_routing.bash`
- Modify: `docker-proxy/3x-ui/scripts/lib/desired_state.bash`
- Modify: `tests/3x-ui-scripts/test_libs.bash`

**Interfaces:**
- Produces: `build_admin_sub_json_rules <webdomain>` → JSON array string for `subJsonRules`
- Deprecate use of `build_admin_sub_json_routing_rules` for desired apply (may keep function unused or make it return empty with comment)
- `subJsonDns` builder unchanged
- Desired: export empty `subJsonRoutingRules` intentionally (panel_settings_json skips empty — **problem**)

**Critical:** `panel_settings_json` skips empty env values, so clearing `subJsonRoutingRules` needs an explicit sentinel or overlay change.

- [ ] **Step 1: Decide clear mechanism (implement one)**

Preferred: in AfterStart after builders, if clearing is required, set a dedicated flag and extend `panel_settings_json` / `ensure_panel_settings` to force-empty listed keys:

```bash
# e.g. PANEL_FORCE_EMPTY_KEYS=subJsonRoutingRules
```

Or merge in `ensure_panel_settings` after body build:

```bash
body=$(jq -c '.subJsonRoutingRules = ""' <<<"$body")
```

when `CLEAR_SUB_JSON_ROUTING_RULES=true`.

Document the chosen mechanism in the commit message.

- [ ] **Step 2: Failing tests for JSON rules builder**

```bash
test_build_admin_sub_json_rules_admin_then_direct() {
	. "$SCRIPTS_DIR/lib/sub_admin_routing.bash"
	local out
	out=$(build_admin_sub_json_rules "example.test")
	assert_eq field "$(jq -r '.[0].type' <<<"$out")" "rule type field"
	assert_eq proxy "$(jq -r '.[0].outboundTag' <<<"$out")" "admin to proxy"
	assert_eq full:arcane.example.test "$(jq -r '.[0].domain[0]' <<<"$out")" "full: domain"
	assert_eq direct "$(jq -r '.[-1].outboundTag' <<<"$out")" "catch-all direct"
	assert_eq 'tcp,udp' "$(jq -r '.[-1].network' <<<"$out")" "catch-all network"
}
```

- [ ] **Step 3: Implement `build_admin_sub_json_rules`; stop exporting non-empty `subJsonRoutingRules`**

- [ ] **Step 4: Tests PASS + commit**

```bash
git commit -m "$(cat <<'EOF'
feat(3x-ui): JSON subJsonRules admin→proxy with DIRECT catch-all

EOF
)"
```

---

### Task 4: Sub Balancer AUTO (leastPing) + observatory

**Files:**
- Create: `docker-proxy/3x-ui/scripts/lib/sub_balancer.bash`
- Modify: `docker-proxy/3x-ui/scripts/lib/3xui_api.bash` (API wrappers)
- Modify: `docker-proxy/3x-ui/scripts/lib/desired_state.bash` (`subJsonObservatory` key)
- Modify: `tests/3x-ui-scripts/test_libs.bash`

**Interfaces:**
- Produces:
  - `build_admin_sub_json_observatory` → JSON string for `subJsonObservatory`
  - `ensure_auto_sub_balancer` — idempotent create/update remark=`AUTO`, strategy=`leastPing`, inboundIds=managed ids
- Consumes: panel session (`xui_*`), list of managed inbound IDs from AfterStart

- [ ] **Step 1: Spike live API paths on VPS (document in report)**

```bash
# Discover from panel OpenAPI or UI network: typically
# GET/POST /panel/api/subbalancer/* or similar — confirm on live image
```

Add thin wrappers matching discovered paths.

- [ ] **Step 2: Unit-test observatory JSON shape**

```bash
test_build_admin_sub_json_observatory() {
	. "$SCRIPTS_DIR/lib/sub_admin_routing.bash"  # or sub_balancer.bash
	local out
	out=$(build_admin_sub_json_observatory)
	jq -e '.destination and .interval' <<<"$out" >/dev/null || fail "observatory fields"
}
```

Default probe: `https://www.gstatic.com/generate_204`, interval consistent with Clash (`300s` / panel-accepted form).

- [ ] **Step 3: Implement ensure helper (plan mode logs; apply mode upserts)**

If API missing/fails: WARN and return 0 (do not fail whole AfterStart).

- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(3x-ui): ensure JSON Sub Balancer AUTO with leastPing observatory

EOF
)"
```

---

### Task 5: Wire AfterStart end-to-end

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/01_AfterStart/3x-ui-upd.sh`
- Modify: `tests/3x-ui-scripts/test_libs.bash` (entrypoint greps)

**Interfaces:**
- Before `ensure_panel_settings`:
  1. Discover node names → temp file
  2. `subClashRules=$(build_admin_sub_clash_rules … "$nodes_file")`
  3. `subJsonRules=$(build_admin_sub_json_rules …)`
  4. `subJsonDns=$(build_admin_sub_json_dns …)`
  5. Clear `subJsonRoutingRules` via Task 3 mechanism
  6. `subJsonObservatory=$(build_admin_sub_json_observatory)`
  7. After panel settings (needs inbound IDs): `ensure_auto_sub_balancer`

- [ ] **Step 1: Update entrypoint + failing grep tests for new exports**

- [ ] **Step 2: Implement wiring; MODE=check must still pass without WEBDOMAIN**

- [ ] **Step 3: Full `test_libs.bash` PASS + commit**

```bash
git commit -m "$(cat <<'EOF'
feat(3x-ui): wire connection policies into AfterStart panel apply

EOF
)"
```

---

### Task 6: Live apply on VPS + assert subscription bodies

**Files:** sync scripts to `/opt/docker-proxy/…` (no product path changes required)

- [ ] **Step 1: Sync + `docker restart 3x-ui`; wait AfterStart success**

- [ ] **Step 2: Assert Clash body**

```bash
# Inside 3x-ui with Host header
grep -E 'name: AUTO|type: url-test|MATCH,DIRECT|DOMAIN,arcane' /tmp/clash-live.yaml
# Expect: AUTO present (if discovery worked), MATCH,DIRECT, admin DOMAIN→PROXY
# Expect: no MATCH,PROXY as residual
```

- [ ] **Step 3: Assert JSON settings + body**

```bash
# Settings: subJsonRoutingRules empty; subJsonRules has outboundTag direct catch-all
# JSON fetch: routing.rules last outboundTag=direct; dns hosts present
# Extra balancer document present when Sub Balancer API worked
```

- [ ] **Step 4: Fix any live bugs; commit if needed; update `.project_context/02_state/last_changes.md`**

---

### Task 7: WSL client smokes (mihomo + xray-core)

**Files:**
- Create: `tests/wsl-clients/smoke_mihomo_sub.sh`
- Create: `tests/wsl-clients/smoke_xray_sub.sh`
- Create: `tests/wsl-clients/README.md` (how to run in WSL)

**Interfaces:**
- Inputs: `CLASH_SUB_URL` / `JSON_SUB_URL` (or file paths), `WEBDOMAIN`, optional Basic-auth not required for sub
- mihomo: load profile, check config parse; optional curl via mixed-port for DIRECT vs PROXY admin
- xray: write config from JSON sub first document (or balancer doc); `xray run -test`; short curl via local inbound

- [ ] **Step 1: Write mihomo smoke script**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
# Fetch Clash YAML, assert AUTO/PROXY/MATCH,DIRECT
# mihomo -t -f /tmp/profile.yaml
# Optional: start briefly, curl -x mixed-port https://arcane.$WEBDOMAIN:9443/ expect 401 when using PROXY
```

- [ ] **Step 2: Write xray smoke script**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
# Fetch JSON array/object; pick first config; xray run -test -c …
# Assert routing catch-all direct via jq on file
```

- [ ] **Step 3: Run both inside WSL against live streambase URLs; record output in task report**

```bash
wsl -e bash -lc 'cd /mnt/y/3x-ui_pro_Docker && bash tests/wsl-clients/smoke_mihomo_sub.sh'
wsl -e bash -lc 'cd /mnt/y/3x-ui_pro_Docker && bash tests/wsl-clients/smoke_xray_sub.sh'
```

- [ ] **Step 4: Commit harness + commit any fixes**

```bash
git add tests/wsl-clients
git commit -m "$(cat <<'EOF'
test(wsl): add mihomo and xray-core subscription policy smokes

EOF
)"
```

---

## Spec coverage self-check

| Spec requirement | Task |
|---|---|
| Clash AUTO url-test + PROXY select | 1–2, 5–7 |
| MATCH/catch-all DIRECT | 1, 3, 5–7 |
| Admin DOMAIN→PROXY | 1, 3, 6–7 |
| JSON subJsonRules + subJsonDns | 3, 5–6 |
| Clear subJsonRoutingRules | 3, 5–6 |
| Sub Balancer leastPing + observatory | 4–6 |
| Native only / no Happ headers | Global + Task 5 greps |
| WSL mihomo + xray | 7 |
| Node discovery failure fallback | 1–2, 6 |

## Placeholder scan

No TBD left: probe URL/interval fixed; clear-`subJsonRoutingRules` mechanism chosen in Task 3 Step 1; Sub Balancer API paths confirmed by live spike in Task 4 Step 1 before coding wrappers.
