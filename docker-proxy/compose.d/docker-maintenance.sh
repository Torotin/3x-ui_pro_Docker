#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="${DOCKER_MAINTENANCE_PATH:-${PATH:-/usr/sbin:/usr/bin:/sbin:/bin}}"
export LC_ALL=C

LOCK_FILE="${DOCKER_MAINTENANCE_LOCK_FILE:-/run/docker-maintenance.lock}"
DRY_RUN="${DRY_RUN:-0}"
GLOBAL_BUDGET_SECONDS="${DOCKER_MAINTENANCE_BUDGET_SECONDS:-1800}"
TIMEOUT_SECONDS="${DOCKER_MAINTENANCE_TIMEOUT_SECONDS:-300s}"
KILL_AFTER="${DOCKER_MAINTENANCE_KILL_AFTER:-30s}"
PROBE_TIMEOUT_SECONDS="${DOCKER_MAINTENANCE_PROBE_TIMEOUT_SECONDS:-30s}"
SHORT_TIMEOUT_SECONDS="${DOCKER_MAINTENANCE_SHORT_TIMEOUT_SECONDS:-15s}"
IMAGE_UNTIL="${DOCKER_MAINTENANCE_IMAGE_UNTIL:-168h}"
CONTAINER_UNTIL="${DOCKER_MAINTENANCE_CONTAINER_UNTIL:-168h}"
BUILDER_UNTIL="${DOCKER_MAINTENANCE_BUILDER_UNTIL:-168h}"
EMERGENCY_UNTIL="${DOCKER_MAINTENANCE_EMERGENCY_UNTIL:-24h}"
SNAPSHOT_DELETE_LIMIT="${DOCKER_MAINTENANCE_SNAPSHOT_DELETE_LIMIT:-150}"
SNAPSHOT_ROOT="${DOCKER_MAINTENANCE_SNAPSHOT_ROOT:-/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots}"
DOCKER_CONTAINER_ROOT="${DOCKER_MAINTENANCE_CONTAINER_ROOT:-/var/lib/docker/containers}"
START_SECONDS=$SECONDS
DOCKER_TIMEOUTS=0
CTR_TIMEOUTS=0

log() {
	printf '[%s] [docker-maintenance] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2 || true
}

warn() {
	log "WARN: $*"
}

critical() {
	log "CRITICAL: $*"
}

usage() {
	cat <<'USAGE'
Usage:
  docker-maintenance.sh
  docker-maintenance.sh run
  docker-maintenance.sh prune
  docker-maintenance.sh report

Environment:
  DRY_RUN=1
  DOCKER_MAINTENANCE_BUDGET_SECONDS=1800
  DOCKER_MAINTENANCE_LOCK_FILE=/run/docker-maintenance.lock

This script never deletes named Docker volumes, never runs broad Docker-wide
prune operations, and never deletes containerd content blobs by filesystem path.
USAGE
}

budget_remaining() {
	((SECONDS - START_SECONDS < GLOBAL_BUDGET_SECONDS))
}

check_budget() {
	if budget_remaining; then
		return 0
	fi
	warn "global maintenance runtime budget exceeded after ${GLOBAL_BUDGET_SECONDS}s; stopping further reclaim stages"
	return 1
}

run_cmd() {
	if [[ "$DRY_RUN" == "1" ]]; then
		printf 'DRY_RUN:' >&2
		printf ' %q' "$@" >&2
		printf '\n' >&2
		return 0
	fi
	"$@"
}

run_timeout() {
	run_cmd timeout --kill-after="$KILL_AFTER" "$TIMEOUT_SECONDS" "$@"
}

run_short_timeout() {
	run_cmd timeout --kill-after=5s "$SHORT_TIMEOUT_SECONDS" "$@"
}

run_probe_timeout() {
	run_cmd timeout --kill-after=10s "$PROBE_TIMEOUT_SECONDS" "$@"
}

run_step() {
	local name=$1
	shift
	check_budget || return 1
	if ! "$@"; then
		warn "$name failed"
		return 1
	fi
	return 0
}

