# Client Subscription Admin-Plane Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make native 3x-ui Clash and JSON subscriptions carry admin-plane client routing (and DNS/hosts when the panel merge allows), then disable base64 after an audit—without any subscription post-processor.

**Architecture:** A small bash builder (`sub_admin_routing.bash`) renders Clash YAML / JSON routing snippets from `WEBDOMAIN` + `PUBLIC_IPV4`. AfterStart sets `subClashEnableRouting`, `subClashRules`, and JSON routing fields, then `ensure_panel_settings` writes them into AllSetting. A live spike first records which Clash top-level keys the deployed 3x-ui actually merges.

**Tech Stack:** bash, jq, 3x-ui panel AllSetting API, native Clash/JSON subscription server, FlClash/Mihomo for live smoke, SSH `vps-vdsok-streambase-torotin`.

**Spec:** `docs/superpowers/specs/2026-10-26-client-sub-admin-routing-design.md`

## Global Constraints

- Branch: `feat/xray-admin-access`.
- **Native only:** no Traefik middleware / response rewriter for subscriptions.
- **Do not set** Happ-only `subEnableRouting` / `subRoutingRules` for this feature (headers ignored by Clash).
- Admin FQDNs (exact): `arcane`, `homepage`, `adguard`, `3x-ui`, `traefik`, `lampac-admin` under `${WEBDOMAIN}`.
- Clash target: hidden group `ADMIN` → `[PROXY]`; rules `DOMAIN,<fqdn>,ADMIN` then `MATCH,PROXY`.
- DNS target: `hosts` → `PUBLIC_IPV4`; `fake-ip-filter` includes `${WEBDOMAIN}` and `+.${WEBDOMAIN}` when merge supports them.
- Do not rename `URI_SUB_PATH` / `URI_JSON_PATH` / `URI_CLASH_PATH` in this plan.
- Base64 (`subEnable=false`) only after explicit audit step; rollback `subEnable=true`.
- `docs/` is gitignored — `git add -f` for plans/specs when committing.
- Live destructive apply allowed on `vps-vdsok-streambase-torotin`; smoke Clash/JSON sub before/after panel settings apply.

## File map

| File | Role |
|---|---|
| `docs/superpowers/specs/2026-10-26-client-sub-admin-routing-capability.md` | Spike results: which Clash/JSON keys merge on live panel |
| `docker-proxy/3x-ui/scripts/lib/sub_admin_routing.bash` | Builders for Clash YAML + JSON routing snippets |
| `docker-proxy/3x-ui/scripts/lib/desired_state.bash` | Extend `desired_panel_keys` |
| `docker-proxy/3x-ui/scripts/lib/panel_runtime.bash` | Optional: call builders before overlay (or AfterStart caller) |
| `docker-proxy/3x-ui/scripts/01_AfterStart/3x-ui-upd.sh` | Export computed `subClashRules` / JSON fields before `ensure_panel_settings` |
| `docker-proxy/3x-ui/3x-ui.env` | `subClashEnableRouting=true`; leave multiline rules to runtime |
| `script/template/install.summary.template` + `09_finalize.sh` | Canonical Clash/JSON URLs; note base64 status |
| `tests/3x-ui-scripts/test_libs.bash` | Unit tests for builders + desired keys |
| `.project_context/02_state/last_changes.md` | Brief ops note after live apply |

## Resolved design choices

1. Injection = native AllSetting only.
2. Hidden `ADMIN` → `PROXY` preferred; if spike shows `proxy-groups` wipe node lists, fall back to `DOMAIN,*,PROXY` without custom groups (record in capability doc).
3. Multiline YAML is **not** stored in `3x-ui.env`; AfterStart computes it into the environment for `panel_settings_json`.

---

### Task 1: Live Clash merge spike + capability doc

**Files:**
- Create: `docs/superpowers/specs/2026-10-26-client-sub-admin-routing-capability.md`
- Create: `.superpowers/sdd/prizrak-test/spike-clash-merge.sh` (operator helper; optional keep)

