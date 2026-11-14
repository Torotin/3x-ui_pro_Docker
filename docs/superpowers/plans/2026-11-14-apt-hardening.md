# APT Module Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden `script/modules/04_apt.sh` for locks without upfront `fuser`, security-safe mirror rewrites, Dpkg force-conf options, Release-based mirror benchmarking, and Ubuntu/Debian unattended origins — surgically, without rewriting the APT domain.

**Architecture:** Keep existing `install_apt_command` / mock `run_cmd` flow. Add small helpers (`install_apt_lock_is_busy`, `install_apt_dpkg_force_opts` via nameref) and adjust apply/pick/unattended writers in place.

**Tech Stack:** Bash ≥ 4.3 (`local -n`, `mapfile`), `curl`, `flock`/`fuser`, mock installer tests.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-11-14-apt-hardening-design.md` (commits `b32fcaa` + `cc12046`).
- Branch: create `fix/apt-hardening` from current `feat/wizard-menu-tui` before Task 1.
- Touch only: `04_apt.sh`, `tests/install-scripts/test_installer_cli.bash`, `CHANGELOG.md`, `VERSION` (→ `0.7.9`).
- Mock-only local validation; no real apt/dpkg.
- Do not edit wizard/`01_menu.sh`.
- Classic sed: `/security\.ubuntu\.com/! s|https?://[^ ]*/ubuntu/?|$mirror|g`
- flock: `[[ -e "$path" ]]` before `flock -n`; never create missing lock files
- Mirror: full `Release` download timing; list `--max-time 5`; probe `--max-time 4`; default limit 6
- Dpkg opts via `local -n` nameref into caller array
- Mock keeps `apt.auto.install`; real-path drops duplicate unattended install
- `docs/` is gitignored → `git add -f` for docs commits

## File map

| File | Responsibility |
|------|----------------|
| `script/modules/04_apt.sh` | All behavioral changes |
| `tests/install-scripts/test_installer_cli.bash` | Apt test updates + new cases |
| `script/CHANGELOG.md` / `script/VERSION` | `0.7.9` release note |
| Spec / this plan | Read-only during implementation |

---

### Task 0: Branch

**Files:** git only

- [ ] **Step 1: Create branch**

```bash
git checkout feat/wizard-menu-tui
git checkout -b fix/apt-hardening
```

- [ ] **Step 2: Confirm tip includes apt design commits**

```bash
git log --oneline -5
# expect cc12046 / b32fcaa among recent docs commits
```

---

### Task 1: Locks + Dpkg force opts helper

**Files:**
- Modify: `script/modules/04_apt.sh`
- Modify: `tests/install-scripts/test_installer_cli.bash`

**Interfaces:**
- Produces: `install_apt_lock_is_busy`, `install_apt_dpkg_force_opts` (nameref)
- Consumes: existing `install_apt_wait_for_locks`, `install_apt_command`, `run_cmd`

- [ ] **Step 1: Extend deps test for force-conf flags (will fail until impl)**

In `test_apt_installs_required_dependencies`, after existing asserts add:

```bash
assert_contains "force-confdef" "$INSTALL_COMMAND_LOG" "apt install/upgrade must pass dpkg force-confdef"
assert_contains "force-confold" "$INSTALL_COMMAND_LOG" "apt install/upgrade must pass dpkg force-confold"
```

- [ ] **Step 2: Run apt-related tests — expect FAIL on new asserts**

```bash
bash tests/install-scripts/run.sh
```

(Or a focused subset if the suite has unrelated failures; at minimum run the three existing apt tests + new asserts.)

- [ ] **Step 3: Implement helpers + wire into wait/install/upgrade**

Add near top of behavioral helpers in `04_apt.sh`:

```bash
install_apt_lock_is_busy() {
	local path=$1
	if command -v fuser >/dev/null 2>&1; then
		fuser "$path" >/dev/null 2>&1
		return $?
	fi
	if command -v flock >/dev/null 2>&1; then
		[[ -e "$path" ]] || return 1
		! flock -n "$path" true
		return $?
	fi
	die "APT lock check needs fuser or flock"
}

install_apt_dpkg_force_opts() {
	local -n _opts=$1
	_opts+=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
}
```

Update `install_apt_wait_for_locks` real loop to call `install_apt_lock_is_busy "$lock"` instead of bare `fuser`.

In `install_apt_command` mock and real paths for `apt.install.deps` and `apt.upgrade`, build:

```bash
local -a dpkg_opts=()
install_apt_dpkg_force_opts dpkg_opts
# mock example:
run_cmd apt.install.deps apt-get install -y "${dpkg_opts[@]}" "${required_packages[@]}"
run_cmd apt.upgrade apt-get upgrade -y -V "${dpkg_opts[@]}"
# real: env DEBIAN_FRONTEND=noninteractive apt-get ... "${dpkg_opts[@]}" ...
```

- [ ] **Step 4: Re-run tests — deps test PASS**

