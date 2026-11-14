# Hybrid Wizard TUI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework `script/modules/01_menu.sh` into a hybrid wizard (whiptail TUI + ANSI text fallback) with step badges, Quick Actions (`auto`/`toggles`/`doctor`), `--yes`, and full mock-test compatibility.

**Architecture:** Keep `dispatch_step` as the only step runner. Add a thin `wizard_ui_*` dialog layer that resolves to whiptail or text; persist OK/FAIL in `$INSTALL_STATE_DIR/wizard-steps.state`; extend text menu with grouped layout and Quick Actions. Whiptail is best-effort on real TTYs; CI/pipe always uses text.

**Tech Stack:** Bash (`set -Eeuo pipefail`), optional `whiptail`/`newt`, existing installer mocks in `tests/install-scripts/`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-11-14-wizard-menu-tui-design.md` (commit `12dd926`).
- Branch: `dev`. Touch only: `01_menu.sh`, `install.sh` usage, `CHANGELOG.md`, `tests/install-scripts/test_installer_cli.bash` (+ optional `VERSION` if changelog bumps).
- Mock-only local runs: no real apt/docker/ufw/systemctl/writes under `/etc|/opt|/var/lib`.
- Preserve: per-step logs, compose filter+ticker, self-update offer, `00_common.sh` toggle helpers, codes `0`–`9`/`t`/`x`/`q`/`quit`/step names.
- Default `Last operation:` before any step: **`No operation yet`** (not `OK env`).
- Auto chain order: `apt → env → docker → user → firewall → ssh → network → compose → final` (`env` before `docker` is intentional).
- Docker wipe: always `wizard_confirm "…" 1` (`force_prompt`); `--yes` never bypasses.
- `docs/` is gitignored → `git add -f` for any docs commits.
- Do not revert unrelated worktree changes.

## File map

| File | Responsibility |
|------|----------------|
| `script/modules/01_menu.sh` | Wizard UI, confirms, toggles, auto, step state |
| `script/install.sh` | `usage()` line for `wizard [--yes\|-y]` only |
| `script/CHANGELOG.md` | Wizard UX release note |
| `script/VERSION` | Bump only if CHANGELOG opens a new version section |
| `tests/install-scripts/test_installer_cli.bash` | Stdin/assert updates + new wizard tests |
| `docs/superpowers/specs/2026-11-14-wizard-menu-tui-design.md` | Read-only source of truth |
| `docs/superpowers/plans/2026-11-14-wizard-menu-tui.md` | This plan |

---

### Task 1: Flags, UI mode, confirm/`force_prompt`

**Files:**
- Modify: `script/modules/01_menu.sh` (top helpers + `wizard_confirm` + `install_wizard` argv parse)
- Modify: `script/install.sh` (`usage` wizard line)
- Test: `tests/install-scripts/test_installer_cli.bash` (new `test_wizard_yes_skips_apt_confirm_but_not_docker`)

**Interfaces:**
- Consumes: existing `wizard_confirm`, `install_wizard`, `log`
- Produces:
  - `WIZARD_ASSUME_YES` (`0`/`1`)
  - `WIZARD_UI_RESOLVED` (`whiptail`|`text`)
  - `WIZARD_UI_WARNED` (one-shot)
  - `wizard_parse_args "$@"`
  - `wizard_resolve_ui_mode` → sets `WIZARD_UI_RESOLVED`
  - `wizard_confirm "prompt" [force_prompt]` — force_prompt `1` ignores assume-yes
  - `wizard_ui_yesno "prompt" [force_prompt]` — later tasks may alias; Task 1 may implement text path inside `wizard_confirm` only

- [ ] **Step 1: Add failing test for `--yes` vs docker**

In `make_fixture`, add:

```bash
export WIZARD_UI=text
unset WIZARD_ASSUME_YES
```

Append near other wizard tests:

```bash
test_wizard_yes_skips_apt_confirm_but_not_docker() {
	make_fixture
	# apt needs no "y"; docker still needs "y"; then Enter pauses; exit
	printf '1\n3\nn\n\nx\n' | bash "$INSTALLER" wizard --yes >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "apt.update" "$INSTALL_COMMAND_LOG" "wizard --yes must run apt without confirm y"
	assert_not_contains "docker.destroy" "$INSTALL_COMMAND_LOG" "declined docker wipe must not destroy"
	assert_contains "SKIPPED docker" "$tmpdir/stdout" "docker force_prompt decline must skip"
}
```

Register the function name in the test runner list at the bottom of the file (same pattern as other `test_wizard_*`).

- [ ] **Step 2: Run test — expect FAIL**

```bash
bash tests/install-scripts/run.sh
```

Expected: FAIL — `wizard --yes` unknown/ignored and/or apt still waiting for `y` / wrong stdin sync.

- [ ] **Step 3: Implement parse + UI resolve + confirm**

Add near top of `01_menu.sh` (after the file header comment):

```bash
: "${WIZARD_ASSUME_YES:=0}"
: "${WIZARD_UI:=auto}"
: "${WIZARD_UI_RESOLVED:=}"
: "${WIZARD_UI_WARNED:=0}"

