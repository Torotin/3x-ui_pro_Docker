#!/usr/bin/env bash
# Wizard/menu runtime. The wizard delegates to the same dispatcher as CLI run.

: "${WIZARD_ASSUME_YES:=0}"
: "${WIZARD_UI:=auto}"
: "${WIZARD_UI_RESOLVED:=}"
: "${WIZARD_UI_WARNED:=0}"
: "${WIZARD_STEPS_STATE:=}"

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

wizard_ui_size() {
	local lines cols
	lines=$(tput lines 2>/dev/null || echo 24)
	cols=$(tput cols 2>/dev/null || echo 80)
	WIZARD_UI_HEIGHT=$((lines < 20 ? 20 : (lines > 40 ? 40 : lines - 2)))
	WIZARD_UI_WIDTH=$((cols < 60 ? 60 : (cols > 100 ? 100 : cols - 2)))
	export WIZARD_UI_HEIGHT WIZARD_UI_WIDTH
}

wizard_ui_yesno() {
	local prompt=$1 force_prompt=${2:-0} rc answer
	if [[ "$force_prompt" != "1" && "$WIZARD_ASSUME_YES" == "1" ]]; then
		return 0
	fi
	if [[ "$WIZARD_UI_RESOLVED" == "whiptail" ]]; then
		wizard_ui_size
		set +e
		whiptail --title "3x-ui wizard" --yesno "$prompt" --defaultno \
			"$WIZARD_UI_HEIGHT" "$WIZARD_UI_WIDTH"
		rc=$?
		set -e
		if ((rc == 0)); then
			return 0
		fi
		return 1
	fi
	printf '%s [y/N] ' "$prompt"
	read -r answer || answer=n
	case "$answer" in
	y | Y | yes | YES) return 0 ;;
	*) return 1 ;;
	esac
}

wizard_confirm() {
	wizard_ui_yesno "$@"
}

wizard_ui_input() {
	local prompt=$1 default=${2:-} result rc
	if [[ "$WIZARD_UI_RESOLVED" != "whiptail" ]]; then
		if [[ -n "$default" ]]; then
			printf '%s [%s] ' "$prompt" "$default"
		else
			printf '%s ' "$prompt"
		fi
		read -r result || result=
		[[ -z "$result" && -n "$default" ]] && result=$default
		printf '%s\n' "$result"
		return 0
	fi
	wizard_ui_size
	set +e
	result=$(whiptail --title "3x-ui wizard" --inputbox "$prompt" \
		"$WIZARD_UI_HEIGHT" "$WIZARD_UI_WIDTH" "$default" \
		3>&1 1>&2 2>&3)
	rc=$?
	set -e
	if ((rc != 0)); then
		return 1
	fi
	printf '%s\n' "$result"
}

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

wizard_ui_checklist() {
	local result rc
	wizard_ui_size
	set +e
	result=$(whiptail --title "3x-ui wizard" --backtitle "$1" --checklist "$2" \
		"$WIZARD_UI_HEIGHT" "$WIZARD_UI_WIDTH" "$3" "${@:4}" \
		3>&1 1>&2 2>&3)
	rc=$?
	set -e
	if ((rc != 0)); then
		return 1
	fi
	printf '%s\n' "$result" | tr -d '"'
	return 0
}

wizard_ui_radiolist() {
	local result rc
	wizard_ui_size
	set +e
	result=$(whiptail --title "3x-ui wizard" --backtitle "$1" --radiolist "$2" \
		"$WIZARD_UI_HEIGHT" "$WIZARD_UI_WIDTH" "$3" "${@:4}" \
		3>&1 1>&2 2>&3)
	rc=$?
	set -e
	if ((rc != 0)); then
		return 1
	fi
	printf '%s\n' "$result" | tr -d '"'
	return 0
}

wizard_step_badge_ascii() {
	local st
	st=$(wizard_step_state_get "$1")
	case "$st" in
	OK) printf '[OK]' ;;
	FAIL) printf '[FAIL]' ;;
	*) printf '[ ]' ;;
	esac
}

wizard_whiptail_backtitle() {
	local features status bt
	features=$(wizard_features_summary)
	status=${WIZARD_LAST_STATUS:-No operation yet}
	bt="3x-ui installer | Features: ${features} | Last operation: ${status}"
	if [[ "$WIZARD_ASSUME_YES" == "1" ]]; then
		bt="${bt} | Mode: --yes"
	fi
	printf '%s' "$bt"
}