**Interfaces:**
- Produces: capability markdown with booleans `merge_rules`, `merge_proxy_groups`, `merge_hosts`, `merge_dns`, `preserves_proxy_node_list`, `supports_hidden_admin`, `json_routing_effective`
- Consumes: live panel on `vps-vdsok-streambase-torotin`, existing Clash `subClashPath` + a client `subId`

- [ ] **Step 1: Write spike script that probes merge keys**

Create `.superpowers/sdd/prizrak-test/spike-clash-merge.sh` (run on the VPS host; uses `docker exec` into `3x-ui`):

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
# Required: SUB_ID of an existing shared client. Optional overrides below.
WEBDOMAIN=${WEBDOMAIN:-streambase.linkpc.net}
SUB_PORT=${SUB_PORT:-34053}
CLASH_PATH=${CLASH_PATH:-/A1yh2uqDoMqw}
JSON_PATH=${JSON_PATH:-}
SUB_ID=${SUB_ID:?set SUB_ID to a real client subId}
PROBE_HOST="spike-host.${WEBDOMAIN}"
PROBE_RULE="spike-rule.${WEBDOMAIN}"
PROBE_FILTER="spike-filter.${WEBDOMAIN}"

PROBE_YAML=$(cat <<EOF
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - DIRECT
  - name: ADMIN
    type: select
    hidden: true
    proxies:
      - PROXY
hosts:
  ${PROBE_HOST}: 203.0.113.10
dns:
  fake-ip-filter:
    - ${PROBE_FILTER}
rules:
  - DOMAIN,${PROBE_RULE},ADMIN
  - MATCH,PROXY
EOF
)

docker exec -i 3x-ui bash -s <<'INNER'
set -Eeuo pipefail
LIB=/mnt/sh/lib
. "$LIB/log.bash"
. "$LIB/env.bash"
. "$LIB/http.bash"
. "$LIB/3xui_api.bash"
. "$LIB/runtime_common.bash"
. "$LIB/panel_runtime.bash"
. "$LIB/desired_state.bash"
load_runtime_env /mnt/sh/01_AfterStart
TMP_ROOT=$(mktemp -d); http_init "$TMP_ROOT"
resolve_panel_base || die "login failed"
xui_get_panel_settings || die "get settings failed"
http_success_json || die "get settings body failed"
printf '%s' "$(api_obj_json)" > /tmp/panel-settings-backup.json
INNER

# Capture backup host-side, then apply probe via same helpers:
docker exec -e MODE=apply -e subClashEnableRouting=true \
  -e "subClashRules=${PROBE_YAML}" 3x-ui bash -lc '
set -Eeuo pipefail
LIB=/mnt/sh/lib
. "$LIB/log.bash"; . "$LIB/env.bash"; . "$LIB/http.bash"
. "$LIB/3xui_api.bash"; . "$LIB/runtime_common.bash"
. "$LIB/panel_runtime.bash"; . "$LIB/desired_state.bash"
load_runtime_env /mnt/sh/01_AfterStart
TMP_ROOT=$(mktemp -d); http_init "$TMP_ROOT"
resolve_panel_base
ensure_panel_settings
'
# If ensure_panel_settings is rejected because desired_panel_keys lack subClashRules,
# temporarily patch desired_panel_keys in the running container copy OR write via
# xui_update_panel_settings with a full AllSetting body from /tmp/panel-settings-backup.json
# merged with jq --arg rules "$PROBE_YAML" '.subClashEnableRouting=true | .subClashRules=$rules'.

docker exec 3x-ui wget -qO- "http://127.0.0.1:${SUB_PORT}${CLASH_PATH}/${SUB_ID}" \
  | tee /tmp/clash-spike.yaml >/dev/null

