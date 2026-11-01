# Telemt `config.toml` live merge (existing installs)

Use when refreshing `script/template/telemt.config.toml.template` on a host that already has panel-created users and WEB profiles. **Do not** blind-overwrite `/opt/docker-proxy/telemt/config/config.toml`.

## Paths (typical server)

| Item | Path |
|---|---|
| Live config | `/opt/docker-proxy/telemt/config/config.toml` |
| Compose env | `/opt/docker-proxy/compose.d/.env` |

## Steps

1. **Backup** — `config.toml.bak-$(date +%Y%m%d%H%M%S)`
2. **Render** new template-owned file to `config.toml.new` (installer `env` or `envsubst` on template)
3. **Merge from backup**
   - Entire `[access.users]` — union: keep all users from backup
   - `[[web.vhosts.profiles]]` from backup not present in `.new` (panel-added profiles; skip duplicate WEB bootstrap user)
   - Optional: panel-expanded `[web.limits]`, `[web.timeouts]`, `[web.debug]` if missing in `.new`
4. **Validate** — `telemt healthcheck` (config load must succeed); restart `telemt`
5. **Rollback** — restore backup and restart

Full Python merge script and aralas-oriented commands: repository `.tmp/task3-merge-procedure.md`.

## Post-merge checklist

- `use_middle_proxy = false`
- Socks → `3x-ui:${PORT_LOCAL_XRAY_MIXED}` enabled; direct upstream disabled
- WEB: `secret_mode = "dd"`, `carrier = "https"`, decoy upstream set
- `[censorship]` mask → `traefik:4443` PP1
- All pre-cutover `[access.users]` entries retained
