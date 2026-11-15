# Wizard Dark Theme + Config Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dark `NEWT_COLORS` whiptail theme and Quick Action `c`/`config` to edit the six required installer variables in `install.env`, mirroring the existing toggles dirty/save UX.

**Architecture:** Keep hybrid wizard in `01_menu.sh`. Theme applies only when `WIZARD_UI_RESOLVED=whiptail`. Config editor reuses `install_load_state_env` + `install_persist_required_env` (no new writers). Text and whiptail branches mirror `wizard_feature_toggles` / `wizard_feature_toggles_whiptail`.

**Tech Stack:** Bash, whiptail/newt (`NEWT_COLORS`), existing mock installer harness (`WIZARD_UI=text`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-11-15-wizard-dark-theme-config-editor-design.md` (commit `3ce2690`)
- Branch: create `fix/wizard-dark-theme-config` from `feat/wizard-menu-tui`; cherry-pick design commit `3ce2690` first
- Touch only: `script/modules/01_menu.sh`, `tests/install-scripts/test_installer_cli.bash`, `script/CHANGELOG.md`
- Do **not** edit `00_common.sh`, `02_env.sh`, `04_apt.sh`, step modules, or `dispatch_step` semantics
- Editable set (order fixed): `WEBDOMAIN`, `USER_SSH`, `PASS_SSH`, `USER_WEB`, `PASS_WEB`, `SSH_PBK`
- Clearable only: `WEBDOMAIN`, `SSH_PBK` via `-` / `clear`
- Secrets: list mask `********`; text `read -rs` + `printf '\n'`; whiptail empty default
- Persist: always `export` all six before `install_persist_required_env`
- Dispatcher names: `wizard_normalize_step` + `wizard_dispatch_step` (not `wizard_run_action`)
- ASCII spaces only (no `\u00A0`)
- `docs/` is gitignored → `git add -f` for docs commits
- Validation gate before finish: `bash -n`, `shellcheck -x -S warning`, `bash tests/install-scripts/run.sh`, `git diff --check`

## File map

| File | Responsibility |
|------|----------------|
| `script/modules/01_menu.sh` | Theme helper, menu wiring, `wizard_edit_config*` |
| `tests/install-scripts/test_installer_cli.bash` | Three new tests + registry calls |
| `script/CHANGELOG.md` | Wizard bullets for this feature |
| Spec / this plan | Read-only during implementation |

---

### Task 0: Branch

**Files:** git only

- [ ] **Step 1: Create branch from wizard tip + cherry-pick design**

```bash
git checkout feat/wizard-menu-tui
git checkout -b fix/wizard-dark-theme-config
git cherry-pick 3ce2690
```

If cherry-pick conflicts only on path presence, resolve by keeping the design file content from the cherry-pick.

- [ ] **Step 2: Confirm tip**

```bash
git log --oneline -3
# expect 3ce2690 (or cherry-pick equivalent) then feat/wizard-menu-tui tip
```

---

### Task 1: Dark theme helper + wire into UI resolve

**Files:**
- Modify: `script/modules/01_menu.sh`
- Modify: `tests/install-scripts/test_installer_cli.bash`

**Interfaces:**
- Produces: `wizard_apply_whiptail_theme`
- Consumes: `wizard_resolve_ui_mode` → sets `WIZARD_UI_RESOLVED`

- [ ] **Step 1: Write failing theme test**

Add near other wizard unit-style tests (after toggles tests is fine):

```bash
test_wizard_whiptail_sets_dark_newt_colors_when_unset() {
	make_fixture
	unset NEWT_COLORS
	# shellcheck source=script/modules/01_menu.sh
	source "$ROOT_DIR/script/modules/01_menu.sh"
	wizard_apply_whiptail_theme
	[[ -n "${NEWT_COLORS:-}" ]] || fail "NEWT_COLORS must be set by theme helper"
	case "$NEWT_COLORS" in
	*root=,black*) ;;
	*) fail "dark theme must use root=,black; got: $NEWT_COLORS" ;;
	esac
	case "$NEWT_COLORS" in
	*actbutton=black,brightcyan*) ;;
	*) fail "dark theme must include actbutton=black,brightcyan" ;;
	esac

	export NEWT_COLORS='custom=white,red'
	wizard_apply_whiptail_theme
	[[ "$NEWT_COLORS" == "custom=white,red" ]] || fail "preset NEWT_COLORS must not be overwritten"
}
```

Register near the other `test_wizard_*` invocations:

```bash
test_wizard_whiptail_sets_dark_newt_colors_when_unset
```

- [ ] **Step 2: Run test — expect FAIL (function missing)**

```bash
bash tests/install-scripts/run.sh
```

Expected: FAIL mentioning `wizard_apply_whiptail_theme` / command not found.

- [ ] **Step 3: Implement theme helper and call site**

Insert `wizard_apply_whiptail_theme` near the top of `01_menu.sh` (after `wizard_resolve_ui_mode` is fine, or immediately before it):

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

At the end of `wizard_resolve_ui_mode`, after `export WIZARD_UI_RESOLVED`:

```bash
	if [[ "$WIZARD_UI_RESOLVED" == "whiptail" ]]; then
		wizard_apply_whiptail_theme
	fi