# Assertions to print (yes/no lines for the capability doc):
grep -Fq "DOMAIN,${PROBE_RULE},ADMIN" /tmp/clash-spike.yaml && echo merge_rules=yes || echo merge_rules=no
grep -Fq "name: ADMIN" /tmp/clash-spike.yaml && echo merge_proxy_groups=yes || echo merge_proxy_groups=no
grep -Fq "hidden: true" /tmp/clash-spike.yaml && echo supports_hidden_admin=yes || echo supports_hidden_admin=no
grep -Fq "${PROBE_HOST}" /tmp/clash-spike.yaml && echo merge_hosts=yes || echo merge_hosts=no
grep -Fq "${PROBE_FILTER}" /tmp/clash-spike.yaml && echo merge_dns=yes || echo merge_dns=no
# Node preservation: PROXY list must still mention a real inbound remark (not only DIRECT)
if grep -A20 'name: PROXY' /tmp/clash-spike.yaml | grep -Eqi 'vless|hysteria|reality|xhttp'; then
  echo preserves_proxy_node_list=yes
else
  echo preserves_proxy_node_list=no
fi

# Restore from /tmp/panel-settings-backup.json via xui_update_panel_settings (full body),
# then restart panel if RESTART_PANEL_REQUIRED would have been set.
# Confirm Happ headers untouched: after restore, subEnableRouting and subRoutingRules
# must equal backup values (grep both from backup vs live get).
```

- [ ] **Step 2: Run spike on VPS**

```bash
# Discover SUB_ID if needed:
ssh vps-vdsok-streambase-torotin "docker exec 3x-ui wget -qO- http://127.0.0.1:2053/...  # or sqlite: SELECT settings FROM clients"
SUB_ID=<from shared client> ssh vps-vdsok-streambase-torotin 'bash -s' < .superpowers/sdd/prizrak-test/spike-clash-merge.sh
```

Expected: stdout prints `merge_*=yes|no` lines; `/tmp/clash-spike.yaml` on the VPS holds the served YAML.

- [ ] **Step 3: Write capability doc from results**

Create `docs/superpowers/specs/2026-10-26-client-sub-admin-routing-capability.md` with a table:

```markdown
# Clash/JSON merge capability (live 3x-ui)

Date: YYYY-MM-DD
Image/panel: <fill>

| Capability | Result | Evidence |
|---|---|---|
| rules DOMAIN merge | yes/no | |
| proxy-groups override | yes/no | |
| preserves node names in proxies | yes/no | |
| hidden ADMIN group | yes/no | |
| hosts merge | yes/no | |
| dns.fake-ip-filter merge | yes/no | |
| subJsonRoutingRules effective | yes/no | |
```

Choose builder mode for later tasks:
- `full` if hosts + hidden ADMIN safe
- `rules-proxy` if only DOMAIN→PROXY safe
- `rules-admin` if ADMIN group works but hosts do not

- [ ] **Step 4: Commit capability doc**

```bash
git add -f docs/superpowers/specs/2026-10-26-client-sub-admin-routing-capability.md
git add .superpowers/sdd/prizrak-test/spike-clash-merge.sh
git commit -m "$(cat <<'EOF'
docs: record 3x-ui Clash merge capabilities for admin sub routing

EOF
)"
```

---

### Task 2: Clash rules builder (TDD) — always-safe rules

**Files:**
- Create: `docker-proxy/3x-ui/scripts/lib/sub_admin_routing.bash`
- Modify: `tests/3x-ui-scripts/test_libs.bash`
- Modify: `docker-proxy/3x-ui/scripts/01_AfterStart/3x-ui-upd.sh` (source only later; tests source lib directly)

**Interfaces:**
- Produces:
  - `admin_sub_hostnames` → prints six short labels one per line
  - `build_admin_sub_clash_rules <webdomain> <public_ipv4> <mode>` → stdout YAML string
  - Modes: `rules-proxy` | `rules-admin` | `full` (full may equal rules-admin until Task 3)
- Consumes: none

- [ ] **Step 1: Write failing tests**

Append to `tests/3x-ui-scripts/test_libs.bash` (and register calls at bottom):

```bash
test_admin_sub_hostnames_list() {
	# shellcheck source=/dev/null
	. "$SCRIPTS_DIR/lib/sub_admin_routing.bash"
	local out
	out=$(admin_sub_hostnames | sort | tr '\n' ',')
	assert_eq "3x-ui,adguard,arcane,homepage,lampac-admin,traefik," "$out" "admin host label set mismatch"
}

