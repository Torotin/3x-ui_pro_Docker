#!/usr/bin/env bash
# Wizard/menu runtime. The wizard delegates to the same dispatcher as CLI run.

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

install_wizard_print_menu() {
	if [[ -t 1 ]]; then
		printf '\033[H\033[2J'
	fi
	cat <<'MENU'
Available steps:
  0. dnscrypt  Install DNSCrypt as system DNS (DoH/DNSCrypt)
  1. apt       Select APT mirror and update OS packages
  2. env       Render installer and compose env files
  3. docker    Install/prepare Docker resources
  4. user      Create or update service user
  5. firewall  Apply firewall policy
  6. ssh       Apply SSH policy
  7. network   Apply sysctl/network tuning
  8. compose   Validate/start compose stack
  9. final     Render final summary
  t. toggles   Enable/disable optional stack features
  x. Exit
MENU
}

install_wizard_print_status() {
	local status=${WIZARD_LAST_STATUS:-No operation yet}
	printf '\nLast operation: %s\n\n' "$status"
}

wizard_normalize_step() {
	case "$1" in
	0) printf 'dnscrypt\n' ;;
	1) printf 'apt\n' ;;
	2) printf 'env\n' ;;
	3) printf 'docker\n' ;;
	4) printf 'user\n' ;;
	5) printf 'firewall\n' ;;
	6) printf 'ssh\n' ;;
	7) printf 'network\n' ;;
	8) printf 'compose\n' ;;
	9) printf 'final\n' ;;
	t) printf 'toggles\n' ;;
	*) printf '%s\n' "$1" ;;
	esac
}

wizard_execute_step() {
	local label=$1
	shift
	local output_file="$INSTALL_STATE_DIR/wizard-last-${label}.log"
	local rc
	printf '\nRunning %s...\n\n' "$label"
	set +e
	if [[ "$label" == "compose" ]]; then
		local ticker_pid="" interval="${WIZARD_COMPOSE_TICKER_SECONDS:-15}"
		(
			while sleep "$interval"; do
				printf '%s\n' 'Compose step still running...'
			done
		) &
		ticker_pid=$!
		trap 'if [[ -n "${ticker_pid:-}" ]]; then kill "$ticker_pid" 2>/dev/null || true; wait "$ticker_pid" 2>/dev/null || true; ticker_pid=""; fi' INT TERM

		"$@" 2>&1 | tee "$output_file" | wizard_filter_compose_output
		rc=${PIPESTATUS[0]}

		trap - INT TERM
		if [[ -n "$ticker_pid" ]]; then
			kill "$ticker_pid" 2>/dev/null || true
			wait "$ticker_pid" 2>/dev/null || true
			ticker_pid=""
		fi
	else
		"$@" 2>&1 | tee "$output_file"
		rc=${PIPESTATUS[0]}
	fi
	set -e
	if ((rc == 0)); then
		WIZARD_LAST_STATUS="OK $label"
		printf '\nLast operation: OK %s\nLog: %s\n' "$label" "$output_file"
		wizard_wait_continue
		return 0
	fi
	WIZARD_LAST_STATUS="FAILED $label"
	printf '\nLast operation: FAILED %s\nLog: %s\n' "$label" "$output_file"
	wizard_wait_continue
	return "$rc"
}

wizard_wait_continue() {
	local _
	printf '\nPress Enter to continue...'
	read -r _ || true
}

wizard_load_feature_toggles() {
	install_load_state_env
	: "${ENABLE_LAMPAC:=false}"
	: "${ENABLE_TELEMT:=false}"
	: "${ENABLE_MIHOMO:=false}"
	: "${ENABLE_VLESS_GRPC:=false}"
	install_normalize_bool_var ENABLE_LAMPAC
	install_normalize_bool_var ENABLE_TELEMT
	install_normalize_bool_var ENABLE_MIHOMO
	install_normalize_bool_var ENABLE_VLESS_GRPC
	install_normalize_udp443_port_env
	install_normalize_udp443_backend
}

wizard_cycle_udp443_backend() {
	case "${UDP443_BACKEND:-amneziawg}" in
	amneziawg) UDP443_BACKEND=hysteria2 ;;
	hysteria2) UDP443_BACKEND=off ;;
	off) UDP443_BACKEND=amneziawg ;;
	*) UDP443_BACKEND=amneziawg ;;
	esac
	export UDP443_BACKEND
	install_normalize_udp443_backend
}