acquire_lock() {
	command -v flock >/dev/null 2>&1 || {
		warn "flock unavailable, continuing without lock"
		return 0
	}
	if ! install -m 0600 /dev/null "$LOCK_FILE" 2>/dev/null; then
		warn "cannot prepare lock file $LOCK_FILE, continuing without lock"
		return 0
	fi
	exec 9>"$LOCK_FILE"
	if ! flock -n 9; then
		warn "another docker maintenance run is active (lock: $LOCK_FILE)"
		exit 0
	fi
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

docker_ok() {
	command_exists docker || return 1
	if run_probe_timeout docker info >/dev/null 2>&1; then
		DOCKER_TIMEOUTS=0
		return 0
	fi
	DOCKER_TIMEOUTS=$((DOCKER_TIMEOUTS + 1))
	return 1
}

ctr_ok() {
	command_exists ctr || return 1
	if run_probe_timeout ctr version >/dev/null 2>&1; then
		CTR_TIMEOUTS=0
		return 0
	fi
	CTR_TIMEOUTS=$((CTR_TIMEOUTS + 1))
	return 1
}

buildx_available() {
	command_exists docker || return 1
	if run_probe_timeout docker buildx version >/dev/null 2>&1; then
		return 0
	fi
	warn "docker buildx unavailable, skipping buildx cleanup"
	return 1
}

df_used_pct() {
	df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}'
}

df_avail_kb() {
	df -P / 2>/dev/null | awk 'NR==2 {print $4}'
}

df_total_kb() {
	df -P / 2>/dev/null | awk 'NR==2 {print $2}'
}

df_inode_used_pct() {
	df -Pi / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}'
}

used_mb() {
	df -P / 2>/dev/null | awk 'NR==2 {printf "%.0f\n", ($3 / 1024)}'
}

target_free_kb() {
	local total five_pct five_gb
	total=$(df_total_kb)
	five_pct=$((total / 20))
	five_gb=$((5 * 1024 * 1024))
	if ((five_pct > five_gb)); then
		printf '%s\n' "$five_pct"
	else
		printf '%s\n' "$five_gb"
	fi
}

target_reached() {
	local avail target
	avail=$(df_avail_kb)
	target=$(target_free_kb)
	[[ -n "$avail" && -n "$target" ]] || return 1
	((avail >= target))
}

warn_pressure() {
	local used inode_used avail
	used=$(df_used_pct || true)
	inode_used=$(df_inode_used_pct || true)
	avail=$(df_avail_kb || true)
	[[ -n "$used" && "$used" -gt 80 ]] && warn "root filesystem usage is ${used}%"
	[[ -n "$used" && "$used" -gt 98 ]] && critical "root filesystem usage is ${used}%"
	[[ -n "$inode_used" && "$inode_used" -gt 80 ]] && warn "root inode usage is ${inode_used}%"
	[[ -n "$inode_used" && "$inode_used" -gt 95 ]] && critical "root inode usage is ${inode_used}%"
	[[ -n "$avail" && "$avail" -lt 524288 ]] && critical "root filesystem has less than 512MB free"
	return 0
}

apt_locked() {
	local service
	for service in apt-daily.service apt-daily-upgrade.service unattended-upgrades.service; do
		if command_exists systemctl && systemctl is-active --quiet "$service" 2>/dev/null; then
			warn "$service is active, skipping apt cleanup"
			return 0
		fi
	done
	for lock in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock; do
		if [[ -e "$lock" ]] && command_exists fuser && fuser "$lock" >/dev/null 2>&1; then
			warn "apt lock is held ($lock), skipping apt cleanup"
			return 0
		fi
	done
	return 1
}

cleanup_journal() {
	run_step "journal vacuum" run_timeout journalctl --vacuum-time=7d || true
}

cleanup_apt() {
	if apt_locked; then
		return 0
	fi
	run_step "apt autoremove" run_timeout apt-get autoremove -y || true
	run_step "apt autoclean" run_timeout apt-get autoclean -y || true
	run_step "apt clean" run_timeout apt-get clean || true
}

