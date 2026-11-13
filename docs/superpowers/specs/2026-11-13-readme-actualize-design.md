# Design: Actualize ReadME.md (UDP443 / AWG operator path)

Date: 2026-11-13  
Status: approved-for-spec (pending user review of this file)  
Branch context: `dev` (includes `feat/udp443-backend-awg` merge)

## Goal

Update root [`ReadME.md`](../../../ReadME.md) so the operator guide matches the **current runtime / rollout** model: UDP443 default backend is **AmneziaWG**, not Hysteria2. Keep structure; do not rewrite the whole document.

## Decisions (from brainstorming)

| Topic | Choice |
|-------|--------|
| Scope | **Medium (B)** — outdated facts + light structure for UDP443 model |
| UDP443 depth | **Operator minimum (C)** — default AWG + short HY2 opt-in; no migration/canary |
| Source of truth | **Runtime / live rollout (A)** — AWG default; wizard legacy noted in one line |
| Edit style | **Surgical replace** in place |
| Filename | Keep `ReadME.md` (no rename to `README.md`) |

## Non-goals

- Full README rewrite
- HY2→AWG migration playbook, AWG profile/canary, prizrak evidence
- Code changes to wizard (`01_menu.sh`), `02_env.sh`, or `3x-ui.env` defaults
- Host-specific domains, subIds, secrets
- Renaming `ReadME.md`

## Canonical operator defaults (to document)

```bash
UDP443_BACKEND=amneziawg
# Derived / aligned flags on managed hosts:
#   ENABLE_AMNEZIAWG=true
#   ENABLE_HYSTERIA2=false
# Opt-in Hysteria2:
#   UDP443_BACKEND=hysteria2
```

Facts that stay true:

- Host publish `443/udp` in `12-3x-ui.yml` and UFW `443/udp` are **always** present.
- Which Xray inbound owns UDP443 is selected by `UDP443_BACKEND` (default AmneziaWG).

Wizard caveat (exactly one note in Feature toggles / wizard submenu):

> Wizard submenu still exposes legacy `ENABLE_HYSTERIA2`; for the current default path use `UDP443_BACKEND` / compose `.env` after rollout. Wizard alignment is a separate follow-up.

## Sections to change

| Section | Change |
|---------|--------|
| Быстрый старт — batch | Replace `ENABLE_HYSTERIA2=true` with `UDP443_BACKEND=amneziawg` (+ aligned flags); one comment line for HY2 opt-in |
| Feature toggles table | Add `UDP443_BACKEND` (default `amneziawg`); treat `ENABLE_HYSTERIA2` / `ENABLE_AMNEZIAWG` as compatibility / derived; remove “HY2 default on” as primary fact |
| Wizard submenu (`t`) | Keep items 1–5 as implemented; add the one-line legacy caveat |
| Публичные порты | State that `443/udp` publish+UFW always; inbound = active UDP443 backend (default AmneziaWG) |
| ASCII (both Telemt on/off) | `443/udp` → AmneziaWG (default), not Hysteria2 |
| Mermaid | Caption: `443_udp` = UDP443 backend (default AWG); keep node ids |
| Что разворачивается | Replace “Hysteria2 inbound default on” with AWG default; HY2 as opt-in |
| Безопасность / destructive | Under docker wipe: stop `docker.socket` → `docker` → `containerd`, lazy-unmount data dirs, then `rm -rf` (installer ≥ 0.7.6) |
| Troubleshooting #10 | Rewrite for AWG (`UDP443_BACKEND` / amneziawg inbound); short how-to switch to HY2 |

## Sections not to change

TOC structure (unless a new anchor is unavoidable), doctor, self-update, uninstall body, Telemt/Lampac/Arcane detail, VPS sizing table, DeepWiki badges, local mock-test policy (except if a sentence falsely asserts HY2 default).

## Docker wipe note (wording intent)

Destructive docker reinstall (`run docker --destroy-docker-data`) must document that installer ≥ **0.7.6** stops `docker.socket` before `docker`/`containerd`, lazy-unmounts `/var/lib/docker` and `/var/lib/containerd`, then removes those trees — avoiding busy `overlay2/*/merged`.

## Acceptance criteria

1. README no longer presents Hysteria2 as the primary/default UDP443 path.
2. Batch example, toggles table, ports, ASCII, and troubleshooting #10 agree on AWG default.
3. HY2 opt-in is documented in 1–2 lines (not a migration guide).
4. Exactly one wizard-legacy caveat.
5. No secrets, hostnames of private fleets, or subscription IDs.
6. File remains `ReadME.md`; diff limited to listed sections.
7. Manual check: `rg -n 'ENABLE_HYSTERIA2=true|Hysteria2 inbound: default' ReadME.md` should not hit guide defaults (legacy caveat may still mention the name).

## Verification

- No automated README tests.
- Reviewer: read the diff; run the grep in acceptance #7.
- Confirm `script/VERSION` reference remains the authority for installer version; CHANGELOG note for 0.7.6 already exists.

## Implementation follow-up

After this spec is approved by the user, create an implementation plan via `writing-plans` and edit only `ReadME.md` (+ this spec already committed). Wizard/env default alignment remains out of scope unless a new task is opened.