```

Do not call the helper in the `text` branch.

- [ ] **Step 4: Re-run tests — theme test PASS**

```bash
bash tests/install-scripts/run.sh
```

Expected: PASS for `test_wizard_whiptail_sets_dark_newt_colors_when_unset`; existing suite still green.

- [ ] **Step 5: Commit**

```bash
git add script/modules/01_menu.sh tests/install-scripts/test_installer_cli.bash
git commit -m "$(cat <<'EOF'
feat(wizard): apply dark NEWT_COLORS for whiptail UI

Set a strict dark palette when resolving whiptail mode, without overwriting a user-provided NEWT_COLORS.
EOF
)"
```

---

### Task 2: Menu wiring for `c` / `config` (no editor body yet)

**Files:**
- Modify: `script/modules/01_menu.sh`
- Modify: `tests/install-scripts/test_installer_cli.bash`

**Interfaces:**
- Produces: normalize `c` → `config`; dispatch stub calling `wizard_edit_config`
- Temporary: `wizard_edit_config` may be a stub that prints and returns (replaced in Task 3)

- [ ] **Step 1: Write failing menu exposure assert**

Extend an existing smoke path or add a tiny test:

```bash
test_wizard_config_menu_entry_exposed() {
	make_fixture
	printf 'x\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "c. config" "$tmpdir/stdout" "wizard must expose config quick action"
	assert_contains "a/t/c/d" "$tmpdir/stdout" "keys hint must include c"
}
```

Register: `test_wizard_config_menu_entry_exposed`

- [ ] **Step 2: Run — expect FAIL (missing menu strings)**

```bash
bash tests/install-scripts/run.sh
```

Expected: FAIL on `c. config` / `a/t/c/d`.

- [ ] **Step 3: Wire menu + normalize + dispatch stub**

In `install_wizard_print_menu` Quick Actions heredoc, after toggles line:

```bash
  t. toggles   Optional stack features
  c. config    Edit installer variables
  d. doctor    System / stack diagnostics
```

Update keys line:

```bash
	printf 'Keys: 0-9 step · a/t/c/d · names (apt, compose) · q quit\n'
```

In `wizard_whiptail_main_menu`, after toggles entry:

```bash
		t "toggles — Optional stack features" \
		c "config — Edit installer variables" \
		d "doctor — System / stack diagnostics" \
```

In `wizard_normalize_step`:

```bash
	t) printf 'toggles\n' ;;
	c) printf 'config\n' ;;
	a) printf 'auto\n' ;;
```

In `wizard_dispatch_step`, next to toggles:

```bash
	toggles)
		wizard_feature_toggles
		;;
	config)
		wizard_edit_config
		;;
```

Add temporary stub (replaced next task):

```bash
wizard_edit_config() {
	WIZARD_LAST_STATUS="SKIPPED config"
}
```

- [ ] **Step 4: Run — menu test PASS**

```bash
bash tests/install-scripts/run.sh
```

Expected: PASS including `test_wizard_config_menu_entry_exposed`.

- [ ] **Step 5: Commit**

```bash
git add script/modules/01_menu.sh tests/install-scripts/test_installer_cli.bash
git commit -m "$(cat <<'EOF'
feat(wizard): expose config quick action in menu

