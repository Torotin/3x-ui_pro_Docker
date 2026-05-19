#!/usr/bin/env bash
# Common runtime: logging, config/state, runner, validation, random helpers.

install_prepare_state() {
	mkdir -p "$INSTALL_STATE_DIR" "$(dirname "$INSTALL_LOG_FILE")" "$(dirname "$INSTALL_COMMAND_LOG")"
	if [[ "$INSTALL_STATE_DIR" != "$INSTALL_LEGACY_STATE_DIR" && -d "$INSTALL_LEGACY_STATE_DIR" && ! -e "$INSTALL_STATE_DIR/install.env" ]]; then
		cp -a "$INSTALL_LEGACY_STATE_DIR"/. "$INSTALL_STATE_DIR"/ 2>/dev/null || true
	fi
	touch "$INSTALL_LOG_FILE" "$INSTALL_COMMAND_LOG"
}

install_enable_exit_permissions_reset() {
	trap install_exit_cleanup EXIT
}

install_exit_cleanup() {
	local status=$?
	trap - EXIT
	set +e
	install_reset_all_permissions
	exit "$status"
}

log() {
	local level=$1
	shift || true
	local ts
	ts=$(date '+%Y-%m-%d %H:%M:%S')
	printf '[%s] [%s] %s\n' "$ts" "$level" "$*" >>"$INSTALL_LOG_FILE"
	case "$level" in
	ERROR | WARN) printf '%s: %s\n' "$level" "$*" >&2 ;;
	*) printf '%s\n' "$*" ;;
	esac
}

die() {
	log ERROR "$*"
	exit 1
}

config_file() {
	printf '%s/config\n' "$INSTALL_STATE_DIR"
}

config_set() {
	local key=$1 value=$2 file
	file=$(config_file)
	mkdir -p "$(dirname "$file")"
	touch "$file"
	if grep -q "^${key}=" "$file"; then
		local tmp
		tmp=$(mktemp)
		awk -v k="$key" -v v="$value" 'BEGIN{done=0} $0 ~ "^" k "=" {print k "=" v; done=1; next} {print} END{if(!done) print k "=" v}' "$file" >"$tmp"
		mv "$tmp" "$file"
	else
		printf '%s=%s\n' "$key" "$value" >>"$file"
	fi
}

config_get() {
	local key=$1 default=${2:-} file
	file=$(config_file)
	if [[ -f "$file" ]]; then
		awk -F= -v k="$key" '$1 == k {value=substr($0, length(k) + 2)} END{if(value!="") print value}' "$file"
	else
		printf '%s\n' "$default"
	fi
}

runner_log() {
	local label=$1
	shift || true
	printf '%s' "$label" >>"$INSTALL_COMMAND_LOG"
	if (($# > 0)); then
		printf ' %q' "$@" >>"$INSTALL_COMMAND_LOG"
	fi
	printf '\n' >>"$INSTALL_COMMAND_LOG"
}

run_cmd() {
	local label=$1
	shift || true
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		runner_log "$label" "$@"
		return 0
	fi
	runner_log "$label" "$@"
	"$@"
}

run_cmd_stdin() {
	local label=$1 input=$2
	shift 2 || true
	runner_log "$label" "$@" "<stdin>"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		return 0
	fi
	printf '%s' "$input" | "$@"
}

has_flag() {
	local wanted=$1
	shift || true
	local arg
	for arg in "$@"; do
		[[ "$arg" == "$wanted" ]] && return 0
	done
	return 1
}

require_opt_in() {
	local flag=$1
	shift || true
	if ! has_flag "$flag" "$@"; then
		die "$flag requires explicit opt-in"
	fi
}

require_apply_confirmation() {
	if has_flag --yes "$@"; then
		return 0
	fi
	if [[ "$INSTALL_NONINTERACTIVE" == "1" ]]; then
		die "--apply requires explicit opt-in with --yes in non-interactive mode"
	fi
	local answer
	read -r -p "Apply system changes? [y/N] " answer
	case "$answer" in
	y | Y | yes | YES) return 0 ;;
	*) die "apply cancelled" ;;
	esac
}