wizard_parse_args() {
	local arg
	WIZARD_ASSUME_YES=0
	for arg in "$@"; do
		case "$arg" in
		--yes | -y) WIZARD_ASSUME_YES=1 ;;
		*) die "wizard: unknown option: $arg" ;;
		esac
	done
	export WIZARD_ASSUME_YES
}

wizard_resolve_ui_mode() {
	local mode=${WIZARD_UI:-auto}
	case "$mode" in
	text)
		WIZARD_UI_RESOLVED=text
		;;
	whiptail)
		if command -v whiptail >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
			WIZARD_UI_RESOLVED=whiptail
		else
			WIZARD_UI_RESOLVED=text
			if [[ "$WIZARD_UI_WARNED" != "1" ]]; then
				log WARN "WIZARD_UI=whiptail but whiptail/TTY unavailable; using text UI"
				WIZARD_UI_WARNED=1
			fi
		fi
		;;
	auto | *)
		if command -v whiptail >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
			WIZARD_UI_RESOLVED=whiptail
		else
			WIZARD_UI_RESOLVED=text
		fi
		;;
	esac
	export WIZARD_UI_RESOLVED
}

wizard_confirm() {
	local prompt=$1
	local force_prompt=${2:-0}
	local answer
	if [[ "$force_prompt" != "1" && "$WIZARD_ASSUME_YES" == "1" ]]; then
		return 0
	fi
	# Task 5 replaces body with wizard_ui_yesno; text path required now:
	printf '%s [y/N] ' "$prompt"
	read -r answer || answer=n
	case "$answer" in
	y | Y | yes | YES) return 0 ;;
	*) return 1 ;;
	esac
}
```

Update docker branch to:

```bash
docker)
	if wizard_confirm "Destroy Docker data and reinstall Docker?" 1; then
		wizard_execute_step docker dispatch_step docker --destroy-docker-data
	else
		...
	fi
	;;
```

Update `install_wizard`:

```bash
install_wizard() {
	wizard_parse_args "$@"
	wizard_resolve_ui_mode
	wizard_offer_self_update
	install_require_required_env wizard
	...
}
```

In `script/install.sh` usage:

```text
  install.sh wizard [--yes|-y]