wizard_toggle_bool_var() {
	local name=$1
	case "${!name}" in
	true) printf -v "$name" '%s' false ;;
	false) printf -v "$name" '%s' true ;;
	*) install_normalize_bool_var "$name" ;;
	esac
	export "${name?}"
}

wizard_save_feature_toggles() {
	install_state_set_env ENABLE_LAMPAC "$ENABLE_LAMPAC"
	install_state_set_env ENABLE_TELEMT "$ENABLE_TELEMT"
	install_state_set_env ENABLE_MIHOMO "$ENABLE_MIHOMO"
	install_state_set_env UDP443_BACKEND "$UDP443_BACKEND"
	install_state_set_env PORT_LOCAL_UDP443 "$PORT_LOCAL_UDP443"
	install_state_set_env ENABLE_VLESS_GRPC "$ENABLE_VLESS_GRPC"
}

wizard_print_feature_toggles() {
	if [[ -t 1 ]]; then
		printf '\033[H\033[2J'
	fi
	cat <<MENU
Feature toggles:
  1. ENABLE_LAMPAC      $ENABLE_LAMPAC   Lampac compose service
  2. ENABLE_TELEMT      $ENABLE_TELEMT   Telemt fallback/proxy stack
  3. UDP443_BACKEND   $UDP443_BACKEND   Owner of public 443/udp (amneziawg|hysteria2|off)
  4. ENABLE_VLESS_GRPC  $ENABLE_VLESS_GRPC   VLESS gRPC inbound in 3x-ui/Xray
  5. ENABLE_MIHOMO      $ENABLE_MIHOMO   Mihomo compose service

Choose 1-5 to toggle, a to apply/render env, x to return:
MENU
}

wizard_feature_toggles() {
	local input
	wizard_load_feature_toggles
	while true; do
		wizard_print_feature_toggles
		printf '> '
		read -r input || return 0
		case "$input" in
		1)
			wizard_toggle_bool_var ENABLE_LAMPAC
			;;
		2)
			wizard_toggle_bool_var ENABLE_TELEMT
			;;
		3)
			wizard_cycle_udp443_backend
			;;
		4)
			wizard_toggle_bool_var ENABLE_VLESS_GRPC
			;;
		5)
			wizard_toggle_bool_var ENABLE_MIHOMO
			;;
		a | apply)
			wizard_save_feature_toggles
			wizard_execute_step env dispatch_step env
			return 0
			;;
		x | q | quit)
			WIZARD_LAST_STATUS="SKIPPED toggles"
			return 0
			;;
		'')
			;;
		*)
			WIZARD_LAST_STATUS="INVALID toggles $input"
			printf '\nUnknown toggle item: %s\n' "$input"
			wizard_wait_continue
			;;
		esac
	done
}

wizard_filter_compose_output() {
	local awk_bin=(awk)
	if command -v stdbuf >/dev/null 2>&1; then
		awk_bin=(stdbuf -oL awk)
	fi
	"${awk_bin[@]}" '
		/^[[:space:]]*[[:xdigit:]]{12,}[[:space:]]+(Preparing|Waiting|Verifying Checksum|Already exists|Pulling fs layer|Downloading|Download complete|Extracting|Pull complete)([[:space:]].*)?$/ { next }

		/^ Image .+ Pulling$/ {
			ref=$0
			sub(/^ Image /, "", ref)
			sub(/ Pulling$/, "", ref)
			print "Pulling image: " ref
			next
		}

		/^ Image .+ Pulled$/ {
			if (!pulled) {
				print "Docker images pulled"
				pulled=1
			}
			next
		}

		/\[run-compose\] Проверяем конфигурацию: / {
			print "Validating compose configuration..."
			next
		}
		/\[run-compose\] Попытка [0-9]+\/[0-9]+: / {
			line=$0
			sub(/^.*\[run-compose\] /, "", line)
			sub(/: docker compose .*$/, "", line)
			print "Starting compose stack: " line
			next
		}

		/\[run-compose\] Каталог с compose-файлами:/ { next }
		/\[run-compose\] Используем env-файл:/ { next }
		/\[run-compose\] Project root:/ { next }
		/\[run-compose\] Lock file:/ { next }

		/^Created symlink / { next }
		/^NEXT[[:space:]]+LEFT[[:space:]]+LAST[[:space:]]+PASSED[[:space:]]+UNIT[[:space:]]+ACTIVATES/ { next }
		/docker-proxy-maintenance\.timer/ { next }
		/^[0-9]+ timers? listed\.?$/ { next }

		{ print }
	'
}