is_debian_like_os() {
	local os_file=${INSTALL_TEST_OS_RELEASE:-/etc/os-release}
	local id=""
	[[ -r "$os_file" ]] || return 1
	while IFS='=' read -r key value; do
		value=${value%\"}
		value=${value#\"}
		[[ "$key" == "ID" ]] && id=$value
	done <"$os_file"
	[[ "$id" == "ubuntu" || "$id" == "debian" ]]
}

install_doctor_command() {
	local status=0
	DOCTOR_VERBOSE=0
	if has_flag --verbose "$@"; then
		DOCTOR_VERBOSE=1
	fi
	printf 'doctor: checking installer, dependencies and stack status\n'
	if ! is_debian_like_os; then
		die "unsupported OS: only Debian/Ubuntu are supported"
	fi
	doctor_ok "OS is Debian/Ubuntu compatible"
	install_doctor_check_commands || status=1
	install_doctor_check_paths || status=1
	install_doctor_check_state || status=1
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		doctor_warn "stack checks skipped in mock mode"
		printf 'doctor: OK\n'
		return 0
	fi
	install_doctor_check_apt_packages || status=1
	install_doctor_check_docker || status=1
	install_doctor_check_compose || status=1
	install_doctor_check_containers || status=1
	if ((status == 0)); then
		printf 'doctor: OK\n'
	else
		printf 'doctor: FAILED\n'
	fi
	return "$status"
}

doctor_ok() {
	printf 'OK: %s\n' "$*"
}

doctor_ok_detail() {
	[[ "${DOCTOR_VERBOSE:-0}" == "1" ]] || return 0
	doctor_ok "$@"
}

doctor_warn() {
	printf 'WARN: %s\n' "$*"
}

doctor_fail() {
	printf 'FAIL: %s\n' "$*"
	return 1
}

install_doctor_check_commands() {
	local status=0 cmd checked=0 available=0
	local -a commands=(
		bash
		apt-get
		systemctl
		envsubst
		curl
		grep
		awk
		sed
		find
		install
		mktemp
		date
		chmod
		chown
		ssh
		rsync
		git
		jq
		openssl
		htpasswd
		ufw
		dpkg-query
		docker
	)
	for cmd in "${commands[@]}"; do
		((checked++))
		if [[ "$INSTALL_MOCK" == "1" ]]; then
			if run_cmd doctor.command command -v "$cmd"; then
				((available++))
				doctor_ok_detail "command available: $cmd"
			else
				doctor_fail "command missing: $cmd" || status=1
			fi
			continue
		fi
		if command -v "$cmd" >/dev/null 2>&1; then
			((available++))
			doctor_ok_detail "command available: $cmd"
		else
			doctor_fail "command missing: $cmd" || status=1
		fi
	done
	((status == 0)) && doctor_ok "commands: $available/$checked available"
	return "$status"
}

install_doctor_check_paths() {
	local status=0 path checked=0 existing=0
	local -a required_paths=(
		"$SCRIPT_DIR/install.sh"
		"$SCRIPT_DIR/modules"
		"$SCRIPT_DIR/template"
		"$SCRIPT_DIR/template/install.summary.template"
		"$SCRIPT_DIR/template/sshd_config.template"
	)
	for path in "${required_paths[@]}"; do
		((checked++))
		if [[ -e "$path" ]]; then
			((existing++))
			doctor_ok_detail "path exists: $path"
		else
			doctor_fail "path missing: $path" || status=1
		fi
	done
	((status == 0)) && doctor_ok "required paths: $existing/$checked exist"
	return "$status"
}

install_doctor_check_state() {
	local status=0 var checked=0 configured=0
	install_load_state_env
	local -a required_vars=(WEBDOMAIN USER_SSH USER_WEB PORT_REMOTE_SSH)
	for var in "${required_vars[@]}"; do
		((checked++))
		if [[ -n "${!var:-}" ]]; then
			((configured++))
			doctor_ok_detail "state variable set: $var"
		else
			doctor_warn "state variable not set yet: $var"
		fi
	done
	if [[ -n "${HT_PASS_ENCODED:-}" || -n "${PASS_WEB:-}" ]]; then
		doctor_ok_detail "web credentials configured"
	else
		doctor_warn "web credentials are not configured yet"
	fi
	if [[ -f "$INSTALL_STATE_DIR/install.env" ]]; then
		doctor_ok_detail "installer env file: $INSTALL_STATE_DIR/install.env"
	else
		doctor_warn "installer env file not found: $INSTALL_STATE_DIR/install.env"
	fi
	if ((configured == checked)) && [[ -n "${HT_PASS_ENCODED:-}" || -n "${PASS_WEB:-}" ]] && [[ -f "$INSTALL_STATE_DIR/install.env" ]]; then
		doctor_ok "installer state: configured"
	else
		doctor_ok "installer state: $configured/$checked required variables set"
	fi
	return "$status"
}

install_doctor_check_apt_packages() {
	local status=0 package checked=0 installed=0
	if ! command -v dpkg-query >/dev/null 2>&1; then
		doctor_fail "command missing: dpkg-query" || return 1
	fi
	if ! declare -F install_apt_required_packages >/dev/null 2>&1; then
		doctor_warn "APT dependency list is unavailable"
		return 0
	fi
	while IFS= read -r package; do
		[[ -n "$package" ]] || continue
		((checked++))
		if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -Fq "install ok installed"; then
			((installed++))
			doctor_ok_detail "APT package installed: $package"
		else
			doctor_fail "APT package missing: $package" || status=1
		fi
	done < <(install_apt_required_packages)
	((status == 0)) && doctor_ok "APT packages: $installed/$checked installed"
	return "$status"
}

install_doctor_check_docker() {
	local status=0
	if ! command -v docker >/dev/null 2>&1; then
		doctor_warn "Docker command is not installed; stack checks skipped"
		return 0
	fi
	doctor_ok_detail "command available: docker"
	if docker compose version >/dev/null 2>&1; then
		doctor_ok_detail "Docker Compose plugin available"
	else
		doctor_fail "Docker Compose plugin is not available" || status=1
	fi
	if command -v docker-compose >/dev/null 2>&1; then
		doctor_fail "legacy docker-compose is installed; remove it and use Docker Compose v2 plugin only" || status=1
	else
		doctor_ok_detail "legacy docker-compose is absent"
	fi
	if systemctl is-active --quiet docker; then
		doctor_ok_detail "Docker service is active"
	else
		doctor_fail "Docker service is not active" || status=1
	fi
	if docker info >/dev/null 2>&1; then
		doctor_ok_detail "Docker daemon responds"
	else
		doctor_fail "Docker daemon does not respond" || status=1
	fi
	((status == 0)) && doctor_ok "Docker: service active, daemon responds, compose plugin available"
	return "$status"
}

install_doctor_check_compose() {
	local status=0 runner="$INSTALL_ROOT/compose.d/run-compose.sh" env_file="$INSTALL_ROOT/compose.d/.env"
	if [[ ! -d "$INSTALL_ROOT/compose.d" ]]; then
		doctor_warn "compose directory not found: $INSTALL_ROOT/compose.d"
		return 0
	fi
	if [[ -x "$runner" ]]; then
		doctor_ok_detail "compose runner executable: $runner"
	else
		doctor_fail "compose runner missing or not executable: $runner" || status=1
	fi
	if [[ -f "$env_file" ]]; then
		doctor_ok_detail "compose env file: $env_file"
	else
		doctor_fail "compose env file missing: $env_file" || status=1
	fi
	if ((status == 0)); then
		local lock_file="$INSTALL_STATE_DIR/docker-proxy-compose.doctor.lock"
		local log_file="$INSTALL_STATE_DIR/doctor-compose.log"
		if ! (: >"$log_file") 2>/dev/null; then
			log_file=$(mktemp "${TMPDIR:-/tmp}/install-doctor-compose.XXXXXX.log")
		fi
		if env "COMPOSE_DIR=$INSTALL_ROOT/compose.d" "ENV_FILE=$env_file" "LOCK_FILE=$lock_file" "$runner" validate >"$log_file" 2>&1; then
			doctor_ok "compose configuration validates"
		else
			doctor_fail "compose configuration validation failed; log: $log_file" || status=1
			tail -n 20 "$log_file" 2>/dev/null || true
		fi
	fi
	return "$status"
}

install_doctor_check_containers() {
	local status=0 name state health checked=0 running=0 healthy=0 no_healthcheck=0
	if ! command -v docker >/dev/null 2>&1; then
		return 0
	fi
	if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fq "traefik"; then
		doctor_warn "compose stack containers are not running yet"
		return 0
	fi
	local -a containers=(
		adguard
		caddy
		crowdsec
		crowdsec_firewall_bouncer
		dockcheck
		dozzle
		homepage
		logrotate
		tor-proxy
		torproxy
		traefik
		traefik-acme-exporter
		usque
		warp
		3x-ui
	)
	if [[ -f "$INSTALL_ROOT/compose.d/14-lampac.yml" || -f "$INSTALL_ROOT/compose.d/14-lampac.yaml" ]]; then
		containers+=(lampac)
	fi
	if [[ -f "$INSTALL_ROOT/compose.d/15-telemt.yml" || -f "$INSTALL_ROOT/compose.d/15-telemt.yaml" ]]; then
		containers+=(telemt telemt-panel)
	fi
	for name in "${containers[@]}"; do
		((checked++))
		if ! docker inspect "$name" >/dev/null 2>&1; then
			doctor_fail "container missing: $name" || status=1
			continue
		fi
		state=$(docker inspect "$name" --format '{{.State.Status}}' 2>/dev/null || printf unknown)
		health=$(docker inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || printf unknown)
		if [[ "$state" != "running" ]]; then
			doctor_fail "container not running: $name ($state/$health)" || status=1
			continue
		fi
		((running++))
		if [[ "$health" == "unhealthy" ]]; then
			doctor_fail "container unhealthy: $name" || status=1
			continue
		fi
		if [[ "$health" == "healthy" ]]; then
			((healthy++))
		elif [[ "$health" == "none" ]]; then
			((no_healthcheck++))
		fi
		doctor_ok_detail "container running: $name ($health)"
	done
	((status == 0)) && doctor_ok "containers: $running/$checked running, $healthy healthy, $no_healthcheck without healthcheck"
	return "$status"
}

backup_path() {
	local src=$1 backup_dir=$2 base
	base=$(basename "$src")
	printf '%s/%s.bak.%s\n' "$backup_dir" "$base" "$(date +%Y%m%d%H%M%S)"
}

backup_file() {
	local src=$1 backup_dir=${2:-$INSTALL_STATE_DIR/backups}
	[[ -e "$src" ]] || return 0
	if ! mkdir -p "$backup_dir"; then
		die "backup directory is not writable: $backup_dir (run with sudo or set INSTALL_ROOT/INSTALL_STATE_DIR to a writable path)"
	fi
	if ! cp -a -- "$src" "$(backup_path "$src" "$backup_dir")" 2>/dev/null; then
		die "could not create backup in $backup_dir (run with sudo or set INSTALL_ROOT/INSTALL_STATE_DIR to a writable path)"
	fi
}

install_effective_uid() {
	printf '%s\n' "${INSTALL_EFFECTIVE_UID:-$EUID}"
}

install_sanitize_user() {
	local value=${1:-}
	value=${value//$'\r'/}
	value=${value//$'\n'/}
	value=${value//$'\t'/}
	value=${value//[[:space:]]/}
	printf '%s\n' "$value"
}

install_reset_permissions() {
	local target_dir=$1 target_user=${2:-} rc=0 main_group=""
	[[ -n "$target_dir" && -d "$target_dir" && "$target_dir" != "/" ]] || {
		return 0
	}
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		if [[ -n "$target_user" ]]; then
			run_cmd permissions.owner chown -hR "$target_user:$target_user" "$target_dir"
		fi
		run_cmd permissions.dirs find "$target_dir" -type d -exec chmod u=rwx,go=rx "{}" "+"
		run_cmd permissions.files find "$target_dir" -type f -exec chmod u=rwX,go=rX "{}" "+"
		return 0
	fi
	if [[ "$(install_effective_uid)" != "0" ]]; then
		return 0
	fi
	if [[ -n "$target_user" ]]; then
		if id -u "$target_user" >/dev/null 2>&1; then
			if getent group "$target_user" >/dev/null 2>&1; then
				main_group=$target_user
			else
				main_group=$(id -gn "$target_user")
			fi
			run_cmd permissions.owner chown -hR "$target_user:$main_group" "$target_dir" || rc=1
		else
			return 0
		fi
	fi
	run_cmd permissions.dirs find "$target_dir" -type d -exec chmod u=rwx,go=rx "{}" "+" || rc=1
	run_cmd permissions.files find "$target_dir" -type f -exec chmod u=rwX,go=rX "{}" "+" || rc=1
	return "$rc"
}

install_reset_all_permissions() {
	local target_user rc=0
	install_load_state_env
	target_user=$(install_sanitize_user "${USER_SSH:-}")
	install_reset_permissions "$SCRIPT_DIR" "$target_user" || rc=1
	install_reset_permissions "$INSTALL_ROOT" "$target_user" || rc=1
	return 0
}

require_writable_target() {
	local target=$1 label=$2 probe
	probe=$target
	[[ "$INSTALL_MOCK" == "1" ]] && return 0
	local euid
	euid=$(install_effective_uid)
	[[ "$euid" == "0" ]] && return 0
	while [[ ! -e "$probe" && "$probe" != "/" ]]; do
		probe=$(dirname "$probe")
	done
	case "$target" in
	/opt/* | /etc/* | /var/lib/*)
		local owner
		owner=$(stat -c '%u' "$probe" 2>/dev/null || printf '0')
		[[ "$owner" == "$euid" ]] || die "$label is not writable: $target (run with sudo or set INSTALL_ROOT/INSTALL_STATE_DIR to a writable path)"
		;;
	esac
	[[ -w "$probe" ]] && return 0
	die "$label is not writable: $target (run with sudo or set INSTALL_ROOT/INSTALL_STATE_DIR to a writable path)"
}

install_load_state_env() {
	local file="$INSTALL_STATE_DIR/install.env" line key value
	[[ -f "$file" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" =~ ^[[:space:]]*# || "$line" =~ ^[[:space:]]*$ ]] && continue
		key=${line%%=*}
		value=${line#*=}
		[[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
		if [[ "$value" == \"*\" && "$value" == *\" ]]; then
			value=${value#\"}
			value=${value%\"}
		fi
		[[ -n "${!key-}" ]] && continue
		printf -v "$key" '%s' "$value"
		export "${key?}"
	done <"$file"
}

install_env_quote_value() {
	local value=$1
	value=${value//\\/\\\\}
	value=${value//\"/\\\"}
	value=${value//$'\n'/}
	printf '"%s"' "$value"
}

install_state_set_env() {
	local key=$1 value=$2 file tmp quoted
	file="$INSTALL_STATE_DIR/install.env"
	mkdir -p "$(dirname "$file")"
	touch "$file"
	quoted=$(install_env_quote_value "$value")
	tmp=$(mktemp)
	awk -v k="$key" -v v="$quoted" 'BEGIN{done=0} $0 ~ "^" k "=" {print k "=" v; done=1; next} {print} END{if(!done) print k "=" v}' "$file" >"$tmp"
	mv "$tmp" "$file"
}

install_persist_required_env() {
	install_state_set_env WEBDOMAIN "${WEBDOMAIN:-}"
	install_state_set_env USER_SSH "${USER_SSH:-}"
	install_state_set_env PASS_SSH "${PASS_SSH:-}"
	install_state_set_env USER_WEB "${USER_WEB:-}"
	install_state_set_env PASS_WEB "${PASS_WEB:-}"
	install_state_set_env SSH_PBK "${SSH_PBK:-}"
}

install_prompt_required() {
	local var=$1 prompt=$2 secret=${3:-0} value
	if [[ -n "${!var-}" ]]; then
		return 0
	fi
	printf '%s: ' "$prompt"
	if [[ "$secret" == "1" && -t 0 ]]; then
		read -rs value || value=
		printf '\n'
	else
		read -r value || value=
	fi
	[[ -n "$value" ]] || die "$var is required"
	printf -v "$var" '%s' "$value"
	export "${var?}"
}

install_require_required_env() {
	local mode=${1:-batch}
	install_load_state_env
	if [[ "$mode" == "wizard" ]]; then
		if [[ -z "${WEBDOMAIN:-}" || -z "${USER_SSH:-}" || -z "${PASS_SSH:-}" || -z "${USER_WEB:-}" || -z "${PASS_WEB:-}" ]]; then
			printf 'Required installer variables\n'
		fi
		install_prompt_required WEBDOMAIN "Web domain"
		install_prompt_required USER_SSH "SSH username"
		install_prompt_required PASS_SSH "SSH password" 1
		install_prompt_required USER_WEB "Web username"
		install_prompt_required PASS_WEB "Web password" 1
		if [[ -z "${SSH_PBK:-}" ]]; then
			printf 'SSH public key (optional): '
			read -r SSH_PBK || SSH_PBK=
			export SSH_PBK
		fi
		install_persist_required_env
		return 0
	fi
	[[ -n "${WEBDOMAIN:-}" ]] || die "WEBDOMAIN is required (set env or run wizard)"
	[[ -n "${USER_SSH:-}" ]] || die "USER_SSH is required (set env or run wizard)"
	[[ -n "${PASS_SSH:-}" ]] || die "PASS_SSH is required (set env or run wizard)"
	[[ -n "${USER_WEB:-}" ]] || die "USER_WEB is required (set env or run wizard)"
	[[ -n "${PASS_WEB:-}" ]] || die "PASS_WEB is required (set env or run wizard)"
}

generate_random_string() {
	local min=${1:-16} max=${2:-32} len
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		printf 'mock%0.sx' $(seq 1 "$min")
		printf '\n'
		return 0
	fi
	len=$(shuf -i "$min-$max" -n 1)
	openssl rand -base64 "$len" | tr -dc 'A-Za-z0-9' | head -c "$len"
	printf '\n'
}

is_port_free() {
	local port=$1
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		[[ "$port" != "1" ]]
		return
	fi
	if command -v ss >/dev/null 2>&1; then
		! ss -tuln | awk '{print $4}' | grep -qE "[:.]${port}\b"
	else
		! netstat -tuln | awk '{print $4}' | grep -qE "[:.]${port}\b"
	fi
}

generate_random_port() {
	local min=${1:-20000} max=${2:-65000} port
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		printf '%s\n' "$min"
		return 0
	fi
	for _ in $(seq 1 100); do
		port=$(shuf -i "$min-$max" -n 1)
		if is_port_free "$port"; then
			printf '%s\n' "$port"
			return 0
		fi
	done
	die "could not find a free port in range $min-$max"
}
