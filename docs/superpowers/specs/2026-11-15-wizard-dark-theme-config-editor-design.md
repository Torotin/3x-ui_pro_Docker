# Design: Wizard dark theme + config editor (`01_menu.sh`)

Date: 2026-11-15  
Status: approved (brainstorming)  
Target branch: `feat/wizard-menu-tui` (or a short-lived fix branch off it)  
Primary file: [`script/modules/01_menu.sh`](../../../script/modules/01_menu.sh)

## Goal

Add two wizard-only improvements while preserving CLI/test contracts and the existing `install.env` persistence path:

1. Dark `whiptail` theme via `NEWT_COLORS` (only when unresolved UI mode is whiptail).
2. Quick Action `c` / `config` — interactive view/edit of the installer **required** variables already owned by `install_persist_required_env`.

## Non-goals

- Editing ports, email, Reality/Telemt fallbacks, or other `02_env` defaults
- Changing `install_require_required_env wizard` startup contract
- Compose prompt from the config screen (toggles keeps that behavior)
- Touching `04_apt.sh`, step modules, or `dispatch_step` semantics
- Rewriting wizard architecture beyond a toggles-mirrored screen

## Decisions

| Topic | Choice |
|-------|--------|
| Approach | Mirror `toggles` (text + whiptail dual UI, dirty/save/apply) |
| Editable set | Exactly `install_persist_required_env`: `WEBDOMAIN`, `USER_SSH`, `PASS_SSH`, `USER_WEB`, `PASS_WEB`, `SSH_PBK` |
| Persist path | Reuse `install_load_state_env` + `install_persist_required_env` (no duplicate writers) |
| Clearable vars | Only `WEBDOMAIN`, `SSH_PBK` via `-` / `clear` |
| Required clear | Reject; keep previous value; do not flip `dirty` |
| Secrets in lists | Mask as `********` when non-empty; empty → `<not set>` |
| Whiptail secret input | Empty default in `--inputbox`; empty OK / Cancel = keep |
| Whiptail clearable clear | Same `-` / `clear` markers; empty OK / Cancel = keep |
| Apply path | Persist → optional/confirm `Render env files now?` → `wizard_execute_step env dispatch_step env` |
| Dirty exit | Confirm `Save changes?` → save-only (no `env`), same as toggles |
| Theme apply | Only when `WIZARD_UI_RESOLVED=whiptail`; never overwrite preset `NEWT_COLORS` |
| Dispatcher | Wire `config` in `wizard_normalize_step` + `wizard_dispatch_step` |

## Architecture & boundaries

### Files

| Path | Change |
|------|--------|
| `script/modules/01_menu.sh` | Theme helper, menu entry, `wizard_edit_config*` |
| `tests/install-scripts/test_installer_cli.bash` | Three new mock tests |
| `script/CHANGELOG.md` | Wizard section note |

Do **not** modify `00_common.sh` / `02_env.sh` unless a blocker appears; prefer calling existing helpers from the menu module.

### Integration points in `01_menu.sh`

- `wizard_resolve_ui_mode`: after resolving mode, if `whiptail` → `wizard_apply_whiptail_theme`.
- `install_wizard_print_menu` Quick Actions + keys hint include `c`.
- `wizard_whiptail_main_menu`: add `c "config — Edit installer variables"`.
- `wizard_normalize_step`: `c) printf 'config\n' ;;` (alias `config` already passes through `*)`).
- `wizard_dispatch_step`: `config) wizard_edit_config ;;`.

### Variable contract

Order matches persist helper:

1. `WEBDOMAIN` — optional / clearable (empty → later `<ipv4>.sslip.io` via `ensure_env_defaults`)
2. `USER_SSH` — required
3. `PASS_SSH` — required, secret
4. `USER_WEB` — required
5. `PASS_WEB` — required, secret
6. `SSH_PBK` — optional / clearable

Before every `install_persist_required_env` call, export all six from the session (in-memory edits) so persist writes current values, not stale unloaded state.

Startup `install_require_required_env wizard` stays unchanged and continues to own first-run prompting into the same `$INSTALL_STATE_DIR/install.env`.

## UX: dirty / save · whiptail vs text

### Shared helpers (conceptual)

- `wizard_edit_config` — chooses text vs whiptail branch (like `wizard_feature_toggles`).
- Display helper: empty → `<not set>`; secrets non-empty → `********`.
- Apply helper: `export` six vars → `install_persist_required_env` → `dirty=0` → env step (or confirm first in whiptail).
- On persist failure: keep `dirty=1`, do not run `env`.