cleanup_tmp() {
	local aggressive=${1:-0}
	local tmp_mtime=3 vartmp_mtime=7
	if [[ "$aggressive" == "1" ]]; then
		tmp_mtime=1
		vartmp_mtime=2
	fi
	[[ -d /tmp ]] && run_step "tmp cleanup" run_short_timeout find /tmp -xdev -type f -mtime +"$tmp_mtime" -delete || true
	[[ -d /var/tmp ]] && run_step "var tmp cleanup" run_short_timeout find /var/tmp -xdev -type f -mtime +"$vartmp_mtime" -delete || true
}

log_files_under_timeout() {
	[[ -d "$DOCKER_CONTAINER_ROOT" ]] || return 0
	run_short_timeout find "$DOCKER_CONTAINER_ROOT" -xdev -type f -name '*-json.log' "$@"
}

truncate_large_logs() {
	local file
	while IFS= read -r file; do
		[[ -f "$file" && ! -L "$file" ]] || continue
		run_step "truncate Docker log $file" run_timeout truncate -s 50M "$file" || true
	done < <(log_files_under_timeout -size +200M 2>/dev/null || true)
}

report_log_pressure() {
	local total_kb=0 file size container_id
	while IFS= read -r file; do
		[[ -f "$file" && ! -L "$file" ]] || continue
		size=$(du -k "$file" 2>/dev/null | awk '{print $1}')
		[[ -n "$size" ]] || continue
		total_kb=$((total_kb + size))
		if ((size > 500 * 1024)); then
			container_id=$(basename "$(dirname "$file")")
			warn "large Docker json log: container=$container_id size_kb=$size path=$file"
		fi
	done < <(log_files_under_timeout 2>/dev/null || true)
	if ((total_kb > 5 * 1024 * 1024)); then
		warn "Docker json logs exceed 5G: $((total_kb / 1024)) MB"
		return 1
	fi
	return 0
}

docker_prune_images_builders() {
	local until=$1 builder_until=${2:-$BUILDER_UNTIL}
	if ! docker_ok; then
		warn "docker CLI unavailable or timed out, skipping Docker prune"
		return 1
	fi
	run_step "docker image prune" run_timeout docker image prune --all --force --filter "until=$until" || true
	run_step "docker builder prune" run_timeout docker builder prune --all --force --filter "until=$builder_until" || true
	if buildx_available; then
		run_step "docker buildx prune" run_timeout docker buildx prune --all --force --filter "until=$builder_until" || true
		if ! active_buildkit_sockets; then
			run_step "docker buildx inactive builder cleanup" run_timeout docker buildx rm --all-inactive --force || true
		else
			warn "active BuildKit sockets detected, skipping inactive builder cleanup"
		fi
	fi
}

docker_prune_containers_networks() {
	if ! docker_ok; then
		warn "docker CLI unavailable or timed out, skipping container/network prune"
		return 1
	fi
	run_step "docker container prune" run_timeout docker container prune --force --filter "until=$CONTAINER_UNTIL" || true
	run_step "docker network prune" run_timeout docker network prune --force --filter "until=$IMAGE_UNTIL" || true
}

active_buildkit_sockets() {
	find /run /tmp -xdev \( -type s -o -type p \) \( -name '*buildkit*' -o -name '*buildctl*' \) -print -quit 2>/dev/null | grep -q .
}

ctr_namespaces() {
	local seen="" ns
	if command_exists ctr; then
		while IFS= read -r ns; do
			[[ -n "$ns" ]] || continue
			case " $seen " in *" $ns "*) continue ;; esac
			seen="$seen $ns"
			printf '%s\n' "$ns"
		done < <(run_probe_timeout ctr namespaces ls -q 2>/dev/null || true)
	fi
	for ns in moby default k8s.io; do
		case " $seen " in *" $ns "*) continue ;; esac
		printf '%s\n' "$ns"
	done
}

ctr_content_gc() {
	local ns
	if ! ctr_ok; then
		warn "ctr unavailable or timed out, skipping containerd content cleanup"
		return 1
	fi
	while IFS= read -r ns; do
		run_step "ctr content gc ($ns)" run_timeout ctr -n "$ns" content gc || true
		if ctr_images_prune_supported; then
			run_step "ctr images prune ($ns)" run_timeout ctr -n "$ns" images prune || true
		fi
	done < <(ctr_namespaces)
}