wizard_offer_self_update() {
	local branch result_file tmp local_version remote_version available answer prepare_rc
	# Fresh hosts often lack git until the apt step; skip instead of a false "up to date".
	if [[ "$INSTALL_MOCK" != "1" ]] && ! command -v git >/dev/null 2>&1; then
		printf 'Update check: skipped (git not installed; run apt step first)\n'
		return 0
	fi
	branch=$(config_get update.branch "$INSTALL_DEFAULT_BRANCH")
	result_file=$(mktemp)
	# Do not wrap prepare in `if ! ( ... )`: bash disables set -e in if-conditions, so
	# failed git/clone + die-inside-$(...) could falsely report "up to date".
	set +e
	install_self_update_prepare "$branch" "$result_file"
	prepare_rc=$?
	set -e
	if ((prepare_rc != 0)); then
		rm -f "$result_file"
		log WARN "self-update check failed"
		return 0
	fi
	install_self_update_load_result "$result_file"
	rm -f "$result_file"
	tmp=$SELF_UPDATE_TMP
	local_version=$SELF_UPDATE_LOCAL_VERSION
	remote_version=$SELF_UPDATE_REMOTE_VERSION
	available=$SELF_UPDATE_AVAILABLE
	if [[ "$available" != "1" ]]; then
		printf 'Update check: installer is up to date (%s)\n' "$local_version"
		rm -rf "$tmp"
		return 0
	fi
	printf 'Update available: %s -> %s\n' "$local_version" "$remote_version"
	install_print_changelog_range "$tmp/script/CHANGELOG.md" "$local_version" "$remote_version"
	rm -rf "$tmp"
	printf 'Run self-update now? [y/N] '
	read -r answer || answer=n
	case "$answer" in
	y | Y | yes | YES) install_self_update_command --branch "$branch" --yes ;;
	*) log INFO "self-update skipped" >/dev/null ;;
	esac
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

wizard_dispatch_step() {
	local input=$1
	case "$input" in
	dnscrypt)
		if wizard_confirm "Install DNSCrypt as system DNS (DoH/DNSCrypt)?"; then
			wizard_execute_step dnscrypt dispatch_step dnscrypt --apply --yes
		else
			WIZARD_LAST_STATUS="SKIPPED dnscrypt"
			printf '\nDNSCrypt install skipped\n'
			wizard_wait_continue
		fi
		;;
	apt)
		if wizard_confirm "Select fastest APT mirror and update OS packages?"; then
			wizard_execute_step apt dispatch_step apt --apply --yes
		else
			WIZARD_LAST_STATUS="SKIPPED apt"
			printf '\nAPT mirror/update skipped\n'
			wizard_wait_continue
		fi
		;;
	docker)
		if wizard_confirm "Destroy Docker data and reinstall Docker?" 1; then
			wizard_execute_step docker dispatch_step docker --destroy-docker-data
		else
			WIZARD_LAST_STATUS="SKIPPED docker"
			printf '\nDocker wipe/reinstall skipped\n'
			wizard_wait_continue
		fi
		;;
	firewall | ssh | network)
		if wizard_confirm "Apply $input system changes?"; then
			wizard_execute_step "$input" dispatch_step "$input" --apply --yes
		else
			WIZARD_LAST_STATUS="SKIPPED $input"
			printf '\n%s apply skipped\n' "$input"
			wizard_wait_continue
		fi
		;;
	user)
		install_load_state_env
		if [[ -z "${USER_SSH:-}" ]]; then
			printf 'SSH username: '
			read -r USER_SSH || USER_SSH=
			export USER_SSH
		fi
		wizard_execute_step user dispatch_step user
		;;
	env | compose | final)
		wizard_execute_step "$input" dispatch_step "$input"
		;;
	toggles)
		wizard_feature_toggles
		;;
	*)
		WIZARD_LAST_STATUS="INVALID $input"
		printf '\nUnknown menu item: %s\n' "$input"
		wizard_wait_continue
		return 0
		;;
	esac
}

install_wizard() {
	wizard_parse_args "$@"
	wizard_resolve_ui_mode
	wizard_offer_self_update
	install_require_required_env wizard

	while true; do
		install_wizard_print_menu
		printf '> '
		install_wizard_print_status
		local input
		read -r input || break
		[[ -z "$input" ]] && continue
		[[ "$input" == "x" ]] && break
		[[ "$input" == "q" || "$input" == "quit" ]] && break
		input=$(wizard_normalize_step "$input")
		if ! wizard_dispatch_step "$input"; then
			log WARN "wizard step failed: $input"
		fi
	done
}
