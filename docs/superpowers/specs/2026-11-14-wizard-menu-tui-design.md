# Design: Hybrid Wizard TUI (`whiptail` + ANSI text fallback)

Date: 2026-11-14  
Status: approved (brainstorming 1/4–4/4)  
Branch context: `dev`  
Primary file: [`script/modules/01_menu.sh`](../../../script/modules/01_menu.sh)

## Goal

Replace the flat numbered wizard list with a hybrid UI:

1. **Primary:** `whiptail` TUI (menus, yesno, inputbox, checklist, radiolist).
2. **Fallback:** improved ANSI text UI when `whiptail` is missing, stdin/stdout is not a TTY, or `WIZARD_UI=text`.

Keep full compatibility with `dispatch_step`, `00_common.sh` helpers, step logging/compose filter/ticker, and the mock installer test suite (with targeted assertion/stdin updates).

## Non-goals

- Changing step modules / `dispatch_step` semantics (except calling existing `doctor` from wizard).
- Real host mutations in local/dev tests (mock-only).
- Russian UI translation.
- New package dependencies beyond optional system `whiptail`.
- Dropping numbered step codes `0`–`9`, `t`, `x`/`q`/`quit`, or direct step names.

## Decisions (from brainstorming)

| Topic | Choice |
|-------|--------|
| UI approach | Hybrid: whiptail + ANSI text fallback |
| Toggles dirty-exit | Ask `Save changes? [y/N]` (default No) |
| Dirty-exit Yes | **save-only** (no automatic `env` / `compose`) |
| Always-yes activation | CLI only: `install.sh wizard --yes` / `-y` → `WIZARD_ASSUME_YES=1` |
| Docker wipe + `--yes` | **Never** auto-confirmed; always `force_prompt` |
| DNSCrypt + `--yes` | Auto-Yes (like apt/firewall/ssh/network) |
| Press Enter pauses + `--yes` | **Unchanged** — pauses remain |
| Features header empty | `Features: none` when all bools false **and** `UDP443_BACKEND=off` |
| Whiptail missing + `WIZARD_UI=whiptail` | Fallback to text; **one** `log WARN` at `install_wizard` start |
| USER_SSH + `--yes` | If set in state/env → silent; if empty → still `wizard_ui_input` / `read` |

## Architecture

### Entry and flags

- Entry remains `install_wizard "$@"` from `install.sh` (`wizard) install_wizard "$@" ;;`).
- Parse `--yes` / `-y` inside `01_menu.sh`; set `WIZARD_ASSUME_YES=1`.
- Update `usage()`: `install.sh wizard [--yes|-y]`.

### UI mode (`wizard_ui_mode` / `WIZARD_UI`)

| `WIZARD_UI` | Behavior |
|-------------|----------|
| `auto` (default) | whiptail only if `command -v whiptail` **and** `[[ -t 0 && -t 1 ]]` |
| `whiptail` | Prefer whiptail; if binary missing → text + single WARN at wizard start |
| `text` | Always ANSI text |

Pipe / non-TTY / typical `INSTALL_MOCK=1` tests → text, no whiptail attempts.

Whiptail window size: derive from `tput lines` / `tput cols` with safe min/max clamps.

Whiptail result capture: standard `3>&1 1>&2 2>&3` swap. Wrap calls so Cancel/Esc (`1` / `255`) do not trip `set -e` — treat as cancel/back.

### Layers (all in `01_menu.sh`)

1. **`wizard_ui_*`** — dialogs (menu, yesno, input, checklist/radiolist).
2. **`wizard_dispatch_step` / `wizard_execute_step`** — existing execution + step-state persistence.
3. **`wizard_auto_install`** — recommended chain runner.

### Confirm helper

`wizard_confirm "prompt" [force_prompt]`

- text: `prompt [y/N]` (default No).
- whiptail: `--yesno` + `--defaultno`.
- If `WIZARD_ASSUME_YES=1` and `force_prompt` is not `1` → return Yes without prompt.
- If `force_prompt=1` → always prompt (ignores `--yes`).

### Unchanged runtime

- Per-step log: `$INSTALL_STATE_DIR/wizard-last-${label}.log`
- Compose: `wizard_filter_compose_output` + ticker (`WIZARD_COMPOSE_TICKER_SECONDS`) + `ticker_pid` cleanup on INT/TERM/exit
- Feature helpers from `00_common.sh`: `install_load_state_env`, `install_normalize_bool_var`, `install_normalize_udp443_port_env`, `install_normalize_udp443_backend`, `install_state_set_env`
- `wizard_offer_self_update` (skip when `git` missing on fresh host)
- `install_require_required_env wizard` before menu

## Menu structure and step status

### Header (both UIs)

