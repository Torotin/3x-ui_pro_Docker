# ReadME.md UDP443 AWG Actualize Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surgically update root `ReadME.md` so the operator guide documents AmneziaWG as the default UDP443 backend, matching the approved design spec.

**Architecture:** In-place edits only to listed sections of `ReadME.md`. No code, wizard, or env-default changes. Verification is manual `rg` acceptance checks from the spec (no README unit tests).

**Tech Stack:** Markdown (`ReadME.md`); design source `docs/superpowers/specs/2026-11-13-readme-actualize-design.md`.

## Global Constraints

- Scope: medium surgical update; file name stays `ReadME.md`.
- Source of truth: runtime / live rollout — `UDP443_BACKEND=amneziawg` default path.
- HY2: opt-in only (`UDP443_BACKEND=hysteria2`), 1–2 lines max; no migration/canary docs.
- Exactly one wizard-legacy caveat (submenu still shows `ENABLE_HYSTERIA2`).
- Host `443/udp` publish + UFW always remain documented as always-on.
- No secrets, fleet hostnames, or subscription IDs.
- Do not edit `script/modules/01_menu.sh`, `02_env.sh`, or `3x-ui.env` in this plan.
- Installer wipe note must mention ≥ `0.7.6` socket→unmount→rm order.

**Spec:** `docs/superpowers/specs/2026-11-13-readme-actualize-design.md`

## File map

| File | Responsibility |
|------|----------------|
| `ReadME.md` | Sole implementation target — operator guide |
| `docs/superpowers/specs/2026-11-13-readme-actualize-design.md` | Already committed; read-only during implementation |
| `docs/superpowers/plans/2026-11-13-readme-actualize.md` | This plan |

---

### Task 1: Batch example + feature toggles + wizard caveat

**Files:**
- Modify: `ReadME.md` (sections «Быстрый старт — batch», «Feature toggles», wizard submenu bullets)
- Test: manual `rg` on `ReadME.md`

**Interfaces:**
- Consumes: canonical defaults from spec (`UDP443_BACKEND=amneziawg`, aligned ENABLE flags, HY2 opt-in comment)
- Produces: batch block and toggles table that later tasks must not reintroduce as HY2-default

- [ ] **Step 1: Baseline failing check (defaults still HY2)**

Run:

```bash
rg -n 'ENABLE_HYSTERIA2=true|ENABLE_HYSTERIA2 \| `true`|Hysteria2 inbound: default' ReadME.md
```

Expected: matches in batch export (~line 124), toggles table (~189), and «Что разворачивается» (~360) — proves work remains.

- [ ] **Step 2: Replace batch exports**

In `ReadME.md` «Быстрый старт — batch», replace:

```bash
export ENABLE_LAMPAC=false
export ENABLE_TELEMT=false
export ENABLE_MIHOMO=false
export ENABLE_HYSTERIA2=true
export ENABLE_VLESS_GRPC=false
```

with:

```bash
export ENABLE_LAMPAC=false
export ENABLE_TELEMT=false
export ENABLE_MIHOMO=false
export UDP443_BACKEND=amneziawg
export ENABLE_AMNEZIAWG=true
export ENABLE_HYSTERIA2=false
export ENABLE_VLESS_GRPC=false
# Opt-in Hysteria2 instead of AWG: UDP443_BACKEND=hysteria2
```

- [ ] **Step 3: Replace feature toggles table + wizard note**

Replace the toggles table rows for HY2 with:

| Переменная | Default | Эффект |
|------------|---------|--------|
| `ENABLE_LAMPAC` | `false` | Compose fragment [`14-lampac.yml`](docker-proxy/compose.d/14-lampac.yml) |
| `ENABLE_TELEMT` | `false` | Compose fragment [`15-telemt.yml`](docker-proxy/compose.d/15-telemt.yml) + Vision/REALITY fallback |
| `ENABLE_MIHOMO` | `false` | Compose fragment [`16-mihomo.yml`](docker-proxy/compose.d/16-mihomo.yml) |
| `UDP443_BACKEND` | `amneziawg` | UDP443 Xray inbound: `amneziawg` \| `hysteria2` \| `off` (**не** host publish/UFW) |
| `ENABLE_AMNEZIAWG` / `ENABLE_HYSTERIA2` | derived | Согласуются с `UDP443_BACKEND` на managed runtime; не держат publish `443/udp` |
| `ENABLE_VLESS_GRPC` | `false` | VLESS gRPC inbound в Xray (не отдельный compose-сервис) |