```

- [ ] **Step 4: Re-run targeted wizard tests**

```bash
bash tests/install-scripts/run.sh
```

Expected: new `--yes` test PASS; existing wizard confirms still PASS (`printf '1\ny\n\nx\n'` style unchanged for non-`--yes`).

- [ ] **Step 5: Commit**

```bash
git add script/modules/01_menu.sh script/install.sh tests/install-scripts/test_installer_cli.bash
git commit -m "feat(wizard): add --yes and force_prompt confirms"
```

---

### Task 2: Step state + text main menu layout

**Files:**
- Modify: `script/modules/01_menu.sh` (`install_wizard_print_menu`, status, execute_step state write, normalize `a`/`d` stubs OK)
- Modify: `tests/install-scripts/test_installer_cli.bash` (menu marker asserts)

**Interfaces:**
- Consumes: `WIZARD_LAST_STATUS`, `INSTALL_STATE_DIR`, feature env via `install_load_state_env`
- Produces:
  - `WIZARD_STEPS_STATE="$INSTALL_STATE_DIR/wizard-steps.state"`
  - `wizard_step_state_get step` → `OK`|`FAIL`|``
  - `wizard_step_state_set step OK|FAIL`
  - `wizard_features_summary` → string for header
  - `wizard_step_badge step` → text badge with optional color
  - Menu marker string **`Quick Actions`** (replaces `Available steps:`)
  - Prompt **`> `** printed **after** Last operation / keys hint

- [ ] **Step 1: Update failing string asserts**

Change:

```bash
assert_contains "Available steps:" ...
```

to:

```bash
assert_contains "Quick Actions" ...
```

in `test_wizard_rejects_unknown_menu_choice_without_exit`.

Add:

```bash
test_wizard_step_state_records_ok_env() {
	make_fixture
	printf '2\n\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "env=OK" "$INSTALL_STATE_DIR/wizard-steps.state" "successful env must persist step state"
	assert_contains "Last operation: OK env" "$tmpdir/stdout" "Last operation phrasing must stay"
	assert_contains "No operation yet" "$tmpdir/stdout" "first paint must show No operation yet"
	assert_contains "Quick Actions" "$tmpdir/stdout" "grouped menu marker required"
}
```

- [ ] **Step 2: Run — expect FAIL** on missing state file / Quick Actions.

- [ ] **Step 3: Implement state + text menu**

Sketch (text mode only for now; whiptail menu in Task 5):

```bash
wizard_step_state_file() {
	printf '%s\n' "${INSTALL_STATE_DIR}/wizard-steps.state"
}

wizard_step_state_get() {
	local step=$1 file
	file=$(wizard_step_state_file)
	[[ -f "$file" ]] || { printf '\n'; return 0; }
	awk -F= -v s="$step" '$1==s { print $2; found=1; exit } END { if (!found) print "" }' "$file"
}

wizard_step_state_set() {
	local step=$1 status=$2 file tmp
	file=$(wizard_step_state_file)
	tmp=$(mktemp)
	mkdir -p "$INSTALL_STATE_DIR"
	if [[ -f "$file" ]]; then
		awk -F= -v s="$step" -v st="$status" '
			$1==s { print s "=" st; seen=1; next }
			{ print }
			END { if (!seen) print s "=" st }
		' "$file" >"$tmp"
	else
		printf '%s=%s\n' "$step" "$status" >"$tmp"
	fi
	mv "$tmp" "$file"
}
```

In `wizard_execute_step`, after computing `rc`:

```bash
if ((rc == 0)); then
	wizard_step_state_set "$label" OK
	WIZARD_LAST_STATUS="OK $label"
	...
else
	wizard_step_state_set "$label" FAIL
	WIZARD_LAST_STATUS="FAILED $label"
	...
