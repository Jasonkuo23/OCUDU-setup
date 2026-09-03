#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=load-temp-gm-env.sh
source "$(cd "$(dirname "$0")" && pwd)/load-temp-gm-env.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

PTP_UDS="$RUN_DIR/ptp4l"
HOLDOVER_MARKER="$RUN_DIR/holdover.active"
ISOLATED_MARKER="$RUN_DIR/isolated-servo.active"
ISOLATED_LOG="$RUN_DIR/phc2sys-isolated.log"
PHC_STABILITY_TIMEOUT_SECONDS="${PHC_STABILITY_TIMEOUT_SECONDS:-180}"
PHC_STABLE_SAMPLE_COUNT="${PHC_STABLE_SAMPLE_COUNT:-30}"
PHC_FREQUENCY_SPREAD_PPB="${PHC_FREQUENCY_SPREAD_PPB:-500}"
PHC_SANITY_FREQ_LIMIT_PPB="${PHC_SANITY_FREQ_LIMIT_PPB:-200000}"
TIMESYNCD_WAS_ACTIVE=0

restore_on_error() {
  rc="${1:-$?}"
  pid_file="$RUN_DIR/phc2sys.pid"
  if [ -f "$pid_file" ]; then
    pid="$(cat "$pid_file")"
    if [ -r "/proc/$pid/comm" ] && [ "$(cat "/proc/$pid/comm")" = phc2sys ]; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  fi
  if [ "$TIMESYNCD_WAS_ACTIVE" -eq 1 ]; then
    systemctl start systemd-timesyncd 2>/dev/null || true
  fi
  rm -f "$ISOLATED_MARKER"
  exit "$rc"
}
trap restore_on_error ERR
trap 'restore_on_error 130' INT
trap 'restore_on_error 143' TERM

if [ ! -f "$HOLDOVER_MARKER" ]; then
  echo "Verified E810 PHC holdover is not active; refusing the transition." >&2
  exit 1
fi
if [ -f "$ISOLATED_MARKER" ]; then
  echo "Isolated phc2sys servo is already marked active." >&2
  exit 1
fi
if pgrep -x phc2sys >/dev/null; then
  echo "A phc2sys process is already running; refusing to start another." >&2
  exit 1
fi
ptp_pid="$(cat "$RUN_DIR/ptp4l.pid" 2>/dev/null || true)"
if [ -z "$ptp_pid" ] || [ ! -r "/proc/$ptp_pid/comm" ] ||
   [ "$(cat "/proc/$ptp_pid/comm")" != ptp4l ]; then
  echo "Temporary-GM ptp4l is not running." >&2
  exit 1
fi
if ! pmc -u -b 0 -d "$PTP_DOMAIN" -s "$PTP_UDS" 'GET PORT_DATA_SET' 2>/dev/null |
     grep -Eq 'portState[[:space:]]+MASTER'; then
  echo "Temporary-GM ptp4l is not in MASTER state." >&2
  exit 1
fi

if systemctl is-active --quiet systemd-timesyncd; then
  TIMESYNCD_WAS_ACTIVE=1
fi
{
  printf 'started_epoch=%s\n' "$(date +%s)"
  printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'timesyncd_was_active=%s\n' "$TIMESYNCD_WAS_ACTIVE"
  printf 'servo=linreg\n'
  printf 'source=CLOCK_REALTIME\n'
  printf 'target=%s\n' "$FH_IF"
} > "$ISOLATED_MARKER"
chmod 0644 "$ISOLATED_MARKER"

if [ "$TIMESYNCD_WAS_ACTIVE" -eq 1 ]; then
  systemctl stop systemd-timesyncd
fi
if systemctl is-active --quiet systemd-timesyncd; then
  echo "systemd-timesyncd did not stop." >&2
  false
fi

: > "$ISOLATED_LOG"
taskset -c "$PHC2SYS_CPU" \
  phc2sys -s CLOCK_REALTIME -c "$FH_IF" -w -m -E linreg \
    -F 0.00002 -L "$PHC_SANITY_FREQ_LIMIT_PPB" -n "$PTP_DOMAIN" -z "$PTP_UDS" \
  > "$ISOLATED_LOG" 2>&1 &
echo $! > "$RUN_DIR/phc2sys.pid"
sleep 2
if ! kill -0 "$(cat "$RUN_DIR/phc2sys.pid")" 2>/dev/null; then
  echo "Isolated phc2sys failed to start:" >&2
  tail -n 40 "$ISOLATED_LOG" >&2
  false
fi

phc_stable=0
for second in $(seq 1 "$PHC_STABILITY_TIMEOUT_SECONDS"); do
  stable_samples="$(awk '/sys offset/ && $6 == "s2" {print $5, $8}' \
    "$ISOLATED_LOG" | tail -n "$PHC_STABLE_SAMPLE_COUNT")"
  if printf '%s\n' "$stable_samples" | awk \
    -v required="$PHC_STABLE_SAMPLE_COUNT" \
    -v max_spread="$PHC_FREQUENCY_SPREAD_PPB" '
      NR == 1 { min_freq = max_freq = $2 }
      {
        offset = $1 + 0
        if (offset < 0) offset = -offset
        if (offset > 250) bad_offset = 1
        if ($2 < min_freq) min_freq = $2
        if ($2 > max_freq) max_freq = $2
      }
      END {
        spread = max_freq - min_freq
        exit !(NR == required && !bad_offset && spread <= max_spread)
      }
    '; then
    phc_stable=1
    break
  fi
  if [ $((second % 30)) -eq 0 ]; then
    latest_sample="$(printf '%s\n' "$stable_samples" | tail -n 1)"
    echo "Waiting for ${PHC_STABLE_SAMPLE_COUNT} isolated E810 s2 samples (${second}/${PHC_STABILITY_TIMEOUT_SECONDS}s, latest offset/frequency ${latest_sample:-unavailable})..."
  fi
  sleep 1
done
if [ "$phc_stable" -ne 1 ]; then
  echo "Isolated phc2sys did not produce five offsets within +/-250 ns:" >&2
  tail -n 30 "$ISOLATED_LOG" >&2
  false
fi

rm -f "$HOLDOVER_MARKER"
echo "Isolated E810 PHC servo started successfully."
echo "systemd-timesyncd is temporarily stopped; host CLOCK_REALTIME is the local source."
echo "phc2sys uses the linreg servo and permits a PHC step only during acquisition."
echo "The gate required ${PHC_STABLE_SAMPLE_COUNT} s2 offsets within +/-250 ns and <=${PHC_FREQUENCY_SPREAD_PPB} ppb frequency spread."
echo "Stop the temporary GM with sudo ./stop-temp-ptp-gm.sh to restore systemd-timesyncd."
echo "Log: $ISOLATED_LOG"
trap - ERR
trap - INT TERM
