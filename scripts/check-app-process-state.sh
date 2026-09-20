#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${KMGCCC_APP_PROCESS_NAME:-kmgccc_player}"

pids="$(/usr/bin/pgrep -x "$APP_NAME" || true)"

if [[ -z "$pids" ]]; then
    printf 'No running %s process found.\n' "$APP_NAME"
    exit 0
fi

printf 'Running %s process(es):\n' "$APP_NAME"
for pid in $pids; do
    printf '  PID %s:\n' "$pid"
    /bin/ps -ww -p "$pid" -o pid=,ppid=,user=,lstart=,command=
done

printf 'Process preflight failed: preserve the existing instance and inspect it before launching another.\n' >&2
exit 1