fi
```

Replace `install_wizard_print_menu` with grouped text layout from the spec. Badge helper:

```bash
wizard_step_badge() {
	local st
	st=$(wizard_step_state_get "$1")
	case "$st" in
	OK)
		if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then printf '[✓]'
		else printf '\033[32m[✓]\033[0m'; fi
		;;
	FAIL)
		if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then printf '[!]'
		else printf '\033[31m[!]\033[0m'; fi
		;;
	*) printf '[ ]' ;;
	esac
}
```

Features summary: load toggles; emit comma-separated active names; if none and `UDP443_BACKEND=off` → `none`.

**Critical layout in `install_wizard` loop:**

```bash
install_wizard_print_menu   # includes header + groups + keys; NO prompt
install_wizard_print_status # Last operation: ${WIZARD_LAST_STATUS:-No operation yet}
printf '> '
read -r input || break
```

Do **not** print `>` before status.

Extend `wizard_normalize_step`:

```bash
a) printf 'auto\n' ;;
d) printf 'doctor\n' ;;
```

Stub in `wizard_dispatch_step` for now:

```bash
auto)
	WIZARD_LAST_STATUS="INVALID auto"
	printf '\nauto not implemented yet\n'
	wizard_wait_continue
	;;
doctor)
	wizard_execute_step doctor dispatch_step doctor
	;;
```

(Doctor can be fully wired here — it needs no confirm. Auto body is Task 4; stub only if you prefer failing-fast — prefer implementing doctor fully in this task since it is one line.)

- [ ] **Step 4: Run suite — menu/status tests PASS**

```bash
bash tests/install-scripts/run.sh
bash -n script/modules/01_menu.sh
```

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(wizard): grouped text menu and step state badges"
```

---

### Task 3: Text toggles (dirty-exit save-only)

**Files:**
- Modify: `script/modules/01_menu.sh` (`wizard_feature_toggles`, print, save paths)
- Modify: `tests/install-scripts/test_installer_cli.bash` (stdin + label asserts)

**Interfaces:**
- Consumes: `wizard_load_feature_toggles`, `wizard_save_feature_toggles`, `wizard_confirm`, `wizard_execute_step`
- Produces: dirty-flag session toggles; human-readable labels; `a` = save+env+compose-ask; dirty `x` = save prompt

- [ ] **Step 1: Fix existing toggle tests (will fail until code matches)**

```bash
test_wizard_toggles_optional_feature_flags_and_renders_env() {
	make_fixture
	printf 't\n1\n2\n3\n4\n5\na\n\nn\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "t. toggles" "$tmpdir/stdout" "wizard must expose feature toggles"
	assert_contains "Optional Stack Features" "$tmpdir/stdout" "toggle screen heading"
	assert_contains "1. Lampac" "$tmpdir/stdout" "human-readable Lampac"
	assert_contains "2. Telemt" "$tmpdir/stdout" "human-readable Telemt"
	assert_contains "3. UDP443" "$tmpdir/stdout" "UDP443 selector"
	assert_contains "4. VLESS gRPC" "$tmpdir/stdout" "VLESS gRPC"
	assert_contains "5. Mihomo" "$tmpdir/stdout" "Mihomo"
	# keep all ENABLE_*=true / UDP443_BACKEND=hysteria2 / VISION_FALLBACK_HOST asserts
}

test_wizard_toggle_exit_does_not_persist_changes() {
	make_fixture
	printf 't\n1\nx\nn\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Optional Stack Features" "$tmpdir/stdout" "toggle screen must render before exit"
	assert_not_contains "ENABLE_LAMPAC=true" "$INSTALL_STATE_DIR/install.env" "discard dirty exit must not persist"
	assert_not_contains "env.render" "$INSTALL_COMMAND_LOG" "discard dirty exit must not render env"
}

test_wizard_toggle_dirty_exit_yes_saves_without_env() {
	make_fixture
	printf 't\n1\nx\ny\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "ENABLE_LAMPAC=true" "$INSTALL_STATE_DIR/install.env" "dirty-exit Yes must persist"
	assert_not_contains "env.render" "$INSTALL_COMMAND_LOG" "dirty-exit Yes is save-only"
}
```

- [ ] **Step 2: Run — expect FAIL** on heading/labels/stdin.

- [ ] **Step 3: Rewrite text toggles loop**

Behavior checklist:

