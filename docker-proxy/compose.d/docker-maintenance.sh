#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_UNTIL="${DOCKER_MAINTENANCE_IMAGE_UNTIL:-168h}"
CONTAINER_UNTIL="${DOCKER_MAINTENANCE_CONTAINER_UNTIL:-168h}"
BUILDER_UNTIL="${DOCKER_MAINTENANCE_BUILDER_UNTIL:-168h}"
LOCK_FILE="${DOCKER_MAINTENANCE_LOCK_FILE:-/tmp/docker-proxy-maintenance.lock}"
DRY_RUN="${DRY_RUN:-0}"

log() {
	printf '[%s] [docker-maintenance] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

usage() {
	cat <<'USAGE'
Usage:
  docker-maintenance.sh report
  docker-maintenance.sh prune

Environment:
  DOCKER_MAINTENANCE_IMAGE_UNTIL=168h
  DOCKER_MAINTENANCE_CONTAINER_UNTIL=168h
  DOCKER_MAINTENANCE_BUILDER_UNTIL=168h
  DOCKER_MAINTENANCE_LOCK_FILE=/tmp/docker-proxy-maintenance.lock
  DRY_RUN=1

The prune command intentionally does not prune Docker volumes or networks.
USAGE
}

require_docker() {
	if ! command -v docker >/dev/null 2>&1; then
		log "ERROR: docker not found in PATH"
		exit 1
	fi
}

acquire_lock() {
	command -v flock >/dev/null 2>&1 || {
		log "WARN: flock unavailable, continuing without lock"
		return
	}
	install -m 0666 /dev/null "$LOCK_FILE" 2>/dev/null || true
	exec 9>"$LOCK_FILE"
	if ! flock -n 9; then
		log "ERROR: another docker maintenance run is active (lock: $LOCK_FILE)"
		exit 1
	fi
}

report() {
	log "Disk usage"
	df -hT / || true
	log "Docker disk usage"
	docker system df -v || true
	if [[ -d /var/lib/containerd ]]; then
		log "containerd top-level usage"
		du -hxd1 /var/lib/containerd 2>/dev/null | sort -h || true
	fi
}

run_or_print() {
	if [[ "$DRY_RUN" == "1" ]]; then
		printf 'DRY_RUN:'
		printf ' %q' "$@"
		printf '\n'
		return
	fi
	"$@"
}

prune() {
	log "Before prune"
	report

	log "Pruning stopped containers older than $CONTAINER_UNTIL"
	run_or_print docker container prune --force --filter "until=$CONTAINER_UNTIL"

	log "Pruning build cache older than $BUILDER_UNTIL"
	run_or_print docker builder prune --all --force --filter "until=$BUILDER_UNTIL"

	log "Pruning unused images older than $IMAGE_UNTIL"
	run_or_print docker image prune --all --force --filter "until=$IMAGE_UNTIL"

	log "After prune"
	report
}

main() {
	local cmd=${1:-report}
	case "$cmd" in
	help | --help | -h)
		usage
		return
		;;
	esac
	require_docker
	acquire_lock
	case "$cmd" in
	report) report ;;
	prune) prune ;;
	*)
		usage >&2
		exit 1
		;;
	esac
}

main "$@"