### Text mode

```
Installer variables
  1. WEBDOMAIN   …
  2. USER_SSH    …
  3. PASS_SSH    ********
  4. USER_WEB    …
  5. PASS_WEB    ********
  6. SSH_PBK     …

  a. Save + render env
  x. Return
```

- `1..6`: prompt new value.
  - Enter empty → keep.
  - `-` / `clear` → clear only if clearable; else message, no dirty flip.
  - Secrets: `read -rs` then **always** `printf '\n'`.
- `a` / `apply`: persist + `wizard_execute_step env dispatch_step env`.
- `x` / `q` / `quit`: if dirty → `wizard_confirm "Save changes?"` (save-only); else return.
- Unknown input → `INVALID config …`, wait, continue loop.

### Whiptail mode

- `--menu` of six `VAR — display_value` entries + `a` (Save + render env) + `x` (Back).
- Selecting a var → `wizard_ui_input`:
  - Non-secrets: default = current value.
  - Secrets: default empty (do not leak into the box); empty OK / Cancel = keep.
  - Clearable: `-` / `clear` clears; empty OK / Cancel = keep.
- Cancel on main config menu with `dirty=0` → `WIZARD_LAST_STATUS="SKIPPED config"`.
- Apply (`a`): persist, then `wizard_confirm "Render env files now?"` (`WIZARD_ASSUME_YES` / `--yes` → auto-Yes via existing `wizard_confirm`).
- No compose prompt from this screen.

### Menu copy

- Text: `c. config    Edit installer variables`
- Whiptail: `c "config — Edit installer variables"`
- Keys: `Keys: 0-9 step · a/t/c/d · names (apt, compose) · q quit`

## Theme (`NEWT_COLORS`)

```bash
wizard_apply_whiptail_theme() {
	: "${NEWT_COLORS:=
root=,black
window=white,black
border=gray,black
shadow=black,black
title=brightcyan,black
button=black,cyan
actbutton=black,brightcyan
compactbutton=white,black
checkbox=white,black
actcheckbox=black,cyan
entry=white,gray
disentry=gray,black
label=white,black
listbox=white,black
actlistbox=black,cyan
sellistbox=brightcyan,black
actsellistbox=black,brightcyan
textbox=white,black
acttextbox=black,cyan
emptyscale=,gray
fullscale=,cyan
helpline=gray,black
roottext=gray,black
}"
	export NEWT_COLORS
}
```

Rules:

- Call only when `WIZARD_UI_RESOLVED=whiptail`.
- Do not export/set in text mode.
- Preset environment `NEWT_COLORS` wins (`:=`).

## Tests

Add to `tests/install-scripts/test_installer_cli.bash` (mock text UI unless noted):

1. **`test_wizard_config_edits_and_persists_variables`**  
   Choose `c`, change a variable (e.g. `USER_SSH` or `WEBDOMAIN`), apply `a` → value present in `$INSTALL_STATE_DIR/install.env`, `env` render invoked.

2. **`test_wizard_config_dirty_exit_save_only_and_discard`**  
   Dirty exit via `x`: answer `n` leaves `install.env` unchanged; answer `y` persists without calling `env.render`.

3. **`test_wizard_whiptail_sets_dark_newt_colors_when_unset`**  
   `wizard_apply_whiptail_theme` sets a dark palette when unset; does not overwrite a pre-set `NEWT_COLORS`.

Existing wizard tests (`0`–`9`, `t`, `a`, `d`, `--yes`, toggles dirty-exit) must keep their contracts.

### Validation gate

```bash
bash -n script/modules/01_menu.sh
shellcheck -x -S warning script/modules/01_menu.sh
bash tests/install-scripts/run.sh
git diff --check
```

Use ASCII spaces only (no `\u00A0`).

## Error handling summary

| Case | Behavior |
|------|----------|
| Unknown text choice | Status + continue |
| Clear required var | Reject; no dirty |
| Persist failure | Keep dirty; skip env |
| Whiptail cancel, clean | `SKIPPED config` |
| Startup prompts vs `c` | Same `install.env`; no contract change |

## Implementation notes

- Prefer small helpers colocated with toggles (`wizard_config_*`) rather than a generic KV framework.
- Keep indentation ASCII-space only.
- Document the feature briefly under the wizard section of `script/CHANGELOG.md`.
