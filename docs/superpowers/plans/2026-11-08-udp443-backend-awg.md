# UDP443 Backend (AmneziaWG) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add installer selector `UDP443_BACKEND=amneziawg|hysteria2|off` (default `amneziawg`), rename the shared UDP publish env to `PORT_LOCAL_UDP443`, and teach AfterStart to ensure exactly one managed protocol on that port (delete the other), then verify on streambase.

**Architecture:** One public `443/udp` owner. Wizard/env resolve a single backend; derived `ENABLE_HYSTERIA2` / `ENABLE_AMNEZIAWG` feed AfterStart. `desired_state` gains kind `amneziawg`; inactive managed UDP443 inbound is deleted (panel reserves ports even when disabled). Compose keeps a single UDP mapping with the new variable name.

**Tech Stack:** bash installer (`script/`), 3x-ui AfterStart libs (`docker-proxy/3x-ui/scripts/`), compose `12-3x-ui.yml`, bash unit tests under `tests/`, live host `vps-vdsok-streambase`.

**Spec:** `docs/superpowers/specs/2026-11-08-udp443-backend-awg-design.md`  
**Spike evidence:** `awg-spike-evidence/api-shape.md`, `server-apply.md`, `wsl-test-log.md`, `NEXT.md`

## Global Constraints

- Implementation branch: create **`feat/udp443-backend-awg` from `dev`** (do not continue feature work only on `feat/awg-inbound-spike`).
- Mutual exclusion on **`443/udp` only** — no second UDP publish.
- Default backend: **`amneziawg`**.
- Inactive managed inbound: **delete** (not park on 5443).
- Port env: **`PORT_LOCAL_UDP443`**; compat read **`PORT_LOCAL_HYSTERIA`** if unset.
- Legacy: if `UDP443_BACKEND` unset and `ENABLE_HYSTERIA2=true` → `hysteria2`; if `ENABLE_HYSTERIA2=false` → `amneziawg`; both unset → `amneziawg`.
- `docs/` is gitignored — `git add -f` for specs/plans when committing them; code/tests commit normally.
- Live done-bar: **streambase** sync + AWG connect; HY2 not on 443 while AWG active.
- Never commit PrivateKey / HeaderProtectionKey / full client conf / API tokens.
- Clash AWG node type is **not** a v1 blocker; omit HY2 from Clash when backend ≠ `hysteria2`.
- Kernel AWG mode out of scope (Docker embedded only).

## File Structure

| Path | Responsibility |
|---|---|
| `script/modules/02_env.sh` | Defaults, `resolve_udp443_backend`, port rename + legacy |
| `script/modules/01_menu.sh` | Selector UI for `UDP443_BACKEND` |
| `script/modules/00_common.sh` | Bool/list normalization hooks if needed |
| `script/modules/06_firewall.sh`, `09_finalize.sh`, `10_uninstall.sh` | Copy/summary for UDP443 backend |
| `script/template/install.env.template`, `docker.env.template`, `install.summary.template` | Persist new vars |
| `docker-proxy/compose.d/12-3x-ui.yml` | `443:${PORT_LOCAL_UDP443:-443}/udp` |
| `docker-proxy/3x-ui/3x-ui.env` | `UDP443_BACKEND`, derived enables, port |
| `docker-proxy/3x-ui/scripts/lib/env.bash` | Load/normalize backend + port |
| `docker-proxy/3x-ui/scripts/lib/desired_state.bash` | `amneziawg` kind + port from `PORT_LOCAL_UDP443` |
| `docker-proxy/3x-ui/scripts/lib/inbound_runtime.bash` | Build/ensure AWG; delete managed inactive |
| `docker-proxy/3x-ui/scripts/lib/3xui_api.bash` | `xui_del_inbound` |
| `docker-proxy/3x-ui/scripts/lib/xray_runtime.bash` | UDP wait for active backend |
| `docker-proxy/3x-ui/scripts/01_AfterStart/3x-ui-upd.sh` | Orchestrate ensure/delete/clients |
| `tests/install-scripts/test_installer_cli.bash` | Menu/env/UFW assertions |
| `tests/run-compose/test_stage_tcp_clean_architecture.bash` | Compose/env template contracts |
| `tests/3x-ui-scripts/test_libs.bash` | desired_state / ensure / delete / wait |