- [ ] **Step 5: Commit**

```bash
git commit -m "fix(apt): flock lock fallback and dpkg force-conf options"
```

---

### Task 2: Security-safe mirror apply

**Files:**
- Modify: `script/modules/04_apt.sh` (`install_apt_apply_ubuntu_mirror`)
- Modify: `tests/install-scripts/test_installer_cli.bash`

**Interfaces:**
- Consumes: `backup_file`, `run_cmd`, `codename`, `mirror`
- Produces: rewrite that never touches `security.ubuntu.com`

- [ ] **Step 1: Add failing test sourcing apply helper**

```bash
test_apt_apply_mirror_preserves_security_uri() {
	make_fixture
	# Source installer modules the same way other unit-style tests do, or
	# invoke via a tiny harness: write fixtures under $tmpdir and call apply.
	local sources=$tmpdir/sources.list deb822=$tmpdir/ubuntu.sources
	cat >"$sources" <<'EOF'
deb http://archive.ubuntu.com/ubuntu/ noble main
deb http://security.ubuntu.com/ubuntu noble-security main
deb http://mirror.yandex.ru/ubuntu/ noble-updates main
EOF
	cat >"$deb822" <<'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates
Components: main

Types: deb
URIs: http://security.ubuntu.com/ubuntu
Suites: noble-security
Components: main
EOF
	# Point apply at fixtures by temporarily overriding paths OR extract
	# rewrite into testable sed/awk invoked the same as production.
	# Preferred: source 04_apt.sh + 00_common stubs and call apply with
	# env override if helpers honor APT_SOURCES_LIST / APT_UBUNTU_SOURCES
	# — if not, add optional overrides only for tests:
	#   sources=${APT_SOURCES_LIST:-/etc/apt/sources.list}
	#   deb822=${APT_UBUNTU_SOURCES:-/etc/apt/sources.list.d/ubuntu.sources}
	export APT_SOURCES_LIST="$sources" APT_UBUNTU_SOURCES="$deb822"
	# After sourcing modules with INSTALL_MOCK=1 and stubbing run_cmd/backup_file
	# to cp/install into place, call:
	#   install_apt_apply_ubuntu_mirror noble http://mirror.example/ubuntu/
	assert_contains "security.ubuntu.com" "$sources" "classic security URI must remain"
	assert_contains "mirror.example/ubuntu" "$sources" "archive/updates lines must rewrite"
	assert_not_contains "security.ubuntu.com/ubuntu/\n" "$sources" # soft — prefer grep -F security line unchanged
	assert_contains "URIs: http://security.ubuntu.com/ubuntu" "$deb822" "DEB822 security URIs must remain"
	assert_contains "URIs: http://mirror.example/ubuntu/" "$deb822" "DEB822 archive URIs must rewrite"
}
```

If path overrides are cleaner, add them in the same commit as apply changes:

```bash
local sources="${APT_SOURCES_LIST:-/etc/apt/sources.list}"
local deb822="${APT_UBUNTU_SOURCES:-/etc/apt/sources.list.d/ubuntu.sources}"
```

- [ ] **Step 2: Run test — expect FAIL**

- [ ] **Step 3: Implement apply rewrite**

DEB822 awk (concept):

```awk
/^URIs:/ {
  if ($0 !~ /security\.ubuntu\.com/) $0 = "URIs: " mirror
}
{ print }
```

Classic:

```bash
sed -i -E "/security\\.ubuntu\\.com/! s|https?://[^ ]*/ubuntu/?|${mirror}|g" "$sources"
```

Generated fresh list: three `$mirror` lines + security on `http://security.ubuntu.com/ubuntu`.

- [ ] **Step 4: Tests PASS (including fallback test still green)**

- [ ] **Step 5: Commit**

```bash
git commit -m "fix(apt): never rewrite Ubuntu security mirror URIs"
```

---

### Task 3: Release mirror benchmark + list timeouts

**Files:**
- Modify: `script/modules/04_apt.sh` (`install_apt_pick_ubuntu_mirror`, `install_apt_country_mirror_list_url` already has `--max-time 3` on HEAD — ensure list GET uses timeouts)

**Interfaces:**
- Consumes: `APT_MIRROR_LIMIT`, `APT_MIRROR_LIST_URL`, country helpers
- Produces: min-`time_total` selection logging

- [ ] **Step 1: Confirm existing country test still defines contract**

No new network test required. Optionally assert mock still logs `apt.mirror.check`.

- [ ] **Step 2: Replace pick loop with Release timing**

Use the approved sketch:

```bash
limit="${APT_MIRROR_LIMIT:-6}"
...
elapsed=$(curl -fsSL --connect-timeout 2 --max-time 4 \
  -o /dev/null -w '%{time_total}' "$probe_url" 2>/dev/null || true)
# compare with awk; track best
done < <(curl -fsSL --connect-timeout 3 --max-time 5 "$list_url" 2>/dev/null || true)
```