1. `wizard_load_feature_toggles` on enter; `dirty=0`.
2. Print ON/OFF badges (respect `NO_COLOR`).
3. Keys `1`–`5` toggle/cycle; set `dirty=1`.
4. `a`/`apply`: `wizard_save_feature_toggles`; `wizard_execute_step env …`; then `wizard_confirm "Apply compose stack now?"`; on Yes run compose; `return 0`.
5. `x`/`q`: if `dirty=0` return; else `wizard_confirm "Save changes?"`; Yes → save-only return; No → return without save.
6. Unknown → status + Enter (unchanged).

Keep using `wizard_cycle_udp443_backend` / `wizard_toggle_bool_var`.

- [ ] **Step 4: Run suite — toggle tests PASS**

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(wizard): human-readable toggles with dirty-exit save"
```

---

### Task 4: `auto` full install chain

**Files:**
- Modify: `script/modules/01_menu.sh` (`wizard_auto_install`, dispatch `auto`)
- Modify: `tests/install-scripts/test_installer_cli.bash`

**Interfaces:**
- Consumes: `wizard_confirm`, `wizard_execute_step`, `dispatch_step`, `WIZARD_ASSUME_YES`
- Produces: `wizard_auto_install` — chain with stop-on-fail; docker always `force_prompt`

- [ ] **Step 1: Add tests**

```bash
test_wizard_auto_runs_chain_with_docker_force_prompt() {
	make_fixture
	# without --yes: confirm auto start (y), then each apply step needs y, docker force y, Enter after each
	# Keep stdin minimal by using --yes for non-docker confirms:
	printf 'a\ny\n\ny\n\ny\n\ny\n\ny\n\ny\n\ny\n\nx\n' | bash "$INSTALLER" wizard --yes >"$tmpdir/stdout" 2>"$tmpdir/stderr" || true
	# With --yes: no auto start confirm; docker still needs y; Enter after each executed step
	# Safer dedicated stdin:
}

test_wizard_auto_yes_skips_start_but_asks_docker() {
	make_fixture
	# a → (no start confirm) → apt auto → Enter → env Enter → docker force n → stop → Enter? → x
	printf 'a\n\n\nn\n\nx\n' | bash "$INSTALLER" wizard --yes >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "apt.update" "$INSTALL_COMMAND_LOG" "auto --yes must run apt"
	assert_contains "env.render" "$INSTALL_COMMAND_LOG" "auto must render env before docker"
	assert_not_contains "docker.destroy" "$INSTALL_COMMAND_LOG" "declined docker must stop chain"
	assert_not_contains "compose.up" "$INSTALL_COMMAND_LOG" "chain must stop before compose when docker declined"
}
```

Tune stdin against actual `wizard_wait_continue` calls while implementing; the asserts above are the contract.

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement `wizard_auto_install`**

```bash
wizard_auto_install() {
	local step rc
	install_load_state_env
	if [[ -z "${USER_SSH:-}" ]]; then
		printf 'SSH username: '
		read -r USER_SSH || USER_SSH=
		export USER_SSH
		[[ -n "$USER_SSH" ]] || { WIZARD_LAST_STATUS="SKIPPED auto"; wizard_wait_continue; return 0; }
	fi
	if [[ "$WIZARD_ASSUME_YES" != "1" ]]; then
		if ! wizard_confirm "Run full install (apt→env→docker→user→firewall→ssh→network→compose→final)? Docker wipe is destructive."; then
			WIZARD_LAST_STATUS="SKIPPED auto"
			wizard_wait_continue
			return 0
		fi
	fi
	for step in apt env docker user firewall ssh network compose final; do
		case "$step" in
		docker)
			if ! wizard_confirm "Destroy Docker data and reinstall Docker?" 1; then
				WIZARD_LAST_STATUS="SKIPPED docker"
				wizard_wait_continue
				return 0
			fi
			wizard_execute_step docker dispatch_step docker --destroy-docker-data || return $?
			;;
		apt)
			wizard_execute_step apt dispatch_step apt --apply --yes || return $?
			;;
		firewall | ssh | network)
			wizard_execute_step "$step" dispatch_step "$step" --apply --yes || return $?
			;;
		user | env | compose | final)
			wizard_execute_step "$step" dispatch_step "$step" || return $?
			;;
		esac
	done
	WIZARD_LAST_STATUS="OK auto"
}
```

Wire `auto)` in `wizard_dispatch_step` to call `wizard_auto_install` (do not double-confirm apt inside auto — chain already assumes start/`--yes`).

Note: when user picks menu item `1` apt manually, still use normal confirm (honors `--yes`). Auto path calls `dispatch_step` directly via `wizard_execute_step` without a second non-force confirm.

- [ ] **Step 4: Run suite — auto tests PASS**

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(wizard): add auto full-install chain"
```

