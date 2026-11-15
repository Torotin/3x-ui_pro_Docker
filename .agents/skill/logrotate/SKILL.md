---
name: logrotate
description: Use when editing or operating logrotate in 3x-ui_pro_Docker, including 02-logrotate.yml, docker-proxy/_logs rotation policy, logrotate-status volume, cron cadence, health, or restarts.
---

# Logrotate

Use this skill for the stack log rotation sidecar.

## Official documentation

- Image/docs: https://github.com/blacklabelops/logrotate
- Live policy: `docker-proxy/compose.d/02-logrotate.yml` and `docker-proxy/_logs`

## First Steps

1. Read [../_shared/project-conventions.md](../_shared/project-conventions.md).
2. Inspect the dirty worktree before edits:
   ```bash
   git status --short
   ```
3. Treat `docker-proxy/compose.d/02-logrotate.yml` as the live source of truth.

## Ownership

Own:
- `docker-proxy/compose.d/02-logrotate.yml`
- Rotation policy for `docker-proxy/_logs`
- `logrotate-status` volume expectations
- Logrotate container inventory and restart guidance

Coordinate with service-specific skills before changing where a service writes logs.

## Core Rules

- Keep the log source mounted as `../_logs:/logs:rw`.
- Keep logrotate state in the named `logrotate-status` volume.
- The current policy runs hourly, rotates `log` and `prev.log`, keeps 10 copies, and writes cron/logrotate logs under `/logs/_logrotate`.
- Do not point this sidecar at Docker JSON logs or service data directories; it owns file logs under `docker-proxy/_logs`.
- Keep the container logging driver capped to avoid the rotator's own logs growing without bounds.

## Health and Restart

```bash
docker-proxy/compose.d/run-compose.sh validate
docker-proxy/compose.d/run-compose.sh restart logrotate
docker-proxy/compose.d/run-compose.sh logs logrotate
```

There is no app-level Traefik route for logrotate; issues are usually compose, volume, cron, or file permission problems.

## Validation

```bash
docker-proxy/compose.d/run-compose.sh validate
git diff --check
```
