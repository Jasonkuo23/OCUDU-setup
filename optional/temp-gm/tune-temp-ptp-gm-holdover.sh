#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=load-temp-gm-env.sh
source "$(cd "$(dirname "$0")" && pwd)/load-temp-gm-env.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

HOLDOVER_MARKER="$RUN_DIR/holdover.active"
PTP_UDS="$RUN_DIR/ptp4l"

case "$TARGET_FREQUENCY_PPB" in
  -[0-9]*|[0-9]*) ;;
  *) echo "TARGET_FREQUENCY_PPB must be an integer." >&2; exit 1 ;;
esac
if [ "$TARGET_FREQUENCY_PPB" -lt -100000 ] ||
   [ "$TARGET_FREQUENCY_PPB" -gt 100000 ]; then
  echo "Refusing frequency outside the guarded +/-100000 ppb range." >&2
  exit 1
fi

if [ ! -f "$HOLDOVER_MARKER" ]; then
  echo "E810 PHC holdover is not active." >&2
  exit 1
fi
if pgrep -x phc2sys >/dev/null; then
  echo "phc2sys is still running; refusing to fight its servo." >&2
  exit 1
fi
if ! pmc -u -b 0 -d "$PTP_DOMAIN" -s "$PTP_UDS" 'GET PORT_DATA_SET' 2>/dev/null |
     grep -Eq 'portState[[:space:]]+MASTER'; then
  echo "Temporary-GM ptp4l is not in MASTER state." >&2
  exit 1
fi

echo "Current E810 PHC frequency adjustment:"
phc_ctl "$FH_IF" -- freq
phc_ctl "$FH_IF" -- freq "$TARGET_FREQUENCY_PPB"
echo "Updated E810 PHC frequency adjustment:"
phc_ctl "$FH_IF" -- freq

{
  printf 'calibrated_epoch=%s\n' "$(date +%s)"
  printf 'calibrated_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'calibrated_frequency_ppb=%s\n' "$TARGET_FREQUENCY_PPB"
} >> "$HOLDOVER_MARKER"

echo "Holdover frequency set to ${TARGET_FREQUENCY_PPB} ppb."
echo "This corresponds to the empirical phc2sys pre-WAN-poll steady value of about -8900 ppb."
echo "It is not a traceable calibration."