---

### Task 5: Whiptail UI layer

**Files:**
- Modify: `script/modules/01_menu.sh` only (UI helpers + branch on `WIZARD_UI_RESOLVED`)

**Interfaces:**
- Consumes: `WIZARD_UI_RESOLVED`, feature state, step state
- Produces:
  - `wizard_ui_size` → `WIZARD_UI_HEIGHT` / `WIZARD_UI_WIDTH`
  - `wizard_ui_yesno`, `wizard_ui_input`, `wizard_ui_menu`, `wizard_ui_checklist`, `wizard_ui_radiolist`
  - Main loop / toggles / confirms call these when resolved mode is whiptail

- [ ] **Step 1: Implement size + fd-safe whiptail wrapper**

```bash
wizard_ui_size() {
	local lines cols
	lines=$(tput lines 2>/dev/null || echo 24)
	cols=$(tput cols 2>/dev/null || echo 80)
	WIZARD_UI_HEIGHT=$((lines < 20 ? 20 : (lines > 40 ? 40 : lines - 2)))
	WIZARD_UI_WIDTH=$((cols < 60 ? 60 : (cols > 100 ? 100 : cols - 2)))
}

# Returns 0=yes, 1=no/cancel. Never aborts set -e.
wizard_ui_yesno() {
	local prompt=$1 force_prompt=${2:-0} rc
	if [[ "$force_prompt" != "1" && "$WIZARD_ASSUME_YES" == "1" ]]; then
		return 0
	fi
	if [[ "$WIZARD_UI_RESOLVED" != "whiptail" ]]; then
		wizard_confirm "$prompt" "$force_prompt"
		return $?
	fi
	wizard_ui_size
	set +e
	whiptail --title "3x-ui wizard" --yesno "$prompt" --defaultno \
		"$WIZARD_UI_HEIGHT" "$WIZARD_UI_WIDTH"
	rc=$?
	set -e
	((rc == 0))
}
```

Redirect pattern for menu/input/checklist (value on stderr):

```bash
wizard_ui_menu() {
	local result rc
	wizard_ui_size
	set +e
	result=$(whiptail --title "3x-ui wizard" --backtitle "$1" --menu "$2" \
		"$WIZARD_UI_HEIGHT" "$WIZARD_UI_WIDTH" "$3" "${@:4}" \
		3>&1 1>&2 2>&3)
	rc=$?
	set -e
	if ((rc != 0)); then
		printf 'x\n'
		return 0
	fi
	printf '%s\n' "$result"
}
```

Strip quotes from checklist tags: `tr -d '"'`.

- [ ] **Step 2: Point `wizard_confirm` at `wizard_ui_yesno`**

- [ ] **Step 3: Whiptail main menu + toggles flow**

- Menu tags: `a t d 0 1 2 3 4 5 6 7 8 9 x` with ASCII `[OK]/`[FAIL]`/`[ ]` in item text.
- Cancel → `x` (exit wizard).
- Toggles: checklist → radiolist → save → yesno env → yesno compose; cancel mid-flow = no write.

- [ ] **Step 4: Verify text path still green (pipe has no TTY)**

```bash
export WIZARD_UI=text
bash tests/install-scripts/run.sh
bash -n script/modules/01_menu.sh
command -v shellcheck >/dev/null && shellcheck -x -S warning script/modules/01_menu.sh script/install.sh
```

Expected: all PASS. Whiptail itself is manual-only.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(wizard): add whiptail UI with text fallback"
```

