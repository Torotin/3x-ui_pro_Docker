# Installer CLI

Use this reference when touching `script/*`, installer tests, server bootstrap, self-update, uninstall, SSH/firewall/network/Docker apply behavior, host DNSCrypt, or generated installation summary.

## Public Interface

Entrypoint: `script/install.sh`

Supported commands:
- `doctor` / `doctor host` / `doctor stack`: read-only diagnostics. `run doctor` remains an alias of bare `doctor`.
- `wizard`: interactive menu over the same step dispatcher.
- `run <step...>`: batch execution of named steps.
- `self-update --branch <branch>`: explicit script tree update from a selected branch. `--check` only reports availability; `--force` can apply even when versions match.
- `uninstall --plan|--apply --yes`: removal workflow with explicit purge flags.

Current steps:

```text
dnscrypt apt env docker user firewall ssh network compose final uninstall
```

`dnscrypt` installs host DNSCrypt/DoH through `script/modules/04_dnscrypt.sh` before `apt`, so OS package and mirror traffic can resolve through encrypted DNS on localhost port 53. It requires `--apply --yes`. By default it resolves the latest GitHub release; pin with `--version X.Y.Z` or `DNSCRYPT_VERSION`. Optional flags: `--force` and `--reconfigure`.

There is no `html` step in the current CLI or wizard.

## Directory Boundaries

- `/opt/script`: installer scripts, modules, templates, and installer state.
- `/opt/docker-proxy`: Docker Compose project root and runtime stack.

Do not collapse these directories. Installer state lives under `/opt/script/install-state`; compose state and service files live under `/opt/docker-proxy`.

## Safety Model

Local development and tests must use mocks or fake state paths only.

Never run locally during development:
- real `apt`, `docker`, `ufw`, `iptables`, `systemctl`, `sshd`, `modprobe`, `sysctl -p`, `useradd`, or `chpasswd`;
- writes under `/etc`, `/opt`, or `/var/lib`.

Host-mutating server actions require explicit flags:
- DNSCrypt host DNS: `run dnscrypt --apply --yes`.
- Firewall apply: `run firewall --apply --yes`.
- SSH apply: `run ssh --apply --yes`.
- Network/sysctl apply: `run network --apply --yes`.
- Docker wipe/reinstall: `run docker --destroy-docker-data`.
- Uninstall purge flags: explicit `--purge-*` flags. DNSCrypt is left installed unless `--purge-dnscrypt` is set.

## Wizard Contract

- Numbered menu, single-screen redraw style.
- Menu order mirrors the step flow: `dnscrypt`, `apt`, `env`, `docker`, `user`, `firewall`, `ssh`, `network`, `compose`, `final`.
- The `toggles` menu persists `ENABLE_LAMPAC`, `ENABLE_TELEMT`, `ENABLE_MIHOMO`, `ENABLE_HYSTERIA2`, and `ENABLE_VLESS_GRPC`, then can apply/render `env`.
- Step output streams online, with compose noise filtered.
- After each operation, prompt to press Enter before redrawing.
- Invalid choices must not exit the wizard.
- Wizard startup may offer `self-update` when a newer version exists on the selected branch.

## Required and Optional State

Required installer variables:
- `WEBDOMAIN`
- `USER_SSH`
- `PASS_SSH`
- `USER_WEB`
- `PASS_WEB`

Optional:
- `SSH_PBK`

SSH auth mode:
- If `SSH_PBK` is set: public-key auth is enabled and password auth is disabled.
- If `SSH_PBK` is empty: public-key auth is disabled and password auth is enabled.

Fresh installs default optional compose services to off:
- `ENABLE_LAMPAC=false`
- `ENABLE_TELEMT=false`
- `ENABLE_MIHOMO=false`

Enable them via wizard toggles or by setting the env vars before `run env`. Telemt and Mihomo templates are rendered by the installer, but runtime behavior and service ownership stay with the `telemt` and `mihomo` skills. When Telemt is off, Xray Vision/REALITY fallback targets Traefik.

## Step Notes

- `dnscrypt`: installs or reconfigures host DNSCrypt/DoH as system DNS on `127.0.0.1:53` and, for dual-stack hosts, `::1:53`. It writes DNSCrypt config, a systemd unit, systemd-resolved drop-in, and `resolv.conf`.
- `apt`: selects a working mirror, updates package lists, installs dependencies, upgrades/autoremoves, and enables unattended-upgrades timers.
- `env`: loads state, generates defaults/secrets, renders installer and compose env files, renders Telemt and Mihomo config templates when enabled, and applies Lampac JacRed secrets when Lampac is enabled and present.
- `docker`: prepares Docker and project Docker resources. Destructive Docker data removal must stay behind `--destroy-docker-data`.
- `user`: creates or updates the service SSH user.
- `firewall`, `ssh`, `network`: mutate host policy only with `--apply --yes`.
- `compose`: ensures/syncs compose files as needed, ensures Docker networks, then runs `run-compose.sh validate` and `run-compose.sh up`.
- `final`: renders `script/template/install.summary.template` to `$INSTALL_STATE_DIR/install.summary` and prints it.
- `uninstall`: stops the compose stack by default; extra removals require explicit purge flags.

## APT Pitfall

Country mirror lists can return mid-sync mirrors with `File has unexpected size`. The `apt` step should retry with fallback mirror behavior after cleaning stale package lists rather than leaving the host stuck on a bad mirror.

