#!/usr/bin/env bash
# Doctor orchestration: CLI parse, phase/expect, profile routing, recording API, checks, exit aggregation.

# Fixed matrix step order (installer.md Doctor Behavior).
DOCTOR_MATRIX_STEPS=(dnscrypt apt env docker user firewall ssh network compose final)

doctor_parse_args() {
	DOCTOR_PROFILE=full
	DOCTOR_VERBOSE=0
	DOCTOR_STRICT=0
	local arg profile_set=0
	for arg in "$@"; do
		case "$arg" in
		--verbose)
			DOCTOR_VERBOSE=1
			;;
		--strict)
			DOCTOR_STRICT=1
			;;
		host | stack)
			if ((profile_set)); then
				die "multiple doctor profiles: already ${DOCTOR_PROFILE}, got ${arg}"
			fi
			DOCTOR_PROFILE=$arg
			profile_set=1
			;;
		--*)
			die "unknown doctor flag: $arg"
			;;
		*)
			die "unknown doctor profile: $arg"
			;;
		esac
	done
	export DOCTOR_PROFILE DOCTOR_VERBOSE DOCTOR_STRICT
}

doctor_detect_phase() {
	# Mock never calls real docker inspect for phase detection.
	if [[ "${INSTALL_MOCK:-0}" == "1" ]]; then
		if [[ "${INSTALL_MOCK_DOCTOR_PHASE:-}" == "stack_expected" ]]; then
			DOCTOR_PHASE=stack_expected
		else
			DOCTOR_PHASE=preinstall
		fi
		export DOCTOR_PHASE
		return 0
	fi
	if [[ -f "$INSTALL_STATE_DIR/install.summary" ]]; then
		DOCTOR_PHASE=stack_expected
		export DOCTOR_PHASE
		return 0
	fi
	if command -v docker >/dev/null 2>&1 && docker inspect traefik >/dev/null 2>&1; then
		DOCTOR_PHASE=stack_expected
		export DOCTOR_PHASE
		return 0
	fi
	DOCTOR_PHASE=preinstall
	export DOCTOR_PHASE
}

doctor_set_expect_stack() {
	if [[ "${DOCTOR_PHASE:-preinstall}" == "stack_expected" || "${DOCTOR_PROFILE:-full}" == "stack" ]]; then
		DOCTOR_EXPECT_STACK=1
	else
		DOCTOR_EXPECT_STACK=0
	fi
	export DOCTOR_EXPECT_STACK
}

doctor_status_rank() {
	case "$1" in
	FAIL) printf '4' ;;
	WARN) printf '3' ;;
	SKIP) printf '2' ;;
	OK) printf '1' ;;
	*) printf '0' ;;
	esac
}

# Map record step → matrix key; empty means no matrix row (preflight / unknown).
doctor_matrix_key() {
	case "$1" in
	dnscrypt | apt | env | docker | user | firewall | ssh | network | compose | final)
		printf '%s' "$1"
		;;
	state)
		printf 'env'
		;;
	containers | stack)
		printf 'compose'
		;;
	*)
		printf ''
		;;
	esac
}

doctor_rollup_update() {
	local step=$1 status=$2 summary=$3 next=${4:-}
	local matrix_key new_rank cur_rank
	matrix_key=$(doctor_matrix_key "$step")
	[[ -n "$matrix_key" ]] || return 0
	new_rank=$(doctor_status_rank "$status")
	((new_rank > 0)) || return 0
	cur_rank=$(doctor_status_rank "${DOCTOR_STEP_STATUS[$matrix_key]:-}")
	# Keep worst status; on equal severity last summary/next wins.
	if ((new_rank < cur_rank)); then
		return 0
	fi
	DOCTOR_STEP_STATUS[$matrix_key]=$status
	DOCTOR_STEP_SUMMARY[$matrix_key]=$summary
	DOCTOR_STEP_NEXT[$matrix_key]=${next:--}
}

