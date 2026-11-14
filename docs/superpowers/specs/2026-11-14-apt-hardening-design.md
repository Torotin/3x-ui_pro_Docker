# Design: APT module hardening (`04_apt.sh`)

Date: 2026-11-14  
Status: approved (brainstorming 1/3–3/3)  
Branch: `fix/apt-hardening` (from `feat/wizard-menu-tui`)  
Primary file: [`script/modules/04_apt.sh`](../../../script/modules/04_apt.sh)

## Goal

Harden the installer APT domain for production Ubuntu/Debian hosts: reliable lock waits without requiring `psmisc` up front, never rewrite Ubuntu security URIs onto country mirrors, noninteractive dpkg conf handling, Release-based mirror benchmarking, and correct `unattended-upgrades` Allowed-Origins for Ubuntu vs Debian — without rewriting the APT module architecture.

## Non-goals

- Hybrid multi-pass / HTTP Range mirror probes
- Full APT domain rewrite / new state machine
- Real apt/dpkg on local Windows/dev machines (mock-only tests)
- Wizard UI changes (`01_menu.sh`)
- Changing the “first N candidates” mirror-list model beyond Release download timing

## Decisions

| Topic | Choice |
|-------|--------|
| Scope | Full analysis set (critical + medium), not summary-only |
| Approach | Surgical edits in `04_apt.sh` (approach A) |
| Mirror metric | Full `dists/$codename/Release` download; min `%{time_total}`; no Range |
| Default probe limit | `APT_MIRROR_LIMIT=6` |
| List fetch | `curl --connect-timeout 3 --max-time 5` |
| Per-mirror probe | `--connect-timeout 2 --max-time 4` |
| Classic sed | `/security\.ubuntu\.com/! s\|https?://[^ ]*/ubuntu/?\|$mirror\|g` |
| flock | Only if path exists (`[[ -e ]]`); never create missing lock files |
| Branch | New `fix/apt-hardening` off current `feat/wizard-menu-tui` |
| Mock `apt.auto.install` | Keep log line for test compatibility; drop duplicate real-path install |

## Architecture

Keep existing entrypoints and mock/`run_cmd` patterns. Add small helpers inside `04_apt.sh`:

- `install_apt_lock_is_busy path`
- `install_apt_dpkg_force_opts` → fills a caller-owned array (no word-splitting on `::`)
- Optionally thin wrappers around origins rendering for Ubuntu/Debian

`dispatch_step apt` / wizard apt confirm flow unchanged.

## 1. Locks

`install_apt_lock_is_busy`:

1. If `command -v fuser` → busy iff `fuser "$path"` succeeds.
2. Else if `command -v flock`:
   - `[[ -e "$path" ]] || return 1` (not busy; do not create the file)
   - busy iff `flock -n "$path" true` fails
3. Else `die` with a clear “need fuser or flock” message.

`install_apt_wait_for_locks` keeps attempts/sleep/`die` loop; mock still logs `apt.locks.wait`.

## 2. Dpkg force options

Use a Bash nameref (`local -n`, Bash ≥ 4.3 — same era as existing `mapfile`) so the helper appends into the caller array without `eval` or word-splitting on `::`:

```bash
install_apt_dpkg_force_opts() {
	local -n _opts=$1
	_opts+=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
}

# caller:
local -a dpkg_opts=()
install_apt_dpkg_force_opts dpkg_opts
env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -V "${dpkg_opts[@]}"
```

Apply to real-path `apt-get install` (required deps) and `apt-get upgrade`. Mock `run_cmd` strings should include the same flags so tests can assert them.

## 3. Security-safe mirror apply

`install_apt_apply_ubuntu_mirror`:

| Format | Rule |
|--------|------|
| DEB822 `ubuntu.sources` | Rewrite `URIs:` only when current URI does **not** contain `security.ubuntu.com` |
| classic `sources.list` | `sed -E '/security\.ubuntu\.com/! s\|https?://[^ ]*/ubuntu/?\|$mirror\|g'` — covers first mirror pick **and** fallback rewrite of a previously chosen non-security mirror |
| generated fresh list | `main` / `updates` / `backports` on `$mirror`; **security** always `http://security.ubuntu.com/ubuntu` |

