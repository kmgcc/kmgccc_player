#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${KMGCCC_APP_PROCESS_NAME:-kmgccc_player}"
TERMINATE_EXISTING=0

usage() {
    printf '%s\n' \
        "Usage: ./scripts/check-app-process-state.sh [--terminate-existing]" \
        "" \
        "Default mode reports the exact app process without changing it." \
        "--terminate-existing gracefully stops matching app processes and uses KILL only if needed."
}

while (($# > 0)); do
    case "$1" in
        --terminate-existing)
            TERMINATE_EXISTING=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

running_pids() {
    /usr/bin/pgrep -x "$APP_NAME" || true
}

print_processes() {
    local pids="$1"

    printf 'Running %s process(es):\n' "$APP_NAME"
    for pid in $pids; do
        printf '  PID %s:\n' "$pid"
        /bin/ps -ww -p "$pid" -o pid=,ppid=,user=,lstart=,command=
    done
}

wait_for_exit() {
    local attempt

    for attempt in {1..40}; do
        [[ -z "$(running_pids)" ]] && return 0
        sleep 0.25
    done
    return 1
}

terminate_processes() {
    local pids="$1"
    local remaining
    local pid

    printf 'Sending TERM to existing %s process(es).\n' "$APP_NAME"
    for pid in $pids; do
        /bin/kill -TERM "$pid" 2>/dev/null || true
    done

    if wait_for_exit; then
        printf 'Existing %s process(es) exited cleanly.\n' "$APP_NAME"
        return 0
    fi

    remaining="$(running_pids)"
    if [[ -n "$remaining" ]]; then
        print_processes "$remaining"
        printf 'Sending KILL to remaining %s process(es).\n' "$APP_NAME" >&2
        for pid in $remaining; do
            /bin/kill -KILL "$pid" 2>/dev/null || true
        done
    fi

    if wait_for_exit; then
        printf 'Existing %s process(es) were terminated.\n' "$APP_NAME"
        return 0
    fi

    remaining="$(running_pids)"
    print_processes "$remaining"
    printf 'Process termination failed; refusing to launch another instance.\n' >&2
    return 1
}

pids="$(running_pids)"

if [[ -z "$pids" ]]; then
    printf 'No running %s process found.\n' "$APP_NAME"
    exit 0
fi

print_processes "$pids"

if ((TERMINATE_EXISTING == 0)); then
    printf 'Process preflight found an existing instance.\n' >&2
    exit 1
fi

if terminate_processes "$pids"; then
    exit 0
fi
exit 1