Wire c/config through normalize and dispatch so the editor screen can land next.
EOF
)"
```

---

### Task 3: Text-mode config editor (persist + dirty exit)

**Files:**
- Modify: `script/modules/01_menu.sh`
- Modify: `tests/install-scripts/test_installer_cli.bash`

**Interfaces:**
- Produces: `wizard_edit_config`, `wizard_edit_config_text`, helpers:
  - `wizard_config_display_value var_name`
  - `wizard_config_is_secret var_name`
  - `wizard_config_is_clearable var_name`
  - `wizard_config_apply_input var_name raw_value` → sets dirty via nameref or echo status
  - `wizard_config_persist` → export six + `install_persist_required_env`
- Consumes: `install_load_state_env`, `install_persist_required_env`, `wizard_confirm`, `wizard_execute_step`, `wizard_wait_continue`

- [ ] **Step 1: Write failing behavioral tests**

```bash
test_wizard_config_edits_and_persists_variables() {
	make_fixture
	# c → edit USER_SSH (item 2) → apply a → Enter after env stream → exit
	printf 'c\n2\ndeployer2\na\n\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Installer variables" "$tmpdir/stdout" "config screen heading"
	assert_contains "1. WEBDOMAIN" "$tmpdir/stdout" "must list WEBDOMAIN"
	assert_contains "3. PASS_SSH" "$tmpdir/stdout" "must list PASS_SSH"
	assert_contains "env.render" "$INSTALL_COMMAND_LOG" "apply must render env through dispatcher"
	assert_contains "USER_SSH=deployer2" "$INSTALL_STATE_DIR/install.env" "edited USER_SSH must persist"
}

test_wizard_config_dirty_exit_save_only_and_discard() {
	make_fixture
	printf 'c\n2\ndeployer-discard\nx\nn\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Installer variables" "$tmpdir/stdout" "config screen must render"
	assert_not_contains "USER_SSH=deployer-discard" "$INSTALL_STATE_DIR/install.env" "discard dirty exit must not persist"
	assert_not_contains "env.render" "$INSTALL_COMMAND_LOG" "discard dirty exit must not render env"

	make_fixture
	printf 'c\n2\ndeployer-save\nx\ny\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "USER_SSH=deployer-save" "$INSTALL_STATE_DIR/install.env" "dirty-exit Yes must persist"
	assert_not_contains "env.render" "$INSTALL_COMMAND_LOG" "dirty-exit Yes is save-only"
}
```

Register both next to other wizard tests. Keep `test_wizard_config_menu_entry_exposed` from Task 2.

- [ ] **Step 2: Run — expect FAIL**

```bash
bash tests/install-scripts/run.sh
```

Expected: FAIL (stub does not persist / no heading).

- [ ] **Step 3: Implement helpers + text editor**

Replace the stub with real helpers. Suggested placement: immediately before `wizard_feature_toggles` / after toggle helpers.

```bash
wizard_config_is_secret() {
	case "$1" in
	PASS_SSH | PASS_WEB) return 0 ;;
	*) return 1 ;;
	esac
}

wizard_config_is_clearable() {
	case "$1" in
	WEBDOMAIN | SSH_PBK) return 0 ;;
	*) return 1 ;;
	esac
}

wizard_config_display_value() {
	local var=$1 value=${!var-}
	if [[ -z "$value" ]]; then
		printf '<not set>'
		return 0
	fi
	if wizard_config_is_secret "$var"; then
		printf '********'
		return 0
	fi
	printf '%s' "$value"
}

wizard_config_persist() {
	export WEBDOMAIN USER_SSH PASS_SSH USER_WEB PASS_WEB SSH_PBK
	install_persist_required_env
}

wizard_config_assign() {
	# $1=var $2=raw; returns 0 if value changed/accepted, 1 if rejected/no-op keep
	local var=$1 raw=$2
	if [[ -z "$raw" ]]; then
		return 1
	fi
	if [[ "$raw" == "-" || "$raw" == "clear" ]]; then
		if wizard_config_is_clearable "$var"; then
			printf -v "$var" '%s' ""
			export "${var?}"
			return 0
		fi
		printf 'Cannot clear required variable %s\n' "$var"
		return 1
	fi
	printf -v "$var" '%s' "$raw"
	export "${var?}"
	return 0
}

wizard_print_config_vars() {
	cat <<MENU
Installer variables
  1. WEBDOMAIN   $(wizard_config_display_value WEBDOMAIN)
  2. USER_SSH    $(wizard_config_display_value USER_SSH)
  3. PASS_SSH    $(wizard_config_display_value PASS_SSH)
  4. USER_WEB    $(wizard_config_display_value USER_WEB)
  5. PASS_WEB    $(wizard_config_display_value PASS_WEB)
  6. SSH_PBK     $(wizard_config_display_value SSH_PBK)

  a. Save + render env
  x. Return

Choose 1-6 to edit, a to apply/render env, x to return:
MENU
}

wizard_config_prompt_text() {
	local var=$1 prompt=$2 value
	if wizard_config_is_secret "$var"; then
		printf '%s (empty=keep, -=clear if allowed): ' "$prompt"
		read -rs value || value=
		printf '\n'
	else
		printf '%s [%s] (empty=keep, -=clear if allowed): ' "$prompt" "${!var-}"
		read -r value || value=
	fi
	# empty means keep → signal no-op
	if [[ -z "$value" ]]; then
		return 1
	fi
	wizard_config_assign "$var" "$value"
}