---

### Task 1: Branch + UDP443 env resolution (installer)

**Files:**
- Create branch: `feat/udp443-backend-awg` from `dev`
- Modify: `script/modules/02_env.sh`
- Modify: `script/modules/00_common.sh` (only if a shared normalizer is required)
- Test: `tests/install-scripts/test_installer_cli.bash` (add focused cases; wire into existing runner)

**Interfaces:**
- Produces: `resolve_udp443_backend` (or inline in `install_prepare_env`) setting `UDP443_BACKEND`, `PORT_LOCAL_UDP443`, derived `ENABLE_HYSTERIA2` / `ENABLE_AMNEZIAWG` (`true`/`false` strings)
- Consumes: optional legacy `ENABLE_HYSTERIA2`, `PORT_LOCAL_HYSTERIA`

- [ ] **Step 1: Create branch from `dev`**

```powershell
cd y:\3x-ui_pro_Docker
git fetch origin 2>$null
git checkout dev
git pull --ff-only 2>$null
git checkout -b feat/udp443-backend-awg
git status -sb
```

Expected: `## feat/udp443-backend-awg`

- [ ] **Step 2: Write failing installer tests for resolution**

In `tests/install-scripts/test_installer_cli.bash`, add tests that source env helpers (same pattern as existing bool tests) and assert:

| Input | Expected `UDP443_BACKEND` | Derived HY2 | Derived AWG |
|---|---|---|---|
| (unset both) | `amneziawg` | `false` | `true` |
| `ENABLE_HYSTERIA2=true` only | `hysteria2` | `true` | `false` |
| `ENABLE_HYSTERIA2=false` only | `amneziawg` | `false` | `true` |
| `UDP443_BACKEND=off` | `off` | `false` | `false` |
| `UDP443_BACKEND=hysteria2` | `hysteria2` | `true` | `false` |
| `PORT_LOCAL_HYSTERIA=443` only | `PORT_LOCAL_UDP443=443` | — | — |
| `PORT_LOCAL_UDP443=443` | unchanged | — | — |
| `UDP443_BACKEND=nope` | fail with clear error | — | — |

- [ ] **Step 3: Run tests — expect FAIL**

```bash
bash tests/install-scripts/test_installer_cli.bash
```

Expected: new cases FAIL (helpers missing).

- [ ] **Step 4: Implement resolution in `02_env.sh`**

Add (names may match existing style):

```bash
install_normalize_udp443_backend() {
	local raw=${UDP443_BACKEND:-}
	if [[ -z "$raw" ]]; then
		if [[ "${ENABLE_HYSTERIA2+x}" == x ]]; then
			install_normalize_bool_var ENABLE_HYSTERIA2
			if [[ "$ENABLE_HYSTERIA2" == "true" ]]; then
				UDP443_BACKEND=hysteria2
			else
				UDP443_BACKEND=amneziawg
			fi
		else
			UDP443_BACKEND=amneziawg
		fi
	fi
	case "$UDP443_BACKEND" in
	amneziawg|hysteria2|off) ;;
	*) die "UDP443_BACKEND must be amneziawg|hysteria2|off (got: $UDP443_BACKEND)" ;;
	esac
	case "$UDP443_BACKEND" in
	amneziawg)
		ENABLE_AMNEZIAWG=true
		ENABLE_HYSTERIA2=false
		;;
	hysteria2)
		ENABLE_AMNEZIAWG=false
		ENABLE_HYSTERIA2=true
		;;
	off)
		ENABLE_AMNEZIAWG=false
		ENABLE_HYSTERIA2=false
		;;
	esac
	export UDP443_BACKEND ENABLE_AMNEZIAWG ENABLE_HYSTERIA2
}

# Port rename with legacy fallback — before defaults freeze:
if [[ -z "${PORT_LOCAL_UDP443:-}" && -n "${PORT_LOCAL_HYSTERIA:-}" ]]; then
	PORT_LOCAL_UDP443=$PORT_LOCAL_HYSTERIA
fi
: "${PORT_LOCAL_UDP443:=443}"
# Keep PORT_LOCAL_HYSTERIA as alias equal to PORT_LOCAL_UDP443 for one release (optional shim):
PORT_LOCAL_HYSTERIA=$PORT_LOCAL_UDP443
```