doctor_record() {
	local step=$1 status=$2 summary=$3
	local next=${4:-}
	case "$status" in
	OK)
		printf 'OK: %s\n' "$summary"
		;;
	WARN)
		printf 'WARN: %s\n' "$summary"
		DOCTOR_WARN_COUNT=$((DOCTOR_WARN_COUNT + 1))
		;;
	FAIL)
		printf 'FAIL: %s\n' "$summary"
		DOCTOR_FAIL_COUNT=$((DOCTOR_FAIL_COUNT + 1))
		;;
	SKIP)
		printf 'SKIP: %s\n' "$summary"
		;;
	*)
		printf 'FAIL: doctor_record unknown status=%s step=%s\n' "$status" "$step"
		DOCTOR_FAIL_COUNT=$((DOCTOR_FAIL_COUNT + 1))
		status=FAIL
		summary="doctor_record unknown status for step=$step"
		;;
	esac
	doctor_rollup_update "$step" "$status" "$summary" "$next"
}

doctor_print_step_matrix() {
	local step status summary next
	printf 'doctor: step matrix\n'
	printf '%-10s %-7s %-36s %s\n' STEP STATUS SUMMARY NEXT
	for step in "${DOCTOR_MATRIX_STEPS[@]}"; do
		status=${DOCTOR_STEP_STATUS[$step]:-SKIP}
		summary=${DOCTOR_STEP_SUMMARY[$step]:-not checked}
		next=${DOCTOR_STEP_NEXT[$step]:--}
		[[ -n "$next" ]] || next=-
		printf '%-10s %-7s %-36.36s %s\n' "$step" "$status" "$summary" "$next"
	done
}