wizard_whiptail_main_menu() {
	local backtitle b0 b1 b2 b3 b4 b5 b6 b7 b8 b9
	backtitle=$(wizard_whiptail_backtitle)
	b0=$(wizard_step_badge_ascii dnscrypt)
	b1=$(wizard_step_badge_ascii apt)
	b4=$(wizard_step_badge_ascii user)
	b6=$(wizard_step_badge_ascii ssh)
	b5=$(wizard_step_badge_ascii firewall)
	b7=$(wizard_step_badge_ascii network)
	b2=$(wizard_step_badge_ascii env)
	b3=$(wizard_step_badge_ascii docker)
	b8=$(wizard_step_badge_ascii compose)
	b9=$(wizard_step_badge_ascii final)
	wizard_ui_menu "$backtitle" "Choose an action" 18 \
		a "auto — Full install (recommended)" \
		t "toggles — Optional stack features" \
		d "doctor — System / stack diagnostics" \
		0 "${b0} dnscrypt — DNSCrypt system DNS" \
		1 "${b1} apt — APT mirror and OS packages" \
		4 "${b4} user — Service user" \
		6 "${b6} ssh — SSH policy" \
		5 "${b5} firewall — Firewall policy" \
		7 "${b7} network — Network tuning" \
		2 "${b2} env — Render env files" \
		3 "${b3} docker — Docker (destructive)" \
		8 "${b8} compose — Validate/start stack" \
		9 "${b9} final — Final summary" \
		x "Exit"
}

wizard_feature_toggles_whiptail() {
	local backtitle selected backend l t g m
	wizard_load_feature_toggles
	backtitle=$(wizard_whiptail_backtitle)
	[[ "${ENABLE_LAMPAC}" == true ]] && l=ON || l=OFF
	[[ "${ENABLE_TELEMT}" == true ]] && t=ON || t=OFF
	[[ "${ENABLE_VLESS_GRPC}" == true ]] && g=ON || g=OFF
	[[ "${ENABLE_MIHOMO}" == true ]] && m=ON || m=OFF
	selected=$(wizard_ui_checklist "$backtitle" "Optional stack features (Space toggles)" 4 \
		ENABLE_LAMPAC "Lampac [$l]" "$l" \
		ENABLE_TELEMT "Telemt [$t]" "$t" \
		ENABLE_VLESS_GRPC "VLESS gRPC [$g]" "$g" \
		ENABLE_MIHOMO "Mihomo [$m]" "$m") || return 0
	ENABLE_LAMPAC=false
	ENABLE_TELEMT=false
	ENABLE_VLESS_GRPC=false
	ENABLE_MIHOMO=false
	for tag in $selected; do
		case "$tag" in
		ENABLE_LAMPAC) ENABLE_LAMPAC=true ;;
		ENABLE_TELEMT) ENABLE_TELEMT=true ;;
		ENABLE_VLESS_GRPC) ENABLE_VLESS_GRPC=true ;;
		ENABLE_MIHOMO) ENABLE_MIHOMO=true ;;
		esac
	done
	export ENABLE_LAMPAC ENABLE_TELEMT ENABLE_VLESS_GRPC ENABLE_MIHOMO
	backend=$(wizard_ui_radiolist "$backtitle" "UDP443 backend" 3 \
		amneziawg "amneziawg" "$([[ ${UDP443_BACKEND:-off} == amneziawg ]] && echo ON || echo OFF)" \
		hysteria2 "hysteria2" "$([[ ${UDP443_BACKEND:-off} == hysteria2 ]] && echo ON || echo OFF)" \
		off "off" "$([[ ${UDP443_BACKEND:-off} == off ]] && echo ON || echo OFF)") || return 0
	UDP443_BACKEND=$backend
	export UDP443_BACKEND
	install_normalize_udp443_backend
	wizard_save_feature_toggles
	wizard_execute_step env dispatch_step env
	if wizard_confirm "Apply compose stack now?"; then
		wizard_execute_step compose dispatch_step compose
	fi
}