## Docker Constraints

- Warn clearly before data destruction.
- Configure Docker APT repository before package install.
- Do not call Docker commands when the Docker binary is absent in a fresh-install path.
- In mock mode, repository/GPG command paths should log without executing.
- Validate generated `daemon.json` before restarting Docker.
- Optional Docker IPv6 is controlled by `DOCKER_ENABLE_IPV6`.
- Use `rm -rf -- /var/lib/docker /var/lib/containerd` only in the explicit destructive path.

## SSH Constraints

- Validate `PORT_REMOTE_SSH` is numeric and in range.
- Verify `USER_SSH` exists in real mode.
- Render `sshd_config` through a dedicated render function.
- Run `sshd -t -f <target>` before applying.
- Prefer `systemctl reload ssh`, then `reload sshd`; restart only as fallback.

## Doctor Behavior

Runtime owner: `script/modules/08_doctor.sh`.

CLI:

```text
script/install.sh doctor [--verbose] [--strict]
script/install.sh doctor host [--verbose] [--strict]
script/install.sh doctor stack [--verbose] [--strict]
```

Profiles:
- bare `doctor` -> profile `full`
- `doctor host` -> profile `host`
- `doctor stack` -> profile `stack`

Rules:
- Unknown profile/token after `doctor` is a hard error.
- `run doctor` remains an alias of bare `doctor`.
- `--verbose` prints detail OK lines.
- `--strict` makes any WARN exit 1 and footer `doctor: FAILED`.

Phase:
- `DOCTOR_PHASE` is `preinstall` or `stack_expected`; it is display/detection only.
- Detect `stack_expected` from `$INSTALL_STATE_DIR/install.summary` or successful `docker inspect traefik`.
- In mock mode, phase is always `preinstall` unless `INSTALL_MOCK_DOCTOR_PHASE=stack_expected`.
- Stack severity uses `DOCTOR_EXPECT_STACK`, not raw `DOCTOR_PHASE`.
- `DOCTOR_EXPECT_STACK=1` when phase is `stack_expected` or profile is `stack`; otherwise `0`.

Profile scope:

| Profile | Runs | Stack/container behavior |
| --- | --- | --- |
| `full` | preflight + host + stack | Stack checks skip when `DOCTOR_EXPECT_STACK=0`, run when `1` |
| `host` | preflight + host only | No container checks |
| `stack` | stack checks only | Host rows are marked SKIP; stack severity is forced |

Severity:
- FAIL always exits nonzero.
- WARN exits 0 unless `--strict`.
- Footer is `doctor: OK`, `doctor: WARN`, or `doctor: FAILED`.
- Missing installer-provided commands, DNSCrypt gaps, and APT package gaps are WARN before stack is expected and FAIL when stack is expected.
- Containers in `starting` are WARN; unhealthy or missing containers are FAIL.
- Missing `install.summary` while a live stack is detected is WARN, or FAIL only with `--strict`.

Read-only contract:
- Doctor must not install packages, restart services, write under `/etc`, or otherwise mutate host config.
- Compose validation may write logs/locks under `$INSTALL_STATE_DIR`; if that is not writable, both files must use unique `mktemp` paths under `${TMPDIR:-/tmp}`.
- Do not use fixed shared files under `/tmp`.

Fixed output order:
1. Header with `profile=<full|host|stack>` and `phase=<preinstall|stack_expected>`. Stack profile also states that it forces stack-expected severity.
2. Sections for preflight / host / stack as applicable.
3. `STEP STATUS SUMMARY NEXT` matrix for `dnscrypt apt env docker user firewall ssh network compose final`.
4. Actionable next actions.
5. Footer.

Doctor checks include OS support, command inventory, installer paths/templates including `04_dnscrypt.sh`, required state without secret values, DNSCrypt module/runtime, APT packages, Docker engine checks, compose validate, and expected containers. Optional containers are only expected when their `ENABLE_*` flag and active compose file apply. Disabled/remnant services such as `dockcheck`, `warp`, `dozzle`, `watchtower`, `sub-json-processor`, and removed `caddy/subs` are do-not-revive.

## Final Summary

The `final` step renders `script/template/install.summary.template`, writes `$INSTALL_STATE_DIR/install.summary`, and prints it. The summary may include URLs, local endpoints, generated paths, and useful commands, but must not print passwords, htpasswd hashes, CrowdSec keys, ACME data, private keys, or session cookies.

## Uninstall

`uninstall --plan` prints intended actions without applying them.

`uninstall --apply --yes` stops the compose stack. Extra removal requires explicit flags:
- `--purge-docker-data`
- `--purge-docker-engine`
- `--purge-firewall`
- `--purge-ssh`
- `--purge-network`
- `--purge-dnscrypt`
- `--remove-project-root`

DNSCrypt is intentionally kept unless `--purge-dnscrypt` is present.

## Validation

Local installer validation is mock-only:

```bash
bash tests/install-scripts/run.sh
bash -n script/install.sh script/modules/*.sh script/check/*.sh
shellcheck -x -S warning script/install.sh script/modules/*.sh script/check/*.sh
git diff --check
```

Useful server-side checks after explicit deploy/acceptance permission:

```bash
/opt/script/install.sh doctor
/opt/script/install.sh self-update --branch main --check
/opt/script/install.sh run final
```