Keep wizard submenu list as-is (`1`…`5`), then **immediately after** those two bullets add **exactly one** caveat paragraph:

> Note: wizard submenu still toggles legacy `ENABLE_HYSTERIA2`; for the current default path set `UDP443_BACKEND=amneziawg` (and aligned flags) in env / compose `.env`. Wizard alignment is a separate follow-up.

- [ ] **Step 4: Verify Task 1**

Run:

```bash
rg -n 'UDP443_BACKEND=amneziawg' ReadME.md
rg -n 'ENABLE_HYSTERIA2=true' ReadME.md
rg -n 'wizard submenu still toggles legacy' ReadME.md
```

Expected: first command ≥1 hit in batch; second has **no** hits in the batch block (table must not show `` `true` `` as HY2 default); third exactly 1 hit.

- [ ] **Step 5: Commit**

```bash
git add -f ReadME.md
git commit -m "$(cat <<'EOF'
docs(readme): set UDP443_BACKEND=amneziawg in batch and toggles

Align fresh-install examples with the runtime AWG default and note
the legacy wizard HY2 toggle in one line.
EOF
)"
```

Note: if `docs/` ignore affects nothing for `ReadME.md`, plain `git add ReadME.md` is enough.

---

### Task 2: Ports section + ASCII + Mermaid captions

**Files:**
- Modify: `ReadME.md` (sections «Публичные порты и маршрутизация», both ASCII blocks, Mermaid captions)
- Test: manual `rg`

**Interfaces:**
- Consumes: Task 1 language (`UDP443_BACKEND`, AmneziaWG default)
- Produces: routing diagrams that Task 3 troubleshooting must match

- [ ] **Step 1: Update ports bullet list**

Replace the bullet:

```markdown
- `ENABLE_HYSTERIA2` включает inbound в Xray desired state; **не** убирает host `443/udp` mapping и UFW.
```

with:

```markdown
- `UDP443_BACKEND` выбирает inbound на `443/udp` в Xray (default `amneziawg`); host mapping в [`12-3x-ui.yml`](docker-proxy/compose.d/12-3x-ui.yml) (`PORT_LOCAL_UDP443`) и UFW `443/udp` — **всегда**, независимо от backend.
```

Keep the Vision/Traefik publish bullets unchanged.

- [ ] **Step 2: Update ASCII Telemt=true block**

Replace the UDP lines:

```text
client --443/udp---------> Xray Hysteria2 inbound
                           (host map+UFW always; inbound if ENABLE_HYSTERIA2=true)
```

with:

```text
client --443/udp---------> Xray AmneziaWG inbound (default)
                           (host map+UFW always; backend=UDP443_BACKEND)
```

- [ ] **Step 3: Update ASCII Telemt=false block**

Replace:

```text
client --443/udp---------> Xray Hysteria2 (как выше)
```

with:

```text
client --443/udp---------> Xray AmneziaWG (default; как выше)
```

- [ ] **Step 4: Update Mermaid captions only**

Above both Mermaid diagrams, ensure the caption states that `443/tcp` and `443/udp` share container `3x-ui` (`Xray3xui`), and that `443_udp` is the UDP443 backend (**default AmneziaWG**). Do **not** rename Mermaid node ids.

Example caption (Telemt=true):

```markdown
`443/tcp` и `443/udp` — один контейнер `3x-ui` (узел `Xray3xui`). `443_udp` = UDP443 backend (default AmneziaWG).
```

- [ ] **Step 5: Verify Task 2**

Run:

```bash
rg -n 'Xray Hysteria2' ReadME.md
rg -n 'AmneziaWG' ReadME.md
rg -n 'UDP443_BACKEND' ReadME.md
```

Expected: no `Xray Hysteria2` in ASCII blocks; `AmneziaWG` present in both ASCII paths; `UDP443_BACKEND` present in ports section.

- [ ] **Step 6: Commit**

```bash
git add ReadME.md
git commit -m "$(cat <<'EOF'
docs(readme): document AmneziaWG on 443/udp diagrams

Update ports bullets and ASCII/Mermaid captions for the UDP443
AWG default without renaming diagram nodes.
EOF
)"
```

---

### Task 3: Deployed services + docker wipe + troubleshooting #10 + acceptance