Call `install_normalize_udp443_backend` from the same place bools are normalized today. Export `PORT_LOCAL_UDP443` (and shim) with other ports.

- [ ] **Step 5: Re-run tests — expect PASS for new cases**

```bash
bash tests/install-scripts/test_installer_cli.bash
```

- [ ] **Step 6: Commit**

```powershell
git add script/modules/02_env.sh script/modules/00_common.sh tests/install-scripts/test_installer_cli.bash
git commit -m "feat(install): resolve UDP443_BACKEND and PORT_LOCAL_UDP443"
```

---

### Task 2: Wizard menu + templates + firewall/summary copy

**Files:**
- Modify: `script/modules/01_menu.sh`
- Modify: `script/template/install.env.template`
- Modify: `script/template/docker.env.template`
- Modify: `script/template/install.summary.template`
- Modify: `script/modules/09_finalize.sh`
- Modify: `script/modules/06_firewall.sh` (comments/log strings only if present)
- Modify: `script/modules/10_uninstall.sh` (comment text if HY2-specific)
- Test: `tests/install-scripts/test_installer_cli.bash`

**Interfaces:**
- Consumes: `UDP443_BACKEND`, `PORT_LOCAL_UDP443` from Task 1
- Produces: rendered env files without primary `ENABLE_HYSTERIA2` / `PORT_LOCAL_HYSTERIA` keys (compat may still appear if shim written — prefer **not** writing `ENABLE_HYSTERIA2` as primary; write `UDP443_BACKEND` + derived optional)

- [ ] **Step 1: Update failing menu/template assertions**

Replace expectations like:

- `3. ENABLE_HYSTERIA2` → show `UDP443_BACKEND` with current value
- `ENABLE_HYSTERIA2=false` persistence → `UDP443_BACKEND=...`
- `PORT_LOCAL_HYSTERIA=` in templates → `PORT_LOCAL_UDP443=`
- Summary line `Hysteria2 : 0.0.0.0:.../udp` → `UDP443 backend (...): 0.0.0.0:${SUMMARY_PORT_LOCAL_UDP443}/udp`
- UFW message text: “UDP 443 backend” (rule stays `ufw allow 443/udp`)

- [ ] **Step 2: Run — expect FAIL**

```bash
bash tests/install-scripts/test_installer_cli.bash
```

- [ ] **Step 3: Implement menu cycle**

```bash
wizard_cycle_udp443_backend() {
	case "${UDP443_BACKEND:-amneziawg}" in
	amneziawg) UDP443_BACKEND=hysteria2 ;;
	hysteria2) UDP443_BACKEND=off ;;
	off) UDP443_BACKEND=amneziawg ;;
	*) UDP443_BACKEND=amneziawg ;;
	esac
	export UDP443_BACKEND
	install_normalize_udp443_backend
}

# In wizard_print_feature_toggles / save / load:
# Replace ENABLE_HYSTERIA2 row with:
#   N. UDP443_BACKEND   $UDP443_BACKEND   Owner of public 443/udp (amneziawg|hysteria2|off)
```

Load/save via `install_state_set_env UDP443_BACKEND "$UDP443_BACKEND"` and `PORT_LOCAL_UDP443`.