ctr_images_prune_supported() {
	run_probe_timeout ctr images --help 2>/dev/null | grep -q 'prune'
}

snapshot_metadata() {
	local ns ok=0
	ACTIVE_SNAPSHOTS=""
	REFERENCED_SNAPSHOTS=""
	while IFS= read -r ns; do
		local snapshots tasks containers tree
		if snapshots=$(run_probe_timeout ctr -n "$ns" snapshots ls -q 2>/dev/null); then
			ok=1
			ACTIVE_SNAPSHOTS+="${snapshots}"$'\n'
			tasks=$(run_probe_timeout ctr -n "$ns" tasks ls 2>/dev/null || true)
			containers=$(run_probe_timeout ctr -n "$ns" containers ls 2>/dev/null || true)
			tree=$(run_probe_timeout ctr -n "$ns" snapshots tree 2>/dev/null || true)
			REFERENCED_SNAPSHOTS+="${tasks}"$'\n'"${containers}"$'\n'"${tree}"$'\n'
		fi
	done < <(ctr_namespaces)
	((ok == 1))
}

id_in_metadata() {
	local id=$1
	grep -qx -- "$id" <<<"$ACTIVE_SNAPSHOTS" && return 0
	grep -Eq "(^|[^0-9])${id}([^0-9]|$)" <<<"$REFERENCED_SNAPSHOTS"
}

cache_mounts() {
	MOUNT_CACHE=$(run_short_timeout findmnt -rn -o TARGET,SOURCE,FSTYPE 2>/dev/null || true)
}

snapshot_is_mounted() {
	local id=$1 dir=$2
	grep -Fq "/snapshots/$id/" <<<"$MOUNT_CACHE" && return 0
	grep -Fq "$dir" <<<"$MOUNT_CACHE" && return 0
	run_short_timeout findmnt -rn -T "$dir" >/dev/null 2>&1
}

