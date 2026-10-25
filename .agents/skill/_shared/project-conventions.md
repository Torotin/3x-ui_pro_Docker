# Project conventions

## Locations

- Local repo: this git checkout (Windows or Linux path may vary)
- Installer root on server: `/opt/script`
- Server stack root: `/opt/docker-proxy`

Server SSH host/user/port/key are runtime inputs. Do not treat prior chat values as durable context.

## Editing rules

- Preserve unrelated dirty worktree changes; never revert them without an explicit request.
- Keep changes scoped; avoid broad Traefik/Compose edits unless requested.
- Local installer development must be mock-only: never run real `apt`, `docker`, `ufw`, `iptables`, `systemctl`, `sshd`, `modprobe`, `sysctl -p`, `useradd`, `chpasswd`, or write under `/etc`, `/opt`, `/var/lib` locally.
- Prefer LF line endings.

## Source of truth

- `docker-proxy/lampac/`: local master; server is sync target.
- `script/`: local master for installer; server `/opt/script` is deploy target.
- 3x-ui scripts in repo sync to `/opt/docker-proxy/3x-ui/scripts`.
- If a skill disagrees with `compose.d` / `script` / service trees, **code wins** — update the skill immediately after the fix.

## Skill maintenance (required)

After **successful** introduction of a new compose service, a material change to an existing service, a new installer module, or an ownership/path change:

1. Update the matching skill(s) **in the same change set**.
2. New service → create `.agents/skill/<name>/` and add a row to the `3x-ui-pro-docker` router map.
3. Removed/disabled service → mark out-of-scope in router + skill; do not leave as active guidance.
4. Do not revive remnants via skills (`sub-json-processor`, removed `caddy/subs`, `dockcheck`, `warp`, `dozzle`, `watchtower`, legacy `torproxy`).
5. Do not require or edit personal global skills for this project (except the one-time deletion of the old monolith during migration).
6. Public Traefik Host/Path/`URI_*` label changes in `compose.d` → update the owning thick skill **and** the `compose-stack` route index in the same change set.
7. `torotin/*` image contract changes → update AutoDockerBuilder `bin/<project>/README.md` first; update this repo's skill only for stack consumption deltas (peers, published ports, env overrides), not a full env-table copy.
8. Skills must include `## Official documentation` (except `_shared`). Prefer upstream product docs + AutoDockerBuilder image READMEs over memory.

## Live server caution

Avoid live server mutation unless the user asks. Prefer local mock/static validation first, then provide exact sync/restart commands.