Fallback after failed `apt-get update` continues to call the same apply helper (security untouched).

## 4. Mirror benchmark

Replace first-alive HEAD loop with Release download timing (user sketch, finalized):

- Load list with timeouts; on empty/fail → keep current sources
- For up to `APT_MIRROR_LIMIT` (default 6) http(s) mirrors:
  - probe `${mirror%/}/dists/${codename}/Release`
  - record numeric `%{time_total}`; keep minimum
- Log `Selected Ubuntu mirror: URL (X.XXXs)` or keep current

Mock path: do not require real network benchmarks; preserve existing logged steps (`apt.country.detect`, `apt.mirror.check`, fallback) so current tests stay green. Optional extra mock marker is not required.

## 5. Unattended-upgrades origins

`install_apt_write_auto_upgrades`:

Build origin lines with `if/fi` **before** writing the file (no `$([[ mode == all ]] && printf …)` inside unquoted heredoc).

**Ubuntu:**

```text
"${distro_id}:${distro_codename}-security";
# mode=all:
"${distro_id}:${distro_codename}-updates";
```

**Debian:**

```text
"origin=Debian,codename=${distro_codename},label=Debian";
"origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
# mode=all:
"origin=Debian,codename=${distro_codename}-updates,label=Debian";
```

Keep `20auto-upgrades`, timers, and dry-run WARN-on-fail behavior.

## 6. Cleanup

- Real-path `install_apt_enable_auto_updates`: remove duplicate `apt-get install unattended-upgrades` (already installed with required packages).
- Mock: keep `run_cmd apt.auto.install …` for assert compatibility.
- Replace `if install_apt_wait_for_locks; then dry_run; fi` with sequential calls (`wait` dies on failure).

## Change boundaries

| Path | Change |
|------|--------|
| `script/modules/04_apt.sh` | Implementation |
| `tests/install-scripts/test_installer_cli.bash` | Apt asserts / new cases |
| `script/CHANGELOG.md` | APT hardening notes |
| `script/VERSION` | Patch bump (e.g. `0.7.9` if `0.7.8` is wizard) |
| `docs/superpowers/specs/2026-11-14-apt-hardening-design.md` | This document |

## Tests

Existing (must stay green):

- `test_apt_detects_country_specific_mirror_list`
- `test_apt_installs_required_dependencies`
- `test_apt_falls_back_when_selected_mirror_update_fails`

Add:

- Security URI preserved after apply (classic and/or DEB822 fixture under mock/temp files if exercised via sourced helpers)
- Debian origins content when `apt_os_id` resolves to debian in a focused write test
- Command log contains `force-confdef` / `force-confold` on install/upgrade mock lines

Validation:

```bash
bash -n script/modules/04_apt.sh
shellcheck -x -S warning script/modules/04_apt.sh
bash tests/install-scripts/run.sh   # mock-only
```

## Implementation order

1. Locks + `install_apt_dpkg_force_opts` array helper  
2. Security-safe apply/fallback + tests  
3. Release mirror benchmark + list timeouts  
4. Unattended Ubuntu/Debian + enable_auto_updates cleanup  
5. CHANGELOG/VERSION + full mock suite  

## Acceptance criteria

1. Missing `fuser` still detects busy locks via `flock` without creating absent lock paths.  
2. Apply/fallback never rewrites `security.ubuntu.com` (classic, DEB822, generated).  
3. Real install/upgrade pass `force-confdef` / `force-confold` via array.  
4. Mirror selection uses full Release timing with hard curl timeouts.  
5. Unattended origins correct for Ubuntu and Debian; `mode=all` adds updates.  
6. Existing apt mock tests pass; new coverage for security rewrite and Debian origins.  
7. Diff stays within change boundaries.

## Spec self-review

- No TBD placeholders.
- Classic sed negative filter and flock `[[ -e ]]` noted explicitly.
- Dpkg helper uses named array append (no word-splitting on `::`).
- Mock keeps `apt.auto.install`; real-path drops duplicate install.
- Scope is surgical; wizard out of bounds.
