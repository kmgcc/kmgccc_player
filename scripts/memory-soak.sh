#!/usr/bin/env bash
set -euo pipefail

# Long-running memory sampler for an already-running kmgccc_player instance.
#
# Short Instruments sessions only see the malloc heap for a minute or two. The
# growth users report appears after an hour of ordinary use and is mostly
# outside the heap (CoreAnimation, IOSurface, CG Image, malloc fragmentation),
# so this records the same phys_footprint Activity Monitor shows, broken down
# by VM category, for as long as the session runs. It never launches,
# activates or terminates the app.

APP_NAME="${KMGCCC_APP_PROCESS_NAME:-kmgccc_player}"
LOG_SUBSYSTEM="kmg.myplayer2"
INTERVAL=15
STEP_MB=50
MAX_MEMGRAPHS=8
OUT_DIR=""
TARGET_PID=""
CAPTURE_LOGS=1
FINAL_MEMGRAPH=1
SUMMARY_DIR=""
WAIT_FOR_LAUNCH=0

usage() {
    printf '%s\n' \
        "Usage: ./scripts/memory-soak.sh [options]" \
        "       ./scripts/memory-soak.sh --summarize <dir>" \
        "" \
        "Samples phys_footprint and its VM categories of the running $APP_NAME until" \
        "Ctrl-C or until the app exits, then prints which categories grew." \
        "" \
        "  --interval <sec>       sampling interval, fractions allowed (default: $INTERVAL)" \
        "  --wait                 wait for the app to launch, then sample from its first moments" \
        "  --step-mb <MB>         capture a memgraph each time footprint rises by this" \
        "                         much above the first sample (default: $STEP_MB)" \
        "  --max-memgraphs <n>    memgraph budget, baseline and final included (default: $MAX_MEMGRAPHS)" \
        "  --pid <pid>            sample this process instead of looking it up by name" \
        "  --out <dir>            output directory (default: /tmp/player-traces/memory-soak-<time>)" \
        "  --no-logs              do not record the app's unified log alongside samples" \
        "  --no-final-memgraph    skip the memgraph taken when sampling stops" \
        "  --summarize <dir>      print the summary of an earlier run and exit" \
        "" \
        "memgraph capture briefly suspends the app (audio may drop out). Allocation backtraces" \
        "are only recorded when the app was started with MallocStackLogging=lite."
}

while (($# > 0)); do
    case "$1" in
        --interval) INTERVAL="$2"; shift ;;
        --step-mb) STEP_MB="$2"; shift ;;
        --max-memgraphs) MAX_MEMGRAPHS="$2"; shift ;;
        --pid) TARGET_PID="$2"; shift ;;
        --wait) WAIT_FOR_LAUNCH=1 ;;
        --out) OUT_DIR="$2"; shift ;;
        --no-logs) CAPTURE_LOGS=0 ;;
        --no-final-memgraph) FINAL_MEMGRAPH=0 ;;
        --summarize) SUMMARY_DIR="$2"; shift ;;
        --help|-h) usage; exit 0 ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

mb() {
    /usr/bin/awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576 }'
}