- [ ] **Step 4: Templates**

`install.env.template` / `docker.env.template`:

```bash
PORT_LOCAL_UDP443=${PORT_LOCAL_UDP443}
UDP443_BACKEND=${UDP443_BACKEND}
```

Remove primary lines for `PORT_LOCAL_HYSTERIA` / `ENABLE_HYSTERIA2` from templates (resolution still reads legacy from old server files).

Summary template: use `SUMMARY_PORT_LOCAL_UDP443` and backend name.

- [ ] **Step 5: Tests PASS + commit**

```powershell
git add script/modules/01_menu.sh script/modules/09_finalize.sh script/modules/06_firewall.sh script/modules/10_uninstall.sh script/template/*.template tests/install-scripts/test_installer_cli.bash
git commit -m "feat(install): UDP443_BACKEND wizard selector and env templates"
```

---

### Task 3: Compose + `3x-ui.env` contract

**Files:**
- Modify: `docker-proxy/compose.d/12-3x-ui.yml`
- Modify: `docker-proxy/3x-ui/3x-ui.env`
- Modify: `tests/run-compose/test_stage_tcp_clean_architecture.bash`

**Interfaces:**
- Consumes: `PORT_LOCAL_UDP443`, `UDP443_BACKEND`
- Produces: compose publish `443:${PORT_LOCAL_UDP443:-443}/udp`

- [ ] **Step 1: Update compose test assertions**

Change strings that require `PORT_LOCAL_HYSTERIA` / “accepted Hysteria2 443/udp” to `PORT_LOCAL_UDP443` / “UDP443 backend stage”. Assert `UDP443_BACKEND=${UDP443_BACKEND}` in env templates. Assert `443/udp` still only on `12-3x-ui.yml` service `3x-ui`.

- [ ] **Step 2: Run — expect FAIL**

```bash
bash tests/run-compose/test_stage_tcp_clean_architecture.bash
```

- [ ] **Step 3: Patch compose + 3x-ui.env**

```yaml
- "443:${PORT_LOCAL_UDP443:-443}/udp"
```

```bash
UDP443_BACKEND="${UDP443_BACKEND:-amneziawg}"
ENABLE_HYSTERIA2="${ENABLE_HYSTERIA2:-false}"
ENABLE_AMNEZIAWG="${ENABLE_AMNEZIAWG:-true}"
# Prefer derived flags from compose/.env after installer resolve; defaults match amneziawg backend.
```

Keep `HYSTERIA2_MASQ_URL` (still used when HY2 selected).

- [ ] **Step 4: Tests PASS + commit**

```powershell
git add docker-proxy/compose.d/12-3x-ui.yml docker-proxy/3x-ui/3x-ui.env tests/run-compose/test_stage_tcp_clean_architecture.bash
git commit -m "feat(compose): publish 443/udp via PORT_LOCAL_UDP443"
```

---