test_build_admin_sub_clash_rules_proxy_mode() {
	. "$SCRIPTS_DIR/lib/sub_admin_routing.bash"
	local yaml
	yaml=$(build_admin_sub_clash_rules "example.test" "203.0.113.9" "rules-proxy")
	grep -Fq 'DOMAIN,arcane.example.test,PROXY' <<<"$yaml" || fail "missing arcane DOMAIN→PROXY"
	grep -Fq 'DOMAIN,3x-ui.example.test,PROXY' <<<"$yaml" || fail "missing 3x-ui DOMAIN→PROXY"
	grep -Fq 'MATCH,PROXY' <<<"$yaml" || fail "missing MATCH,PROXY"
	grep -Fq 'name: ADMIN' <<<"$yaml" && fail "rules-proxy must not emit ADMIN group"
}

test_build_admin_sub_clash_rules_skips_hosts_without_ipv4() {
	. "$SCRIPTS_DIR/lib/sub_admin_routing.bash"
	local yaml
	yaml=$(build_admin_sub_clash_rules "example.test" "" "full")
	grep -Fq 'hosts:' <<<"$yaml" && fail "empty PUBLIC_IPV4 must omit hosts"
}
```

- [ ] **Step 2: Run tests — expect FAIL**

```bash
bash tests/3x-ui-scripts/test_libs.bash
```

Expected: FAIL sourcing missing `sub_admin_routing.bash` or missing functions.

- [ ] **Step 3: Implement minimal builder**

Create `docker-proxy/3x-ui/scripts/lib/sub_admin_routing.bash`:

```bash
#!/usr/bin/env bash

admin_sub_hostnames() {
	printf '%s\n' arcane homepage adguard 3x-ui traefik lampac-admin
}

build_admin_sub_clash_rules() {
	local webdomain=$1 public_ipv4=${2:-} mode=${3:-rules-proxy}
	local host fqdn
	local rules=$'rules:\n'
	local target=PROXY

	case "$mode" in
	rules-admin | full) target=ADMIN ;;
	rules-proxy) target=PROXY ;;
	*) die "build_admin_sub_clash_rules: unknown mode $mode" ;;
	esac

	if [[ "$target" == "ADMIN" ]]; then
		printf '%s\n' \
			'proxy-groups:' \
			'  - name: ADMIN' \
			'    type: select' \
			'    hidden: true' \
			'    proxies:' \
			'      - PROXY'
	fi

	if [[ "$mode" == "full" && -n "$public_ipv4" ]]; then
		printf '%s\n' 'hosts:'
		printf '  %s: %s\n' "$webdomain" "$public_ipv4"
		while IFS= read -r host; do
			printf '  %s.%s: %s\n' "$host" "$webdomain" "$public_ipv4"
		done < <(admin_sub_hostnames)
		printf '%s\n' 'dns:' '  fake-ip-filter:' "    - ${webdomain}" "    - \"+.${webdomain}\""
	fi

	printf '%s' "$rules"
	while IFS= read -r host; do
		printf '  - DOMAIN,%s.%s,%s\n' "$host" "$webdomain" "$target"
	done < <(admin_sub_hostnames)
	printf '  - MATCH,PROXY\n'
}
```

Wire `die` via existing log lib or `printf`+`return 1` if this file is sourced after `log.bash`.

- [ ] **Step 4: Run tests — expect PASS**

```bash
bash tests/3x-ui-scripts/test_libs.bash
```

Expected: new tests PASS (full suite OK or at least new tests when run focused).

- [ ] **Step 5: Commit**

```bash
git add docker-proxy/3x-ui/scripts/lib/sub_admin_routing.bash tests/3x-ui-scripts/test_libs.bash
git commit -m "$(cat <<'EOF'
feat(3x-ui): add admin-plane Clash rules builder for subscriptions