doctor_print_next_actions() {
	local step status next
	local -a actions=()
	local -A seen=()
	for step in "${DOCTOR_MATRIX_STEPS[@]}"; do
		status=${DOCTOR_STEP_STATUS[$step]:-}
		case "$status" in
		WARN | FAIL) ;;
		*) continue ;;
		esac
		next=${DOCTOR_STEP_NEXT[$step]:-}
		[[ -n "$next" && "$next" != "-" ]] || continue
		[[ -z "${seen[$next]:-}" ]] || continue
		seen[$next]=1
		actions+=("$next")
	done
	if ((${#actions[@]} == 0)); then
		printf 'doctor: next actions: none\n'
		return 0
	fi
	printf 'doctor: next actions\n'
	for next in "${actions[@]}"; do
		printf -- '- %s\n' "$next"
	done
}

doctor_finish() {
	doctor_print_step_matrix
	doctor_print_next_actions
	doctor_compute_exit
	return $?
}

# Severity follows DOCTOR_EXPECT_STACK: WARN when 0, FAIL when 1.
doctor_issue() {
	local step=$1 summary=$2
	local next=${3:-}
	if [[ "${DOCTOR_EXPECT_STACK:-0}" == "1" ]]; then
		doctor_record "$step" FAIL "$summary" "$next"
	else
		doctor_record "$step" WARN "$summary" "$next"
	fi
}

doctor_ok() {
	doctor_record preflight OK "$*"
}

doctor_ok_detail() {
	[[ "${DOCTOR_VERBOSE:-0}" == "1" ]] || return 0
	doctor_ok "$@"
}

doctor_warn() {
	doctor_record preflight WARN "$*"
}

doctor_fail() {
	doctor_record preflight FAIL "$*"
}

doctor_compute_exit() {
	local exit_code=0
	local footer=OK
	if ((DOCTOR_FAIL_COUNT > 0)); then
		exit_code=1
		footer=FAILED
	elif ((DOCTOR_WARN_COUNT > 0)); then
		if [[ "${DOCTOR_STRICT:-0}" == "1" ]]; then
			exit_code=1
			footer=FAILED
		else
			footer=WARN
		fi
	fi
	printf 'doctor: %s\n' "$footer"
	return "$exit_code"
}

doctor_run_preflight() {
	# OS already checked by install_doctor_command. Commands + paths for all profiles
	# (including stack) so a broken installer tree still hard-fails.
	install_doctor_check_commands
	install_doctor_check_paths
}

doctor_run_host_steps() {
	install_doctor_check_state
	if declare -F install_doctor_check_dnscrypt >/dev/null 2>&1; then
		install_doctor_check_dnscrypt
	fi
	install_doctor_check_user
	install_doctor_check_firewall
	install_doctor_check_ssh
	install_doctor_check_network
	install_doctor_check_final
	if [[ "${INSTALL_MOCK:-0}" == "1" ]]; then
		return 0
	fi
	install_doctor_check_apt_packages
	install_doctor_check_docker
}

doctor_run_stack_steps() {
	install_doctor_check_compose
	install_doctor_check_containers
}

doctor_skip_host_steps_for_stack_profile() {
	doctor_record env SKIP "state checks skipped (profile=stack)"
	doctor_record dnscrypt SKIP "dnscrypt checks skipped (profile=stack)"
	doctor_record apt SKIP "APT package checks skipped (profile=stack)"
	doctor_record docker SKIP "Docker engine checks skipped (profile=stack)"
	doctor_record user SKIP "user checks skipped (profile=stack)"
	doctor_record firewall SKIP "firewall checks skipped (profile=stack)"
	doctor_record ssh SKIP "ssh checks skipped (profile=stack)"
	doctor_record network SKIP "network checks skipped (profile=stack)"
	doctor_record final SKIP "final checks skipped (profile=stack)"
}

doctor_skip_stack_steps_for_host_profile() {
	# host must never run compose/containers, even if DOCTOR_EXPECT_STACK=1.
	doctor_record compose SKIP "compose checks skipped (profile=host)"
	doctor_record containers SKIP "container checks skipped (profile=host)"
}

install_doctor_command() {
	DOCTOR_FAIL_COUNT=0
	DOCTOR_WARN_COUNT=0
	export DOCTOR_FAIL_COUNT DOCTOR_WARN_COUNT
	unset DOCTOR_STEP_STATUS DOCTOR_STEP_SUMMARY DOCTOR_STEP_NEXT
	declare -gA DOCTOR_STEP_STATUS DOCTOR_STEP_SUMMARY DOCTOR_STEP_NEXT

	doctor_parse_args "$@"
	doctor_detect_phase
	doctor_set_expect_stack

	printf 'doctor: profile=%s phase=%s\n' "$DOCTOR_PROFILE" "$DOCTOR_PHASE"
	if [[ "$DOCTOR_PROFILE" == "stack" ]]; then
		printf 'doctor: stack profile forces stack-expected severity (DOCTOR_EXPECT_STACK=1)\n'
	fi

	if ! is_debian_like_os; then
		die "unsupported OS: only Debian/Ubuntu are supported"
	fi
	doctor_ok "OS is Debian/Ubuntu compatible"

	doctor_run_preflight

	case "$DOCTOR_PROFILE" in
	full)
		doctor_run_host_steps
		if [[ "${INSTALL_MOCK:-0}" == "1" ]]; then
			doctor_warn "stack checks skipped in mock mode"
			doctor_finish
			return $?
		fi
		if [[ "${DOCTOR_EXPECT_STACK:-0}" == "1" ]]; then
			doctor_run_stack_steps
		else
			doctor_record compose SKIP "runtime stack checks skipped (DOCTOR_EXPECT_STACK=0)"
		fi
		;;
	host)
		doctor_run_host_steps
		doctor_skip_stack_steps_for_host_profile
		if [[ "${INSTALL_MOCK:-0}" == "1" ]]; then
			doctor_warn "stack checks skipped in mock mode"
		fi
		;;
	stack)
		# Do not run host body as FAIL/WARN sources; mark SKIP and force stack path.
		doctor_skip_host_steps_for_stack_profile
		if [[ "${INSTALL_MOCK:-0}" == "1" ]]; then
			# compose/containers are not mock-safe (would call real docker); keep expect=1 for severity fixtures.
			doctor_warn "stack checks skipped in mock mode"
			doctor_finish
			return $?
		fi
		doctor_run_stack_steps
		;;
	*)
		die "internal error: unhandled doctor profile: $DOCTOR_PROFILE"
		;;
	esac

	doctor_finish
	return $?
}

