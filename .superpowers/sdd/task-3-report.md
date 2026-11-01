# Task 3 Report: JSON subJsonRules + clear subJsonRoutingRules

**Branch:** `feat/client-sub-connection-policies`  
**Status:** Complete

## Deliverables

- `build_admin_sub_json_rules <webdomain>` emits an Xray rules array: admin `full:` FQDNs to `proxy`, then terminal `tcp,udp` to `direct`.
- `build_admin_sub_json_routing_rules` is intentionally deprecated for desired apply and now returns empty.
- `ensure_panel_settings` honors `CLEAR_SUB_JSON_ROUTING_RULES=true` by comparing desired `.subJsonRoutingRules=""` and forcing the empty string into the update body.
- `desired_panel_keys` still includes `subJsonRules`, `subJsonRoutingRules`, and `subJsonDns`.

## TDD Evidence

### RED

After adding the force-clear and JSON-rule tests, the full harness failed on the expected missing clear behavior:

```text
$ bash tests/3x-ui-scripts/run.sh
FAIL: CLEAR_SUB_JSON_ROUTING_RULES must force empty subJsonRoutingRules into update body (expected '', got '{"RouteOrder":"proxy-direct-block"}')
```

### GREEN

After implementation:

```text
$ bash tests/3x-ui-scripts/run.sh
test_download.bash: OK
test_libs.bash: OK
shfmt not installed; skipping format diff

$ git diff --check
# no output
```

IDE lints reported no errors for edited files.

## Concerns

AfterStart is not rewired in this task; Task 5 should export `subJsonRules` and `CLEAR_SUB_JSON_ROUTING_RULES=true` at runtime.

## Important Task 3 Follow-up: AfterStart Runtime Export

**Branch:** `feat/client-sub-connection-policies`

Fixed the blocking AfterStart gap:

- `3x-ui-upd.sh` now computes `subJsonRules=$(build_admin_sub_json_rules "${WEBDOMAIN}")` and exports it when non-empty.
- `subJsonDns` remains computed and exported only when non-empty.
- The runtime entrypoint no longer computes or exports deprecated `subJsonRoutingRules`.
- `CLEAR_SUB_JSON_ROUTING_RULES=true` is exported so `ensure_panel_settings` force-clears the live Happ field.
- `test_afterstart_exports_json_sub_rules_and_clears_legacy_routing` now asserts the new AfterStart contract.

TDD evidence:

```text
$ bash tests/3x-ui-scripts/test_libs.bash
FAIL: after-start must compute subJsonRules
```

Verification:

```text
$ bash tests/3x-ui-scripts/test_libs.bash
SKIP: sqlite3 unavailable for inbound flow repair test
node-alpha
test_libs.bash: OK

$ git diff --check
# no output
```
