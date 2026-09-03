#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=load-temp-gm-env.sh
source "$(cd "$(dirname "$0")" && pwd)/load-temp-gm-env.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

RUN_DIR="${RUN_DIR:-/run/ocudu-temp-gm}"
HOLDOVER_MARKER="$RUN_DIR/holdover.active"
PTP_UDS="$RUN_DIR/ptp4l"

if [ -f "$HOLDOVER_MARKER" ]; then
  echo "E810 PHC holdover is already active."
  exit 0
fi

ptp_pid="$(cat "$RUN_DIR/ptp4l.pid" 2>/dev/null || true)"
if [ -z "$ptp_pid" ] || [ ! -r "/proc/$ptp_pid/comm" ] ||
   [ "$(cat "/proc/$ptp_pid/comm")" != ptp4l ]; then
  echo "Temporary-GM ptp4l is not running." >&2
  exit 1
fi

ptp_state="$(pmc -u -b 0 -d "$PTP_DOMAIN" -s "$PTP_UDS" 'GET PORT_DATA_SET' 2>/dev/null || true)"
if ! printf '%s\n' "$ptp_state" | grep -Eq 'portState[[:space:]]+MASTER'; then
  echo "Temporary-GM ptp4l is not in MASTER state." >&2
  exit 1
fi

phc_pid="$(cat "$RUN_DIR/phc2sys.pid" 2>/dev/null || true)"
if [ -z "$phc_pid" ] || [ ! -r "/proc/$phc_pid/comm" ] ||
   [ "$(cat "/proc/$phc_pid/comm")" != phc2sys ]; then
  echo "phc2sys is not running; cannot enter a verified holdover." >&2
  exit 1
fi

offsets="$(awk '/sys offset/ {print $5}' "$RUN_DIR/phc2sys.log" | tail -n 5)"
if ! printf '%s\n' "$offsets" | awk '
  { value = $1 + 0; if (value < 0) value = -value; if (value > 250) bad = 1 }
  END { exit !(NR == 5 && !bad) }
'; then
  echo "E810 PHC has not produced five consecutive offsets within +/-250 ns." >&2
  printf '%s\n' "$offsets" >&2
  exit 1
fi

last_offset="$(printf '%s\n' "$offsets" | tail -n 1)"
last_frequency="$(awk '/sys offset/ {print $8}' "$RUN_DIR/phc2sys.log" | tail -n 1)"

kill "$phc_pid"
for _ in $(seq 1 50); do
  if ! kill -0 "$phc_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if kill -0 "$phc_pid" 2>/dev/null; then
  echo "phc2sys (pid $phc_pid) did not stop; holdover was not entered." >&2
  exit 1
fi
rm -f "$RUN_DIR/phc2sys.pid"

if ! pmc -u -b 0 -d "$PTP_DOMAIN" -s "$PTP_UDS" 'GET PORT_DATA_SET' 2>/dev/null |
     grep -Eq 'portState[[:space:]]+MASTER'; then
  echo "ptp4l lost MASTER state while entering holdover." >&2
  exit 1
fi

{
  printf 'started_epoch=%s\n' "$(date +%s)"
  printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'last_offset_ns=%s\n' "$last_offset"
  printf 'last_frequency_ppb=%s\n' "$last_frequency"
} > "$HOLDOVER_MARKER"
chmod 0644 "$HOLDOVER_MARKER"

echo "E810 PHC holdover started; ptp4l remains MASTER."
echo "Last disciplined offset: ${last_offset} ns; last PHC frequency: ${last_frequency} ppb."
echo "WARNING: this freezes the PHC against WAN-NTP corrections for an isolated, short-duration lab test."
echo "The checker permits at most 7200 seconds of holdover by default."
echo "Stop the temporary GM after the test with sudo ./stop-temp-ptp-gm.sh."