install_doctor_check_commands() {
	local cmd checked=0 available=0 bootstrap_missing=0
	local -a bootstrap_commands=(
		bash
		apt-get
		systemctl
		curl
		grep
		awk
		sed
		find
		mktemp
	)
	local -a installer_commands=(
		docker
		ufw
		jq
		openssl
		htpasswd
		git
		rsync
		ssh
		envsubst
		dpkg-query
		install
		date
		chmod
		chown
	)

	_doctor_cmd_present() {
		local name=$1
		if [[ "${INSTALL_MOCK:-0}" == "1" ]]; then
			run_cmd doctor.command command -v "$name"
		else
			command -v "$name" >/dev/null 2>&1
		fi
	}

	for cmd in "${bootstrap_commands[@]}"; do
		checked=$((checked + 1))
		if _doctor_cmd_present "$cmd"; then
			available=$((available + 1))
			doctor_ok_detail "command available: $cmd"
		else
			bootstrap_missing=$((bootstrap_missing + 1))
			doctor_fail "command missing: $cmd"
		fi
	done
	for cmd in "${installer_commands[@]}"; do
		checked=$((checked + 1))
		if _doctor_cmd_present "$cmd"; then
			available=$((available + 1))
			doctor_ok_detail "command available: $cmd"
		else
			doctor_issue commands "command missing: $cmd" "run apt --apply --yes"
		fi
	done
	unset -f _doctor_cmd_present

	if ((bootstrap_missing == 0)); then
		doctor_ok "commands: $available/$checked available"
	fi
	return 0
}

install_doctor_check_paths() {
	local path checked=0 existing=0 missing=0
	local -a required_paths=(
		"$SCRIPT_DIR/install.sh"
		"$SCRIPT_DIR/modules"
		"$SCRIPT_DIR/modules/04_dnscrypt.sh"
		"$SCRIPT_DIR/template"
		"$SCRIPT_DIR/template/install.summary.template"
		"$SCRIPT_DIR/template/sshd_config.template"
	)
	for path in "${required_paths[@]}"; do
		checked=$((checked + 1))
		if [[ -e "$path" ]]; then
			existing=$((existing + 1))
			doctor_ok_detail "path exists: $path"
		else
			missing=$((missing + 1))
			doctor_fail "path missing: $path"
		fi
	done
	if ((missing == 0)); then
		doctor_ok "required paths: $existing/$checked exist"
	fi
	return 0
}

install_doctor_check_state() {
	local var checked=0 configured=0
	local next_action="run env"
	install_load_state_env
	local -a required_vars=(WEBDOMAIN USER_SSH USER_WEB PORT_REMOTE_SSH)
	for var in "${required_vars[@]}"; do
		checked=$((checked + 1))
		if [[ -n "${!var:-}" ]]; then
			configured=$((configured + 1))
			doctor_ok_detail "state variable set: $var"
		else
			doctor_record env WARN "state variable not set yet: $var" "$next_action"
		fi
	done
	if [[ -n "${HT_PASS_ENCODED:-}" || -n "${PASS_WEB:-}" ]]; then
		doctor_ok_detail "web credentials configured"
	else
		doctor_record env WARN "web credentials are not configured yet" "$next_action"
	fi
	if [[ -f "$INSTALL_STATE_DIR/install.env" ]]; then
		doctor_ok_detail "installer env file: $INSTALL_STATE_DIR/install.env"
	else
		doctor_record env WARN "installer env file not found: $INSTALL_STATE_DIR/install.env" "$next_action"
	fi
	if ((configured == checked)) && [[ -n "${HT_PASS_ENCODED:-}" || -n "${PASS_WEB:-}" ]] && [[ -f "$INSTALL_STATE_DIR/install.env" ]]; then
		doctor_record env OK "installer state: configured"
	else
		doctor_record env OK "installer state: $configured/$checked required variables set"
	fi
	return 0
}