### Task 4: desired_state + AWG inbound build/delete helpers

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/lib/desired_state.bash`
- Modify: `docker-proxy/3x-ui/scripts/lib/inbound_runtime.bash`
- Modify: `docker-proxy/3x-ui/scripts/lib/3xui_api.bash`
- Modify: `docker-proxy/3x-ui/scripts/lib/env.bash`
- Test: `tests/3x-ui-scripts/test_libs.bash`

**Interfaces:**
- Produces:
  - `inbound_remark_slug amneziawg` → `amneziawg`
  - `build_desired_state` includes `.inbounds.amneziawg` with `protocol:"amneziawg"`, `port` from `PORT_LOCAL_UDP443` (fallback `PORT_LOCAL_HYSTERIA`)
  - `build_amneziawg_settings_json` / branch in `build_inbound_components_json`
  - `xui_del_inbound id`
  - `delete_managed_inbound_kind kind desired` — find by managed remarks or port+protocol; delete if found and remarks match managed set
- Consumes: spike minimal settings `{mtu, subnet, dns1, dns2}`; panel fills obfuscation

- [ ] **Step 1: Failing unit tests**

Add to `test_libs.bash`:

1. `build_desired_state` with `PORT_LOCAL_UDP443=443` → `.inbounds.amneziawg.protocol == "amneziawg"` and port 443; hysteria2 port also reads same env (both kinds present in desired JSON; AfterStart decides which to ensure).
2. `build_inbound_components_json amneziawg` → protocol `amneziawg`, settings contain subnet/dns (or empty server leave panel-fill — match ensure path: minimal settings object).
3. `managed_inbound_remarks_json amneziawg` includes flag remark + `managed:amneziawg`.
4. Mock/plan-mode: `delete_managed_inbound_kind` records delete when inbound exists with managed remark.

- [ ] **Step 2: Run — expect FAIL**

```bash
bash tests/3x-ui-scripts/test_libs.bash
```

- [ ] **Step 3: Implement API + builders**

`3xui_api.bash`:

```bash
xui_del_inbound() {
	local id=$1
	xui_api_post "/panel/api/inbounds/del/${id}" || return 1
}
```

`desired_state.bash` — extend slug + `build_desired_state`:

```bash
amneziawg) printf '%s' amneziawg ;;
# ...
--arg udp443Port "${PORT_LOCAL_UDP443:-${PORT_LOCAL_HYSTERIA:-443}}" \
# hysteria2 and amneziawg both use $udp443Port
amneziawg: {managed: true, protocol: "amneziawg", port: ($udp443Port|tonumber), remark: $amneziawgRemark,
  subnet: "10.8.1.0/24", mtu: 1420, dns1: "8.8.8.8", dns2: "8.8.4.4"},
