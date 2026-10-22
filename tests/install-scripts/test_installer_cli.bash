#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
INSTALLER="$ROOT_DIR/script/install.sh"
INSTALLER_VERSION=$(sed -n '1{s/[[:space:]]//g;p;q;}' "$ROOT_DIR/script/VERSION")
# Always-newer mock remote for self-update "update available" cases.
INSTALLER_NEWER_VERSION=$(
	IFS=. read -r major minor patch <<<"$INSTALLER_VERSION"
	printf '%s.%s.%s\n' "$major" "$minor" "$((patch + 1))"
)

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_contains() {
	local needle=$1 file=$2 message=$3
	grep -Fq -- "$needle" "$file" || fail "$message; missing: $needle"
}

assert_not_contains() {
	local needle=$1 file=$2 message=$3
	! grep -Fq -- "$needle" "$file" || fail "$message; unexpected: $needle"
}

# Extract doctor step-matrix lines only (from banner through line before next-actions).
extract_doctor_matrix_block() {
	local file=$1 dest=$2
	awk '
		/^doctor: step matrix$/ { grab=1 }
		/^doctor: next actions/ { if (grab) exit }
		grab { print }
	' "$file" >"$dest"
	[[ -s "$dest" ]] || fail "doctor matrix block missing (expected doctor: step matrix .. doctor: next actions)"
}

