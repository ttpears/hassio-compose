#!/usr/bin/env bash
# Lifecycle helper for hassio-compose.
#
# Subcommands:
#   restart  Stop + start the supervisor (default).
#   up       Start the supervisor; wait for Home Assistant to respond.
#   down     Stop the supervisor and the containers it spawned.
#   clean    Down + force-remove addon_/hassio_/homeassistant containers.
#            Use when the supervisor refuses to recover stale state.
#   status   Show every hassio-related container and HA reachability.
#   logs     Follow supervisor logs.
#
# Env overrides: HA_URL (default http://127.0.0.1:8123), HA_TIMEOUT (default 180).

set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HA_URL="${HA_URL:-http://127.0.0.1:8123}"
HA_TIMEOUT="${HA_TIMEOUT:-180}"

docker compose version >/dev/null 2>&1 || {
    echo "ERROR: 'docker compose' (v2) required" >&2; exit 1; }

dc() { docker compose -f "$COMPOSE_DIR/docker-compose.yaml" "$@"; }
log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }

# Containers spawned by the supervisor (excludes the supervisor itself).
spawned_children() {
    docker ps -a --format '{{.Names}}' \
        | grep -E '^(addon_|hassio_|homeassistant$)' \
        | grep -v '^hassio_supervisor$' || true
}

stop_children() {
    local names; names=$(spawned_children)
    [[ -n "$names" ]] || return 0
    log "Stopping supervisor-spawned containers..."
    echo "$names" | xargs -r docker stop -t 20 >/dev/null
}

remove_children() {
    local names; names=$(spawned_children)
    [[ -n "$names" ]] || return 0
    log "Removing supervisor-spawned containers..."
    echo "$names" | xargs -r docker rm -f >/dev/null
}

wait_for_ha() {
    log "Waiting for Home Assistant at $HA_URL (timeout ${HA_TIMEOUT}s)..."
    local deadline=$((SECONDS + HA_TIMEOUT))
    while (( SECONDS < deadline )); do
        if curl -fsS -o /dev/null --max-time 5 "$HA_URL"; then
            log "Home Assistant responded after $((SECONDS - (deadline - HA_TIMEOUT)))s."
            return 0
        fi
        sleep 5
    done
    log "WARNING: Home Assistant did not respond within ${HA_TIMEOUT}s."
    return 1
}

cmd_up() {
    log "docker compose up -d"
    dc up -d
    wait_for_ha || true
    cmd_status
}

cmd_down() {
    log "docker compose down"
    dc down
    stop_children
}

cmd_clean() {
    cmd_down
    remove_children
    log "Cleanup complete."
}

cmd_restart() { cmd_down; cmd_up; }

cmd_status() {
    log "Compose state:"
    dc ps
    echo
    log "Hassio-related containers:"
    docker ps -a --format 'table {{.Names}}\t{{.Status}}' \
        | awk 'NR==1 || /^(addon_|hassio_|homeassistant)/'
    echo
    if curl -fsS -o /dev/null --max-time 3 "$HA_URL"; then
        log "Home Assistant: responding on $HA_URL"
    else
        log "Home Assistant: NOT responding on $HA_URL"
    fi
}

cmd_logs() { dc logs -f --tail=100 hassio; }

case "${1:-restart}" in
    restart)        cmd_restart ;;
    up|start)       cmd_up ;;
    down|stop)      cmd_down ;;
    clean)          cmd_clean ;;
    status|ps)      cmd_status ;;
    logs)           cmd_logs ;;
    -h|--help|help) sed -n '/^# Subcommands:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//' ;;
    *) echo "Unknown subcommand: $1" >&2
       echo "Try: $0 help" >&2; exit 2 ;;
esac