```text
3x-ui installer · wizard
Features: lampac, telemt, udp443:amneziawg
Last operation: OK env
Mode: --yes                    # only if WIZARD_ASSUME_YES=1
```

- Features lists only active optional pieces; if all four bools are false and `UDP443_BACKEND=off` → `Features: none`.
- Keep the exact phrase **`Last operation:`** (test compatibility).

### Text menu groups (codes unchanged)

```text
── Quick Actions ─────────────────────────
  a. auto      Full install (recommended path)
  t. toggles   Optional stack features
  d. doctor    System / stack diagnostics

── 1. Host & Security Preparation ────────
  [✓] 0. dnscrypt   ...
  [ ] 1. apt        ...
  [!] 4. user       ...
  [ ] 6. ssh        ...
  [ ] 5. firewall   ...
  [ ] 7. network    ...

── 2. Docker & Stack Deployment ──────────
  [✓] 2. env        ...
  [ ] 3. docker     ... (destructive)
  [ ] 8. compose    ...
  [ ] 9. final      ...

  x. Exit
Keys: 0-9 step · a/t/d · names (apt, compose) · q quit
Last operation: OK env
> 
```

Render order: clear → header → groups → Last operation → keys hint → **`> ` last**.

Badges:

- Text UI: `[✓]` / `[!]` / `[ ]` with green/red ANSI unless `NO_COLOR`.
- Whiptail labels: ASCII `[OK]` / `[FAIL]` / `[ ]` (avoid Unicode in newt).

### Step state file

- Path: `$INSTALL_STATE_DIR/wizard-steps.state`
- Lines: `step=OK` or `step=FAIL` written from `wizard_execute_step` by `rc`
- `SKIPPED` / `INVALID` update **Last operation** only; they do **not** overwrite OK/FAIL badges
- Persist across wizard sessions (no reset on `auto`)

### Input normalization (text)

Existing: `0`–`9`, `t`, step names, `x`/`q`/`quit`.  
New: `a` → `auto`, `d` → `doctor`.

### Whiptail main menu

Single `--menu` with the same tags (`a`,`t`,`d`,`0`…`9`,`x`). Summary via `--backtitle` / title. Cancel/Esc → exit wizard (same as `x`) or stay — **exit wizard** to match Escape-as-quit expectation.

## Confirmations matrix

| Step / action | Confirm? | `--yes` |
|---------------|----------|---------|
| `dnscrypt` | yes | auto-Yes |
| `apt`, `firewall`, `ssh`, `network` | yes | auto-Yes |
| `docker` (`--destroy-docker-data`) | **always** `force_prompt` | **does not** bypass |
| `env`, `compose`, `final`, `doctor` | no | — |
| `user` | no; empty `USER_SSH` → input required even under `--yes` | — |
| `auto` start screen | yes (chain list + docker wipe warning) | **skipped** (see Auto below) |
| toggles dirty-exit save | `Save changes? [y/N]` default No | auto-Yes |
| toggles `a` apply | save + env; then ask compose | compose ask auto-Yes |
| self-update offer | unchanged | not under `--yes` |
| Press Enter continue | unchanged | not under `--yes` |

## Auto install (`a` / `auto`) — canonical `--yes` + docker rule

Chain (dnscrypt **not** included):

`apt → env → docker → user → firewall → ssh → network → compose → final`

**Canonical behavior (fixed for implementation):**

1. Without `--yes`: show one start yesno listing the chain and warning that `docker` reinitializes Docker (destructive wipe). On decline → return to menu. On accept → run chain.
2. With `--yes`: **skip** the auto start screen.
3. In **both** cases, when the chain reaches `docker`, call `wizard_confirm … force_prompt=1` (docker wipe **always** asks). Decline → stop chain, mark docker skipped/not OK, return to menu.
4. Stop the chain on the first failed step (`rc != 0`).
5. Before chain: if `USER_SSH` empty, prompt for it once.

This unifies earlier wording: start-screen may be skipped under `--yes`, but docker wipe confirm is never skipped.

## Toggles

### Whiptail

1. `--checklist` for `ENABLE_LAMPAC`, `ENABLE_TELEMT`, `ENABLE_VLESS_GRPC`, `ENABLE_MIHOMO` (human-readable labels; tags = env names).
2. `--radiolist` for `UDP443_BACKEND`: `amneziawg` | `hysteria2` | `off`.
3. Cancel/Esc on either screen → no state write; back to main menu.
4. OK → `wizard_save_feature_toggles` → offer `dispatch_step env` → if env accepted/run, offer `dispatch_step compose`.
5. Parse checklist/radiolist tags with quote stripping (`tr -d '"'`) — newt/whiptail versions differ on quoting.

### Text