summarize() {
    local dir="$1"
    local timeline="$dir/timeline.tsv"
    local categories="$dir/categories.tsv"

    if [[ ! -s "$timeline" ]]; then
        printf 'No samples in %s\n' "$dir" >&2
        return 1
    fi

    printf '\n== Footprint (%s)\n' "$dir"
    /usr/bin/awk -F'\t' '
        NR == 1 { first = $3; firstTime = $2 }
        { last = $3; lastTime = $2; samples++
          if ($3 > peak) { peak = $3; peakTime = $2 }
          if ($4 > kernelPeak) kernelPeak = $4 }
        END {
            printf "start %.1f MB @ %s   end %.1f MB @ %s   delta %+.1f MB\n",
                first / 1048576, firstTime, last / 1048576, lastTime, (last - first) / 1048576
            printf "sampled peak %.1f MB @ %s   kernel peak since launch %.1f MB   samples %d\n",
                peak / 1048576, peakTime, kernelPeak / 1048576, samples
        }' "$timeline"

    [[ -s "$categories" ]] || return 0

    printf '\n== Categories, sorted by growth (MB)\n'
    printf '%10s %10s %10s %10s   %s\n' start end peak delta category
    /usr/bin/awk -F'\t' '
        !($1 in seen) { seen[$1] = 1; epochs[++n] = $1 }
        { value[$1 SUBSEP $2] = $3; names[$2] = 1 }
        END {
            for (c in names) {
                f = ((epochs[1] SUBSEP c) in value) ? value[epochs[1] SUBSEP c] : 0
                l = ((epochs[n] SUBSEP c) in value) ? value[epochs[n] SUBSEP c] : 0
                mx = 0
                for (i = 1; i <= n; i++) {
                    k = epochs[i] SUBSEP c
                    if ((k in value) && value[k] > mx) mx = value[k]
                }
                if (mx < 1048576) continue
                printf "%d\t%.1f\t%.1f\t%.1f\t%s\n", l - f, f / 1048576, l / 1048576, mx / 1048576, c
            }
        }' "$categories" \
        | /usr/bin/sort -t$'\t' -k1,1nr \
        | /usr/bin/head -n 20 \
        | /usr/bin/awk -F'\t' '{ printf "%10s %10s %10s %+10.1f   %s\n", $2, $3, $4, $1 / 1048576, $5 }'

    if compgen -G "$dir/memgraphs/*.memgraph" >/dev/null; then
        printf '\n== memgraphs\n'
        ls -1 "$dir"/memgraphs/*.memgraph
        printf '\nNext: heap -s -H --diffFrom=<baseline>.memgraph <later>.memgraph | head -60\n'
    fi
}

if [[ -n "$SUMMARY_DIR" ]]; then
    summarize "$SUMMARY_DIR"
    exit $?
fi

if [[ -z "$TARGET_PID" ]] && ((WAIT_FOR_LAUNCH)); then
    if /usr/bin/pgrep -x "$APP_NAME" >/dev/null; then
        printf '%s is already running; quit it first so sampling starts at launch.\n' "$APP_NAME" >&2
        exit 1
    fi
    printf 'Waiting for %s to launch ...\n' "$APP_NAME"
    until TARGET_PID="$(/usr/bin/pgrep -n -x "$APP_NAME")"; do
        sleep 0.1
    done
fi

if [[ -z "$TARGET_PID" ]]; then
    pids="$(/usr/bin/pgrep -x "$APP_NAME" || true)"
    count="$(printf '%s\n' "$pids" | /usr/bin/grep -c . || true)"
    if [[ "$count" != "1" ]]; then
        printf 'Expected exactly one running %s, found %s. Start the app first, or pass --pid.\n' \
            "$APP_NAME" "$count" >&2
        exit 1
    fi
    TARGET_PID="$pids"
fi

# The XCTest host is the App binary; sampling it would describe a test run.
if /bin/ps -p "$TARGET_PID" -o command= 2>/dev/null \
    | /usr/bin/grep -qE -- '-NSTreatUnknownArgumentsAsOpen|-ApplePersistenceIgnoreState|XCTest'; then
    printf 'PID %s is an XCTest host; refusing to sample it.\n' "$TARGET_PID" >&2
    exit 1
fi

if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="/tmp/player-traces/memory-soak-$(date +%Y%m%d-%H%M%S)"
fi
/bin/mkdir -p "$OUT_DIR/memgraphs"

{
    printf 'date\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf 'pid\t%s\n' "$TARGET_PID"
    printf 'process\t%s\n' "$(/bin/ps -ww -p "$TARGET_PID" -o lstart=,command=)"
    printf 'macos\t%s (%s)\n' "$(/usr/bin/sw_vers -productVersion)" "$(/usr/bin/sw_vers -buildVersion)"
    printf 'hw.memsize\t%s\n' "$(/usr/sbin/sysctl -n hw.memsize)"
    printf 'interval\t%s\nstep_mb\t%s\nmax_memgraphs\t%s\n' "$INTERVAL" "$STEP_MB" "$MAX_MEMGRAPHS"
} >"$OUT_DIR/meta.tsv"

LOG_STREAM_PID=""
if ((CAPTURE_LOGS)); then
    /usr/bin/log stream --style compact --level info \
        --predicate "subsystem == \"$LOG_SUBSYSTEM\"" \
        >"$OUT_DIR/app-log.txt" 2>/dev/null &
    LOG_STREAM_PID=$!
fi

GRAPH_COUNT=0
BASELINE=""
LAST_TOTAL=""
NEXT_THRESHOLD=""

capture_memgraph() {
    local label="$1"
    ((GRAPH_COUNT < MAX_MEMGRAPHS)) || return 0
    /bin/kill -0 "$TARGET_PID" 2>/dev/null || return 0

    local base
    base="$OUT_DIR/memgraphs/$(printf '%02d' "$GRAPH_COUNT")-$(date +%H%M%S)-$label"
    printf '  capturing memgraph %s ...\n' "$(basename "$base")"
    # A corpse fork keeps the live app suspended only while it is copied.
    # leaks exits non-zero when it finds leaks; the graph is still written.
    /usr/bin/leaks --forkCorpse "$TARGET_PID" --outputGraph="$base.memgraph" >"$base.leaks.txt" 2>&1 || true
    if [[ -s "$base.memgraph" ]]; then
        GRAPH_COUNT=$((GRAPH_COUNT + 1))
    else
        printf '  memgraph failed, see %s.leaks.txt (Release builds without get-task-allow cannot be inspected)\n' \
            "$base" >&2
        # Stop retrying a capture that cannot succeed for this process.
        MAX_MEMGRAPHS=0
    fi
}

sample_once() {
    local now raw total peak
    now="$(date +%s)"
    raw="$(/usr/bin/footprint -p "$TARGET_PID" -f bytes 2>/dev/null)" || return 1
    total="$(/usr/bin/awk '/phys_footprint:/ { print $2; exit }' <<<"$raw")"
    peak="$(/usr/bin/awk '/phys_footprint_peak:/ { print $2; exit }' <<<"$raw")"
    [[ -n "$total" ]] || return 1

    printf '%s\t%s\t%s\t%s\n' "$now" "$(date -r "$now" +%H:%M:%S)" "$total" "${peak:-0}" \
        >>"$OUT_DIR/timeline.tsv"
    /usr/bin/awk -v t="$now" '
        $1 ~ /^[0-9]+$/ && $2 == "B" && $4 == "B" && $6 == "B" && $8 != "TOTAL" {
            name = $8
            for (i = 9; i <= NF; i++) name = name " " $i
            printf "%s\t%s\t%s\n", t, name, $1
        }' <<<"$raw" >>"$OUT_DIR/categories.tsv"
    LAST_TOTAL="$total"
}

FINISHED=0
finish() {
    ((FINISHED)) && return
    FINISHED=1
    trap - INT TERM
    if ((FINAL_MEMGRAPH)) && [[ -n "$BASELINE" ]]; then
        # Reserve the final slot even if threshold captures used the budget.
        MAX_MEMGRAPHS=$((GRAPH_COUNT + 1))
        capture_memgraph "final"
    fi
    if [[ -n "$LOG_STREAM_PID" ]]; then
        /bin/kill "$LOG_STREAM_PID" 2>/dev/null || true
        wait "$LOG_STREAM_PID" 2>/dev/null || true
    fi
    summarize "$OUT_DIR" || true
}
trap 'finish; exit 0' INT TERM
trap finish EXIT

printf 'Sampling %s (PID %s) every %ss into %s\n' "$APP_NAME" "$TARGET_PID" "$INTERVAL" "$OUT_DIR"
printf 'Use the app normally; press Ctrl-C to stop.\n\n'

while /bin/kill -0 "$TARGET_PID" 2>/dev/null; do
    if ! sample_once; then
        printf 'footprint could not read PID %s; stopping.\n' "$TARGET_PID" >&2
        break
    fi

    if [[ -z "$BASELINE" ]]; then
        BASELINE="$LAST_TOTAL"
        NEXT_THRESHOLD=$((BASELINE + STEP_MB * 1048576))
        capture_memgraph "baseline-$(mb "$LAST_TOTAL")MB"
    elif ((LAST_TOTAL >= NEXT_THRESHOLD)); then
        capture_memgraph "$(mb "$LAST_TOTAL")MB"
        while ((NEXT_THRESHOLD <= LAST_TOTAL)); do
            NEXT_THRESHOLD=$((NEXT_THRESHOLD + STEP_MB * 1048576))
        done
    fi

    printf '%s  %8s MB  %+8.1f MB vs start\n' \
        "$(date +%H:%M:%S)" "$(mb "$LAST_TOTAL")" \
        "$(/usr/bin/awk -v a="$LAST_TOTAL" -v b="$BASELINE" 'BEGIN { print (a - b) / 1048576 }')"
    sleep "$INTERVAL"
done
