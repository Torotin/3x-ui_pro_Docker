# 3x-ui Python runtime (`xui_runtime`)

Deterministic client `subId` when `CLIENT_SUB_ID` is unset (Task 6 parity with bash):

`sha256(f"{WEBDOMAIN or 'localhost'}:{shared_email}")[:16]` via `env.deterministic_sub_id`.

MODE `check` and `plan` reuse the same env loading and IDs as `apply` so dry-runs match applies.