---

### Task 6: Doctor menu item polish, CHANGELOG, full gate

**Files:**
- Modify: `script/modules/01_menu.sh` if doctor/user inputbox still text-only under whiptail (`wizard_ui_input` for empty `USER_SSH`)
- Modify: `script/CHANGELOG.md` (+ `script/VERSION` if new section)
- Modify: `tests/install-scripts/test_installer_cli.bash` (`test_wizard_doctor_from_menu`)

**Interfaces:**
- Consumes: completed wizard
- Produces: release note; doctor coverage test

- [ ] **Step 1: Add doctor test**

```bash
test_wizard_doctor_from_menu() {
	make_fixture
	printf 'd\n\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "d. doctor" "$tmpdir/stdout" "menu must list doctor"
	assert_contains "doctor: profile=" "$tmpdir/stdout" "doctor must run from wizard"
	assert_contains "Last operation: OK doctor" "$tmpdir/stdout" "doctor success status"
}
```

- [ ] **Step 2: Implement any missing `wizard_ui_input` for `user` / auto USER_SSH under whiptail**

- [ ] **Step 3: CHANGELOG**

If still on `0.7.7`, append bullets under it **or** open `0.7.8` with today's date — follow repo convention (new UX → new patch version preferred):

```markdown
## 0.7.8 - 2026-11-14

- Wizard: hybrid whiptail + ANSI text UI, step badges, Quick Actions (`auto`/`toggles`/`doctor`).
- Wizard: `install.sh wizard --yes|-y` skips non-destructive confirms; docker wipe always prompts.
- Wizard: feature toggles dirty-exit save-only; `WIZARD_UI=auto|whiptail|text`.
```

Bump `script/VERSION` to match.

- [ ] **Step 4: Full validation**

```bash
bash -n script/install.sh script/modules/01_menu.sh
shellcheck -x -S warning script/install.sh script/modules/01_menu.sh
bash tests/install-scripts/run.sh
git diff --check
```

Expected: all green.

- [ ] **Step 5: Final commit**

```bash
git add -u script/modules/01_menu.sh script/install.sh script/CHANGELOG.md script/VERSION tests/install-scripts/test_installer_cli.bash
git commit -m "feat(wizard): finalize hybrid TUI, tests, and changelog"
```

---

## Spec coverage checklist

| Spec requirement | Task |
|------------------|------|
| `WIZARD_UI` auto/whiptail/text + TTY checks | 1, 5 |
| One-shot WARN if whiptail forced but missing | 1 |
| `--yes` / `-y` parse + usage | 1, 6 |
| `force_prompt` docker always | 1, 4 |
| Step state file + badges | 2 |
| Grouped text menu + `>` at bottom | 2 |
| `Last operation:` + default `No operation yet` | 2 |
| Features summary / `none` | 2 |
| Quick Actions `a`/`t`/`d` | 2–4 |
| Text toggles + dirty-exit save-only | 3 |
| Whiptail checklist/radiolist + quote strip | 5 |
| Auto chain order + stop on fail | 4 |
| Compose filter/ticker untouched | 1–6 (do not rewrite filter) |
| Test stdin chains from spec | 3, 4 |
| CHANGELOG | 6 |

## Plan self-review

- No TBD placeholders; stdin examples match spec (`t\n1\nx\nn\nx\n`).
- Auto `--yes` skips start; docker always `force_prompt`.
- `wizard_confirm` signature consistent: `"prompt" [force_prompt]`.
- Task 4 auto must not double-wrap apt in non-force confirm when already inside chain under assume-yes (direct `wizard_execute_step` with `--apply --yes`).