EOF
)"
```

---

### Task 3: Align builder with spike mode (`full` / fallback)

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/lib/sub_admin_routing.bash`
- Modify: `tests/3x-ui-scripts/test_libs.bash`
- Read: `docs/superpowers/specs/2026-10-26-client-sub-admin-routing-capability.md`

**Interfaces:**
- Produces: `admin_sub_clash_mode_from_capability` or hard-coded default mode constant `ADMIN_SUB_CLASH_MODE` chosen from capability doc
- Consumes: Task 1 capability results

- [ ] **Step 1: Add tests for chosen mode**

If capability = `full`:

```bash
test_build_admin_sub_clash_rules_full_mode() {
	. "$SCRIPTS_DIR/lib/sub_admin_routing.bash"
	local yaml
	yaml=$(build_admin_sub_clash_rules "example.test" "198.51.100.10" "full")
	grep -Fq 'hidden: true' <<<"$yaml" || fail "full mode needs hidden ADMIN"
	grep -Fq 'DOMAIN,arcane.example.test,ADMIN' <<<"$yaml" || fail "full mode DOMAIN→ADMIN"
	grep -Fq 'arcane.example.test: 198.51.100.10' <<<"$yaml" || fail "full mode hosts"
	grep -Fq '+.example.test' <<<"$yaml" || fail "full mode fake-ip-filter"
}
```

If capability forbids proxy-groups, assert `rules-proxy` is the runtime default instead and skip ADMIN assertions.

- [ ] **Step 2: Run test — FAIL then implement mode tweaks**

Adjust `build_admin_sub_clash_rules` so `full` matches spike-safe shape (e.g. omit wholesale `PROXY` group replace; only add `ADMIN` group).

- [ ] **Step 3: Export default mode helper**

```bash
# Default after spike — replace value to match capability doc.
admin_sub_clash_default_mode() {
	printf '%s\n' "full"   # or rules-proxy / rules-admin
}
```

- [ ] **Step 4: Tests PASS + commit**

```bash
git add docker-proxy/3x-ui/scripts/lib/sub_admin_routing.bash tests/3x-ui-scripts/test_libs.bash
git commit -m "$(cat <<'EOF'
feat(3x-ui): tune admin Clash sub builder to live merge capabilities

EOF
)"
```

---

### Task 4: Wire builder into panel settings apply path

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/lib/desired_state.bash` (`desired_panel_keys`)
- Modify: `docker-proxy/3x-ui/scripts/01_AfterStart/3x-ui-upd.sh`
- Modify: `docker-proxy/3x-ui/3x-ui.env`
- Modify: `tests/3x-ui-scripts/test_libs.bash` (keys include `subClashEnableRouting` / `subClashRules`)

**Interfaces:**
- Consumes: `build_admin_sub_clash_rules`, `admin_sub_clash_default_mode`, `WEBDOMAIN`, `PUBLIC_IPV4`
- Produces: env `subClashEnableRouting=true`, `subClashRules=<yaml>` before `ensure_panel_settings`

- [ ] **Step 1: Failing key presence test**

```bash
test_desired_panel_keys_include_clash_routing() {
	local keys
	keys=$(desired_panel_keys)
	grep -qx subClashEnableRouting <<<"$keys" || fail "subClashEnableRouting missing"
	grep -qx subClashRules <<<"$keys" || fail "subClashRules missing"
}
```

- [ ] **Step 2: Extend `desired_panel_keys`**

In `desired_state.bash`, add to the `subClash*` line:

```bash
		subClashEnable subClashPath subClashURI subClashEnableRouting subClashRules \
```

Keep `subEnableRouting` / `subRoutingRules` listed but **do not** flip them true in env for this feature.

- [ ] **Step 3: Source builder + export rules in AfterStart**

In `3x-ui-upd.sh` `main()`, after `load_runtime_env` / before `ensure_panel_settings`:

```bash
# shellcheck source=../lib/sub_admin_routing.bash
. "$LIB_DIR/sub_admin_routing.bash"
subClashEnableRouting=true
subClashRules=$(build_admin_sub_clash_rules "${WEBDOMAIN}" "${PUBLIC_IPV4:-}" "$(admin_sub_clash_default_mode)")
export subClashEnableRouting subClashRules
if [[ -z "${PUBLIC_IPV4:-}" ]]; then
	log WARN "PUBLIC_IPV4 empty: admin Clash hosts map omitted"