install_doctor_check_user() {
	local next_action="run user"
	install_load_state_env
	if [[ -z "${USER_SSH:-}" ]]; then
		doctor_issue user "USER_SSH is not set" "$next_action"
		return 0
	fi
	if [[ "${INSTALL_MOCK:-0}" == "1" ]]; then
		run_cmd doctor.user.id id "$USER_SSH"
		run_cmd doctor.user.groups id -nG "$USER_SSH" || true
		doctor_record user OK "SSH user configured: $USER_SSH (runtime checks skipped in mock)"
		return 0
	fi
	if ! id "$USER_SSH" >/dev/null 2>&1; then
		doctor_issue user "SSH user missing: $USER_SSH" "$next_action"
		return 0
	fi
	doctor_record user OK "SSH user exists: $USER_SSH"
	# Soft WARN only: docker group membership is optional convenience.
	if command -v docker >/dev/null 2>&1; then
		if id -nG "$USER_SSH" 2>/dev/null | grep -qw docker; then
			doctor_ok_detail "user $USER_SSH is in docker group"
		else
			doctor_record user WARN "user $USER_SSH is not in docker group" "$next_action"
		fi
	fi
	return 0
}

install_doctor_check_firewall() {
	local next_action="run firewall --apply --yes"
	local status_out=""
	if [[ "${INSTALL_MOCK:-0}" == "1" ]]; then
		run_cmd doctor.firewall.present command -v ufw
		run_cmd doctor.firewall ufw status
		doctor_record firewall OK "ufw present (runtime status skipped in mock)"
		return 0
	fi
	if ! command -v ufw >/dev/null 2>&1; then
		doctor_issue firewall "ufw is not installed" "$next_action"
		return 0
	fi
	status_out=$(ufw status 2>/dev/null || true)
	run_cmd doctor.firewall ufw status >/dev/null || true
	if printf '%s\n' "$status_out" | grep -qiE 'Status:[[:space:]]*inactive'; then
		doctor_issue firewall "ufw is inactive" "$next_action"
		return 0
	fi
	if printf '%s\n' "$status_out" | grep -qiE 'Status:[[:space:]]*active'; then
		doctor_record firewall OK "ufw is active"
		return 0
	fi
	doctor_issue firewall "ufw status could not be determined" "$next_action"
	return 0
}

install_doctor_check_ssh() {
	local next_action="run ssh --apply --yes"
	install_load_state_env
	if [[ -n "${PORT_REMOTE_SSH:-}" ]]; then
		if [[ ! "$PORT_REMOTE_SSH" =~ ^[0-9]+$ ]] || ((PORT_REMOTE_SSH < 1 || PORT_REMOTE_SSH > 65535)); then
			doctor_issue ssh "PORT_REMOTE_SSH is not a valid port: $PORT_REMOTE_SSH" "$next_action"
			return 0
		fi
	else
		doctor_issue ssh "PORT_REMOTE_SSH is not set" "run env"
		return 0
	fi
	if [[ "${INSTALL_MOCK:-0}" == "1" ]]; then
		run_cmd doctor.ssh.listen ss -H -ltn
		doctor_record ssh OK "SSH port $PORT_REMOTE_SSH configured (listen check skipped in mock)"
		return 0
	fi
	# Read-only listen probe; never mutate sshd_config or restart ssh.
	if declare -F install_ssh_port_listening >/dev/null 2>&1 && install_ssh_port_listening "$PORT_REMOTE_SSH"; then
		doctor_record ssh OK "SSH listening on port $PORT_REMOTE_SSH"
	else
		run_cmd doctor.ssh.listen ss -H -ltn || true
		doctor_issue ssh "SSH not listening on port $PORT_REMOTE_SSH" "$next_action"
	fi
	return 0
}

install_doctor_check_network() {
	local next_action="run network --apply --yes"
	local target="${INSTALL_SYSCTL_CONF:-/etc/sysctl.d/99-xray.conf}"
	# Read-only: confirm file presence/readability; do not run sysctl -p (applies kernel settings).
	run_cmd doctor.network.sysctl test -r "$target" || true
	if [[ ! -f "$target" ]]; then
		doctor_issue network "sysctl conf missing: $target" "$next_action"
		return 0
	fi
	if [[ "${INSTALL_MOCK:-0}" == "1" ]]; then
		doctor_record network OK "sysctl conf present: $target (mock)"
		return 0
	fi
	if [[ -r "$target" ]]; then
		doctor_record network OK "sysctl conf present: $target"
	else
		doctor_issue network "sysctl conf not readable: $target" "$next_action"
	fi
	return 0
}

