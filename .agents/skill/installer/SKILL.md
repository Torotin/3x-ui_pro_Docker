---
name: installer
description: Use when operating or editing the 3x-ui_pro_Docker Debian/Ubuntu installer CLI, script modules, host DNSCrypt, doctor, wizard, run, self-update, uninstall, installer templates, or mock installer tests.
---

# Installer

Use this skill for `script/`: the Debian/Ubuntu installer CLI, host bootstrap modules, installer templates, and mock installer tests.

The installer renders telemt, mihomo, and lampac config templates from installer assets; ongoing runtime configuration and service behavior stay with the `telemt`, `mihomo`, and `lampac` skills.

## Official documentation

- This repository `script/` and README — installer CLI, doctor, wizard, uninstall
- Image rebuilds for stack `torotin/*` images: https://github.com/Torotin/AutoDockerBuilder
- Host DNSCrypt (if changing doctor/wizard DNS modules): https://www.dnscrypt.org/ / dnscrypt-proxy project docs

Installer renders templates; runtime ownership of telemt/mihomo/lampac stays with those skills.

## First Steps

1. Read [../_shared/project-conventions.md](../_shared/project-conventions.md).
2. Read [references/installer.md](references/installer.md) before changing installer behavior or docs.
3. Inspect the dirty worktree before edits:
   ```bash
   git status --short
   ```

## Public Commands

- `script/install.sh doctor [host|stack] [--verbose] [--strict]`
- `script/install.sh wizard`
- `script/install.sh run <step...> [--apply] [--yes]`
- `script/install.sh self-update [--branch <branch>] [--check] [--yes] [--force]`
- `script/install.sh uninstall --plan|--apply --yes [--purge-*]`

Current run steps are `dnscrypt apt env docker user firewall ssh network compose final uninstall`.

## Safety

Local installer development is mock-only. Do not run real `apt`, `docker`, `ufw`, `iptables`, `systemctl`, `sshd`, `modprobe`, `sysctl -p`, `useradd`, `chpasswd`, or write under `/etc`, `/opt`, or `/var/lib` locally.

## Validation

Use installer-scoped checks before claiming completion:

```bash
bash tests/install-scripts/run.sh
bash -n script/install.sh script/modules/*.sh script/check/*.sh
shellcheck -x -S warning script/install.sh script/modules/*.sh script/check/*.sh
git diff --check
```