fi
# Leave Happ fields alone — do not export subEnableRouting=true or subRoutingRules here.
```

Verify `PUBLIC_IPV4` is already present in the container via compose `env_file: ./.env` (`docker.env.template` writes it). Only add an explicit `environment: - PUBLIC_IPV4=${PUBLIC_IPV4}` in `12-3x-ui.yml` if `docker exec 3x-ui printenv PUBLIC_IPV4` is empty on the live host.

- [ ] **Step 4: Set flag in `3x-ui.env`**

```bash
subClashEnableRouting="true"
# subClashRules computed at runtime — do not put multiline YAML here
```

Assert in unit or live check that after apply, panel `subEnableRouting` remains whatever backup had (typically `false`) and `subRoutingRules` is unchanged.

- [ ] **Step 5: Run unit tests + commit**

```bash
bash tests/3x-ui-scripts/test_libs.bash
git add docker-proxy/3x-ui/scripts/lib/desired_state.bash \
  docker-proxy/3x-ui/scripts/01_AfterStart/3x-ui-upd.sh \
  docker-proxy/3x-ui/3x-ui.env \
  docker-proxy/3x-ui/scripts/lib/sub_admin_routing.bash \
  tests/3x-ui-scripts/test_libs.bash
# include 12-3x-ui.yml only if PUBLIC_IPV4 env wire was required
git commit -m "$(cat <<'EOF'
feat(3x-ui): apply admin Clash routing via native panel settings

EOF
)"
```

---

### Task 5: JSON subscription routing (as panel allows)

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/lib/sub_admin_routing.bash`
- Modify: `docker-proxy/3x-ui/scripts/lib/desired_state.bash`
- Modify: `docker-proxy/3x-ui/scripts/01_AfterStart/3x-ui-upd.sh`
- Modify: `tests/3x-ui-scripts/test_libs.bash`

**Interfaces:**
- Produces: `build_admin_sub_json_routing_rules <webdomain>` → text/JSON suitable for `subJsonRoutingRules` or `subJsonRules` per capability doc
- Consumes: Task 1 JSON effectiveness flag

- [ ] **Step 1: Write failing test for JSON snippet**

```bash
test_build_admin_sub_json_routing_rules() {
	. "$SCRIPTS_DIR/lib/sub_admin_routing.bash"
	local out
	out=$(build_admin_sub_json_routing_rules "example.test")
	grep -Fq 'arcane.example.test' <<<"$out" || fail "json rules need arcane host"
}
```

- [ ] **Step 2: Implement builder matching spike format**

From Task 1 capability doc, lock the exact field name and payload. If `json_routing_effective=yes`, use the probe format that worked. If the panel stores free-text domain rules like Clash `DOMAIN-SUFFIX` lines, emit:

```bash
build_admin_sub_json_routing_rules() {
	local webdomain=$1 host
	while IFS= read -r host; do
		printf 'full:%s.%s,proxy\n' "$host" "$webdomain"
	done < <(admin_sub_hostnames)
}
```

If `json_routing_effective=no`, implement:

```bash
build_admin_sub_json_routing_rules() {
	# Panel build ignores JSON routing fields — Clash is canonical for admin DNS/routing.
	printf ''
}
```

and keep the empty export so AfterStart does not wipe unrelated keys (`panel_settings_json` skips empty env overlays).

- [ ] **Step 3: Add keys that spike proved effective (`subJsonRoutingRules` and/or `subJsonDns`) to `desired_panel_keys`; export non-empty values in AfterStart only when effective**

- [ ] **Step 4: Tests PASS + commit**

```bash
git commit -m "$(cat <<'EOF'
feat(3x-ui): add admin-plane JSON subscription routing fields

EOF
)"
```