# Grep ordered line-start needles inside a section file (matrix-scoped).
assert_ordered_line_starts() {
	local file=$1
	shift
	local -a expected=("$@")
	local line idx=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		((idx < ${#expected[@]})) || break
		case "$line" in
		"${expected[$idx]}" | "${expected[$idx]}"[[:space:]]*)
			idx=$((idx + 1))
			;;
		esac
	done <"$file"
	((idx == ${#expected[@]})) || fail "ordered matrix rows incomplete in $file; missing from '${expected[$idx]}' onward (matched $idx/${#expected[@]})"
}

# Assert step matrix content + footer order (matrix before next actions before footer).
assert_doctor_step_matrix() {
	local stdout=$1
	local footer=${2:-WARN}
	local matrix=$tmpdir/doctor_matrix.txt
	extract_doctor_matrix_block "$stdout" "$matrix"

	assert_contains "STEP" "$matrix" "doctor matrix header must include STEP"
	assert_contains "STATUS" "$matrix" "doctor matrix header must include STATUS"
	assert_contains "SUMMARY" "$matrix" "doctor matrix header must include SUMMARY"
	assert_contains "NEXT" "$matrix" "doctor matrix header must include NEXT"
	grep -Eq '^STEP[[:space:]]+STATUS' "$matrix" || fail "doctor matrix must have STEP/STATUS column header line"

	assert_ordered_line_starts "$matrix" \
		dnscrypt apt env docker user firewall ssh network compose final

	# Footer must appear after next-actions (which itself is after the matrix block).
	awk -v footer="doctor: $footer" '
		/^doctor: step matrix$/ { seen_matrix=1; next }
		/^doctor: next actions/ {
			if (!seen_matrix) { print "next actions before step matrix"; exit 2 }
			seen_next=1
			next
		}
		$0 == footer {
			if (!seen_next) { print "footer before next actions"; exit 3 }
			seen_footer=1
			next
		}
		END {
			if (!seen_matrix) { print "missing step matrix"; exit 4 }
			if (!seen_next) { print "missing next actions"; exit 5 }
			if (!seen_footer) { print "missing footer " footer; exit 6 }
		}
	' "$stdout" || fail "doctor matrix/footer order invalid for footer=$footer"
}

make_fixture() {
	tmpdir=$(mktemp -d)
	export INSTALL_MOCK=1
	export INSTALL_NONINTERACTIVE=1
	export INSTALL_ROOT="$tmpdir/root"
	export INSTALL_STATE_DIR="$tmpdir/state"
	export INSTALL_COMMAND_LOG="$tmpdir/commands.log"
	export INSTALL_LOG_FILE="$tmpdir/install.log"
	export INSTALL_REPO_ROOT="$ROOT_DIR"
	export INSTALL_REPO_URL="file://$ROOT_DIR"
	export INSTALL_TEST_OS_RELEASE="$tmpdir/os-release"
	export WEBDOMAIN=example.test
	export USER_WEB=admin
	export PASS_WEB=secret
	export USER_SSH=deployer
	export PASS_SSH=secret
	export SSH_PBK=ssh-ed25519-mock
	export PORT_REMOTE_SSH=22022
	unset INSTALL_MOCK_REMOTE_VERSION INSTALL_MOCK_REMOTE_CHANGELOG HT_PASS_ENCODED ADGUARD_ADMIN_HASH
	unset ENABLE_LAMPAC ENABLE_TELEMT ENABLE_MIHOMO ENABLE_VLESS_GRPC ENABLE_HYSTERIA2 STRICT_DNS_CHECK STRICT_ACME_CHECK
	unset DNSCRYPT_VERSION
	unset TELEMT_MIDDLE_PROXY_NAT_PROBE TELEMT_ME_KEEPALIVE_ENABLED TELEMT_HARDSWAP
	unset TELEMT_PROXY_SECRET_ROTATE_RUNTIME TELEMT_STUN_USE TELEMT_STUN_TCP_FALLBACK
	unset TELEMT_MASK_SHAPE_HARDENING TELEMT_MASK_SHAPE_HARDENING_AGGRESSIVE_MODE TELEMT_MASK_SHAPE_ABOVE_CAP_BLUR
	unset VISION_FALLBACK_HOST VISION_FALLBACK_PORT VISION_FALLBACK_XVER
	unset REALITY_TARGET_HOST REALITY_TARGET_PORT REALITY_TARGET_XVER
	unset INSTALL_MOCK_DOCTOR_PHASE
	unset INSTALL_MOCK_IP_PROBE_IPV4 INSTALL_MOCK_IP_PROBE_IPV6
	unset INSTALL_MOCK_PUBLIC_IPV4 INSTALL_MOCK_PUBLIC_IPV6
	mkdir -p "$INSTALL_ROOT" "$INSTALL_STATE_DIR"
	cat >"$INSTALL_TEST_OS_RELEASE" <<'OS'
ID=ubuntu
VERSION_CODENAME=noble
OS
	: >"$INSTALL_COMMAND_LOG"
}

run_installer() {
	# Invoke via bash so Samba/WSL execute-bit quirks do not break mock tests.
	bash "$INSTALLER" "$@" >"$tmpdir/stdout" 2>"$tmpdir/stderr"
}

test_doctor_is_mock_only_and_reports_supported_os() {
	make_fixture
	run_installer doctor
	assert_contains "doctor: profile=" "$tmpdir/stdout" "doctor must print profile= in banner"
	assert_contains "phase=" "$tmpdir/stdout" "doctor must print phase= in banner"
	assert_contains "OK: OS is Debian/Ubuntu compatible" "$tmpdir/stdout" "doctor must report supported OS"
	assert_contains "OK: commands:" "$tmpdir/stdout" "doctor must summarize command checks by default"
	assert_contains "WARN: stack checks skipped in mock mode" "$tmpdir/stdout" "doctor must skip stack checks in mock mode"
	assert_doctor_step_matrix "$tmpdir/stdout" WARN
	assert_not_contains "OK: command available: bash" "$tmpdir/stdout" "doctor must not spam individual successful commands by default"
	assert_contains "doctor.command command -v apt-get" "$INSTALL_COMMAND_LOG" "doctor must check required commands through runner in mock mode"
	assert_contains "doctor.command command -v docker" "$INSTALL_COMMAND_LOG" "doctor must check Docker command through runner in mock mode"
	assert_not_contains "apt-get install" "$INSTALL_COMMAND_LOG" "doctor must not install apt packages"
	assert_not_contains "systemctl restart" "$INSTALL_COMMAND_LOG" "doctor must not restart services"
	assert_not_contains "sysctl -p" "$INSTALL_COMMAND_LOG" "doctor must not apply sysctl"
	assert_not_contains "ufw --force" "$INSTALL_COMMAND_LOG" "doctor must not mutate ufw"
}

test_doctor_rejects_unknown_profile() {
	make_fixture
	if run_installer doctor nope; then
		fail "doctor must reject unknown profile token"
	fi
	assert_contains "unknown doctor profile: nope" "$tmpdir/stderr" "doctor must explain unknown profile"
}

test_doctor_host_and_stack_profiles_parse() {
	make_fixture
	run_installer doctor host
	assert_contains "profile=host" "$tmpdir/stdout" "doctor host must set profile=host"
	assert_contains "doctor: WARN" "$tmpdir/stdout" "doctor host must complete in mock with WARN footer"

	make_fixture
	run_installer doctor stack
	assert_contains "profile=stack" "$tmpdir/stdout" "doctor stack must set profile=stack"
	assert_contains "DOCTOR_EXPECT_STACK=1" "$tmpdir/stdout" "doctor stack must state forced stack-expected severity"
	assert_contains "doctor: WARN" "$tmpdir/stdout" "doctor stack must complete in mock with WARN footer (stack skipped)"
}

test_doctor_host_skips_stack() {
	make_fixture
	run_installer doctor host
	assert_contains "profile=host" "$tmpdir/stdout" "doctor host must set profile=host"
	assert_contains "SKIP: compose checks skipped (profile=host)" "$tmpdir/stdout" "doctor host must SKIP compose for profile"
	assert_contains "SKIP: container checks skipped (profile=host)" "$tmpdir/stdout" "doctor host must SKIP containers for profile"
	assert_doctor_step_matrix "$tmpdir/stdout" WARN
	grep -Eq '^compose[[:space:]]+SKIP' "$tmpdir/doctor_matrix.txt" || fail "doctor host matrix must include compose SKIP row"
	assert_not_contains "compose configuration validates" "$tmpdir/stdout" "doctor host must not run compose validate"
	assert_not_contains "run-compose.sh validate" "$INSTALL_COMMAND_LOG" "doctor host must not attempt compose validate via command log"
	assert_not_contains "compose.validate" "$INSTALL_COMMAND_LOG" "doctor host must not log compose.validate"
}

test_doctor_stack_profile_sets_expect() {
	make_fixture
	run_installer doctor stack
	assert_contains "profile=stack" "$tmpdir/stdout" "doctor stack must set profile=stack"
	assert_contains "DOCTOR_EXPECT_STACK=1" "$tmpdir/stdout" "doctor stack must print DOCTOR_EXPECT_STACK=1"
	assert_contains "stack profile forces stack-expected severity" "$tmpdir/stdout" "doctor stack must state forced severity"
	assert_contains "SKIP: state checks skipped (profile=stack)" "$tmpdir/stdout" "doctor stack must SKIP host state checks"
	assert_contains "SKIP: dnscrypt checks skipped (profile=stack)" "$tmpdir/stdout" "doctor stack must SKIP dnscrypt host checks"
	assert_contains "SKIP: APT package checks skipped (profile=stack)" "$tmpdir/stdout" "doctor stack must SKIP apt host checks"
	assert_contains "SKIP: Docker engine checks skipped (profile=stack)" "$tmpdir/stdout" "doctor stack must SKIP docker engine host checks"
	assert_contains "SKIP: user checks skipped (profile=stack)" "$tmpdir/stdout" "doctor stack must SKIP user host checks"
	assert_contains "SKIP: firewall checks skipped (profile=stack)" "$tmpdir/stdout" "doctor stack must SKIP firewall host checks"
	assert_contains "SKIP: ssh checks skipped (profile=stack)" "$tmpdir/stdout" "doctor stack must SKIP ssh host checks"
	assert_contains "SKIP: network checks skipped (profile=stack)" "$tmpdir/stdout" "doctor stack must SKIP network host checks"
	assert_contains "SKIP: final checks skipped (profile=stack)" "$tmpdir/stdout" "doctor stack must SKIP final host checks"
	assert_doctor_step_matrix "$tmpdir/stdout" WARN
	grep -Eq '^dnscrypt[[:space:]]+SKIP' "$tmpdir/doctor_matrix.txt" || fail "doctor stack matrix must include dnscrypt SKIP row"
	grep -Eq '^user[[:space:]]+SKIP' "$tmpdir/doctor_matrix.txt" || fail "doctor stack matrix must include user SKIP row"
}

test_doctor_host_checks_user_firewall_matrix() {
	make_fixture
	run_installer doctor host
	assert_contains "doctor.user.id" "$INSTALL_COMMAND_LOG" "doctor host must probe user via doctor.user.id"
	assert_contains "doctor.firewall" "$INSTALL_COMMAND_LOG" "doctor host must probe firewall via doctor.firewall"
	assert_contains "doctor.ssh.listen" "$INSTALL_COMMAND_LOG" "doctor host must probe ssh listen via doctor.ssh.listen"
	assert_contains "doctor.network.sysctl" "$INSTALL_COMMAND_LOG" "doctor host must probe network via doctor.network.sysctl"
	assert_doctor_step_matrix "$tmpdir/stdout" WARN
	grep -Eq '^user[[:space:]]+(OK|WARN|FAIL)' "$tmpdir/doctor_matrix.txt" || fail "doctor host matrix user STATUS must be recorded (not only not checked)"
	! grep -Eq '^user[[:space:]]+SKIP[[:space:]]+not checked' "$tmpdir/doctor_matrix.txt" || fail "doctor host matrix user must not stay 'not checked'"
	grep -Eq '^firewall[[:space:]]+(OK|WARN|FAIL|SKIP)' "$tmpdir/doctor_matrix.txt" || fail "doctor host matrix firewall STATUS must be recorded"
	! grep -Eq '^firewall[[:space:]]+SKIP[[:space:]]+not checked' "$tmpdir/doctor_matrix.txt" || fail "doctor host matrix firewall must not stay 'not checked'"
	grep -Eq '^final[[:space:]]+(OK|WARN|SKIP)' "$tmpdir/doctor_matrix.txt" || fail "doctor host matrix final STATUS must be recorded"
	! grep -Eq '^final[[:space:]]+SKIP[[:space:]]+not checked' "$tmpdir/doctor_matrix.txt" || fail "doctor host matrix final must not stay 'not checked'"
	assert_not_contains "sysctl -p" "$INSTALL_COMMAND_LOG" "doctor host checks must not apply sysctl"
	assert_not_contains "ufw --force" "$INSTALL_COMMAND_LOG" "doctor host checks must not mutate ufw"
	assert_not_contains "systemctl restart" "$INSTALL_COMMAND_LOG" "doctor host checks must not restart services"
}

test_doctor_strict_flag_parses() {
	make_fixture
	if run_installer doctor --strict; then
		fail "doctor --strict must exit nonzero when WARNs are present"
	fi
	assert_contains "doctor: profile=" "$tmpdir/stdout" "doctor --strict must parse and run"
	assert_contains "doctor: FAILED" "$tmpdir/stdout" "doctor --strict with WARNs must print FAILED footer"
}

test_doctor_verbose_keeps_detailed_success_output() {
	make_fixture
	run_installer doctor --verbose
	assert_contains "OK: command available: bash" "$tmpdir/stdout" "doctor --verbose must show individual successful command checks"
	assert_contains "OK: path exists:" "$tmpdir/stdout" "doctor --verbose must show individual successful path checks"
	assert_contains "doctor: WARN" "$tmpdir/stdout" "doctor --verbose must still aggregate WARN footer in mock"
}

test_doctor_inventory_uses_bundled_telemt_panel_healthcheck() {
	assert_contains 'containers+=(telemt)' "$ROOT_DIR/script/modules/08_doctor.sh" "doctor must check the bundled Telemt container"
	assert_contains 'install_telemt_enabled' "$ROOT_DIR/script/modules/08_doctor.sh" "doctor must gate Telemt checks on ENABLE_TELEMT"
	assert_not_contains 'containers+=(telemt telemt-panel)' "$ROOT_DIR/script/modules/08_doctor.sh" "doctor must not expect a retired standalone panel container"
	assert_contains 'containers+=(mihomo)' "$ROOT_DIR/script/modules/08_doctor.sh" "doctor must check the Mihomo container when gated"
	assert_contains 'install_mihomo_enabled' "$ROOT_DIR/script/modules/08_doctor.sh" "doctor must gate Mihomo checks on ENABLE_MIHOMO"
	assert_not_contains 'sub-json-processor' "$ROOT_DIR/script/modules/08_doctor.sh" "doctor must not inventory removed sub-json-processor"
}

# dockcheck must match compose: only active 01-dockcheck.yml/.yaml, never *.yml.disable alone
test_doctor_inventory_gates_dockcheck_on_active_compose_file() {
	local doctor_src="$ROOT_DIR/script/modules/08_doctor.sh"
	assert_contains 'containers+=(dockcheck)' "$doctor_src" "doctor must be able to inventory dockcheck when enabled"
	assert_contains '01-dockcheck.yml' "$doctor_src" "doctor must gate dockcheck on active compose fragment"
	# Bare name must not sit in the unconditional base containers=(...) list.
	if awk '
		/local -a containers=\(/ { in_base=1; next }
		in_base && /^[[:space:]]*\)/ { in_base=0 }
		in_base && $0 ~ /(^|[[:space:]])dockcheck([[:space:]]|$)/ { exit 1 }
		END { exit 0 }
	' "$doctor_src"; then
		:
	else
		fail "dockcheck must not be in the unconditional base containers array (only *.yml.disable would still FAIL)"
	fi
	# Gate file check must precede the push (same pattern as telemt/mihomo).
	awk '
		/01-dockcheck\.yml/ { gate=NR }
		/containers\+=\(dockcheck\)/ { push=NR }
		END {
			if (!(gate && push && gate < push)) exit 2
		}
	' "$doctor_src" || fail "dockcheck active-yml gate must precede containers+=(dockcheck)"
}

# --- Phase 7: doctor exit-matrix (plan IDs T-preflight-default .. T-os) ---

# T-preflight-default: bare doctor mock → exit 0; WARN ok; missing stack not FAIL
test_doctor_exit_preflight_default() {
	make_fixture
	run_installer doctor || fail "T-preflight-default: bare doctor mock must exit 0"
	assert_contains "doctor: WARN" "$tmpdir/stdout" "T-preflight-default: mock full must print WARN footer"
	assert_not_contains "doctor: FAILED" "$tmpdir/stdout" "T-preflight-default: WARN-only mock must not print FAILED"
	assert_contains "WARN: stack checks skipped in mock mode" "$tmpdir/stdout" "T-preflight-default: missing stack must WARN in mock"
	assert_not_contains "FAIL: compose" "$tmpdir/stdout" "T-preflight-default: missing stack must not FAIL compose"
	assert_not_contains "FAIL: container" "$tmpdir/stdout" "T-preflight-default: missing stack must not FAIL containers"
	assert_doctor_step_matrix "$tmpdir/stdout" WARN
}

# T-host: doctor host → exit 0; compose SKIP; not FAIL for down stack
test_doctor_exit_host() {
	make_fixture
	run_installer doctor host || fail "T-host: doctor host mock must exit 0"
	assert_contains "profile=host" "$tmpdir/stdout" "T-host: must set profile=host"
	assert_contains "doctor: WARN" "$tmpdir/stdout" "T-host: mock host must print WARN footer"
	assert_not_contains "doctor: FAILED" "$tmpdir/stdout" "T-host: down/missing stack must not FAILED"
	assert_contains "SKIP: compose checks skipped (profile=host)" "$tmpdir/stdout" "T-host: compose must SKIP"
	assert_doctor_step_matrix "$tmpdir/stdout" WARN
	grep -Eq '^compose[[:space:]]+SKIP' "$tmpdir/doctor_matrix.txt" || fail "T-host: matrix compose STATUS must be SKIP"
	assert_not_contains "FAIL: compose" "$tmpdir/stdout" "T-host: must not FAIL compose for down stack"
	assert_not_contains "compose.validate" "$INSTALL_COMMAND_LOG" "T-host: must not run compose validate"
}

# T-stack-fail: mockable FAIL via --strict and/or INSTALL_MOCK_DOCTOR_PHASE + doctor_issue path
test_doctor_exit_stack_fail() {
	make_fixture
	if run_installer doctor stack --strict; then
		fail "T-stack-fail: doctor stack --strict with mock WARNs must exit nonzero"
	fi
	assert_contains "profile=stack" "$tmpdir/stdout" "T-stack-fail: stack --strict must parse profile=stack"
	assert_contains "doctor: FAILED" "$tmpdir/stdout" "T-stack-fail: stack --strict must print FAILED footer"

	# Force a real FAIL (not only strict-promoted WARN) via expect-stack + soft ssh issue.
	make_fixture
	unset PORT_REMOTE_SSH
	export INSTALL_MOCK_DOCTOR_PHASE=stack_expected
	if run_installer doctor; then
		fail "T-stack-fail: stack_expected + missing PORT_REMOTE_SSH must exit nonzero"
	fi
	assert_contains "phase=stack_expected" "$tmpdir/stdout" "T-stack-fail: INSTALL_MOCK_DOCTOR_PHASE must force stack_expected"
	assert_contains "FAIL: PORT_REMOTE_SSH is not set" "$tmpdir/stdout" "T-stack-fail: doctor_issue must harden to FAIL when expect-stack"
	assert_contains "doctor: FAILED" "$tmpdir/stdout" "T-stack-fail: real FAIL must print FAILED footer"
}

# T-strict: WARN-only + --strict → nonzero FAILED
test_doctor_exit_strict() {
	make_fixture
	if run_installer doctor --strict; then
		fail "T-strict: WARN-only + --strict must exit nonzero"
	fi
	assert_contains "doctor: FAILED" "$tmpdir/stdout" "T-strict: --strict must print doctor: FAILED"
	assert_contains "WARN: stack checks skipped in mock mode" "$tmpdir/stdout" "T-strict: underlying WARN must still be visible"
}

# T-warn-ne-fail: without strict, WARN footer exit 0
test_doctor_exit_warn_ne_fail() {
	make_fixture
	run_installer doctor || fail "T-warn-ne-fail: WARN without --strict must exit 0"
	assert_contains "doctor: WARN" "$tmpdir/stdout" "T-warn-ne-fail: must print doctor: WARN"
	assert_not_contains "doctor: FAILED" "$tmpdir/stdout" "T-warn-ne-fail: WARN must not be FAILED without --strict"
}

# T-mock-skip: mutation guards (apt/systemctl/sysctl/ufw) stay asserted
test_doctor_exit_mock_skip() {
	make_fixture
	run_installer doctor || fail "T-mock-skip: mock doctor must exit 0"
	assert_contains "WARN: stack checks skipped in mock mode" "$tmpdir/stdout" "T-mock-skip: stack must be skipped in mock"
	assert_not_contains "apt-get install" "$INSTALL_COMMAND_LOG" "T-mock-skip: must not install apt packages"
	assert_not_contains "systemctl restart" "$INSTALL_COMMAND_LOG" "T-mock-skip: must not restart services"
	assert_not_contains "sysctl -p" "$INSTALL_COMMAND_LOG" "T-mock-skip: must not apply sysctl"
	assert_not_contains "ufw --force" "$INSTALL_COMMAND_LOG" "T-mock-skip: must not mutate ufw"
	assert_not_contains "compose.validate" "$INSTALL_COMMAND_LOG" "T-mock-skip: must not validate compose via docker"
}

# T-docker-tier: missing docker is soft (doctor_issue), not hard doctor_fail; mock run_cmd always succeeds
test_doctor_exit_docker_tier() {
	make_fixture
	run_installer doctor || fail "T-docker-tier: mock doctor must exit 0"
	# Mock run_cmd always succeeds command -v probes, so docker is reported available.
	assert_not_contains "FAIL: command missing: docker" "$tmpdir/stdout" "T-docker-tier: mock must not hard-FAIL missing docker"
	assert_contains "doctor.command command -v docker" "$INSTALL_COMMAND_LOG" "T-docker-tier: docker must still be probed via runner"

	local doctor_src="$ROOT_DIR/script/modules/08_doctor.sh"
	local cmds_fn=$tmpdir/doctor_check_commands.sh
	sed -n '/^install_doctor_check_commands()/,/^}/p' "$doctor_src" >"$cmds_fn"
	[[ -s "$cmds_fn" ]] || fail "T-docker-tier: install_doctor_check_commands not found"
	# docker belongs to installer_commands (soft doctor_issue), not bootstrap (hard doctor_fail).
	awk '
		/bootstrap_commands=\(/ { tier="bootstrap"; next }
		/installer_commands=\(/ { tier="installer"; next }
		tier == "bootstrap" && /^[[:space:]]*\)/ { tier="" }
		tier == "installer" && /^[[:space:]]*\)/ { tier="" }
		tier == "bootstrap" && $1 == "docker" { boot=1 }
		tier == "installer" && $1 == "docker" { inst=1 }
		END { exit (inst && !boot) ? 0 : 1 }
	' "$cmds_fn" || fail "T-docker-tier: docker must be in installer_commands soft tier, not bootstrap"
	assert_contains 'doctor_issue commands "command missing: $cmd"' "$cmds_fn" "T-docker-tier: installer missing cmds must use doctor_issue"
	# Bootstrap hard-fail path must not name docker specifically.
	! grep -Eq 'doctor_fail.*"command missing: docker"' "$doctor_src" || fail "T-docker-tier: must not hard-code doctor_fail for docker"
}

# T-telemt-gate / T-mihomo-gate: inventory source gates (extend inventory asserts)
test_doctor_exit_telemt_mihomo_gates() {
	local doctor_src="$ROOT_DIR/script/modules/08_doctor.sh"
	assert_contains 'install_telemt_enabled' "$doctor_src" "T-telemt-gate: Telemt container checks must gate on ENABLE_TELEMT"
	assert_contains 'containers+=(telemt)' "$doctor_src" "T-telemt-gate: Telemt container must be inventoried when enabled"
	assert_not_contains 'containers+=(telemt telemt-panel)' "$doctor_src" "T-telemt-gate: retired telemt-panel must not be expected"
	assert_contains 'install_mihomo_enabled' "$doctor_src" "T-mihomo-gate: Mihomo container checks must gate on ENABLE_MIHOMO"
	assert_contains 'containers+=(mihomo)' "$doctor_src" "T-mihomo-gate: Mihomo container must be inventoried when enabled"
	# Gate helpers must appear before the push into the inventory list (source order).
	awk '
		/install_telemt_enabled/ { telemt_gate=NR }
		/containers\+=\(telemt\)/ { telemt_push=NR }
		/install_mihomo_enabled/ { mihomo_gate=NR }
		/containers\+=\(mihomo\)/ { mihomo_push=NR }
		END {
			if (!(telemt_gate && telemt_push && telemt_gate < telemt_push)) exit 2
			if (!(mihomo_gate && mihomo_push && mihomo_gate < mihomo_push)) exit 3
		}
	' "$doctor_src" || fail "T-telemt/mihomo-gate: enable gates must precede containers+=(…) inventory pushes"
}

# T-os: unsupported OS already covered by test_doctor_rejects_unsupported_os; keep exit-matrix alias assert
test_doctor_exit_unsupported_os() {
	make_fixture
	cat >"$INSTALL_TEST_OS_RELEASE" <<'OS'
ID=fedora
VERSION_ID=40
OS
	if run_installer doctor; then
		fail "T-os: doctor must reject unsupported OS"
	fi
	assert_contains "unsupported OS" "$tmpdir/stderr" "T-os: doctor must explain unsupported OS"
	assert_not_contains "doctor: WARN" "$tmpdir/stdout" "T-os: unsupported OS must die before WARN footer"
}

test_exit_resets_script_and_project_permissions() {
	make_fixture
	run_installer doctor
	assert_contains "permissions.owner chown -hR deployer:deployer $ROOT_DIR/script" "$INSTALL_COMMAND_LOG" "exit hook must reset script ownership"
	assert_contains "permissions.owner chown -hR deployer:deployer $INSTALL_ROOT" "$INSTALL_COMMAND_LOG" "exit hook must reset project ownership"
	assert_contains "permissions.dirs find $ROOT_DIR/script -type d -exec chmod u=rwx\\,go=rx" "$INSTALL_COMMAND_LOG" "exit hook must reset directory permissions"
	assert_contains "permissions.files find $INSTALL_ROOT -type f -exec chmod u=rwX\\,go=rX" "$INSTALL_COMMAND_LOG" "exit hook must reset file permissions"
}

test_run_dispatches_named_steps_without_eval() {
	make_fixture
	run_installer run env compose
	assert_contains "env.render" "$INSTALL_COMMAND_LOG" "run env must dispatch env command"
	assert_contains "compose.validate" "$INSTALL_COMMAND_LOG" "run compose must dispatch compose command"
	assert_not_contains "eval" "$INSTALL_COMMAND_LOG" "dispatcher must not use eval"
}

test_compose_installs_docker_maintenance_timer() {
	make_fixture
	run_installer run compose
	assert_contains "docker.maintenance.script.chmod chmod +x $INSTALL_ROOT/compose.d/docker-maintenance.sh" "$INSTALL_COMMAND_LOG" "compose install must ensure maintenance script is executable"
	assert_contains "docker.maintenance.service.write" "$INSTALL_COMMAND_LOG" "compose install must write Docker maintenance service"
	assert_contains "docker.maintenance.timer.write" "$INSTALL_COMMAND_LOG" "compose install must write Docker maintenance timer"
	assert_contains "docker.maintenance.enable systemctl enable docker-proxy-maintenance.timer" "$INSTALL_COMMAND_LOG" "compose install must enable maintenance timer"
	assert_contains "docker.maintenance.start systemctl start docker-proxy-maintenance.timer" "$INSTALL_COMMAND_LOG" "compose install must start maintenance timer"
	assert_contains "docker.maintenance.list systemctl list-timers --all docker-proxy-maintenance.timer" "$INSTALL_COMMAND_LOG" "compose install must list maintenance timer"
}

test_env_reports_permission_problem_before_backup() {
	make_fixture
	export INSTALL_MOCK=0
	export INSTALL_EFFECTIVE_UID=1000
	export INSTALL_ROOT="/opt/docker-proxy"
	export INSTALL_STATE_DIR="/opt/docker-proxy/install-state"
	if run_installer run env; then
		fail "env must fail early when non-root user targets /opt"
	fi
	assert_contains "run with sudo or set INSTALL_ROOT/INSTALL_STATE_DIR" "$tmpdir/stderr" "env must explain how to fix write permissions"
	assert_not_contains "cp:" "$tmpdir/stderr" "env must not fail with raw cp permission errors"
}

test_env_preserves_existing_state_defaults() {
	make_fixture
	unset WEBDOMAIN USER_SSH CROWDSEC_API_KEY_FIREWALL HT_PASS_ENCODED ADGUARD_ADMIN_HASH
	cat >"$INSTALL_STATE_DIR/install.env" <<'ENV'
WEBDOMAIN=state.example.test
USER_SSH="state-user"
CROWDSEC_API_KEY_FIREWALL=state-firewall-key
TELEMT_STACK_IMAGE=torotin/telemt-stack:test-pin
DOCKER_SOCKET_GID=12345
ENABLE_LAMPAC=false
ENABLE_TELEMT=false
ENABLE_MIHOMO=false
ENV
	run_installer run env
	assert_contains "WEBDOMAIN=state.example.test" "$INSTALL_STATE_DIR/install.env" "env must preserve existing domain when no override is provided"
	assert_contains 'USER_SSH="state-user"' "$INSTALL_STATE_DIR/install.env" "env must preserve existing SSH user when no override is provided"
	assert_contains "CROWDSEC_API_KEY_FIREWALL=state-firewall-key" "$INSTALL_STATE_DIR/install.env" "env must preserve existing crowdsec key when no override is provided"
	assert_contains "TELEMT_STACK_IMAGE=torotin/telemt-stack:test-pin" "$INSTALL_STATE_DIR/install.env" "env must preserve an explicit telemt-stack image"
	assert_contains "TELEMT_STACK_IMAGE=torotin/telemt-stack:test-pin" "$INSTALL_ROOT/compose.d/.env" "compose env must receive an explicit telemt-stack image"
	assert_contains "DOCKER_SOCKET_GID=12345" "$INSTALL_STATE_DIR/install.env" "env must preserve an explicit Docker socket group id"
	assert_contains "DOCKER_SOCKET_GID=12345" "$INSTALL_ROOT/compose.d/.env" "compose env must receive the Docker socket group id"
	assert_contains "ENABLE_LAMPAC=false" "$INSTALL_STATE_DIR/install.env" "env must preserve the Lampac enable switch"
	assert_contains "ENABLE_LAMPAC=false" "$INSTALL_ROOT/compose.d/.env" "compose env must receive the Lampac enable switch"
	assert_contains "ENABLE_TELEMT=false" "$INSTALL_STATE_DIR/install.env" "env must preserve the Telemt enable switch"
	assert_contains "ENABLE_TELEMT=false" "$INSTALL_ROOT/compose.d/.env" "compose env must receive the Telemt enable switch"
	assert_contains "ENABLE_MIHOMO=false" "$INSTALL_STATE_DIR/install.env" "env must preserve the Mihomo enable switch"
	assert_contains "ENABLE_MIHOMO=false" "$INSTALL_ROOT/compose.d/.env" "compose env must receive the Mihomo enable switch"
}

test_env_renders_mihomo_config_with_generated_secret() {
	make_fixture
	export ENABLE_MIHOMO=true
	run_installer run env
	local config_file="$INSTALL_ROOT/mihomo/config.yaml"
	[[ -f "$config_file" ]] || fail "env must render Mihomo config"
	assert_contains 'MIHOMO_SECRET="' "$INSTALL_STATE_DIR/install.env" "env must persist the generated Mihomo secret"
	assert_contains 'MIHOMO_SECRET="' "$INSTALL_ROOT/compose.d/.env" "compose env must receive the generated Mihomo secret"
	assert_contains "secret:" "$config_file" "rendered Mihomo config must contain a controller secret"
	assert_not_contains '${MIHOMO_SECRET}' "$config_file" "rendered Mihomo config must not keep an unsubstituted placeholder"
	assert_not_contains "MyStrongSecret123" "$config_file" "rendered Mihomo config must not use the old static secret"
	python3 - "$INSTALL_STATE_DIR/install.env" "$config_file" <<'PY'
import re
import sys
from pathlib import Path
env_text = Path(sys.argv[1]).read_text(encoding="utf-8")
config_text = Path(sys.argv[2]).read_text(encoding="utf-8")
env_match = re.search(r'^MIHOMO_SECRET="([^"]+)"$', env_text, re.M)
cfg_match = re.search(r'^secret:\s*([A-Za-z0-9]+)$', config_text, re.M)
if not env_match or not cfg_match:
    raise SystemExit("missing Mihomo secret in env or config")
secret = env_match.group(1)
if secret != cfg_match.group(1):
    raise SystemExit("Mihomo config secret must match install state")
if not re.fullmatch(r"[A-Za-z0-9]{48,64}", secret):
    raise SystemExit("Mihomo secret must be a generated 48-64 character token")
PY
}

test_env_normalizes_global_boolean_values() {
	make_fixture
	export ENABLE_LAMPAC=off
	export ENABLE_TELEMT=disabled
	export ENABLE_MIHOMO=no
	export ENABLE_VLESS_GRPC=YES
	export ENABLE_HYSTERIA2=0
	export STRICT_DNS_CHECK=ON
	export STRICT_ACME_CHECK=off
	export TELEMT_MIDDLE_PROXY_NAT_PROBE=enabled
	export TELEMT_ME_KEEPALIVE_ENABLED=No
	export TELEMT_HARDSWAP=1
	export TELEMT_PROXY_SECRET_ROTATE_RUNTIME=false
	export TELEMT_STUN_USE=True
	export TELEMT_STUN_TCP_FALLBACK=FALSE
	export TELEMT_MASK_SHAPE_HARDENING=yes
	export TELEMT_MASK_SHAPE_HARDENING_AGGRESSIVE_MODE=no
	export TELEMT_MASK_SHAPE_ABOVE_CAP_BLUR=Disabled

	run_installer run env

	for file in "$INSTALL_STATE_DIR/install.env" "$INSTALL_ROOT/compose.d/.env"; do
		assert_contains "ENABLE_LAMPAC=false" "$file" "ENABLE_LAMPAC must normalize to false in $file"
		assert_contains "ENABLE_TELEMT=false" "$file" "ENABLE_TELEMT must normalize to false in $file"
		assert_contains "ENABLE_MIHOMO=false" "$file" "ENABLE_MIHOMO must normalize to false in $file"
		assert_contains "ENABLE_VLESS_GRPC=true" "$file" "ENABLE_VLESS_GRPC must normalize to true in $file"
		assert_contains "ENABLE_HYSTERIA2=false" "$file" "ENABLE_HYSTERIA2 must normalize to false in $file"
		assert_contains "STRICT_DNS_CHECK=true" "$file" "STRICT_DNS_CHECK must normalize to true in $file"
		assert_contains "STRICT_ACME_CHECK=false" "$file" "STRICT_ACME_CHECK must normalize to false in $file"
		assert_contains "TELEMT_MIDDLE_PROXY_NAT_PROBE=true" "$file" "TELEMT_MIDDLE_PROXY_NAT_PROBE must normalize to true in $file"
		assert_contains "TELEMT_ME_KEEPALIVE_ENABLED=false" "$file" "TELEMT_ME_KEEPALIVE_ENABLED must normalize to false in $file"
		assert_contains "TELEMT_HARDSWAP=true" "$file" "TELEMT_HARDSWAP must normalize to true in $file"
		assert_contains "TELEMT_PROXY_SECRET_ROTATE_RUNTIME=false" "$file" "TELEMT_PROXY_SECRET_ROTATE_RUNTIME must normalize to false in $file"
		assert_contains "TELEMT_STUN_USE=true" "$file" "TELEMT_STUN_USE must normalize to true in $file"
		assert_contains "TELEMT_STUN_TCP_FALLBACK=false" "$file" "TELEMT_STUN_TCP_FALLBACK must normalize to false in $file"
		assert_contains "TELEMT_MASK_SHAPE_HARDENING=true" "$file" "TELEMT_MASK_SHAPE_HARDENING must normalize to true in $file"
		assert_contains "TELEMT_MASK_SHAPE_HARDENING_AGGRESSIVE_MODE=false" "$file" "TELEMT_MASK_SHAPE_HARDENING_AGGRESSIVE_MODE must normalize to false in $file"
		assert_contains "TELEMT_MASK_SHAPE_ABOVE_CAP_BLUR=false" "$file" "TELEMT_MASK_SHAPE_ABOVE_CAP_BLUR must normalize to false in $file"
	done
	assert_contains "VISION_FALLBACK_HOST=traefik" "$INSTALL_ROOT/compose.d/.env" "normalized disabled Telemt must affect fallback defaults"
}

test_env_rejects_invalid_global_boolean_values() {
	make_fixture
	export ENABLE_HYSTERIA2=maybe
	if run_installer run env; then
		fail "env must reject invalid global boolean values"
	fi
	assert_contains "ENABLE_HYSTERIA2 must be boolean" "$tmpdir/stderr" "invalid boolean must name the variable and allowed values"
}

test_state_loader_preserves_literal_dollars() {
	make_fixture
	unset HT_PASS_ENCODED ADGUARD_ADMIN_HASH
	cat >"$INSTALL_STATE_DIR/install.env" <<'ENV'
HT_PASS_ENCODED="user:$$2y$$hash"
ENV
	source "$ROOT_DIR/script/modules/00_common.sh"
	install_load_state_env
	assert_contains 'HT_PASS_ENCODED="user:$$2y$$hash"' "$INSTALL_STATE_DIR/install.env" "env loader must preserve literal dollar signs"
	[[ "$HT_PASS_ENCODED" == 'user:$$2y$$hash' ]] || fail "state loader must not shell-expand dollar signs: $HT_PASS_ENCODED"
	source "$ROOT_DIR/script/modules/02_env.sh"
	generate_adguard_hash_from_htpasswd
	[[ "$ADGUARD_ADMIN_HASH" == '$2y$hash' ]] || fail "AdGuard hash must unescape doubled dollars: $ADGUARD_ADMIN_HASH"
}

test_env_prints_rendered_paths() {
	make_fixture
	run_installer run env
	assert_contains "rendered:" "$tmpdir/stdout" "env must print rendered paths header"
	assert_contains "- $INSTALL_STATE_DIR/install.env" "$tmpdir/stdout" "env must print install state env path"
	assert_contains "- $INSTALL_ROOT/compose.d/.env" "$tmpdir/stdout" "env must print compose env path"
}

test_env_writes_host_ip_mode_dual() {
	make_fixture
	unset PUBLIC_IPV4 PUBLIC_IPV6 HOST_IP_MODE
	export INSTALL_MOCK_IP_PROBE_IPV4=1 INSTALL_MOCK_IP_PROBE_IPV6=1
	run_installer run env
	assert_contains "HOST_IP_MODE=dual" "$INSTALL_STATE_DIR/install.env" "env must persist HOST_IP_MODE=dual"
	assert_contains "HOST_IP_MODE=dual" "$INSTALL_ROOT/compose.d/.env" "compose env must persist HOST_IP_MODE"
	assert_contains "TOR_IPV6_AVAILABLE=true" "$INSTALL_ROOT/compose.d/.env" "dual host must enable TOR IPv6 bridges"
}

test_env_ipv4_only_does_not_copy_v4_into_v6() {
	make_fixture
	unset PUBLIC_IPV4 PUBLIC_IPV6 HOST_IP_MODE
	export INSTALL_MOCK_IP_PROBE_IPV4=1 INSTALL_MOCK_IP_PROBE_IPV6=0
	run_installer run env
	assert_contains "HOST_IP_MODE=ipv4" "$INSTALL_STATE_DIR/install.env" "env must persist ipv4 mode"
	assert_contains "TOR_IPV6_AVAILABLE=false" "$INSTALL_ROOT/compose.d/.env" "ipv4-only host must disable TOR IPv6 bridges"
	assert_contains "PUBLIC_IPV4=" "$INSTALL_STATE_DIR/install.env" "env must keep PUBLIC_IPV4"
	# PUBLIC_IPV6 may be absent or empty — must not equal dotted-quad v4
	if grep -q '^PUBLIC_IPV6=' "$INSTALL_STATE_DIR/install.env"; then
		v6=$(awk -F= '/^PUBLIC_IPV6=/{print substr($0,13)}' "$INSTALL_STATE_DIR/install.env")
		v4=$(awk -F= '/^PUBLIC_IPV4=/{print substr($0,13)}' "$INSTALL_STATE_DIR/install.env")
		[[ "$v6" != "$v4" ]] || fail "PUBLIC_IPV6 must not equal PUBLIC_IPV4"
		[[ ! "$v6" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "PUBLIC_IPV6 must not be an IPv4 address"
	fi
}

test_env_defaults_optional_services_disabled() {
	make_fixture
	unset ENABLE_LAMPAC ENABLE_TELEMT ENABLE_MIHOMO VISION_FALLBACK_HOST
	run_installer run env
	assert_contains "ENABLE_LAMPAC=false" "$INSTALL_STATE_DIR/install.env" "Lampac must default to disabled"
	assert_contains "ENABLE_TELEMT=false" "$INSTALL_STATE_DIR/install.env" "Telemt must default to disabled"
	assert_contains "ENABLE_MIHOMO=false" "$INSTALL_STATE_DIR/install.env" "Mihomo must default to disabled"
	assert_contains "ENABLE_LAMPAC=false" "$INSTALL_ROOT/compose.d/.env" "compose env must default Lampac to disabled"
	assert_contains "ENABLE_TELEMT=false" "$INSTALL_ROOT/compose.d/.env" "compose env must default Telemt to disabled"
	assert_contains "ENABLE_MIHOMO=false" "$INSTALL_ROOT/compose.d/.env" "compose env must default Mihomo to disabled"
	assert_contains "VISION_FALLBACK_HOST=traefik" "$INSTALL_ROOT/compose.d/.env" "disabled Telemt must default Xray fallback to Traefik"
}

test_ip_probe_sets_dual_mode_in_mock() {
	make_fixture
	unset PUBLIC_IPV4 PUBLIC_IPV6 HOST_IP_MODE
	# shellcheck source=/dev/null
	source "$ROOT_DIR/script/modules/00_common.sh"
	# shellcheck source=/dev/null
	source "$ROOT_DIR/script/modules/lib_ip.sh"
	export INSTALL_MOCK=1
	ip_probe_resolve_host_mode
	[[ "$HOST_IP_MODE" == "dual" ]] || fail "expected dual, got $HOST_IP_MODE"
	[[ "$PUBLIC_IPV4" == "198.51.100.10" ]] || fail "unexpected PUBLIC_IPV4=$PUBLIC_IPV4"
	[[ "$PUBLIC_IPV6" == "2001:db8::10" ]] || fail "unexpected PUBLIC_IPV6=$PUBLIC_IPV6"
}

test_ip_probe_ipv4_only_leaves_ipv6_empty() {
	make_fixture
	unset PUBLIC_IPV4 PUBLIC_IPV6 HOST_IP_MODE
	export INSTALL_MOCK=1
	export INSTALL_MOCK_IP_PROBE_IPV6=0
	# shellcheck source=/dev/null
	source "$ROOT_DIR/script/modules/00_common.sh"
	# shellcheck source=/dev/null
	source "$ROOT_DIR/script/modules/lib_ip.sh"
	ip_probe_resolve_host_mode
	[[ "$HOST_IP_MODE" == "ipv4" ]] || fail "expected ipv4, got $HOST_IP_MODE"
	[[ -n "$PUBLIC_IPV4" ]] || fail "PUBLIC_IPV4 empty"
	[[ -z "${PUBLIC_IPV6:-}" ]] || fail "PUBLIC_IPV6 must be empty, got $PUBLIC_IPV6"
	[[ "$PUBLIC_IPV6" != "$PUBLIC_IPV4" ]] || fail "PUBLIC_IPV6 must not equal PUBLIC_IPV4"
}

test_ip_probe_clears_stale_ipv6_when_unreachable() {
	make_fixture
	export PUBLIC_IPV4=198.51.100.10
	export PUBLIC_IPV6=2001:db8:dead:beef::1
	unset HOST_IP_MODE
	export INSTALL_MOCK=1
	export INSTALL_MOCK_IP_PROBE_IPV4=1
	export INSTALL_MOCK_IP_PROBE_IPV6=0
	# shellcheck source=/dev/null
	source "$ROOT_DIR/script/modules/00_common.sh"
	# shellcheck source=/dev/null
	source "$ROOT_DIR/script/modules/lib_ip.sh"
	ip_probe_resolve_host_mode
	[[ "$HOST_IP_MODE" == "ipv4" ]] || fail "stale PUBLIC_IPV6 must downgrade to ipv4, got $HOST_IP_MODE"
	[[ -z "${PUBLIC_IPV6:-}" ]] || fail "stale PUBLIC_IPV6 must be cleared, got $PUBLIC_IPV6"
}

test_env_detects_public_ips_when_missing() {
	make_fixture
	unset PUBLIC_IPV4 PUBLIC_IPV6
	run_installer run env
	assert_contains "PUBLIC_IPV4=198.51.100.10" "$INSTALL_STATE_DIR/install.env" "env must detect public IPv4"
	assert_contains "PUBLIC_IPV6=2001:db8::10" "$INSTALL_STATE_DIR/install.env" "env must detect public IPv6"
	assert_contains "HOST_IP_MODE=dual" "$INSTALL_STATE_DIR/install.env" "env must persist HOST_IP_MODE=dual when both IPs detected"
	assert_contains "ip.detect.ipv4" "$INSTALL_COMMAND_LOG" "env must route IPv4 detection through runner"
	assert_contains "ip.detect.ipv6" "$INSTALL_COMMAND_LOG" "env must route IPv6 detection through runner"
}

test_env_generates_adguard_hash_from_htpasswd() {
	make_fixture
	mkdir -p "$tmpdir/bin"
	cat >"$tmpdir/bin/htpasswd" <<'BASH'
#!/usr/bin/env bash
if [[ "$1" == "-nBb" ]]; then
	printf '%s:$2y$05$abc\n' "$2"
	exit 0
fi
if [[ "$1" == "-vb" ]]; then
	exit 0
fi
exit 2
BASH
	chmod +x "$tmpdir/bin/htpasswd"
	unset HT_PASS_ENCODED ADGUARD_ADMIN_HASH
	export INSTALL_MOCK=0
	source "$ROOT_DIR/script/modules/00_common.sh"
	source "$ROOT_DIR/script/modules/02_env.sh"
	PATH="$tmpdir/bin:$PATH" generate_htpasswd_if_needed
	[[ "$HT_PASS_ENCODED" == 'admin:$$2y$$05$$abc' ]] || fail "HT_PASS_ENCODED mismatch: $HT_PASS_ENCODED"
	[[ "$ADGUARD_ADMIN_HASH" == '$2y$05$abc' ]] || fail "ADGUARD_ADMIN_HASH mismatch: $ADGUARD_ADMIN_HASH"
}

test_env_writes_escaped_htpasswd_to_compose_env_for_labels() {
	make_fixture
	run_installer run env
	assert_contains 'HT_PASS_ENCODED="admin:$$2y$$05$$mockhash"' "$INSTALL_STATE_DIR/install.env" "install state must keep shell-safe escaped bcrypt dollars"
	assert_contains 'HT_PASS_ENCODED="admin:$$2y$$05$$mockhash"' "$INSTALL_ROOT/compose.d/.env" "compose env must keep escaped bcrypt dollars so Docker Compose emits raw Docker labels"
}

test_env_renders_telemt_network_lists_as_toml_arrays_from_legacy_state() {
	make_fixture
	cat >"$INSTALL_STATE_DIR/install.env" <<'ENV'
WEBDOMAIN=example.test
USER_WEB=admin
PASS_WEB=secret
USER_SSH=deployer
PASS_SSH=secret
SSH_PBK=ssh-ed25519-mock
PORT_REMOTE_SSH=22022
ENABLE_TELEMT=true
TELEMT_STUN_SERVERS_JSON='["stun1.l.google.com:19302", "stun2.l.google.com:19302"]'
TELEMT_HTTP_IP_DETECT_URLS_JSON='["https://api.ipify.org", "https://ifconfig.me/ip"]'
TELEMT_PANEL_VERSION=v-retired
ENV
	run_installer run env
	assert_contains 'TELEMT_STACK_IMAGE=torotin/telemt-stack:latest' "$INSTALL_ROOT/compose.d/.env" "compose env must default to AutoDockerBuilder telemt-stack image"
	assert_contains 'DOCKER_SOCKET_GID=' "$INSTALL_ROOT/compose.d/.env" "compose env must render a Docker socket group id for Telemt panel logs"
	assert_not_contains 'TELEMT_PANEL_VERSION=' "$INSTALL_ROOT/compose.d/.env" "compose env must drop the retired standalone panel build version"
	assert_contains 'TELEMT_STUN_SERVERS_JSON="[\"stun1.l.google.com:19302\", \"stun2.l.google.com:19302\"]"' "$INSTALL_ROOT/compose.d/.env" "compose env must store dotenv-safe Telemt STUN list"
	assert_contains 'stun_servers = ["stun1.l.google.com:19302", "stun2.l.google.com:19302"]' "$INSTALL_ROOT/telemt/config/config.toml" "Telemt config must render STUN servers as TOML array"
	assert_contains 'http_ip_detect_urls = ["https://api.ipify.org", "https://ifconfig.me/ip"]' "$INSTALL_ROOT/telemt/config/config.toml" "Telemt config must render HTTP IP detect URLs as TOML array"
	assert_not_contains "http_ip_detect_urls = '[" "$INSTALL_ROOT/telemt/config/config.toml" "Telemt config must not render HTTP IP detect URLs as TOML string"
}

test_env_can_disable_telemt_rendering() {
	make_fixture
	export ENABLE_TELEMT=false
	run_installer run env
	assert_contains "ENABLE_TELEMT=false" "$INSTALL_STATE_DIR/install.env" "install env must persist disabled Telemt state"
	assert_contains "ENABLE_TELEMT=false" "$INSTALL_ROOT/compose.d/.env" "compose env must persist disabled Telemt state"
	assert_contains "VISION_FALLBACK_HOST=traefik" "$INSTALL_ROOT/compose.d/.env" "disabled Telemt must make Xray fallback target Traefik"
	assert_contains "REALITY_TARGET_HOST=traefik" "$INSTALL_ROOT/compose.d/.env" "disabled Telemt must make REALITY target Traefik"
	[[ ! -e "$INSTALL_ROOT/telemt/config/config.toml" ]] || fail "disabled Telemt must not render Telemt config"
	[[ ! -e "$INSTALL_ROOT/telemt-panel/config/config.toml" ]] || fail "disabled Telemt must not render Telemt panel config"
	assert_not_contains "$INSTALL_ROOT/telemt/config/config.toml" "$tmpdir/stdout" "disabled Telemt must not report Telemt config path"
}

test_env_regenerates_stale_htpasswd_when_password_changes() {
	make_fixture
	mkdir -p "$tmpdir/bin"
	cat >"$tmpdir/bin/htpasswd" <<'BASH'
#!/usr/bin/env bash
if [[ "$1" == "-nBb" ]]; then
	printf '%s:$2y$05$new\n' "$2"
	exit 0
fi
if [[ "$1" == "-vb" ]]; then
	if grep -Fq '$2y$05$new' "$2" && [[ "$4" == "new-secret" ]]; then
		exit 0
	fi
	exit 1
fi
exit 2
BASH
	chmod +x "$tmpdir/bin/htpasswd"
	export HT_PASS_ENCODED='admin:$$2y$$05$$old'
	export ADGUARD_ADMIN_HASH='$2y$05$old'
	export PASS_WEB='new-secret'
	export INSTALL_MOCK=0
	source "$ROOT_DIR/script/modules/00_common.sh"
	source "$ROOT_DIR/script/modules/02_env.sh"
	PATH="$tmpdir/bin:$PATH" generate_htpasswd_if_needed
	[[ "$HT_PASS_ENCODED" == 'admin:$$2y$$05$$new' ]] || fail "stale HT_PASS_ENCODED must be regenerated: $HT_PASS_ENCODED"
	[[ "$ADGUARD_ADMIN_HASH" == '$2y$05$new' ]] || fail "stale ADGUARD_ADMIN_HASH must be regenerated: $ADGUARD_ADMIN_HASH"
}

test_env_regenerates_existing_hash_when_verify_is_unsupported() {
	make_fixture
	mkdir -p "$tmpdir/bin"
	cat >"$tmpdir/bin/htpasswd" <<'BASH'
#!/usr/bin/env bash
if [[ "$1" == "-nBb" ]]; then
	printf '%s:$2y$05$new\n' "$2"
	exit 0
fi
if [[ "$1" == "-vb" ]]; then
	printf 'usage: htpasswd [-nBb] user password\n' >&2
	exit 1
fi
exit 2
BASH
	chmod +x "$tmpdir/bin/htpasswd"
	export HT_PASS_ENCODED='admin:$$2y$$05$$old'
	export ADGUARD_ADMIN_HASH='$2y$05$old'
	export PASS_WEB='new-secret'
	export INSTALL_MOCK=0
	source "$ROOT_DIR/script/modules/00_common.sh"
	source "$ROOT_DIR/script/modules/02_env.sh"
	PATH="$tmpdir/bin:$PATH" generate_htpasswd_if_needed
	[[ "$HT_PASS_ENCODED" == 'admin:$$2y$$05$$new' ]] || fail "existing hash must be regenerated when verification is unsupported: $HT_PASS_ENCODED"
	[[ "$ADGUARD_ADMIN_HASH" == '$2y$05$new' ]] || fail "AdGuard hash must follow regenerated htpasswd hash: $ADGUARD_ADMIN_HASH"
}

test_adguard_update_pass_uses_precomputed_hash() {
	make_fixture
	mkdir -p "$tmpdir/bin"
	cat >"$tmpdir/bin/yq" <<'BASH'
#!/usr/bin/env bash
echo "unexpected yq call" >"$YQ_LOG"
exit 99
BASH
	chmod +x "$tmpdir/bin/yq"
	local conf="$tmpdir/AdGuardHome.yaml"
	cat >"$conf" <<'YAML'
users:
  - name: ""
    password: ""
auth_attempts: 5
YAML
	YQ_LOG="$tmpdir/yq.log" PATH="$tmpdir/bin:/usr/bin:/bin" ADGUARD_CONF="$conf" USER_WEB=admin PASS_WEB=secret HT_PASS_ENCODED='admin:$$2y$$05$$abc' \
		bash "$ROOT_DIR/docker-proxy/adguard/update-pass.sh" >"$tmpdir/adguard.out" 2>"$tmpdir/adguard.err"
	assert_contains '  - name: "admin"' "$conf" "AdGuard password updater must preserve username"
	assert_contains '    password: "$2y$05$abc"' "$conf" "AdGuard password updater must derive raw hash from escaped htpasswd"
	assert_not_contains "Installing apache2-utils" "$tmpdir/adguard.out" "AdGuard password updater must not install htpasswd when hash is precomputed"
	[[ ! -f "$tmpdir/yq.log" ]] || fail "AdGuard password updater must not call yq"
}

test_adguard_update_pass_updates_yaml_without_yq() {
	make_fixture
	mkdir -p "$tmpdir/bin"
	cat >"$tmpdir/bin/awk" <<'BASH'
#!/usr/bin/env bash
exec /usr/bin/awk "$@"
BASH
	chmod +x "$tmpdir/bin/awk"
	local conf="$tmpdir/AdGuardHome.yaml"
	cat >"$conf" <<'YAML'
http:
  address: 0.0.0.0:80
users:
  - name: ""
    password: ""
auth_attempts: 5
YAML
	PATH="$tmpdir/bin:/usr/bin:/bin" ADGUARD_CONF="$conf" USER_WEB=admin PASS_WEB=secret HT_PASS_ENCODED='admin:$$2y$$05$$abc' \
		bash "$ROOT_DIR/docker-proxy/adguard/update-pass.sh" >"$tmpdir/adguard.out" 2>"$tmpdir/adguard.err"
	assert_contains '  - name: "admin"' "$conf" "AdGuard password updater must write user without yq"
	assert_contains '    password: "$2y$05$abc"' "$conf" "AdGuard password updater must write raw hash without yq"
	assert_contains "auth_attempts: 5" "$conf" "AdGuard password updater must keep following YAML keys"
	assert_not_contains "Installing yq" "$tmpdir/adguard.out" "AdGuard password updater must not install yq at container startup"
}

test_state_loader_keeps_explicit_values_over_state() {
	make_fixture
	export USER_SSH=explicit-user
	cat >"$INSTALL_STATE_DIR/install.env" <<'ENV'
USER_SSH="state-user"
ENV
	run_installer run user
	assert_contains "user.ensure useradd -m -d /home/explicit-user -s /bin/bash explicit-user" "$INSTALL_COMMAND_LOG" "explicit env must override state env"
}

test_destructive_steps_require_explicit_flags() {
	make_fixture
	if run_installer run docker firewall ssh; then
		fail "destructive steps without opt-in must fail"
	fi
	assert_contains "requires explicit opt-in" "$tmpdir/stderr" "destructive guard must explain opt-in"
	assert_not_contains "docker system prune" "$INSTALL_COMMAND_LOG" "docker data wipe must be blocked"
	assert_not_contains "ufw --force reset" "$INSTALL_COMMAND_LOG" "firewall reset must be blocked"
	assert_not_contains "systemctl restart ssh" "$INSTALL_COMMAND_LOG" "ssh restart must be blocked"
}

test_destructive_steps_use_mock_runner_when_explicit() {
	make_fixture
	run_installer run docker --destroy-docker-data
	assert_contains "docker.repo.gpg printf" "$INSTALL_COMMAND_LOG" "docker install must log Docker repo GPG pipeline safely in mock mode"
	assert_contains "download.docker.com/linux/ubuntu" "$INSTALL_COMMAND_LOG" "docker repo must target detected Debian/Ubuntu OS"
	assert_contains "docker.repo.write printf %s\\\\n deb\\ \\[arch=amd64\\ signed-by=/etc/apt/keyrings/docker.gpg\\]\\ https://download.docker.com/linux/ubuntu\\ noble\\ stable" "$INSTALL_COMMAND_LOG" "docker repo write must log exact source line"
	assert_contains "WARNING: Docker data will be destroyed" "$tmpdir/stdout" "docker destructive reinstall must warn about data loss"
	assert_not_contains "docker.containers.remove" "$INSTALL_COMMAND_LOG" "docker wipe must use Docker prune instead of hand-removing containers"
	assert_contains "docker.system.prune" "$INSTALL_COMMAND_LOG" "explicit docker command must be routed through runner"
	assert_contains "docker.daemon.write" "$INSTALL_COMMAND_LOG" "docker install must write daemon config through runner"
	assert_contains "docker.daemon.json.validate printf python3\\ -m\\ json.tool\\ %s\\\\n /etc/docker/daemon.json" "$INSTALL_COMMAND_LOG" "docker install must log daemon.json validation in mock mode"
	assert_contains "docker.service.enable systemctl enable docker" "$INSTALL_COMMAND_LOG" "docker install must enable Docker service"
	assert_not_contains "docker.service.enable systemctl enable --now docker" "$INSTALL_COMMAND_LOG" "docker install must not start service before daemon restart"
	assert_contains "docker.service.reset_failed systemctl reset-failed docker docker.socket" "$INSTALL_COMMAND_LOG" "docker install must clear failed service/socket state before restart"
	assert_contains "docker.socket.start systemctl start docker.socket" "$INSTALL_COMMAND_LOG" "docker install must start socket before dockerd fd activation restart"
	assert_contains "docker.service.restart systemctl restart docker" "$INSTALL_COMMAND_LOG" "docker install must restart Docker after daemon config"
	assert_contains "docker.validate.info timeout --kill-after=10s 30s docker info" "$INSTALL_COMMAND_LOG" "docker install must run timeout-wrapped docker info validation"
	assert_contains "docker.validate.df docker system df" "$INSTALL_COMMAND_LOG" "docker install must report docker disk usage"
	assert_contains "docker.validate.driver_status timeout --kill-after=10s 30s docker info --format \\{\\{json\\ .DriverStatus\\}\\}" "$INSTALL_COMMAND_LOG" "docker install must inspect overlay2 driver status"
	run_installer run firewall --apply --yes
	run_installer run ssh --apply --yes
	assert_contains "firewall.apply" "$INSTALL_COMMAND_LOG" "explicit firewall command must be routed through runner"
	assert_contains "ufw default allow routed" "$INSTALL_COMMAND_LOG" "firewall must allow Docker bridge routed traffic"
	assert_contains "ufw allow 22022/tcp" "$INSTALL_COMMAND_LOG" "firewall must preserve configured SSH port"
	assert_contains "ufw allow 443/udp" "$INSTALL_COMMAND_LOG" "firewall must open UDP 443 for accepted Hysteria2 stage"
	assert_contains "ssh.apply bash -c" "$INSTALL_COMMAND_LOG" "ssh apply must render config through shell redirection"
	assert_contains "ssh.detect" "$INSTALL_COMMAND_LOG" "ssh apply must detect the active SSH systemd unit"
	assert_contains "ssh.reload systemctl reload ssh" "$INSTALL_COMMAND_LOG" "ssh apply must reload SSH before restart fallback"
	assert_contains "ssh.listener.check" "$INSTALL_COMMAND_LOG" "ssh apply must verify the configured SSH port listener"
	assert_not_contains "ssh.restart systemctl restart ssh" "$INSTALL_COMMAND_LOG" "ssh apply must not restart when reload and listener check succeed"
}

test_firewall_does_not_preserve_current_ssh_port() {
	make_fixture
	export SSH_CONNECTION="198.51.100.20 54321 203.0.113.10 22"
	run_installer run firewall --apply --yes
	assert_not_contains "CURRENT_SSH_PORT" "$INSTALL_COMMAND_LOG" "firewall must not preserve active SSH port"
	assert_not_contains "ufw allow 22/tcp" "$INSTALL_COMMAND_LOG" "firewall must not allow current SSH port when it differs from configured port"
	assert_contains "ufw allow 22022/tcp comment PORT_REMOTE_SSH" "$INSTALL_COMMAND_LOG" "firewall must still allow configured target SSH port"
}

test_firewall_ensures_ipv6_yes() {
	make_fixture
	run_installer run firewall --apply --yes
	assert_contains "IPV6=yes" "$INSTALL_COMMAND_LOG" "firewall apply must ensure UFW IPV6=yes"
}

test_doctor_dual_mock_logs_host_probes() {
	make_fixture
	export HOST_IP_MODE=dual
	printf 'HOST_IP_MODE=dual\n' >>"$INSTALL_STATE_DIR/install.env"
	run_installer doctor host
	assert_contains "doctor.network.dual.accept_ra" "$INSTALL_COMMAND_LOG" "doctor dual must probe accept_ra via runner"
	assert_contains "doctor.network.dual.route" "$INSTALL_COMMAND_LOG" "doctor dual must probe default v6 route via runner"
	assert_contains "doctor.firewall.ipv6" "$INSTALL_COMMAND_LOG" "doctor dual must probe UFW IPV6 setting via runner"
	assert_contains "doctor.dnscrypt.dig6" "$INSTALL_COMMAND_LOG" "doctor dual must probe dig @::1 via runner"
	assert_not_contains "ufw --force" "$INSTALL_COMMAND_LOG" "doctor dual probes must not mutate ufw"
}

test_ssh_rejects_invalid_port_before_apply() {
	make_fixture
	export PORT_REMOTE_SSH=not-a-port
	if run_installer run ssh --apply --yes; then
		fail "ssh step must reject non-numeric PORT_REMOTE_SSH"
	fi
	assert_contains "PORT_REMOTE_SSH must be numeric" "$tmpdir/stderr" "ssh step must explain invalid port"
	assert_not_contains "ssh.apply" "$INSTALL_COMMAND_LOG" "ssh step must not render config with invalid port"
}

test_ssh_restarts_when_listener_check_fails_after_reload() {
	make_fixture
	export INSTALL_MOCK_SSH_LISTENER_READY=0
	run_installer run ssh --apply --yes
	assert_contains "ssh.reload systemctl reload ssh" "$INSTALL_COMMAND_LOG" "ssh apply must reload before fallback"
	assert_contains "ssh.listener.check" "$INSTALL_COMMAND_LOG" "ssh apply must check configured listener"
	assert_contains "ssh.restart systemctl restart ssh" "$INSTALL_COMMAND_LOG" "ssh apply must restart when listener check fails"
}

test_ssh_listener_mock_uses_realistic_address_pattern() {
	make_fixture
	run_installer run ssh --apply --yes
	assert_contains 'addr ~ port' "$INSTALL_COMMAND_LOG" "ssh listener check must match address-prefixed sockets"
}

test_ssh_auth_mode_follows_optional_public_key() {
	make_fixture
	local rendered="$tmpdir/sshd_config"
	export INSTALL_MOCK=0
	export INSTALL_SSHD_CONFIG="$rendered"
	source "$ROOT_DIR/script/modules/07_ssh.sh"

	export SSH_PBK=ssh-ed25519-mock
	install_ssh_set_auth_mode
	install_render_sshd_config "$ROOT_DIR/script/template/sshd_config.template" "$rendered"
	assert_contains "PubkeyAuthentication yes" "$rendered" "ssh with public key must enable pubkey auth"
	assert_contains "PasswordAuthentication no" "$rendered" "ssh with public key must disable password auth"

	export SSH_PBK=
	install_ssh_set_auth_mode
	install_render_sshd_config "$ROOT_DIR/script/template/sshd_config.template" "$rendered"
	assert_contains "PubkeyAuthentication no" "$rendered" "ssh without public key must disable pubkey auth"
	assert_contains "PasswordAuthentication yes" "$rendered" "ssh without public key must enable password auth"
}

test_docker_install_handles_missing_docker_binary() {
	make_fixture
	export INSTALL_MOCK_DOCKER_PRESENT=0
	run_installer run docker --destroy-docker-data
	assert_contains "Docker command not found; installing Docker engine" "$tmpdir/stdout" "docker install must explain fresh install path"
	assert_not_contains "docker.containers.stop" "$INSTALL_COMMAND_LOG" "fresh install must not call docker before it exists"
	assert_contains "docker.repo.update" "$INSTALL_COMMAND_LOG" "fresh install must update Docker repo before package install"
	assert_contains "docker.legacy-compose.remove" "$INSTALL_COMMAND_LOG" "docker install must remove legacy docker-compose package"
	assert_contains "apt-get remove -y docker-compose" "$INSTALL_COMMAND_LOG" "docker install must not leave Compose v1 package installed"
	assert_contains "docker.install.packages" "$INSTALL_COMMAND_LOG" "fresh install must install Docker packages"
	assert_contains "docker-compose-plugin" "$INSTALL_COMMAND_LOG" "docker install must install Compose v2 plugin"
	assert_contains "docker.data.remove rm -rf -- /var/lib/docker /var/lib/containerd" "$INSTALL_COMMAND_LOG" "docker data purge must use rm -rf --"
}

test_network_sysctl_dual_preserves_slaac() {
	make_fixture
	export HOST_IP_MODE=dual
	printf 'HOST_IP_MODE=dual\n' >>"$INSTALL_STATE_DIR/install.env"
	run_installer run network --apply --yes
	assert_contains "net.ipv6.conf.all.forwarding = 1" "$INSTALL_COMMAND_LOG" "dual sysctl must enable ipv6 forwarding"
	assert_contains "net.ipv6.conf.all.accept_ra = 2" "$INSTALL_COMMAND_LOG" "dual sysctl must use accept_ra=2 with forwarding"
	assert_contains "net.ipv6.conf.all.autoconf = 1" "$INSTALL_COMMAND_LOG" "dual sysctl must enable autoconf"
	assert_not_contains "net.ipv6.conf.all.accept_ra = 0" "$INSTALL_COMMAND_LOG" "dual must not force accept_ra=0"
}

test_network_sysctl_ipv4_keeps_ra_off() {
	make_fixture
	export HOST_IP_MODE=ipv4
	printf 'HOST_IP_MODE=ipv4\n' >>"$INSTALL_STATE_DIR/install.env"
	run_installer run network --apply --yes
	assert_contains "net.ipv6.conf.all.accept_ra = 0" "$INSTALL_COMMAND_LOG" "ipv4 profile keeps accept_ra=0"
	assert_contains "net.ipv6.conf.all.autoconf = 0" "$INSTALL_COMMAND_LOG" "ipv4 profile keeps autoconf=0"
}

test_network_apply_uses_runner() {
	make_fixture
	run_installer run network --apply --yes
	assert_contains "network.apply" "$INSTALL_COMMAND_LOG" "network apply must use runner"
	assert_contains "network.sysctl" "$INSTALL_COMMAND_LOG" "network sysctl must use runner"
}

test_docker_networks_created_dual_stack() {
	make_fixture
	run_installer run docker --destroy-docker-data
	assert_contains "--ipv6" "$INSTALL_COMMAND_LOG" "docker network create must pass --ipv6"
	assert_contains "fd00:dead:beef:12::/64" "$INSTALL_COMMAND_LOG" "traefik-proxy must use ULA /64"
	assert_contains "fd00:dead:beef:13::/64" "$INSTALL_COMMAND_LOG" "dns-net must use ULA /64"
}

test_docker_enable_ipv6_zero_dies_on_user_networks() {
	make_fixture
	export DOCKER_ENABLE_IPV6=0
	if run_installer run docker --destroy-docker-data; then
		fail "DOCKER_ENABLE_IPV6=0 must abort before creating dual-stack user networks"
	fi
	assert_contains "DOCKER_ENABLE_IPV6=0 conflicts with dual-stack user networks" "$tmpdir/stderr" "must explain DOCKER_ENABLE_IPV6 conflict"
	assert_not_contains "docker.network.ensure docker network create" "$INSTALL_COMMAND_LOG" "must not create user networks when DOCKER_ENABLE_IPV6=0"
}

test_docker_repo_and_daemon_config_are_safe() {
	make_fixture
	run_installer run docker --destroy-docker-data
	assert_contains "docker.repo.gpg printf" "$INSTALL_COMMAND_LOG" "docker repo key install must log a non-executing pipeline in mock mode"
	assert_contains "curl\\ -fsSL\\ %s\\ \\|\\ gpg\\ --dearmor\\ -o\\ %s" "$INSTALL_COMMAND_LOG" "docker repo key install must show the intended pipeline"
	assert_contains "docker.repo.update apt-get update" "$INSTALL_COMMAND_LOG" "docker repo update must not pass -y"
	assert_not_contains "docker.repo.update apt-get update -y" "$INSTALL_COMMAND_LOG" "docker repo update must not use unsupported -y"
	assert_contains "docker.daemon.backup printf backup\\ %s\\\\n /etc/docker/daemon.json" "$INSTALL_COMMAND_LOG" "docker daemon mock backup must not copy a missing host file"
	assert_contains "docker.daemon.json.validate printf python3\\ -m\\ json.tool\\ %s\\\\n /etc/docker/daemon.json" "$INSTALL_COMMAND_LOG" "docker daemon mock validation must log validation target without reading it"
	assert_contains '"live-restore": true' "$INSTALL_COMMAND_LOG" "docker daemon config must enable live restore"
	assert_contains '"storage-driver": "overlay2"' "$INSTALL_COMMAND_LOG" "docker daemon config must force overlay2"
	assert_contains '"compress": "true"' "$INSTALL_COMMAND_LOG" "docker daemon logs must be compressed"
	assert_contains '"mode": "non-blocking"' "$INSTALL_COMMAND_LOG" "docker daemon logs must be non-blocking"
	assert_contains '"max-buffer-size": "4m"' "$INSTALL_COMMAND_LOG" "docker daemon logs must cap non-blocking buffer"
	assert_not_contains '"containerd-snapshotter": true' "$INSTALL_COMMAND_LOG" "docker daemon must not enable containerd snapshotter with explicit overlay2 by default"
	assert_not_contains "overlay2.size=20G" "$INSTALL_COMMAND_LOG" "overlay2 size limit must be opt-in and quota-gated"
	assert_not_contains "docker.network.remove docker network rm docker-proxy_default" "$INSTALL_COMMAND_LOG" "docker network creation must not auto-delete compose default network"
}

test_docker_containerd_snapshotter_is_explicit_opt_in() {
	make_fixture
	export DOCKER_ENABLE_CONTAINERD_SNAPSHOTTER=1
	run_installer run docker --destroy-docker-data
	assert_contains '"storage-driver": "overlay2"' "$INSTALL_COMMAND_LOG" "docker daemon must keep explicit overlay2 when snapshotter opt-in is requested"
	assert_contains '"containerd-snapshotter": true' "$INSTALL_COMMAND_LOG" "containerd snapshotter must be available only via explicit opt-in"
	assert_contains "docker.validate.driver_status" "$INSTALL_COMMAND_LOG" "docker validation must catch overlayfs migration after daemon restart"
}

test_docker_installs_journald_policy() {
	make_fixture
	run_installer run docker --destroy-docker-data
	assert_contains "docker.journald.dir install -d -m 0755 /etc/systemd/journald.conf.d" "$INSTALL_COMMAND_LOG" "docker install must create journald drop-in directory"
	assert_contains "docker.journald.write" "$INSTALL_COMMAND_LOG" "docker install must write journald policy"
	assert_contains "SystemMaxUse=200M" "$INSTALL_COMMAND_LOG" "journald policy must cap persistent journal"
	assert_contains "RuntimeKeepFree=200M" "$INSTALL_COMMAND_LOG" "journald policy must keep runtime free space"
	assert_contains "docker.journald.restart systemctl try-restart systemd-journald" "$INSTALL_COMMAND_LOG" "docker install must apply journald policy"
}

test_uninstall_plan_is_non_destructive() {
	make_fixture
	run_installer uninstall --plan
	assert_contains "Uninstall plan" "$tmpdir/stdout" "uninstall plan must be visible"
	assert_contains "uninstall.plan" "$INSTALL_COMMAND_LOG" "uninstall plan must be routed through runner"
	assert_not_contains "compose.down" "$INSTALL_COMMAND_LOG" "plan must not stop compose"
	assert_not_contains "rm -rf" "$INSTALL_COMMAND_LOG" "plan must not remove files"
	assert_not_contains "ufw --force reset" "$INSTALL_COMMAND_LOG" "plan must not reset firewall"
}

test_uninstall_apply_requires_confirmation() {
	make_fixture
	if run_installer uninstall --apply; then
		fail "uninstall apply without --yes must fail in non-interactive mode"
	fi
	assert_contains "--apply requires explicit opt-in with --yes" "$tmpdir/stderr" "uninstall apply must require confirmation"
	assert_not_contains "compose.down" "$INSTALL_COMMAND_LOG" "unconfirmed uninstall must not stop compose"
}

test_uninstall_apply_uses_mock_runner_and_explicit_purge_flags() {
	make_fixture
	unset PORT_REMOTE_SSH
	cat >"$INSTALL_STATE_DIR/install.env" <<'ENV'
PORT_REMOTE_SSH="22022"
PORT_REMOTE_TEST="2443"
ENV
	run_installer uninstall --apply --yes --purge-docker-data --purge-firewall --purge-ssh --purge-network --remove-project-root
	assert_contains "compose.down" "$INSTALL_COMMAND_LOG" "uninstall must stop compose through runner"
	assert_contains "docker.volume.prune" "$INSTALL_COMMAND_LOG" "docker data purge must be explicit"
	assert_contains "firewall.purge" "$INSTALL_COMMAND_LOG" "firewall purge must be explicit"
	assert_contains "ufw delete allow 22022/tcp" "$INSTALL_COMMAND_LOG" "firewall purge must load PORT_REMOTE_SSH from install-state"
	assert_contains "ufw delete allow 2443/tcp" "$INSTALL_COMMAND_LOG" "firewall purge must load all PORT_REMOTE_* values from install-state"
	assert_contains "ufw delete allow 443/udp" "$INSTALL_COMMAND_LOG" "firewall purge must remove accepted UDP 443 stage rule"
	assert_contains "ssh.restore" "$INSTALL_COMMAND_LOG" "ssh purge must be explicit"
	assert_contains "network.restore" "$INSTALL_COMMAND_LOG" "network purge must be explicit"
	assert_contains "project.remove" "$INSTALL_COMMAND_LOG" "project root removal must be explicit"
	assert_not_contains "dnscrypt.purge" "$INSTALL_COMMAND_LOG" "default uninstall apply must not purge dnscrypt without flag"
}

test_uninstall_can_remove_docker_engine_with_explicit_flag() {
	make_fixture
	run_installer uninstall --apply --yes --purge-docker-engine
	assert_contains "docker.maintenance.disable systemctl disable --now docker-proxy-maintenance.timer" "$INSTALL_COMMAND_LOG" "docker engine purge must disable maintenance timer"
	assert_contains "docker.maintenance.service.remove rm -f /etc/systemd/system/docker-proxy-maintenance.service" "$INSTALL_COMMAND_LOG" "docker engine purge must remove maintenance service"
	assert_contains "docker.maintenance.timer.remove rm -f /etc/systemd/system/docker-proxy-maintenance.timer" "$INSTALL_COMMAND_LOG" "docker engine purge must remove maintenance timer"
	assert_contains "docker.remove.packages" "$INSTALL_COMMAND_LOG" "docker engine purge must remove packages"
	assert_contains "docker.data.remove" "$INSTALL_COMMAND_LOG" "docker engine purge must remove Docker data dirs"
}

test_self_update_check_persists_branch_without_applying() {
	make_fixture
	export INSTALL_MOCK_REMOTE_VERSION=$INSTALLER_NEWER_VERSION
	INSTALL_MOCK_REMOTE_CHANGELOG=$(printf '%s\n' \
		'# Журнал изменений установщика' \
		'' \
		"## ${INSTALLER_NEWER_VERSION} - 2026-10-17" \
		'- Новая проверка' \
		'' \
		"## ${INSTALLER_VERSION} - 2026-10-16" \
		'- Текущая версия')
	export INSTALL_MOCK_REMOTE_CHANGELOG
	run_installer self-update --branch feature/install --check
	assert_contains "update.branch=feature/install" "$INSTALL_STATE_DIR/config" "branch must be persisted"
	assert_contains "self-update.check" "$INSTALL_COMMAND_LOG" "self-update check must be routed through runner"
	assert_contains "self-update: update available: ${INSTALLER_VERSION} -> ${INSTALLER_NEWER_VERSION}" "$tmpdir/stdout" "check must report newer remote version"
	assert_contains "## ${INSTALLER_NEWER_VERSION}" "$tmpdir/stdout" "check must print newer changelog section"
	assert_not_contains "## ${INSTALLER_VERSION}" "$tmpdir/stdout" "check must not print current version changelog section"
	assert_not_contains "self-update.apply" "$INSTALL_COMMAND_LOG" "check must not apply files"
}

test_self_update_apply_tolerates_diff_changes() {
	make_fixture
	export INSTALL_MOCK_REMOTE_VERSION=$INSTALLER_NEWER_VERSION
	run_installer self-update --branch feature/install --yes
	assert_contains "self-update.diff" "$INSTALL_COMMAND_LOG" "self-update must record diff"
	assert_contains "self-update.apply" "$INSTALL_COMMAND_LOG" "self-update must continue to apply when diff reports changes"
	assert_contains "self-update: applied feature/install (${INSTALLER_VERSION} -> ${INSTALLER_NEWER_VERSION})" "$tmpdir/stdout" "self-update must print applied version range"
}

test_self_update_equal_version_does_not_apply_without_force() {
	make_fixture
	run_installer self-update --branch feature/install --yes
	assert_contains "self-update: up to date (${INSTALLER_VERSION})" "$tmpdir/stdout" "equal version must be treated as up to date"
	assert_not_contains "self-update.apply" "$INSTALL_COMMAND_LOG" "equal version must not apply without --force"
}

test_self_update_force_applies_equal_version() {
	make_fixture
	run_installer self-update --branch feature/install --yes --force
	assert_contains "self-update.apply" "$INSTALL_COMMAND_LOG" "force must apply even when versions are equal"
	assert_contains "self-update: applied feature/install (${INSTALLER_VERSION} -> ${INSTALLER_VERSION})" "$tmpdir/stdout" "force apply must print version range"
}

test_wizard_offers_update_and_uses_same_dispatcher() {
	make_fixture
	printf 'env\n\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Update check: installer is up to date (${INSTALLER_VERSION})" "$tmpdir/stdout" "wizard must report up-to-date installer without update prompt"
	assert_not_contains "Run self-update now?" "$tmpdir/stdout" "wizard must not prompt when no newer version exists"
	assert_contains "env.render" "$INSTALL_COMMAND_LOG" "wizard env selection must use command dispatcher"
}

test_wizard_offers_update_only_when_newer_version_exists() {
	make_fixture
	export INSTALL_MOCK_REMOTE_VERSION=$INSTALLER_NEWER_VERSION
	INSTALL_MOCK_REMOTE_CHANGELOG=$(printf '%s\n' \
		'# Журнал изменений установщика' \
		'' \
		"## ${INSTALLER_NEWER_VERSION} - 2026-10-17" \
		'- Новая версия wizard' \
		'' \
		"## ${INSTALLER_VERSION} - 2026-10-16" \
		'- Текущая версия')
	export INSTALL_MOCK_REMOTE_CHANGELOG
	printf 'n\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Update available: ${INSTALLER_VERSION} -> ${INSTALLER_NEWER_VERSION}" "$tmpdir/stdout" "wizard must show newer installer version"
	assert_contains "## ${INSTALLER_NEWER_VERSION}" "$tmpdir/stdout" "wizard must show newer changelog section"
	assert_not_contains "## ${INSTALLER_VERSION}" "$tmpdir/stdout" "wizard must not show current changelog section"
	assert_contains "Run self-update now?" "$tmpdir/stdout" "wizard must prompt only for newer version"
	assert_not_contains "self-update.apply" "$INSTALL_COMMAND_LOG" "declined wizard update must not apply"
}

test_wizard_menu_accepts_numbered_choices() {
	make_fixture
	printf '2\n\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "0. dnscrypt" "$tmpdir/stdout" "wizard must show dnscrypt as first step"
	assert_contains "1. apt" "$tmpdir/stdout" "wizard must show apt as numbered step"
	assert_contains "2. env" "$tmpdir/stdout" "wizard must show numbered menu"
	assert_contains "env.render" "$INSTALL_COMMAND_LOG" "wizard must dispatch numbered choices"
}

test_wizard_toggles_optional_feature_flags_and_renders_env() {
	make_fixture
	printf 't\n1\n2\n3\n4\n5\na\n\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "t. toggles" "$tmpdir/stdout" "wizard must expose feature toggles"
	assert_contains "Feature toggles:" "$tmpdir/stdout" "toggle screen must have a clear heading"
	assert_contains "1. ENABLE_LAMPAC" "$tmpdir/stdout" "toggle screen must show Lampac flag"
	assert_contains "2. ENABLE_TELEMT" "$tmpdir/stdout" "toggle screen must show Telemt flag"
	assert_contains "3. ENABLE_HYSTERIA2" "$tmpdir/stdout" "toggle screen must show Hysteria2 flag"
	assert_contains "4. ENABLE_VLESS_GRPC" "$tmpdir/stdout" "toggle screen must show VLESS gRPC flag"
	assert_contains "5. ENABLE_MIHOMO" "$tmpdir/stdout" "toggle screen must show Mihomo flag"
	assert_contains "env.render" "$INSTALL_COMMAND_LOG" "applying toggles must render env through dispatcher"
	assert_contains "ENABLE_LAMPAC=true" "$INSTALL_STATE_DIR/install.env" "Lampac toggle must persist true"
	assert_contains "ENABLE_TELEMT=true" "$INSTALL_STATE_DIR/install.env" "Telemt toggle must persist true"
	assert_contains "ENABLE_HYSTERIA2=false" "$INSTALL_STATE_DIR/install.env" "Hysteria2 toggle must persist false"
	assert_contains "ENABLE_VLESS_GRPC=true" "$INSTALL_STATE_DIR/install.env" "VLESS gRPC toggle must persist true"
	assert_contains "ENABLE_MIHOMO=true" "$INSTALL_STATE_DIR/install.env" "Mihomo toggle must persist true"
	assert_contains "ENABLE_LAMPAC=true" "$INSTALL_ROOT/compose.d/.env" "Lampac toggle must render compose env"
	assert_contains "ENABLE_TELEMT=true" "$INSTALL_ROOT/compose.d/.env" "Telemt toggle must render compose env"
	assert_contains "ENABLE_HYSTERIA2=false" "$INSTALL_ROOT/compose.d/.env" "Hysteria2 toggle must render compose env"
	assert_contains "ENABLE_VLESS_GRPC=true" "$INSTALL_ROOT/compose.d/.env" "VLESS gRPC toggle must render compose env"
	assert_contains "ENABLE_MIHOMO=true" "$INSTALL_ROOT/compose.d/.env" "Mihomo toggle must render compose env"
	assert_contains "VISION_FALLBACK_HOST=telemt" "$INSTALL_ROOT/compose.d/.env" "enabled Telemt must rerender fallback target"
}

test_wizard_toggle_exit_does_not_persist_changes() {
	make_fixture
	printf 't\n1\nx\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Feature toggles:" "$tmpdir/stdout" "toggle screen must render before exit"
	assert_not_contains "ENABLE_LAMPAC=true" "$INSTALL_STATE_DIR/install.env" "exiting toggles without apply must not persist changes"
	assert_not_contains "env.render" "$INSTALL_COMMAND_LOG" "exiting toggles without apply must not render env"
}

test_wizard_removes_html_and_shows_last_status() {
	make_fixture
	printf '2\n\n9\n\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Last operation: OK env" "$tmpdir/stdout" "wizard must show final status for previous operation"
	assert_contains "9. final" "$tmpdir/stdout" "wizard final step must be menu item 9"
	assert_not_contains "html" "$tmpdir/stdout" "wizard must not show removed html step"
	assert_contains "final.summary" "$INSTALL_COMMAND_LOG" "wizard must dispatch final as menu item 8"
}

test_wizard_rejects_unknown_menu_choice_without_exit() {
	make_fixture
	printf '99\n\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Last operation: INVALID 99" "$tmpdir/stdout" "wizard must report invalid menu choices"
	assert_contains "Unknown menu item: 99" "$tmpdir/stdout" "wizard must explain invalid menu choice"
	assert_contains "Available steps:" "$tmpdir/stdout" "wizard must continue after invalid menu choice"
}

test_wizard_streams_output_and_waits_for_enter() {
	make_fixture
	printf '7\ny\n\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Running network..." "$tmpdir/stdout" "wizard must start step output immediately"
	assert_contains "net.ipv4.tcp_keepalive_time" "$tmpdir/stdout" "wizard must stream step output to the console"
	assert_contains "Press Enter to continue..." "$tmpdir/stdout" "wizard must pause after completed operation"
	assert_contains "Log: $INSTALL_STATE_DIR/wizard-last-network.log" "$tmpdir/stdout" "wizard must keep log link after streamed output"
}

test_wizard_apt_step_streams_and_uses_confirmation() {
	make_fixture
	printf '1\ny\n\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Running apt..." "$tmpdir/stdout" "wizard must show step start before apt output"
	assert_contains "Press Enter to continue..." "$tmpdir/stdout" "wizard must wait after apt step"
	assert_contains "apt.update" "$INSTALL_COMMAND_LOG" "apt wizard step must run apt update through runner"
	assert_contains "apt.upgrade" "$INSTALL_COMMAND_LOG" "apt wizard step must run apt upgrade through runner"
}

test_wizard_compose_output_filter_removes_pull_noise() {
	make_fixture
	source "$ROOT_DIR/script/modules/01_menu.sh"
	wizard_filter_compose_output >"$tmpdir/filtered-compose.out" <<'OUT'
[2026-05-08 23:52:53] [run-compose] Каталог с compose-файлами: /opt/docker-proxy/compose.d
[2026-05-08 23:52:53] [run-compose] Используем env-файл: /opt/docker-proxy/compose.d/.env
[2026-05-08 23:52:53] [run-compose] Project root: /opt/docker-proxy
[2026-05-08 23:52:53] [run-compose] Lock file: /opt/state/docker-proxy-compose.lock
[2026-05-08 23:52:53] [run-compose] Проверяем конфигурацию: docker compose --project-name docker-proxy --env-file /opt/docker-proxy/compose.d/.env -f /opt/docker-proxy/compose.d/00-base.yml config
[2026-05-08 23:52:55] [run-compose] Попытка 1/3: docker compose --project-name docker-proxy --env-file /opt/docker-proxy/compose.d/.env -f /opt/docker-proxy/compose.d/00-base.yml up -d
Created symlink '/etc/systemd/system/timers.target.wants/docker-proxy-maintenance.timer' → '/etc/systemd/system/docker-proxy-maintenance.timer'.
NEXT                        LEFT LAST PASSED UNIT                           ACTIVATES
Sat 2026-10-17 00:35:22 UTC   7h -         - docker-proxy-maintenance.timer docker-proxy-maintenance.service
1 timers listed.
 Image torotin/caddy-l4:latest Pulling
 Image traefik:latest Pulling
 59fccd767ac6 Preparing
 5b40d9c3d03b Waiting 0B
 e2de96513ba9 Verifying Checksum 0B
 59fccd767ac6 Pulling fs layer 0B
 a57ae2b1d9eb Downloading 10.49MB
 59fccd767ac6 Pull complete 0B
 Image torotin/caddy-l4:latest Pulled
 Image traefik:latest Pulled
 Container caddy Starting
 Container caddy Healthy
OUT
	assert_contains "Pulling image: torotin/caddy-l4:latest" "$tmpdir/filtered-compose.out" "filter must emit per-image pull for caddy-l4"
	assert_contains "Pulling image: traefik:latest" "$tmpdir/filtered-compose.out" "filter must emit per-image pull for traefik"
	assert_contains "Validating compose configuration..." "$tmpdir/filtered-compose.out" "filter must keep concise validation status"
	assert_contains "Starting compose stack: Попытка 1/3" "$tmpdir/filtered-compose.out" "filter must keep concise attempt status"
	assert_contains "Docker images pulled" "$tmpdir/filtered-compose.out" "filter must summarize pulled images once"
	assert_contains "Container caddy Healthy" "$tmpdir/filtered-compose.out" "filter must keep container status"
	assert_not_contains "Pulling Docker images..." "$tmpdir/filtered-compose.out" "old collapse summary must be removed"
	assert_not_contains "docker compose --project-name" "$tmpdir/filtered-compose.out" "filter must hide full compose command"
	assert_not_contains "Downloading 10.49MB" "$tmpdir/filtered-compose.out" "filter must hide download spam"
	assert_not_contains "Pulling fs layer" "$tmpdir/filtered-compose.out" "filter must hide Pulling fs layer"
	assert_not_contains "Waiting 0B" "$tmpdir/filtered-compose.out" "filter must hide Waiting layer status"
	assert_not_contains "Verifying Checksum" "$tmpdir/filtered-compose.out" "filter must hide Verifying Checksum"
	assert_not_contains "59fccd767ac6 Preparing" "$tmpdir/filtered-compose.out" "filter must hide Preparing layer status"
	assert_not_contains "Project root:" "$tmpdir/filtered-compose.out" "filter must hide Project root"
	assert_not_contains "Lock file:" "$tmpdir/filtered-compose.out" "filter must hide Lock file"
	assert_not_contains "Created symlink" "$tmpdir/filtered-compose.out" "filter must hide Created symlink"
	assert_not_contains "1 timers listed" "$tmpdir/filtered-compose.out" "filter must hide timers listed"
}

test_wizard_compose_step_ticker_emits_liveness() {
	make_fixture
	source "$ROOT_DIR/script/modules/01_menu.sh"
	wizard_wait_continue() { :; }
	export INSTALL_STATE_DIR="$tmpdir/state"
	mkdir -p "$INSTALL_STATE_DIR"
	export WIZARD_COMPOSE_TICKER_SECONDS=1
	wizard_execute_step compose sleep 3 >"$tmpdir/ticker.out" 2>&1
	assert_contains "Compose step still running..." "$tmpdir/ticker.out" "compose step must emit ticker liveness"
	local lines_after lines_later
	lines_after=$(wc -l <"$tmpdir/ticker.out")
	sleep 2
	lines_later=$(wc -l <"$tmpdir/ticker.out")
	[[ "$lines_after" == "$lines_later" ]] || fail "compose ticker must stop after step completes"
}

test_html_step_is_removed_from_cli_dispatch() {
	make_fixture
	if run_installer run html; then
		fail "removed html step must fail"
	fi
	assert_contains "unknown step: html" "$tmpdir/stderr" "removed html step must be rejected"
}

test_wizard_collects_required_variables_before_menu() {
	make_fixture
	unset WEBDOMAIN USER_SSH PASS_SSH USER_WEB PASS_WEB SSH_PBK
	printf 'wizard.example.test\nwizard-user\nwizard-pass\nweb-user\nweb-pass\n\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Required installer variables" "$tmpdir/stdout" "wizard must collect required variables before menu"
	assert_contains "Web domain" "$tmpdir/stdout" "wizard must prompt for WEBDOMAIN"
	assert_contains "SSH username" "$tmpdir/stdout" "wizard must prompt for USER_SSH"
	assert_contains "SSH password" "$tmpdir/stdout" "wizard must prompt for PASS_SSH"
	assert_contains "Web username" "$tmpdir/stdout" "wizard must prompt for USER_WEB"
	assert_contains "Web password" "$tmpdir/stdout" "wizard must prompt for PASS_WEB"
	assert_contains "SSH public key" "$tmpdir/stdout" "wizard must offer optional SSH public key"
	assert_contains "1. apt" "$tmpdir/stdout" "wizard must show menu after required prompts"
}

test_wizard_persists_required_variables_before_env_step() {
	make_fixture
	unset WEBDOMAIN USER_SSH PASS_SSH USER_WEB PASS_WEB SSH_PBK
	printf 'persist.example.test\npersist-ssh\nssh-pass\npersist-web\nweb-pass\nssh-ed25519 persist-key\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains 'WEBDOMAIN="persist.example.test"' "$INSTALL_STATE_DIR/install.env" "wizard must persist WEBDOMAIN immediately"
	assert_contains 'USER_SSH="persist-ssh"' "$INSTALL_STATE_DIR/install.env" "wizard must persist USER_SSH immediately"
	assert_contains 'PASS_SSH="ssh-pass"' "$INSTALL_STATE_DIR/install.env" "wizard must persist PASS_SSH immediately"
	assert_contains 'USER_WEB="persist-web"' "$INSTALL_STATE_DIR/install.env" "wizard must persist USER_WEB immediately"
	assert_contains 'PASS_WEB="web-pass"' "$INSTALL_STATE_DIR/install.env" "wizard must persist PASS_WEB immediately"
	assert_contains 'SSH_PBK="ssh-ed25519 persist-key"' "$INSTALL_STATE_DIR/install.env" "wizard must persist optional SSH key immediately"
}

test_batch_requires_ssh_and_web_credentials() {
	make_fixture
	unset USER_SSH PASS_SSH USER_WEB PASS_WEB
	if run_installer run env; then
		fail "batch run must require SSH/Web credentials"
	fi
	assert_contains "USER_SSH is required" "$tmpdir/stderr" "batch must require USER_SSH first"
}

test_dnscrypt_requires_apply_confirmation() {
	make_fixture
	if run_installer run dnscrypt; then
		fail "dnscrypt without --apply --yes must fail"
	fi
	assert_contains "requires explicit opt-in" "$tmpdir/stderr" "dnscrypt must require --apply"
	assert_not_contains "dnscrypt.deps" "$INSTALL_COMMAND_LOG" "dnscrypt must not install without opt-in"
}

test_dnscrypt_mock_install_logs_intent_without_host_mutation() {
	make_fixture
	run_installer run dnscrypt --apply --yes
	assert_contains "dnscrypt.mode" "$INSTALL_COMMAND_LOG" "dnscrypt must log install mode"
	assert_contains "dnscrypt.deps" "$INSTALL_COMMAND_LOG" "dnscrypt must log dependency install"
	assert_contains "dnscrypt.resolve.latest" "$INSTALL_COMMAND_LOG" "dnscrypt must resolve latest release by default"
	assert_contains "dnscrypt.download" "$INSTALL_COMMAND_LOG" "dnscrypt must log binary download intent"
	assert_contains "dnscrypt.config" "$INSTALL_COMMAND_LOG" "dnscrypt must log config write"
	assert_contains "dnscrypt.unit" "$INSTALL_COMMAND_LOG" "dnscrypt must log unit write"
	assert_contains "dnscrypt.resolved" "$INSTALL_COMMAND_LOG" "dnscrypt must log resolved drop-in"
	assert_contains "dnscrypt.service.enable" "$INSTALL_COMMAND_LOG" "dnscrypt must log service enable"
	assert_contains "dnscrypt.dig" "$INSTALL_COMMAND_LOG" "dnscrypt must log dig readiness check"
	assert_not_contains "vendor/" "$INSTALL_COMMAND_LOG" "dnscrypt must not reference a vendor path"
	assert_not_contains "chattr +i" "$INSTALL_COMMAND_LOG" "mock dnscrypt must not lock resolv.conf"
}

test_dnscrypt_forwards_force_flag() {
	make_fixture
	run_installer run dnscrypt --apply --yes --force
	assert_contains "dnscrypt.mode" "$INSTALL_COMMAND_LOG" "dnscrypt must log mode for --force"
	assert_contains "--force" "$INSTALL_COMMAND_LOG" "dnscrypt must record --force in mode log"
	assert_not_contains "vendor/" "$INSTALL_COMMAND_LOG" "dnscrypt --force must not reference a vendor path"
}

test_dnscrypt_pins_version_flag() {
	make_fixture
	run_installer run dnscrypt --apply --yes --version 2.1.14
	assert_contains "dnscrypt.resolve.pinned" "$INSTALL_COMMAND_LOG" "dnscrypt must log pinned version resolve"
	assert_contains "2.1.14" "$INSTALL_COMMAND_LOG" "dnscrypt must record --version value"
	assert_contains "dnscrypt-proxy-2.1.14" "$INSTALL_COMMAND_LOG" "dnscrypt download label must use pinned version"
	assert_not_contains "dnscrypt.resolve.latest" "$INSTALL_COMMAND_LOG" "pinned version must not query GitHub latest"
}

test_dnscrypt_detect_connectivity_uses_shared_probe_in_mock() {
	make_fixture
	unset DNSCRYPT_HAS_IPV4 DNSCRYPT_HAS_IPV6 DNSCRYPT_PUBLIC_IPV4 DNSCRYPT_PUBLIC_IPV6
	unset DNSCRYPT_LISTEN_ADDRESSES DNSCRYPT_IPV4_SERVERS DNSCRYPT_IPV6_SERVERS
	export INSTALL_MOCK=1
	# shellcheck source=/dev/null
	source "$ROOT_DIR/script/modules/00_common.sh"
	# shellcheck source=/dev/null
	source "$ROOT_DIR/script/modules/04_dnscrypt.sh"
	dnscrypt_detect_connectivity >/dev/null
	((DNSCRYPT_HAS_IPV4 == 1 && DNSCRYPT_HAS_IPV6 == 1)) || fail "mock probe must detect dual connectivity"
	[[ "$DNSCRYPT_PUBLIC_IPV4" == "198.51.100.10" ]] || fail "DNSCRYPT_PUBLIC_IPV4 must come from shared probe"
	[[ "$DNSCRYPT_PUBLIC_IPV6" == "2001:db8::10" ]] || fail "DNSCRYPT_PUBLIC_IPV6 must come from shared probe"
	[[ "$DNSCRYPT_LISTEN_ADDRESSES" == "['127.0.0.1:53', '[::1]:53']" ]] || fail "dual must listen on v4 and v6 localhost"
	[[ "$DNSCRYPT_IPV4_SERVERS" == "true" && "$DNSCRYPT_IPV6_SERVERS" == "true" ]] || fail "dual must enable both server families"
}

test_dnscrypt_decide_mode_matches_original_semver_rules() {
	make_fixture
	# shellcheck source=script/modules/00_common.sh
	source "$ROOT_DIR/script/modules/00_common.sh"
	# shellcheck source=script/modules/04_dnscrypt.sh
	source "$ROOT_DIR/script/modules/04_dnscrypt.sh"
	DNSCRYPT_VERSION=2.1.18
	DNSCRYPT_FORCE_REINSTALL=0
	DNSCRYPT_RECONFIGURE_ONLY=0
	DNSCRYPT_EXISTING_BINARY=1
	DNSCRYPT_EXISTING_UNIT=1
	DNSCRYPT_EXISTING_ACTIVE=1
	DNSCRYPT_EXISTING_ENABLED=1
	DNSCRYPT_INSTALLED_VERSION=2.1.18
	dnscrypt_is_healthy_install() { return 0; }
	dnscrypt_decide_mode >/dev/null
	[[ "$DNSCRYPT_MODE" == "skip" ]] || fail "same healthy version must skip (got $DNSCRYPT_MODE)"
	((DNSCRYPT_SKIP_HEALTHY == 1)) || fail "skip flag must be set for healthy install"
	dnscrypt_is_healthy_install() { return 1; }
	dnscrypt_decide_mode >/dev/null
	[[ "$DNSCRYPT_MODE" == "reconfigure" ]] || fail "same version but unhealthy must reconfigure (got $DNSCRYPT_MODE)"
	DNSCRYPT_INSTALLED_VERSION=2.1.14
	dnscrypt_decide_mode >/dev/null
	[[ "$DNSCRYPT_MODE" == "upgrade" ]] || fail "older version must upgrade (got $DNSCRYPT_MODE)"
	DNSCRYPT_FORCE_REINSTALL=1
	dnscrypt_decide_mode >/dev/null
	[[ "$DNSCRYPT_MODE" == "install" ]] || fail "--force must install (got $DNSCRYPT_MODE)"
}

test_dnscrypt_appears_in_usage_and_wizard() {
	make_fixture
	run_installer help
	assert_contains "dnscrypt apt env docker" "$tmpdir/stdout" "usage must list dnscrypt before apt"
	printf '0\nn\n\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "0. dnscrypt" "$tmpdir/stdout" "wizard must list dnscrypt"
	assert_contains "DNSCrypt install skipped" "$tmpdir/stdout" "wizard must allow skipping dnscrypt"
	assert_not_contains "dnscrypt.deps" "$INSTALL_COMMAND_LOG" "declined dnscrypt must not install"
}

test_uninstall_purge_dnscrypt_is_explicit() {
	make_fixture
	run_installer uninstall --plan
	assert_not_contains "Remove host DNSCrypt" "$tmpdir/stdout" "default uninstall plan must not purge dnscrypt"
	run_installer uninstall --plan --purge-dnscrypt
	assert_contains "Remove host DNSCrypt" "$tmpdir/stdout" "plan with --purge-dnscrypt must mention DNSCrypt removal"
	run_installer uninstall --apply --yes --purge-dnscrypt
	assert_contains "dnscrypt.purge.stop" "$INSTALL_COMMAND_LOG" "purge-dnscrypt must stop service through runner"
	assert_contains "dnscrypt.purge.resolv" "$INSTALL_COMMAND_LOG" "purge-dnscrypt must restore public DNS"
	assert_contains "dnscrypt.purge.dir" "$INSTALL_COMMAND_LOG" "purge-dnscrypt must remove install dir"
}

test_final_summary_mentions_host_dnscrypt() {
	make_fixture
	run_installer run env final
	assert_contains "Host DNS         : DNSCrypt/DoH via 127.0.0.1:53" "$tmpdir/stdout" "final summary must mention host DNSCrypt"
}

test_apt_detects_country_specific_mirror_list() {
	make_fixture
	export APT_COUNTRY=RU
	run_installer run apt --apply --yes
	assert_contains "RU.txt" "$INSTALL_COMMAND_LOG" "apt must use country-specific mirror list"
}

test_apt_installs_required_dependencies() {
	make_fixture
	run_installer run apt --apply --yes
	assert_contains "apt.install.deps" "$INSTALL_COMMAND_LOG" "apt must install required dependencies"
	assert_contains "ca-certificates curl gnupg lsb-release apache2-utils gettext-base" "$INSTALL_COMMAND_LOG" "apt dependencies must include installer requirements"
	assert_contains "mc perl openssl lsof ufw jq gzip cron sqlite3 git tcpdump net-tools traceroute whois idn iproute2 rsync sudo openssh-client psmisc unattended-upgrades" "$INSTALL_COMMAND_LOG" "apt dependencies must include legacy utility list"
	assert_contains "apt.locks.wait" "$INSTALL_COMMAND_LOG" "apt must wait for apt/dpkg locks"
	assert_contains "apt.timer.enable" "$INSTALL_COMMAND_LOG" "apt must enable unattended-upgrades timers"
	assert_contains "apt.unattended.dry-run" "$INSTALL_COMMAND_LOG" "apt must validate unattended-upgrades"
}

test_apt_falls_back_when_selected_mirror_update_fails() {
	make_fixture
	export INSTALL_MOCK_APT_UPDATE_FAIL_ONCE=1
	run_installer run apt --apply --yes
	assert_contains "apt.update.fail apt-get update -y" "$INSTALL_COMMAND_LOG" "apt must detect failed update attempt"
	assert_contains "apt.sources.fallback printf fallback\\ mirror\\ %s\\\\n http://archive.ubuntu.com/ubuntu/" "$INSTALL_COMMAND_LOG" "apt must switch to fallback mirror"
	assert_contains "apt.lists.clean rm -rf /var/lib/apt/lists" "$INSTALL_COMMAND_LOG" "apt must clear stale package lists before retry"
	assert_contains "apt.update apt-get update -y" "$INSTALL_COMMAND_LOG" "apt must retry update after fallback"
	assert_contains "apt.install.deps" "$INSTALL_COMMAND_LOG" "apt must install dependencies only after retry"
}

test_wizard_skips_docker_wipe_when_user_declines() {
	make_fixture
	printf 'docker\nn\n\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "Docker wipe/reinstall skipped" "$tmpdir/stdout" "wizard must keep running when docker wipe is declined"
	assert_contains "Press Enter to continue..." "$tmpdir/stdout" "wizard must pause after skipped operation"
	assert_not_contains "docker.system.prune" "$INSTALL_COMMAND_LOG" "wizard must not wipe Docker when user declines"
}

test_wizard_confirms_apply_steps() {
	make_fixture
	printf 'firewall\ny\n\nssh\ny\n\nnetwork\ny\n\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "firewall.apply" "$INSTALL_COMMAND_LOG" "wizard must pass apply confirmation to firewall"
	assert_contains "ssh.apply" "$INSTALL_COMMAND_LOG" "wizard must pass apply confirmation to ssh"
	assert_contains "network.apply" "$INSTALL_COMMAND_LOG" "wizard must pass apply confirmation to network"
}

test_wizard_prompts_for_missing_user() {
	make_fixture
	unset USER_SSH PASS_SSH USER_WEB PASS_WEB SSH_PBK
	printf 'wizard-user\nwizard-pass\nweb-user\nweb-pass\n\nuser\n\nx\n' | bash "$INSTALLER" wizard >"$tmpdir/stdout" 2>"$tmpdir/stderr"
	assert_contains "SSH username" "$tmpdir/stdout" "wizard must prompt for missing USER_SSH"
	assert_contains "user.ensure useradd -m -d /home/wizard-user -s /bin/bash wizard-user" "$INSTALL_COMMAND_LOG" "wizard must pass prompted user to user step"
}

test_user_loads_rendered_state_env() {
	make_fixture
	unset USER_SSH PASS_SSH
	cat >"$INSTALL_STATE_DIR/install.env" <<'ENV'
USER_SSH="state-user"
PASS_SSH="state-pass"
ENV
	run_installer run user
	assert_contains "user.ensure useradd -m -d /home/state-user -s /bin/bash state-user" "$INSTALL_COMMAND_LOG" "user step must load USER_SSH from install-state"
	assert_contains "user.password chpasswd \\<stdin\\>" "$INSTALL_COMMAND_LOG" "user step must feed chpasswd through stdin"
}

test_user_configures_ssh_sudo_groups_and_aliases() {
	make_fixture
	run_installer run user
	assert_contains "user.ssh.dir install -d -m 0700" "$INSTALL_COMMAND_LOG" "user step must prepare .ssh"
	assert_contains "user.ssh.keygen ssh-keygen -t ed25519" "$INSTALL_COMMAND_LOG" "user step must generate ED25519 key"
	assert_contains "user.ssh.authorized.add printf" "$INSTALL_COMMAND_LOG" "user step must add provided SSH public key"
	assert_contains "user.groups usermod -aG sudo\\,docker deployer" "$INSTALL_COMMAND_LOG" "user step must add sudo/docker groups"
	assert_contains "user.sudoers.write" "$INSTALL_COMMAND_LOG" "user step must configure sudoers"
	assert_contains "user.aliases.install" "$INSTALL_COMMAND_LOG" "user step must install bash aliases"
	assert_contains "user.home.chown chown -R deployer:deployer /home/deployer" "$INSTALL_COMMAND_LOG" "user step must restore home ownership"
}

test_user_sudoers_content_uses_portable_defaults() {
	make_fixture
	# shellcheck source=script/modules/05_user.sh
	. "$ROOT_DIR/script/modules/05_user.sh"
	USER_SSH=deployer install_user_sudoers_content >"$tmpdir/sudoers"
	assert_contains "deployer ALL=(ALL) NOPASSWD:ALL" "$tmpdir/sudoers" "sudoers must grant expected passwordless sudo"
	assert_not_contains "log_output" "$tmpdir/sudoers" "sudoers must not use sudo-rs incompatible log_output"
	assert_not_contains "logfile" "$tmpdir/sudoers" "sudoers must not use sudo-rs incompatible logfile"
	assert_not_contains "tty_tickets" "$tmpdir/sudoers" "sudoers must not use sudo-rs incompatible tty_tickets"
	assert_not_contains "requiretty" "$tmpdir/sudoers" "sudoers must not use sudo-rs incompatible requiretty"
}

test_compose_uses_installer_state_lock() {
	make_fixture
	run_installer run compose
	assert_contains "project.sync" "$INSTALL_COMMAND_LOG" "compose step must sync project files when runner is missing"
	assert_contains "env.render" "$INSTALL_COMMAND_LOG" "compose step must render env when compose env is missing"
	assert_contains "docker.network.ensure" "$INSTALL_COMMAND_LOG" "compose step must ensure external Docker networks"
	assert_contains "COMPOSE_DIR=$INSTALL_ROOT/compose.d" "$INSTALL_COMMAND_LOG" "compose step must pass explicit compose directory"
	assert_contains "ENV_FILE=$INSTALL_ROOT/compose.d/.env" "$INSTALL_COMMAND_LOG" "compose step must pass explicit compose env file"
	assert_contains "LOCK_FILE=$INSTALL_STATE_DIR/docker-proxy-compose.lock" "$INSTALL_COMMAND_LOG" "compose step must avoid shared /tmp lock file"
	assert_contains "compose.validate env -u HT_PASS_ENCODED -u ADGUARD_ADMIN_HASH -u URI_SUB_PATH -u URI_JSON_PATH -u URI_CLASH_PATH -u URI_VLESS_XHTTP" "$INSTALL_COMMAND_LOG" "compose validation must not inherit transformed values from installer environment"
}

test_final_summary_prints_details() {
	make_fixture
	export ENABLE_MIHOMO=true
	run_installer run env final
	assert_contains "INSTALLATION SUMMARY" "$tmpdir/stdout" "final step must print summary"
	assert_contains "Domain           : example.test" "$tmpdir/stdout" "final summary must include domain"
	assert_contains "Target           : deployer@198.51.100.10:22022" "$tmpdir/stdout" "final summary must include SSH target"
	assert_contains "Homepage         : https://example.test/" "$tmpdir/stdout" "final summary must include service URLs"
	assert_contains "Mihomo UI        : https://example.test/" "$tmpdir/stdout" "final summary must include Mihomo UI URL"
	assert_contains "Mihomo secret    :" "$tmpdir/stdout" "final summary must print Mihomo controller secret for copy-paste"
	assert_contains "Traefik Dashboard: https://example.test/" "$tmpdir/stdout" "final summary must include dashboard URL"
	assert_contains "Compose validate : $INSTALL_ROOT/compose.d/run-compose.sh validate" "$tmpdir/stdout" "final summary must include operational commands"
	assert_contains "Summary saved: $INSTALL_STATE_DIR/install.summary" "$tmpdir/stdout" "final summary must print saved summary path"
	assert_contains "INSTALLATION SUMMARY" "$INSTALL_STATE_DIR/install.summary" "final step must persist summary file"
	assert_contains "Mihomo secret    :" "$INSTALL_STATE_DIR/install.summary" "final summary file must include Mihomo controller secret for copy-paste"
	assert_contains "Password         : configured, not printed" "$INSTALL_STATE_DIR/install.summary" "final summary must not print web password"
	assert_not_contains "Password         : $PASS_WEB" "$INSTALL_STATE_DIR/install.summary" "final summary must not leak web password"
	assert_not_contains "Password         : $PASS_SSH" "$INSTALL_STATE_DIR/install.summary" "final summary must not leak SSH password"
}

test_final_summary_urls_use_trailing_slash_except_doh() {
	make_fixture
	# shellcheck source=script/modules/09_finalize.sh
	. "$ROOT_DIR/script/modules/09_finalize.sh"
	SUMMARY_DOMAIN=example.test
	local panel doh traefik mihomo
	panel=$(install_summary_url "nC4sRgYpwUgiad")
	doh=$(install_summary_url "3pDA9wdT58rg0aMC" "" noslash)
	traefik=$(install_summary_url "UoAJFIMva4GETi" "dashboard/#/")
	mihomo=$(install_summary_url "mihomoPath" "ui/")
	[[ "$panel" == "https://example.test/nC4sRgYpwUgiad/" ]] || fail "panel summary URL must end with trailing slash; got: $panel"
	[[ "$doh" == "https://example.test/3pDA9wdT58rg0aMC" ]] || fail "DoH summary URL must stay exact Path without slash; got: $doh"
	[[ "$traefik" == "https://example.test/UoAJFIMva4GETi/dashboard/#/" ]] || fail "Traefik summary URL must keep dashboard fragment; got: $traefik"
	[[ "$mihomo" == "https://example.test/mihomoPath/ui/" ]] || fail "Mihomo UI summary URL must keep ui/ suffix; got: $mihomo"

	export ENABLE_MIHOMO=true
	run_installer run env final
	uri_from_env() {
		local key=$1
		grep -E "^${key}=" "$INSTALL_STATE_DIR/install.env" | head -n1 | cut -d= -f2- | tr -d '"'
	}
	local panel_path dozzle_path doh_path
	panel_path=$(uri_from_env URI_PANEL_PATH)
	dozzle_path=$(uri_from_env URI_DOZZLE)
	doh_path=$(uri_from_env URI_ADGUARD_DOH)
	[[ -n "$panel_path" && -n "$dozzle_path" && -n "$doh_path" ]] || fail "install.env must define panel/dozzle/doh URI paths"
	assert_contains "3X-UI Panel      : https://example.test/${panel_path}/" "$INSTALL_STATE_DIR/install.summary" "persisted panel URL must include trailing slash"
	assert_contains "Dozzle Logs      : https://example.test/${dozzle_path}/" "$INSTALL_STATE_DIR/install.summary" "persisted Dozzle URL must include trailing slash"
	assert_contains "AdGuard DoH      : https://example.test/${doh_path}" "$INSTALL_STATE_DIR/install.summary" "persisted DoH URL must omit trailing slash"
	assert_not_contains "AdGuard DoH      : https://example.test/${doh_path}/" "$INSTALL_STATE_DIR/install.summary" "persisted DoH URL must not gain a trailing slash"
}

test_doctor_rejects_unsupported_os() {
	make_fixture
	cat >"$INSTALL_TEST_OS_RELEASE" <<'OS'
ID=fedora
VERSION_ID=40
OS
	if run_installer doctor; then
		fail "doctor must reject unsupported OS"
	fi
	assert_contains "unsupported OS" "$tmpdir/stderr" "doctor must explain unsupported OS"
}

test_doctor_is_mock_only_and_reports_supported_os
test_doctor_rejects_unknown_profile
test_doctor_host_and_stack_profiles_parse
test_doctor_host_skips_stack
test_doctor_stack_profile_sets_expect
test_doctor_host_checks_user_firewall_matrix
test_doctor_strict_flag_parses
test_doctor_verbose_keeps_detailed_success_output
test_doctor_inventory_uses_bundled_telemt_panel_healthcheck
test_doctor_inventory_gates_dockcheck_on_active_compose_file
test_doctor_exit_preflight_default
test_doctor_exit_host
test_doctor_exit_stack_fail
test_doctor_exit_strict
test_doctor_exit_warn_ne_fail
test_doctor_exit_mock_skip
test_doctor_exit_docker_tier
test_doctor_exit_telemt_mihomo_gates
test_doctor_exit_unsupported_os
test_exit_resets_script_and_project_permissions
test_run_dispatches_named_steps_without_eval
test_compose_installs_docker_maintenance_timer
test_env_reports_permission_problem_before_backup
test_env_preserves_existing_state_defaults
test_env_renders_mihomo_config_with_generated_secret
test_env_normalizes_global_boolean_values
test_env_rejects_invalid_global_boolean_values
test_state_loader_preserves_literal_dollars
test_env_prints_rendered_paths
test_env_defaults_optional_services_disabled
test_env_writes_host_ip_mode_dual
test_env_ipv4_only_does_not_copy_v4_into_v6
test_ip_probe_sets_dual_mode_in_mock
test_ip_probe_ipv4_only_leaves_ipv6_empty
test_ip_probe_clears_stale_ipv6_when_unreachable
test_env_detects_public_ips_when_missing
test_env_generates_adguard_hash_from_htpasswd
test_env_writes_escaped_htpasswd_to_compose_env_for_labels
test_env_renders_telemt_network_lists_as_toml_arrays_from_legacy_state
test_env_can_disable_telemt_rendering
test_env_regenerates_stale_htpasswd_when_password_changes
test_env_regenerates_existing_hash_when_verify_is_unsupported
test_adguard_update_pass_uses_precomputed_hash
test_adguard_update_pass_updates_yaml_without_yq
test_state_loader_keeps_explicit_values_over_state
test_destructive_steps_require_explicit_flags
test_destructive_steps_use_mock_runner_when_explicit
test_firewall_does_not_preserve_current_ssh_port
test_firewall_ensures_ipv6_yes
test_doctor_dual_mock_logs_host_probes
test_ssh_rejects_invalid_port_before_apply
test_ssh_restarts_when_listener_check_fails_after_reload
test_ssh_listener_mock_uses_realistic_address_pattern
test_docker_install_handles_missing_docker_binary
test_network_sysctl_dual_preserves_slaac
test_network_sysctl_ipv4_keeps_ra_off
test_network_apply_uses_runner
test_docker_networks_created_dual_stack
test_docker_enable_ipv6_zero_dies_on_user_networks
test_docker_repo_and_daemon_config_are_safe
test_docker_containerd_snapshotter_is_explicit_opt_in
test_docker_installs_journald_policy
test_uninstall_plan_is_non_destructive
test_uninstall_apply_requires_confirmation
test_uninstall_apply_uses_mock_runner_and_explicit_purge_flags
test_uninstall_can_remove_docker_engine_with_explicit_flag
test_self_update_check_persists_branch_without_applying
test_self_update_apply_tolerates_diff_changes
test_self_update_equal_version_does_not_apply_without_force
test_self_update_force_applies_equal_version
test_wizard_offers_update_and_uses_same_dispatcher
test_wizard_offers_update_only_when_newer_version_exists
test_wizard_menu_accepts_numbered_choices
test_wizard_toggles_optional_feature_flags_and_renders_env
test_wizard_toggle_exit_does_not_persist_changes
test_wizard_removes_html_and_shows_last_status
test_wizard_rejects_unknown_menu_choice_without_exit
test_wizard_streams_output_and_waits_for_enter
test_wizard_apt_step_streams_and_uses_confirmation
test_wizard_compose_output_filter_removes_pull_noise
test_wizard_compose_step_ticker_emits_liveness
test_html_step_is_removed_from_cli_dispatch
test_wizard_collects_required_variables_before_menu
test_wizard_persists_required_variables_before_env_step
test_batch_requires_ssh_and_web_credentials
test_dnscrypt_requires_apply_confirmation
test_dnscrypt_mock_install_logs_intent_without_host_mutation
test_dnscrypt_forwards_force_flag
test_dnscrypt_pins_version_flag
test_dnscrypt_detect_connectivity_uses_shared_probe_in_mock
test_dnscrypt_decide_mode_matches_original_semver_rules
test_dnscrypt_appears_in_usage_and_wizard
test_uninstall_purge_dnscrypt_is_explicit
test_final_summary_mentions_host_dnscrypt
test_apt_detects_country_specific_mirror_list
test_apt_installs_required_dependencies
test_apt_falls_back_when_selected_mirror_update_fails
test_wizard_skips_docker_wipe_when_user_declines
test_wizard_confirms_apply_steps
test_wizard_prompts_for_missing_user
test_user_loads_rendered_state_env
test_user_configures_ssh_sudo_groups_and_aliases
test_user_sudoers_content_uses_portable_defaults
test_compose_uses_installer_state_lock
test_final_summary_prints_details
test_final_summary_urls_use_trailing_slash_except_doh
test_doctor_rejects_unsupported_os

printf 'test_installer_cli.bash: OK\n'