Mock path of `install_apt_command` unchanged (no real benchmark).

- [ ] **Step 3: Run apt tests — PASS**

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(apt): benchmark Ubuntu mirrors via Release download time"
```

---

### Task 4: Unattended Ubuntu/Debian + enable_auto_updates cleanup

**Files:**
- Modify: `script/modules/04_apt.sh`
- Modify: `tests/install-scripts/test_installer_cli.bash`

**Interfaces:**
- Consumes: `apt_os_id`, `apt_os_codename`, `AUTO_UPDATES_MODE`
- Produces: OS-correct `50unattended-upgrades`; sequential wait→dry-run; mock keeps `apt.auto.install`

- [ ] **Step 1: Add Debian origins test**

```bash
test_apt_unattended_origins_debian() {
	make_fixture
	cat >"$INSTALL_TEST_OS_RELEASE" <<'OS'
ID=debian
VERSION_CODENAME=bookworm
OS
	# Source write helper with INSTALL_MOCK stubs that capture written file
	# OR run a unit harness that calls install_apt_write_auto_upgrades all
	# writing into $tmpdir and asserts:
	assert_contains 'origin=Debian,codename=${distro_codename}-security,label=Debian-Security' "$tmpdir/50unattended-upgrades" "..."
	assert_contains 'origin=Debian,codename=${distro_codename},label=Debian' "$tmpdir/50unattended-upgrades" "..."
	assert_contains 'origin=Debian,codename=${distro_codename}-updates,label=Debian' "$tmpdir/50unattended-upgrades" "..."
	assert_not_contains '${distro_id}:${distro_codename}-security' "$tmpdir/50unattended-upgrades" "must not use Ubuntu origin form on Debian"
}
```

Adapt to how the test harness can invoke `install_apt_write_auto_upgrades` (source modules + redirect paths via temp files / `run_cmd` capture). Simplest robust approach: make `install_apt_write_auto_upgrades` honor `APT_AUTO_UPGRADES_FILE` / `APT_UNATTENDED_FILE` overrides for tests (default to `/etc/apt/apt.conf.d/...`).

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement origins + cleanup**

- Build `origins` string with `if os_id; if mode; fi; fi` then quoted/heredoc write with literal `${distro_id}` where Ubuntu needs them (escape `$` as in current Ubuntu security line).
- Real `install_apt_enable_auto_updates`: remove `apt-get install unattended-upgrades`; keep mock `apt.auto.install`; call `install_apt_wait_for_locks` then `install_apt_unattended_dry_run` without useless `if`.

- [ ] **Step 4: Tests PASS**

- [ ] **Step 5: Commit**

```bash
git commit -m "fix(apt): OS-specific unattended origins and enable cleanup"
```

---

### Task 5: CHANGELOG + VERSION + full gate

**Files:**
- Modify: `script/CHANGELOG.md`, `script/VERSION`
- Verify: tests

- [ ] **Step 1: Bump to 0.7.9**

`script/VERSION` → `0.7.9\n`

CHANGELOG section:

```markdown
## 0.7.9 - 2026-11-15

- APT: flock fallback for dpkg/apt locks when `fuser` is missing; do not create absent lock files.
- APT: never rewrite `security.ubuntu.com` when applying country/archive mirrors (classic + DEB822).
- APT: `force-confdef`/`force-confold` on install/upgrade; Release-timed Ubuntu mirror pick with curl timeouts.
- APT: Debian vs Ubuntu `unattended-upgrades` Allowed-Origins; drop duplicate real-path auto-install.
```

- [ ] **Step 2: Full validation**

```bash
bash -n script/modules/04_apt.sh
shellcheck -x -S warning script/modules/04_apt.sh
bash tests/install-scripts/run.sh
git diff --check
```

- [ ] **Step 3: Commit**

```bash
git commit -m "chore(apt): release notes for 0.7.9 APT hardening"
```

---

## Spec coverage checklist

| Spec item | Task |
|-----------|------|
| flock + `[[ -e ]]` + fuser preference | 1 |
| Dpkg nameref force-conf* | 1 |
| Security-safe apply (sed / DEB822 / generated) | 2 |
| Release benchmark + list timeouts | 3 |
| Ubuntu/Debian unattended + heredoc cleanup | 4 |
| Mock keep auto.install; real drop duplicate; wait→dry-run | 4 |
| CHANGELOG/VERSION 0.7.9 | 5 |
| Branch off wizard | 0 |

## Plan self-review

- No TBD left as implementation blockers; test harness may use optional path overrides (`APT_SOURCES_LIST`, `APT_UBUNTU_SOURCES`, `APT_UNATTENDED_FILE`) — those overrides are in-scope for Task 2/4.
- Nameref pattern matches approved spec amendment.
- Classic sed negative filter and generated security line covered in Task 2.
- Wizard explicitly out of scope.