snapshot_path_safe() {
	local root_real dir_real dir=$1
	root_real=$(realpath -m "$SNAPSHOT_ROOT" 2>/dev/null || true)
	dir_real=$(realpath -m "$dir" 2>/dev/null || true)
	[[ -n "$root_real" && -n "$dir_real" ]] || return 1
	[[ "$dir_real" == "$root_real"/* ]]
}

systemctl_timeout() {
	run_timeout systemctl "$@"
}

verify_services_ready() {
	local failed=0
	if command_exists systemctl; then
		systemctl is-active --quiet containerd || failed=1
		systemctl is-active --quiet docker || failed=1
	fi
	run_probe_timeout docker info >/dev/null 2>&1 || failed=1
	run_probe_timeout ctr version >/dev/null 2>&1 || failed=1
	if ((failed != 0)); then
		critical "Docker/containerd did not become ready after maintenance restart"
		return 1
	fi
}

orphan_snapshot_cleanup() {
	[[ -d "$SNAPSHOT_ROOT" ]] || return 0
	if ! ctr_ok; then
		warn "ctr unavailable, skipping orphan snapshot cleanup"
		return 0
	fi
	if ! snapshot_metadata; then
		warn "containerd snapshot metadata unavailable, skipping destructive snapshot cleanup"
		return 0
	fi
	cache_mounts
	run_step "stop docker" systemctl_timeout stop docker || true
	run_step "stop containerd" systemctl_timeout stop containerd || true

	local deleted=0 checked=0 dir id
	for dir in "$SNAPSHOT_ROOT"/*; do
		check_budget || break
		[[ -d "$dir" && ! -L "$dir" ]] || continue
		id=$(basename "$dir")
		[[ "$id" =~ ^[0-9]+$ ]] || {
			warn "skipping non-numeric snapshot directory: $dir"
			continue
		}
		snapshot_path_safe "$dir" || {
			warn "skipping snapshot path outside root: $dir"
			continue
		}
		if id_in_metadata "$id"; then
			continue
		fi
		if snapshot_is_mounted "$id" "$dir"; then
			warn "skipping mounted snapshot: $id"
			continue
		fi
		if ! run_timeout rm -rf --one-file-system -- "$dir"; then
			warn "failed to delete orphan snapshot $id"
			continue
		fi
		deleted=$((deleted + 1))
		checked=$((checked + 1))
		sleep 0.05
		if ((checked % 25 == 0)); then
			sync -f "$SNAPSHOT_ROOT" 2>/dev/null || sync || true
		fi
		if ((deleted >= SNAPSHOT_DELETE_LIMIT)); then
			warn "snapshot deletion limit reached ($SNAPSHOT_DELETE_LIMIT); remaining orphans will be handled by a later run"
			break
		fi
	done

	run_step "start containerd" systemctl_timeout start containerd || true
	run_step "start docker" systemctl_timeout start docker || true
	verify_services_ready
}

run_reclaim_stage() {
	local name=$1
	shift
	check_budget || return 1
	log "stage: $name"
	"$@" || true
	warn_pressure
	target_reached && return 1
	return 0
}

emergency_reclaim() {
	warn "entering emergency reclaim-only path"
	truncate_large_logs
	docker_prune_images_builders "$EMERGENCY_UNTIL" "$EMERGENCY_UNTIL" || true
	ctr_content_gc || true
	warn_pressure
}

full_maintenance() {
	local before after duration avail used inode_used
	before=$(used_mb || printf 0)
	warn_pressure
	avail=$(df_avail_kb || printf 0)
	if [[ -n "$avail" && "$avail" -lt 524288 ]]; then
		emergency_reclaim
		final_metrics "$before"
		return
	fi

	cleanup_journal
	cleanup_apt
	truncate_large_logs
	report_log_pressure || docker_prune_images_builders "$IMAGE_UNTIL"
	run_reclaim_stage "Docker image/build cleanup" docker_prune_images_builders "$IMAGE_UNTIL" || true
	run_reclaim_stage "Docker network cleanup" docker_prune_containers_networks || true
	run_reclaim_stage "containerd content cleanup" ctr_content_gc || true

	inode_used=$(df_inode_used_pct || printf 0)
	if [[ -n "$inode_used" && "$inode_used" -gt 90 ]]; then
		cleanup_tmp 1
	else
		cleanup_tmp 0
	fi

	used=$(df_used_pct || printf 0)
	if [[ -n "$used" && "$used" -gt 85 ]]; then
		run_reclaim_stage "aggressive Docker cleanup" docker_prune_images_builders "$EMERGENCY_UNTIL" "$EMERGENCY_UNTIL" || true
		run_reclaim_stage "post-aggressive containerd content cleanup" ctr_content_gc || true
	fi
	used=$(df_used_pct || printf 0)
	if [[ -n "$used" && "$used" -gt 95 ]]; then
		run_reclaim_stage "orphan snapshot cleanup" orphan_snapshot_cleanup || true
	fi
	final_metrics "$before"
	duration=$((SECONDS - START_SECONDS))
	after=$(used_mb || printf 0)
	log "Reclaimed: $((before - after)) MB in ${duration}s"
}

prune_only() {
	docker_prune_containers_networks || true
	docker_prune_images_builders "$IMAGE_UNTIL" || true
}

report() {
	df -h / || true
	df -hi / || true
	if command_exists docker; then
		run_probe_timeout docker system df || true
	fi
	if command_exists ctr; then
		run_probe_timeout ctr -n moby images ls || true
	fi
	du -sh "$SNAPSHOT_ROOT" 2>/dev/null || true
}

final_metrics() {
	local before=${1:-0} after duration
	after=$(used_mb || printf 0)
	duration=$((SECONDS - START_SECONDS))
	log "Reclaimed: $((before - after)) MB in ${duration}s"
	report
}

main() {
	local cmd=${1:-run}
	case "$cmd" in
	help | --help | -h)
		usage
		return
		;;
	esac
	acquire_lock
	case "$cmd" in
	run) full_maintenance ;;
	prune) prune_only ;;
	report) report ;;
	*)
		usage >&2
		exit 1
		;;
	esac
}

main "$@"