install_doctor_check_final() {
	local summary="$INSTALL_STATE_DIR/install.summary"
	local next_action="run final"
	if [[ -f "$summary" ]]; then
		doctor_record final OK "install.summary present: $summary"
		return 0
	fi
	# Missing summary: never FAIL via doctor_issue (expect=1 would hard-FAIL).
	# WARN when stack expected (strict → exit 1); SKIP/light WARN otherwise.
	if [[ "${DOCTOR_EXPECT_STACK:-0}" == "1" ]]; then
		doctor_record final WARN "install.summary missing while stack expected" "$next_action"
	else
		doctor_record final SKIP "install.summary not present yet (preinstall)"
	fi
	return 0
}

install_doctor_check_apt_packages() {
	local package checked=0 installed=0 missing=0
	local next_action="run apt --apply --yes"
	if ! command -v dpkg-query >/dev/null 2>&1; then
		doctor_issue apt "command missing: dpkg-query" "$next_action"
		return 0
	fi
	if ! declare -F install_apt_required_packages >/dev/null 2>&1; then
		doctor_record apt WARN "APT dependency list is unavailable" "$next_action"
		return 0
	fi
	while IFS= read -r package; do
		[[ -n "$package" ]] || continue
		checked=$((checked + 1))
		if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -Fq "install ok installed"; then
			installed=$((installed + 1))
			doctor_ok_detail "APT package installed: $package"
		else
			missing=$((missing + 1))
			doctor_issue apt "APT package missing: $package" "$next_action"
		fi
	done < <(install_apt_required_packages)
	if ((missing == 0)); then
		doctor_record apt OK "APT packages: $installed/$checked installed"
	fi
	return 0
}

install_doctor_check_docker() {
	local had_fail=0
	local next_action="run docker"
	if ! command -v docker >/dev/null 2>&1; then
		doctor_record docker WARN "Docker command is not installed; stack checks skipped" "$next_action"
		return 0
	fi
	doctor_ok_detail "command available: docker"
	if docker compose version >/dev/null 2>&1; then
		doctor_ok_detail "Docker Compose plugin available"
	else
		doctor_record docker FAIL "Docker Compose plugin is not available" "$next_action"
		had_fail=1
	fi
	if command -v docker-compose >/dev/null 2>&1; then
		doctor_record docker FAIL "legacy docker-compose is installed; remove it and use Docker Compose v2 plugin only" "$next_action"
		had_fail=1
	else
		doctor_ok_detail "legacy docker-compose is absent"
	fi
	if systemctl is-active --quiet docker; then
		doctor_ok_detail "Docker service is active"
	else
		doctor_record docker FAIL "Docker service is not active" "$next_action"
		had_fail=1
	fi
	if docker info >/dev/null 2>&1; then
		doctor_ok_detail "Docker daemon responds"
	else
		doctor_record docker FAIL "Docker daemon does not respond" "$next_action"
		had_fail=1
	fi
	if ((had_fail == 0)); then
		doctor_record docker OK "Docker: service active, daemon responds, compose plugin available"
	fi
	return 0
}

install_doctor_check_compose() {
	local had_fail=0 runner="$INSTALL_ROOT/compose.d/run-compose.sh" env_file="$INSTALL_ROOT/compose.d/.env"
	local next_action="run compose"
	if [[ ! -d "$INSTALL_ROOT/compose.d" ]]; then
		doctor_record compose WARN "compose directory not found: $INSTALL_ROOT/compose.d" "$next_action"
		return 0
	fi
	if [[ -x "$runner" ]]; then
		doctor_ok_detail "compose runner executable: $runner"
	else
		doctor_record compose FAIL "compose runner missing or not executable: $runner" "$next_action"
		had_fail=1
	fi
	if [[ -f "$env_file" ]]; then
		doctor_ok_detail "compose env file: $env_file"
	else
		doctor_record compose FAIL "compose env file missing: $env_file" "$next_action"
		had_fail=1
	fi
	if ((had_fail == 0)); then
		local lock_file="$INSTALL_STATE_DIR/docker-proxy-compose.doctor.lock"
		local log_file="$INSTALL_STATE_DIR/doctor-compose.log"
		if ! (: >"$log_file") 2>/dev/null; then
			log_file=$(mktemp "${TMPDIR:-/tmp}/install-doctor-compose.XXXXXX.log")
			lock_file=$(mktemp "${TMPDIR:-/tmp}/install-doctor-compose.XXXXXX.lock")
			doctor_ok_detail "doctor compose log/lock fell back to tmp: $log_file / $lock_file"
		fi
		if env "COMPOSE_DIR=$INSTALL_ROOT/compose.d" "ENV_FILE=$env_file" "LOCK_FILE=$lock_file" "$runner" validate >"$log_file" 2>&1; then
			doctor_record compose OK "compose configuration validates"
		else
			doctor_record compose FAIL "compose configuration validation failed; log: $log_file" "$next_action"
			tail -n 20 "$log_file" 2>/dev/null || true
		fi
	fi
	return 0
}