```

`inbound_runtime.bash` — settings for create (minimal; do not invent obfuscation keys):

```bash
build_amneziawg_settings_json() {
	local desired=$1
	jq -nc --argjson d "$desired" '{
	  mtu: ($d.inbounds.amneziawg.mtu // 1420),
	  subnet: ($d.inbounds.amneziawg.subnet // "10.8.1.0/24"),
	  dns1: ($d.inbounds.amneziawg.dns1 // "8.8.8.8"),
	  dns2: ($d.inbounds.amneziawg.dns2 // "8.8.4.4")
	}'
}
```

In `build_inbound_components_json`, for `amneziawg`: settings from builder; `streamSettings: {}`; sniffing `{}` (match spike).

`ensure_inbound`: when kind is `amneziawg`, find by port+`amneziawg`. If existing inbound has panel-generated `settings.server`, **preserve** (current ensure already preserves existing id without forcing update — keep that).

`delete_managed_inbound_kind`:

```bash
delete_managed_inbound_kind() {
	local kind=$1 desired=$2 inbounds id expected_remarks remark protocol port
	inbounds=$(inbounds_json)
	expected_remarks=$(managed_inbound_remarks_json "$kind" "$desired")
	port=$(jq -r ".inbounds.$kind.port" <<<"$desired")
	protocol=$(jq -r ".inbounds.$kind.protocol" <<<"$desired")
	id=$(find_inbound_by_port "$inbounds" "$port" "$protocol")
	# also scan remarks if port moved (spike HY2 on 5443):
	if [[ -z "$id" ]]; then
		id=$(jq -r --argjson remarks "$expected_remarks" '
		  .[] | select(.remark as $r | $remarks | index($r)) | .id' <<<"$inbounds" | head -n1)
	fi
	[[ -n "$id" ]] || return 0
	inbound=$(jq -c --arg id "$id" '.[] | select((.id|tostring)==$id)' <<<"$inbounds")
	remark=$(jq -r '.remark // empty' <<<"$inbound")
	jq -e --arg r "$remark" --argjson remarks "$expected_remarks" '$remarks | index($r)' >/dev/null \
		|| { log WARN "skip delete id=$id remark=$remark (not managed $kind)"; return 0; }
	if [[ "$MODE" == "plan" ]]; then
		record_change "PLAN: delete managed $kind inbound id=$id"
		return 0
	fi
	record_change "APPLY: delete managed $kind inbound id=$id"
	xui_del_inbound "$id" || die "Failed to delete $kind inbound id=$id"
	http_success_json || die "delete $kind failed: $(http_body)"
	RESTART_XRAY_REQUIRED=1
}
```

Also recognize spike remark `awg-spike-443` as optional alias in `managed_inbound_remarks_json` for `amneziawg` **or** document streambase manual cleanup — prefer adding legacy remarks: `awg-spike-443` and current HY2 flag remark already covered.

`env.bash`: normalize `UDP443_BACKEND` / port / derived flags like installer (share logic duplication acceptable if small; or source same rules).

- [ ] **Step 4: Tests PASS + commit**

```powershell
git add docker-proxy/3x-ui/scripts/lib/*.bash tests/3x-ui-scripts/test_libs.bash
git commit -m "feat(3x-ui): amneziawg desired_state and managed inbound delete"
```

---

### Task 5: AfterStart orchestration + UDP wait + AWG client

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/01_AfterStart/3x-ui-upd.sh`
- Modify: `docker-proxy/3x-ui/scripts/lib/xray_runtime.bash`
- Modify: `docker-proxy/3x-ui/scripts/lib/inbound_runtime.bash` (client ensure)
- Modify: `docker-proxy/3x-ui/scripts/lib/sub_admin_routing.bash` (remark pattern: add `amneziawg`, keep omitting HY2 from clash discovery when disabled)
- Test: `tests/3x-ui-scripts/test_libs.bash`

**Interfaces:**
- Consumes: `UDP443_BACKEND` / derived enables; helpers from Task 4
- Produces: AfterStart path that ensures active backend only

- [ ] **Step 1: Failing tests for orchestration helpers**

- When `UDP443_BACKEND=amneziawg`: wait path expects AWG UDP, not HY2.
- `ensure_amneziawg_client` plan-mode attaches/creates client via `xui_add_client` shape from spike (`client` + `inboundIds`).
- Remark allowlist includes `amneziawg`.

- [ ] **Step 2: Implement `3x-ui-upd.sh` branch**

Pseudo-order after vision/xhttp/grpc:

```bash
udp_backend=${UDP443_BACKEND:-}
# if empty, derive from ENABLE_* for container-only runs
amneziawg_id=""
hysteria2_id=""
case "$udp_backend" in
amneziawg)
	delete_managed_inbound_kind hysteria2 "$desired"
	ensure_inbound amneziawg "$desired"
	amneziawg_id=$ENSURE_INBOUND_ID
	ensure_amneziawg_client "$amneziawg_id" "$desired"
	;;
hysteria2)
	delete_managed_inbound_kind amneziawg "$desired"
	ensure_inbound hysteria2 "$desired"
	hysteria2_id=$ENSURE_INBOUND_ID
	ensure_hysteria2_client "$hysteria2_id" "$desired"
	;;
off)
	delete_managed_inbound_kind amneziawg "$desired"
	delete_managed_inbound_kind hysteria2 "$desired"
	;;
*)
	die "UDP443_BACKEND invalid: $udp_backend"
	;;
esac
# shared client: pass hysteria2_id only when non-empty (existing signature);
# do not force AWG into shared VLESS client attach list.
```

`ensure_amneziawg_client`: if no client on inbound, `POST /panel/api/clients/add` with email from desired (e.g. `${shared}-amneziawg` or dedicated `CLIENT_EMAIL_AMNEZIAWG`), `inboundIds:[id]`. If client exists, preserve.

- [ ] **Step 3: UDP wait in `xray_runtime.bash`**

```bash
case "${UDP443_BACKEND:-}" in
amneziawg)
	# wait PORT_LOCAL_UDP443 for amneziawg present
	;;
hysteria2)
	# existing HY2 wait using PORT_LOCAL_UDP443
	;;
off) ;; # skip
esac
```

Replace `PORT_LOCAL_HYSTERIA` reads with `PORT_LOCAL_UDP443` fallback chain.

- [ ] **Step 4: Clash remark filter**

Update `sub_admin_routing.bash` pattern to include `amneziawg` slug; HY2 only when backend is hysteria2 (existing ENABLE gate).

- [ ] **Step 5: Tests PASS + commit**

```powershell
git add docker-proxy/3x-ui/scripts/01_AfterStart/3x-ui-upd.sh docker-proxy/3x-ui/scripts/lib/xray_runtime.bash docker-proxy/3x-ui/scripts/lib/inbound_runtime.bash docker-proxy/3x-ui/scripts/lib/sub_admin_routing.bash tests/3x-ui-scripts/test_libs.bash
git commit -m "feat(3x-ui): AfterStart UDP443 backend ensure/delete and AWG client"
```

---

### Task 6: Streambase live verification

**Files:**
- Create (tracked evidence): `awg-spike-evidence/udp443-backend-live.md` **or** new `awg-managed-evidence/live.md` (prefer `awg-spike-evidence/` only if continuing that folder; otherwise `docs/` + `git add -f` / small `udp443-evidence/live.md`)
- Local only: sync scripts via existing project sync helper if present (`tmp/sync-streambase.sh`)

**Interfaces:**
- Consumes: merged code on `feat/udp443-backend-awg`
- Produces: sanitized live log; AWG working; HY2 absent from 443

- [ ] **Step 1: Set server env**

On streambase `compose.d/.env` and/or `3x-ui/3x-ui.env`:

```bash
UDP443_BACKEND=amneziawg
PORT_LOCAL_UDP443=443
# optional: remove ENABLE_HYSTERIA2 or set false; resolver must yield amneziawg
```

- [ ] **Step 2: Sync scripts + recreate/restart `3x-ui`**

Use project sync path (PowerShell/scp/rsync as established). Then:

```bash
ssh -o BatchMode=yes vps-vdsok-streambase
# recreate or restart 3x-ui so AfterStart runs
```

- [ ] **Step 3: Verify panel DB + listener**

```bash
docker exec 3x-ui sqlite3 /etc/x-ui/x-ui.db \
  "SELECT id,remark,port,protocol,enable FROM inbounds ORDER BY id;"
ss -ulnp | grep ':443'
```

Expected: managed AWG on 443 enable=1; no HY2 on 443; spike HY2 on 5443 deleted or absent if managed remarks matched; spike `awg-spike-443` reconciled or replaced by managed remark.

- [ ] **Step 4: Client smoke**

Phone QR and/or WSL conf (fix booleans `true`→`on` if using awg-quick). Handshake + short HTTPS check.

- [ ] **Step 5: Optional switch test**

Set `UDP443_BACKEND=hysteria2`, restart AfterStart path, confirm AWG deleted and HY2 on 443; switch back to `amneziawg`.

- [ ] **Step 6: Write sanitized evidence + commit**

```powershell
git add udp443-evidence/live.md
# or awg-spike-evidence/udp443-backend-live.md
git commit -m "docs(udp443): streambase live verification for managed AWG backend"
```

- [ ] **Step 7: Stop — do not merge until user asks**

---

## Self-Review (plan author)

1. **Spec coverage:** Selector, port rename, delete inactive, desired_state AWG, AfterStart, templates/tests, streambase live — Tasks 1–6. Clash non-blocker noted in Task 5. Kernel/park/second-port excluded.
2. **Placeholders:** None intentional; legacy spike remark handling specified.
3. **Consistency:** `UDP443_BACKEND` / `PORT_LOCAL_UDP443` / derived enables used throughout; delete via `inbounds/del/{id}`.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-11-08-udp443-backend-awg.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks  
2. **Inline Execution** — this session with executing-plans and checkpoints  

Which approach?