wizard_edit_config_text() {
	local input dirty=0
	install_load_state_env
	while true; do
		wizard_print_config_vars
		printf '> '
		read -r input || return 0
		case "$input" in
		1)
			if wizard_config_prompt_text WEBDOMAIN "WEBDOMAIN"; then dirty=1; fi
			;;
		2)
			if wizard_config_prompt_text USER_SSH "USER_SSH"; then dirty=1; fi
			;;
		3)
			if wizard_config_prompt_text PASS_SSH "PASS_SSH"; then dirty=1; fi
			;;
		4)
			if wizard_config_prompt_text USER_WEB "USER_WEB"; then dirty=1; fi
			;;
		5)
			if wizard_config_prompt_text PASS_WEB "PASS_WEB"; then dirty=1; fi
			;;
		6)
			if wizard_config_prompt_text SSH_PBK "SSH_PBK"; then dirty=1; fi
			;;
		a | apply)
			if wizard_config_persist; then
				dirty=0
				wizard_execute_step env dispatch_step env
			else
				printf 'Failed to persist installer variables\n'
				wizard_wait_continue
			fi
			return 0
			;;
		x | q | quit)
			if ((dirty == 0)); then
				return 0
			fi
			if wizard_confirm "Save changes?"; then
				wizard_config_persist || true
			fi
			return 0
			;;
		'')
			;;
		*)
			WIZARD_LAST_STATUS="INVALID config $input"
			printf '\nUnknown config item: %s\n' "$input"
			wizard_wait_continue
			;;
		esac
	done
}

wizard_edit_config() {
	if [[ "$WIZARD_UI_RESOLVED" == "whiptail" ]]; then
		wizard_edit_config_whiptail
		return 0
	fi
	wizard_edit_config_text
}
```

For Task 3 only, if `wizard_edit_config_whiptail` is not ready yet, use:

```bash
wizard_edit_config() {
	wizard_edit_config_text
}
```

and implement whiptail in Task 4 (tests force `WIZARD_UI=text`).

Note on empty keep for non-secrets: `wizard_config_prompt_text` treats empty as keep (`return 1`). Clear uses `-`/`clear` only. Do **not** treat empty Enter as clear.

- [ ] **Step 4: Run — config tests PASS**

```bash
bash -n script/modules/01_menu.sh
bash tests/install-scripts/run.sh
```

Expected: PASS for both new config tests; toggles/dirty-exit still PASS.

- [ ] **Step 5: Commit**

```bash
git add script/modules/01_menu.sh tests/install-scripts/test_installer_cli.bash
git commit -m "$(cat <<'EOF'
feat(wizard): add text config editor for required install.env vars

