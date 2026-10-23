# Arcane path-prefix ops

## Layout
- UI: `https://$WEBDOMAIN/$URI_ARCANE/` (Basic + Arcane login)
- Forced root (no upstream subpath): `/_app`, `/api` (prio 900), PWA helpers, SPA redirects
- Lampac keeps `/api/v1.0` and `/api/v2.0` at prio 910
- Homepage NextAuth only: `/api/auth/signin|signout|session|csrf|providers|error|_log|callback` (prio 949). Do **not** use broad `PathPrefix(/api/auth)` — that steals Arcane `/api/auth/login|me|…` and causes a second Basic Auth (realm Homepage).

## After bumping Arcane image
1. Pin new digest in `docker-proxy/compose.d/07-arcane.yml`.
2. Pull one `/_app` chunk from the new image behind Traefik; confirm semantic rewrite still matches (`startsWith(\`${t}/`)` guard and dashboard signature). Update `arcane.yml` only if shapes changed.
3. Run `bash tests/arcane/run.sh` locally.
4. Deploy compose Arcane + ensure `traefik/dynamic/arcane.yml` synced; recreate Traefik only if file provider stale.
5. On host: `bash tests/arcane/probe-live.sh` (or copy from repo).
6. Manual: Basic -> login form -> dashboard.

## Rollback
- Revert compose digest + `arcane.yml` on branch `fix/arcane-path-prefix-hardening`.
- Do not open a PR from this playbook.

## Never
- Put `{{` / `}}` in comments inside Traefik-templated YAML under `traefik/dynamic/`.
- Key JS rewrites on minified names.