```text
Optional Stack Features
  1. Lampac         [ON ] / [OFF]
  2. Telemt         [ON ] / [OFF]
  3. UDP443 backend [amneziawg]     # cycle amneziawg→hysteria2→off
  4. VLESS gRPC     [ON ] / [OFF]
  5. Mihomo         [ON ] / [OFF]

  a. Save + render env (+ optional compose)
  x. Return
```

- In-memory edits + dirty flag.
- `a`: save → `wizard_execute_step env` → ask compose.
- `x`/`q` without dirty → return.
- `x`/`q` with dirty → `Save changes? [y/N]`:
  - No / empty → discard; no persist; no `env.render`.
  - Yes → **save-only** (no automatic env/compose).

### Dirty-exit stdin (tests)

Exit toggles is **`x` first**, then the save prompt consumes the next line:

- Discard path: `t\n1\nx\nn\nx\n` or `t\n1\nx\n\nx\n`  
  (**not** `t\n1\nn\nx\n` — that sends `n` into the toggle menu as an unknown item.)

## Change boundaries

| Path | Change |
|------|--------|
| `script/modules/01_menu.sh` | Main implementation |
| `script/install.sh` | usage line for `wizard [--yes\|-y]` |
| `script/CHANGELOG.md` | Wizard UX entry |
| `tests/install-scripts/test_installer_cli.bash` | Assertion/stdin updates + new cases |
| `script/modules/00_common.sh` / step modules | No semantic changes |
| `docs/superpowers/specs/2026-11-14-wizard-menu-tui-design.md` | This document |

Optional follow-up (post-implement): refresh Wizard UX Contract in installer skill reference.

## Test plan

### Existing tests — required updates

1. **`test_wizard_toggle_exit_does_not_persist_changes`**  
   Stdin: `t\n1\nx\nn\nx\n` (or empty answer instead of `n`).  
   Still asserts no `ENABLE_LAMPAC=true` persist and no `env.render`.

2. **`test_wizard_toggles_optional_feature_flags_and_renders_env`**  
   After `a`: Enter after env + explicit compose decline, e.g.  
   `t\n1\n2\n3\n4\n5\na\n\nn\nx\n`.  
   Update UI string asserts to human-readable labels / `Optional Stack Features`.  
   Keep persist/render asserts on `install.env` and compose `.env`.

3. **`test_wizard_rejects_unknown_menu_choice_without_exit`**  
   Replace `Available steps:` with a stable new marker (e.g. `Quick Actions`).

4. Prefer explicit `WIZARD_UI=text` in wizard fixtures so CI never accidentally hits whiptail.

5. Keep asserts on **`Last operation:`** phrasing.

### New mock tests

- `wizard --yes` / `-y`: apt proceeds without `y` in stdin; docker wipe still requires separate `y`.
- `a` / auto: runs chain; stops on first failure; docker always prompts (`force_prompt`).
- Dirty-exit Yes: persists toggles to state; **no** `env.render`.
- `d` / doctor: dispatches `doctor` from wizard.
- Step state: successful env writes `env=OK` to `wizard-steps.state`; badge visible in text UI stdout.
- `WIZARD_UI=text` under pipe: no whiptail invoke / no hard error.

### Out of automated scope

Full interactive whiptail journeys — manual check on a real TTY host. Text fallback is the CI contract.

## Implementation order

1. UI mode resolution + one-shot WARN + `--yes` parse + `wizard_confirm`/`force_prompt`
2. Step state file + text menu layout (groups, header, prompt at bottom)
3. Text toggles (dirty-exit save-only, `a`, badges)
4. `auto` + `doctor` wiring
5. Whiptail layer (menu / yesno / input / checklist / radiolist)
6. Test updates + new cases; `bash -n`; shellcheck; `tests/install-scripts/run.sh`
7. CHANGELOG

## Acceptance criteria

1. `install_wizard` still the only wizard entry; all steps go through `dispatch_step`.
2. Text codes `0`–`9`, `t`, `a`, `d`, `x`/`q`/`quit`, and step names work under `WIZARD_UI=text`.
3. Non-TTY / pipe / `WIZARD_UI=text` never require whiptail.
4. Docker wipe always confirms via `force_prompt`, including inside `auto` under `--yes`.
5. `--yes` skips non-forced confirms and the auto start screen; does not skip Press Enter or self-update offer.
6. Toggles dirty-exit Yes = save-only; discard path leaves state untouched.
7. Compose filter + ticker + per-step logs preserved.
8. Mock installer suite green after documented test updates.
9. Diff stays within change boundaries above.

## Spec self-review

- No TBD placeholders.
- Auto + `--yes` + docker rule stated once (start skipped under `--yes`; docker always `force_prompt`).
- Toggle exit stdin example uses `x` then save answer (`t\n1\nx\nn\nx\n`).
- Scope limited to wizard UI + usage/tests/CHANGELOG.