Allow interactive edit/persist of WEBDOMAIN and credentials with toggles-like dirty exit and env render on apply.
EOF
)"
```

---

### Task 4: Whiptail config editor

**Files:**
- Modify: `script/modules/01_menu.sh`

**Interfaces:**
- Produces: `wizard_edit_config_whiptail`
- Consumes: helpers from Task 3, `wizard_ui_menu`, `wizard_ui_input`, `wizard_confirm`, `wizard_whiptail_backtitle`

- [ ] **Step 1: Implement whiptail branch**

```bash
wizard_edit_config_whiptail() {
	local backtitle choice var prompt default raw dirty=0
	install_load_state_env
	backtitle=$(wizard_whiptail_backtitle)
	while true; do
		choice=$(wizard_ui_menu "$backtitle" "Installer variables" 10 \
			1 "WEBDOMAIN — $(wizard_config_display_value WEBDOMAIN)" \
			2 "USER_SSH — $(wizard_config_display_value USER_SSH)" \
			3 "PASS_SSH — $(wizard_config_display_value PASS_SSH)" \
			4 "USER_WEB — $(wizard_config_display_value USER_WEB)" \
			5 "PASS_WEB — $(wizard_config_display_value PASS_WEB)" \
			6 "SSH_PBK — $(wizard_config_display_value SSH_PBK)" \
			a "Save + render env" \
			x "Back") || {
			if ((dirty == 0)); then
				WIZARD_LAST_STATUS="SKIPPED config"
				return 0
			fi
			if wizard_confirm "Save changes?"; then
				wizard_config_persist || true
			fi
			return 0
		}
		case "$choice" in
		1) var=WEBDOMAIN ;;
		2) var=USER_SSH ;;
		3) var=PASS_SSH ;;
		4) var=USER_WEB ;;
		5) var=PASS_WEB ;;
		6) var=SSH_PBK ;;
		a)
			if ! wizard_config_persist; then
				continue
			fi
			dirty=0
			if wizard_confirm "Render env files now?"; then
				wizard_execute_step env dispatch_step env
			fi
			return 0
			;;
		x)
			if ((dirty == 0)); then
				return 0
			fi
			if wizard_confirm "Save changes?"; then
				wizard_config_persist || true
			fi
			return 0
			;;
		*)
			continue
			;;
		esac

		prompt="$var (empty=keep"
		wizard_config_is_clearable "$var" && prompt+=", -=clear"
		prompt+="):"
		if wizard_config_is_secret "$var"; then
			default=
		else
			default=${!var-}
		fi
		if ! raw=$(wizard_ui_input "$prompt" "$default"); then
			continue
		fi
		# Secret/non-secret: empty after cancel already handled; empty OK = keep
		if [[ -z "$raw" ]]; then
			continue
		fi
		# For non-secret inputbox with default prefilled, whiptail returns the
		# default string on OK-without-edit — that is a keep-looking no-op only
		# if unchanged; still OK to assign same value and set dirty, or compare:
		if [[ "$raw" == "${!var-}" ]] && ! wizard_config_is_secret "$var"; then
			continue
		fi
		if wizard_config_assign "$var" "$raw"; then
			dirty=1
		fi
	done
}
```

Wire `wizard_edit_config` to call whiptail when resolved:

```bash
wizard_edit_config() {
	if [[ "$WIZARD_UI_RESOLVED" == "whiptail" ]]; then
		wizard_edit_config_whiptail
		return 0
	fi
	wizard_edit_config_text
}
```

Important: `wizard_ui_input` already maps empty+default → default for text; for whiptail secrets default is empty so empty OK means keep (we `continue` on empty). For clearable, user types `-` or `clear`.

- [ ] **Step 2: Syntax + full suite**

```bash
bash -n script/modules/01_menu.sh
shellcheck -x -S warning script/modules/01_menu.sh
bash tests/install-scripts/run.sh
```

Expected: shellcheck clean at warning severity; all installer tests PASS (text path covered; whiptail exercised only if present — theme unit test still covers theme).

- [ ] **Step 3: Commit**

```bash
git add script/modules/01_menu.sh
git commit -m "$(cat <<'EOF'
feat(wizard): add whiptail config editor for installer variables

Mirror text dirty/save semantics with masked secrets and clear markers for optional fields.
EOF
)"
```

---

### Task 5: CHANGELOG + final validation

**Files:**
- Modify: `script/CHANGELOG.md`

- [ ] **Step 1: Add wizard notes**

At top of `script/CHANGELOG.md`, add (or extend if `0.7.9` already exists from apt work):

```markdown
## 0.7.9 - 2026-11-15

### Added
- Wizard: dark `NEWT_COLORS` theme for whiptail (honors preset env).
- Wizard: Quick Action `c` / `config` to edit required `install.env` variables (dirty save like toggles).
```

Do **not** bump `script/VERSION` in this plan unless an adjacent release already claims `0.7.9` and you are consolidating notes only — stick to CHANGELOG as in the spec file list.

- [ ] **Step 2: Full validation gate**

```bash
bash -n script/modules/01_menu.sh
shellcheck -x -S warning script/modules/01_menu.sh
bash tests/install-scripts/run.sh
git diff --check
```

Expected: all green; no whitespace errors.

- [ ] **Step 3: Commit**

```bash
git add script/CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs(wizard): note dark theme and config editor in CHANGELOG
EOF
)"
```

---

## Spec coverage checklist (author self-review)

| Spec requirement | Task |
|------------------|------|
| `wizard_apply_whiptail_theme` + `:=` | Task 1 |
| Theme only when whiptail resolved | Task 1 |
| Menu `c` / keys / whiptail entry | Task 2 |
| `wizard_normalize_step` + `wizard_dispatch_step` | Task 2 |
| Required six vars + persist helper | Task 3 |
| Text dirty/save/apply + secrets newline | Task 3 |
| Clearable only WEBDOMAIN/SSH_PBK | Task 3 |
| Whiptail menu/input/clear/mask | Task 4 |
| Confirm render env; no compose | Task 3/4 |
| Three named tests | Tasks 1–3 |
| CHANGELOG | Task 5 |
| No `04_apt` / step module edits | Global |

## Placeholder / consistency notes

- Function names stable across tasks: `wizard_edit_config`, `wizard_edit_config_text`, `wizard_edit_config_whiptail`, `wizard_config_persist`, `wizard_config_assign`.
- Text apply always renders env; whiptail apply confirms first (per spec).
- Startup `install_require_required_env wizard` untouched.