install_doctor_check_containers() {
	local name state health checked=0 running=0 healthy=0 no_healthcheck=0 starting=0 had_fail=0
	local next_action="run compose"
	if ! command -v docker >/dev/null 2>&1; then
		return 0
	fi
	# Base inventory = containers from always-on active compose fragments.
	# Optional fragments (*.yml.disable or ENABLE_*=false) must not be required.
	local -a containers=(
		adguard
		arcane
		caddy
		crowdsec
		crowdsec_firewall_bouncer
		homepage
		logrotate
		tor-proxy
		traefik
		traefik-acme-exporter
		usque
		3x-ui
	)
	# dockcheck: only when active 01-dockcheck.yml/.yaml exists (not *.yml.disable)
	if [[ -f "$INSTALL_ROOT/compose.d/01-dockcheck.yml" || -f "$INSTALL_ROOT/compose.d/01-dockcheck.yaml" ]]; then
		containers+=(dockcheck)
	fi
	# Legacy dozzle: only when active 07-dozzle.yml/.yaml still exists
	if [[ -f "$INSTALL_ROOT/compose.d/07-dozzle.yml" || -f "$INSTALL_ROOT/compose.d/07-dozzle.yaml" ]]; then
		containers+=(dozzle)
	fi
	if install_lampac_enabled && [[ -f "$INSTALL_ROOT/compose.d/14-lampac.yml" || -f "$INSTALL_ROOT/compose.d/14-lampac.yaml" ]]; then
		containers+=(lampac)
	fi
	if install_telemt_enabled && [[ -f "$INSTALL_ROOT/compose.d/15-telemt.yml" || -f "$INSTALL_ROOT/compose.d/15-telemt.yaml" ]]; then
		containers+=(telemt)
	fi
	if install_mihomo_enabled && [[ -f "$INSTALL_ROOT/compose.d/16-mihomo.yml" || -f "$INSTALL_ROOT/compose.d/16-mihomo.yaml" ]]; then
		containers+=(mihomo)
	fi
	for name in "${containers[@]}"; do
		checked=$((checked + 1))
		if ! docker inspect "$name" >/dev/null 2>&1; then
			doctor_record compose FAIL "container missing: $name" "$next_action"
			had_fail=1
			continue
		fi
		state=$(docker inspect "$name" --format '{{.State.Status}}' 2>/dev/null || printf unknown)
		health=$(docker inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || printf unknown)
		if [[ "$state" != "running" ]]; then
			doctor_record compose FAIL "container not running: $name ($state/$health)" "$next_action"
			had_fail=1
			continue
		fi
		running=$((running + 1))
		if [[ "$health" == "starting" ]]; then
			starting=$((starting + 1))
			doctor_record compose WARN "container starting: $name" "$next_action"
			continue
		fi
		if [[ "$health" == "unhealthy" ]]; then
			doctor_record compose FAIL "container unhealthy: $name" "$next_action"
			had_fail=1
			continue
		fi
		if [[ "$health" == "healthy" ]]; then
			healthy=$((healthy + 1))
		elif [[ "$health" == "none" ]]; then
			no_healthcheck=$((no_healthcheck + 1))
		fi
		doctor_ok_detail "container running: $name ($health)"
	done
	if ((had_fail == 0)); then
		doctor_record compose OK "containers: $running/$checked running, $healthy healthy, $no_healthcheck without healthcheck${starting:+, $starting starting}"
	fi
	return 0
}