wizard_step_state_file() {
	WIZARD_STEPS_STATE="${INSTALL_STATE_DIR}/wizard-steps.state"
	export WIZARD_STEPS_STATE
	printf '%s\n' "$WIZARD_STEPS_STATE"
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

wizard_features_summary() {
	local -a items=()
	wizard_load_feature_toggles
	[[ "${ENABLE_LAMPAC}" == true ]] && items+=(lampac)
	[[ "${ENABLE_TELEMT}" == true ]] && items+=(telemt)
	[[ "${ENABLE_VLESS_GRPC}" == true ]] && items+=(vless-grpc)
	[[ "${ENABLE_MIHOMO}" == true ]] && items+=(mihomo)
	if [[ "${UDP443_BACKEND:-off}" != off ]]; then
		items+=("udp443:${UDP443_BACKEND}")
	fi
	if ((${#items[@]} == 0)); then
		printf 'none'
		return 0
	fi
	local IFS=,
	printf '%s' "${items[*]}"
}

wizard_step_badge() {
	local st
	st=$(wizard_step_state_get "$1")
	case "$st" in
	OK)
		if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
			printf '[✓]'
		else
			printf '\033[32m[✓]\033[0m'
		fi
		;;
	FAIL)
		if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
			printf '[!]'
		else
			printf '\033[31m[!]\033[0m'
		fi
		;;
	*) printf '[ ]' ;;
	esac
}

wizard_print_menu_step() {
	local step=$1
	shift
	printf '  '
	wizard_step_badge "$step"
	printf ' %s\n' "$*"
}

install_wizard_print_menu() {
	local features
	if [[ -t 1 ]]; then
		printf '\033[H\033[2J'
	fi
	features=$(wizard_features_summary)
	printf '3x-ui installer · wizard\n'
	printf 'Features: %s\n' "$features"
	if [[ "$WIZARD_ASSUME_YES" == "1" ]]; then
		printf 'Mode: --yes\n'
	fi
	printf '\n── Quick Actions ─────────────────────────\n'
	cat <<'MENU'
  a. auto      Full install (recommended path)
  t. toggles   Optional stack features
  d. doctor    System / stack diagnostics
MENU
	printf '\n── 1. Host & Security Preparation ────────\n'
	wizard_print_menu_step dnscrypt '0. dnscrypt   Install DNSCrypt as system DNS (DoH/DNSCrypt)'
	wizard_print_menu_step apt '1. apt        Select APT mirror and update OS packages'
	wizard_print_menu_step user '4. user       Create or update service user'
	wizard_print_menu_step ssh '6. ssh        Apply SSH policy'
	wizard_print_menu_step firewall '5. firewall  Apply firewall policy'
	wizard_print_menu_step network '7. network    Apply sysctl/network tuning'
	printf '\n── 2. Docker & Stack Deployment ──────────\n'
	wizard_print_menu_step env '2. env        Render installer and compose env files'
	wizard_print_menu_step docker '3. docker     Install/prepare Docker resources (destructive)'
	wizard_print_menu_step compose '8. compose    Validate/start compose stack'
	wizard_print_menu_step final '9. final      Render final summary'
	printf '\n  x. Exit\n'
	printf 'Keys: 0-9 step · a/t/d · names (apt, compose) · q quit\n'
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
	a) printf 'auto\n' ;;
	d) printf 'doctor\n' ;;
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
		wizard_step_state_set "$label" OK
		WIZARD_LAST_STATUS="OK $label"
		printf '\nLast operation: OK %s\nLog: %s\n' "$label" "$output_file"
		wizard_wait_continue
		return 0
	fi
	wizard_step_state_set "$label" FAIL
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

wizard_state_set_env_literal() {
	local key=$1 value=$2 file tmp
	file="$INSTALL_STATE_DIR/install.env"
	mkdir -p "$(dirname "$file")"
	touch "$file"
	tmp=$(mktemp)
	awk -v k="$key" -v v="$value" 'BEGIN{done=0} $0 ~ "^" k "=" {print k "=" v; done=1; next} {print} END{if(!done) print k "=" v}' "$file" >"$tmp"
	mv "$tmp" "$file"
}

wizard_save_feature_toggles() {
	wizard_state_set_env_literal ENABLE_LAMPAC "$ENABLE_LAMPAC"
	wizard_state_set_env_literal ENABLE_TELEMT "$ENABLE_TELEMT"
	wizard_state_set_env_literal ENABLE_MIHOMO "$ENABLE_MIHOMO"
	wizard_state_set_env_literal UDP443_BACKEND "$UDP443_BACKEND"
	wizard_state_set_env_literal PORT_LOCAL_UDP443 "$PORT_LOCAL_UDP443"
	wizard_state_set_env_literal ENABLE_VLESS_GRPC "$ENABLE_VLESS_GRPC"
}