---

### Task 6: Install summary — Clash/JSON canonical for admin

**Files:**
- Modify: `script/template/install.summary.template`
- Modify: `script/modules/09_finalize.sh`
- Modify: `tests/install-scripts/test_installer_cli.bash`

**Interfaces:**
- Produces: summary lines for Clash + JSON subscription URLs; note that base64 may be disabled
- Consumes: existing `URI_CLASH_PATH`, `URI_JSON_PATH`, `WEBDOMAIN`

- [ ] **Step 1: Extend summary template**

Under Public HTTPS (or new Subscriptions section):

```text
Subscriptions:
  Clash/Mihomo     : ${SUMMARY_URL_SUB_CLASH}
  Xray JSON        : ${SUMMARY_URL_SUB_JSON}
  Standard/base64  : ${SUMMARY_URL_SUB_STD}
  Note             : Admin panels require Clash or JSON (client routing). Standard may be disabled.
```

- [ ] **Step 2: Build URLs in `install_prepare_summary_env`**

```bash
SUMMARY_URL_SUB_CLASH=$(install_summary_url "${URI_CLASH_PATH:-}" "" noslash)
SUMMARY_URL_SUB_JSON=$(install_summary_url "${URI_JSON_PATH:-}" "" noslash)
SUMMARY_URL_SUB_STD=$(install_summary_url "${URI_SUB_PATH:-}" "" noslash)
# If SUB_ENABLE_STD=false later, set SUMMARY_URL_SUB_STD=disabled
```

Export the new vars.

- [ ] **Step 3: Update installer tests for new labels**

- [ ] **Step 4: Run focused summary tests + commit**

```bash
bash tests/install-scripts/test_installer_cli.bash  # or focused harness
git add script/template/install.summary.template script/modules/09_finalize.sh tests/install-scripts/test_installer_cli.bash
git commit -m "$(cat <<'EOF'
feat(installer): document Clash/JSON subscriptions for admin access

EOF
)"
```

---

### Task 7: Live apply + verify admin via stock Clash sub

**Files:**
- Sync: `sub_admin_routing.bash`, `desired_state.bash`, AfterStart, `3x-ui.env`, compose env if needed → `/opt/docker-proxy/...`
- No new product files required beyond sync

**Interfaces:**
- Consumes: Tasks 1–5 artifacts on server mount `/mnt/sh/lib`
- Produces: panel settings applied; Clash YAML contains admin rules; live `:9443` → 401 via FlClash

- [ ] **Step 1: Smoke current Clash sub + admin URL (baseline)**

```bash
curl -fsS -x http://127.0.0.1:7890 -skI --max-time 20 "https://arcane.${WEBDOMAIN}:9443/" | head
```

- [ ] **Step 2: rsync/scp updated scripts to VPS `/opt/docker-proxy/3x-ui/scripts/` (sudo install)**

Same pattern as prior admin sync (`/tmp/sync-upload` + `sudo install`).

- [ ] **Step 3: Re-run AfterStart path or `docker restart 3x-ui` so `ensure_panel_settings` runs**

```bash
ssh vps-vdsok-streambase-torotin 'docker restart 3x-ui && docker logs 3x-ui --since 2m 2>&1 | tail -n 80'
```

Expected: log line that panel settings updated / already match; no API validation errors.

- [ ] **Step 4: Fetch Clash body and assert markers**

```bash
ssh vps-vdsok-streambase-torotin "docker exec 3x-ui wget -qO- http://127.0.0.1:34053${CLASH_PATH}/${SUB_ID}" | tee /tmp/clash-live.yaml
grep -E 'DOMAIN,arcane\.|MATCH,PROXY|ADMIN|hosts:' /tmp/clash-live.yaml
```

Expected: admin DOMAIN rules present; hosts/ADMIN if capability full.

- [ ] **Step 5: Client smoke through system proxy**