**Files:**
- Modify: `ReadME.md` (sections «Что разворачивается», «Безопасность / destructive flags», Troubleshooting item 10)
- Test: full acceptance `rg` from spec

**Interfaces:**
- Consumes: wording from Tasks 1–2
- Produces: finished `ReadME.md` meeting all acceptance criteria

- [ ] **Step 1: Replace «Что разворачивается» HY2 sentence**

Replace:

```markdown
Hysteria2 inbound: default **on** (`ENABLE_HYSTERIA2=true`). Host `443/udp` mapping + UFW — **всегда**, независимо от toggle.
```

with:

```markdown
UDP443 inbound: default **AmneziaWG** (`UDP443_BACKEND=amneziawg`). Host `443/udp` mapping + UFW — **всегда**. Opt-in Hysteria2: `UDP443_BACKEND=hysteria2`.
```

- [ ] **Step 2: Expand docker wipe bullet**

Replace:

```markdown
- Docker wipe/reinstall: `run docker --destroy-docker-data`.
```

with:

```markdown
- Docker wipe/reinstall: `run docker --destroy-docker-data` (installer ≥ 0.7.6: stop `docker.socket` → `docker` → `containerd`, lazy-unmount `/var/lib/docker` and `/var/lib/containerd`, then `rm -rf` — avoids busy `overlay2/*/merged`).
```

- [ ] **Step 3: Rewrite troubleshooting #10**

Replace item 10 with:

```markdown
10. **`443/udp` открыт, AmneziaWG / UDP443 клиенты не работают**  
    Проверка: `UDP443_BACKEND` в `$INSTALL_ROOT/compose.d/.env` (ожидание default `amneziawg`); inbound `amneziawg` в панели 3x-ui; publish/UFW ≠ наличие inbound.  
    Действие: выставить `UDP443_BACKEND=amneziawg` (и согласованные `ENABLE_AMNEZIAWG=true` / `ENABLE_HYSTERIA2=false`), `run env`, затем `run compose` / restart `3x-ui`. Для Hysteria2 вместо AWG: `UDP443_BACKEND=hysteria2`.
```

- [ ] **Step 4: Full acceptance grep**

Run:

```bash
rg -n 'ENABLE_HYSTERIA2=true|Hysteria2 inbound: default' ReadME.md
rg -n 'wizard submenu still toggles legacy' ReadME.md
rg -n 'UDP443_BACKEND=amneziawg' ReadME.md
rg -n '0\.7\.6' ReadME.md
rg -n 'Xray Hysteria2' ReadME.md
```

Expected:

- First: **no** guide-default hits (caveat may mention `ENABLE_HYSTERIA2` by name without `=true` as default path).
- Second: exactly **1** hit.
- Third: ≥1 hit (batch).
- Fourth: ≥1 hit (docker wipe).
- Fifth: **0** hits in ASCII.

Also skim `git diff ReadME.md` — only sections listed in the spec; no unrelated rewrites.

- [ ] **Step 5: Update spec status line (optional, same commit)**

In `docs/superpowers/specs/2026-11-13-readme-actualize-design.md`, set:

```markdown
Status: implemented (see plan docs/superpowers/plans/2026-11-13-readme-actualize.md)
```

Force-add if needed: `git add -f docs/superpowers/specs/2026-11-13-readme-actualize-design.md`.

- [ ] **Step 6: Commit**

```bash
git add ReadME.md
git add -f docs/superpowers/specs/2026-11-13-readme-actualize-design.md
git commit -m "$(cat <<'EOF'
docs(readme): finish AWG default path and docker wipe notes

Update deployed-services blurb, destructive docker wipe order, and
troubleshooting #10; mark the README actualize spec implemented.
EOF
)"
```

---

## Plan self-review

1. **Spec coverage:** Batch, toggles, wizard caveat, ports, ASCII, Mermaid captions, deployed services, docker wipe, troubleshooting #10, acceptance grep — each mapped to a step. Non-goals (wizard code, migration, rename) excluded.
2. **Placeholders:** None; replacement text is concrete.
3. **Consistency:** `UDP443_BACKEND=amneziawg` / AmneziaWG naming used across all three tasks; HY2 only as opt-in.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-11-13-readme-actualize.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks  
**2. Inline Execution** — execute tasks in this session with executing-plans checkpoints  

Which approach?