wizard_bool_toggle_badge() {
	if [[ "$1" == true ]]; then
		printf '[ON ]'
	else
		printf '[OFF]'
	fi
}

wizard_print_feature_toggles() {
	if [[ -t 1 ]]; then
		printf '\033[H\033[2J'
	fi
	cat <<MENU
Optional Stack Features
  1. Lampac         $(wizard_bool_toggle_badge "$ENABLE_LAMPAC")
  2. Telemt         $(wizard_bool_toggle_badge "$ENABLE_TELEMT")
  3. UDP443 backend [${UDP443_BACKEND}]
  4. VLESS gRPC     $(wizard_bool_toggle_badge "$ENABLE_VLESS_GRPC")
  5. Mihomo         $(wizard_bool_toggle_badge "$ENABLE_MIHOMO")

  a. Save + render env (+ optional compose)
  x. Return

Choose 1-5 to toggle, a to apply/render env, x to return:
MENU
}

wizard_feature_toggles() {
	if [[ "$WIZARD_UI_RESOLVED" == "whiptail" ]]; then
		wizard_feature_toggles_whiptail
		return 0
	fi
	local input dirty=0
	wizard_load_feature_toggles
	while true; do
		wizard_print_feature_toggles
		printf '> '
		read -r input || return 0
		case "$input" in
		1)
			wizard_toggle_bool_var ENABLE_LAMPAC
			dirty=1
			;;
		2)
			wizard_toggle_bool_var ENABLE_TELEMT
			dirty=1
			;;
		3)
			wizard_cycle_udp443_backend
			dirty=1
			;;
		4)
			wizard_toggle_bool_var ENABLE_VLESS_GRPC
			dirty=1
			;;
		5)
			wizard_toggle_bool_var ENABLE_MIHOMO
			dirty=1
			;;
		a | apply)
			wizard_save_feature_toggles
			dirty=0
			wizard_execute_step env dispatch_step env
			if wizard_confirm "Apply compose stack now?"; then
				wizard_execute_step compose dispatch_step compose
			fi
			return 0
			;;
		x | q | quit)
			if ((dirty == 0)); then
				return 0
			fi
			if wizard_confirm "Save changes?"; then
				wizard_save_feature_toggles
			fi
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

wizard_auto_install() {
	local step rc
	install_load_state_env
	if [[ -z "${USER_SSH:-}" ]]; then
		if [[ "$WIZARD_UI_RESOLVED" == "whiptail" ]]; then
			if ! USER_SSH=$(wizard_ui_input "SSH username:" ""); then
				WIZARD_LAST_STATUS="SKIPPED auto"
				return 0
			fi
			export USER_SSH
		else
			printf 'SSH username: '
			read -r USER_SSH || USER_SSH=
			export USER_SSH
		fi
		[[ -n "$USER_SSH" ]] || {
			WIZARD_LAST_STATUS="SKIPPED auto"
			wizard_wait_continue
			return 0
		}
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
			if [[ "$WIZARD_UI_RESOLVED" == "whiptail" ]]; then
				USER_SSH=$(wizard_ui_input "SSH username:" "") || USER_SSH=
				export USER_SSH
			else
				printf 'SSH username: '
				read -r USER_SSH || USER_SSH=
				export USER_SSH
			fi
		fi
		wizard_execute_step user dispatch_step user
		;;
	env | compose | final)
		wizard_execute_step "$input" dispatch_step "$input"
		;;
	toggles)
		wizard_feature_toggles
		;;
	auto)
		wizard_auto_install
		;;
	doctor)
		wizard_execute_step doctor dispatch_step doctor
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
		if [[ "$WIZARD_UI_RESOLVED" == "whiptail" ]]; then
			local input
			input=$(wizard_whiptail_main_menu)
			[[ "$input" == "x" ]] && break
			[[ -z "$input" ]] && continue
			input=$(wizard_normalize_step "$input")
		else
			install_wizard_print_menu
			install_wizard_print_status
			printf '> '
			local input
			read -r input || break
			[[ -z "$input" ]] && continue
			[[ "$input" == "x" ]] && break
			[[ "$input" == "q" || "$input" == "quit" ]] && break
			input=$(wizard_normalize_step "$input")
		fi
		if ! wizard_dispatch_step "$input"; then
			log WARN "wizard step failed: $input"
		fi
	done
}