```bash
curl.exe -sx http://127.0.0.1:7890 -skI --max-time 20 "https://arcane.streambase.linkpc.net:9443/"
# Expected: HTTP/1.1 401 Unauthorized (Basic Auth)
```

Repeat for homepage, adguard, 3x-ui panel path, traefik `/dashboard/`.

- [ ] **Step 6: Regression checks from the design spec**

```bash
# No freedom blackhole of Traefik admin IP:9443
ssh vps-vdsok-streambase-torotin "docker logs 3x-ui --since 10m 2>&1 | grep -F 'blocked target: 172.18.0.6:9443' || true"
# Expected: empty

# Happ header fields untouched (compare to pre-apply backup or known defaults)
ssh vps-vdsok-streambase-torotin "docker exec 3x-ui bash -lc '... get settings ... | jq -r \"[.subEnableRouting,.subRoutingRules]|@tsv\"'"
# Expected: subEnableRouting false/empty; subRoutingRules empty (unless operator had custom Happ)

# VLESS share / JSON path still returns a body
curl -sk "https://${WEBDOMAIN}${URI_JSON_PATH}/${SUB_ID}" | head -c 200
# Expected: JSON starts with { or [
```

- [ ] **Step 7: Commit any script fixes discovered live; update `.project_context/02_state/last_changes.md`**

```bash
git commit -m "$(cat <<'EOF'
fix(3x-ui): address live panel apply issues for admin sub routing

EOF
)"
```

---

### Task 8: Base64 audit + disable

**Files:**
- Modify: `docker-proxy/3x-ui/3x-ui.env` (`subEnable="false"`) **only after audit**
- Modify: AfterStart/env if a dedicated `SUB_ENABLE_STD` gate is clearer
- Modify: summary `SUMMARY_URL_SUB_STD=disabled`

**Interfaces:**
- Consumes: operator confirmation or access evidence that no required client uses `URI_SUB_PATH` alone
- Produces: `subEnable=false` on panel; Clash/JSON still work

- [ ] **Step 1: Audit**

Check Traefik/access logs or operator list for hits to `URI_SUB_PATH` vs Clash/JSON paths over a representative window. Record result in capability/ops note.

- [ ] **Step 2: Disable base64 in desired env**

```bash
subEnable="false"
```

Ensure AfterStart exports it; apply via panel settings; restart if required.

- [ ] **Step 3: Verify**

```bash
# Standard path should not return a usable node list (empty/error/disabled)
curl -sk "https://${WEBDOMAIN}${URI_SUB_PATH}/$SUB_ID" | head
# Clash still works
curl -sk "https://${WEBDOMAIN}${URI_CLASH_PATH}/$SUB_ID" | head
```

- [ ] **Step 4: Regenerate install summary on server**

```bash
sudo /opt/script/install.sh run final
```

- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat(3x-ui): disable standard base64 subscription after Clash/JSON audit

EOF
)"
```

---

## Spec coverage self-check

| Spec requirement | Task |
|---|---|
| Native Clash routing via panel settings | 2–4, 7 |
| Hidden ADMIN → PROXY (or documented fallback) | 1, 3 |
| hosts + fake-ip-filter when merge allows | 1, 3, 7 |
| JSON routing as capable | 1, 5, 7 |
| No Happ header misuse | Global + Task 4 + Task 7 Step 6 |
| Base64 disable after audit | 8 |
| Install summary Clash/JSON canonical | 6 |
| No post-processor | Global Constraints |
| Live verify admin :9443 | 7 |
| Spike checklist (merge keys / PROXY nodes / hidden / JSON / Happ) | 1 + Task 7 Step 6 |
| No `blocked target: 172.18.0.6:9443` regression | Task 7 Step 6 |
| VLESS/JSON path regression | Task 7 Step 6 |
| Empty PUBLIC_IPV4 skips hosts + WARN | Task 2 + Task 4 |

## Placeholder scan

Spike outcomes choose Task 3 mode via the committed capability doc (`full` / `rules-admin` / `rules-proxy`). No open TBD/TODO in steps; JSON Task 5 branches on the same doc’s `json_routing_effective` flag.
