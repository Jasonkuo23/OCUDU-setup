#!/usr/bin/env bash
set -u

# shellcheck source=load-temp-gm-env.sh
source "$(cd "$(dirname "$0")" && pwd)/load-temp-gm-env.sh"

CFG="$PTP_CONFIG"
HOLDOVER_MARKER="$RUN_DIR/holdover.active"
ISOLATED_MARKER="$RUN_DIR/isolated-servo.active"
ISOLATED_LOG="$RUN_DIR/phc2sys-isolated.log"
FAIL=0

check() {
  if "$@"; then
    printf '[PASS] %s\n' "$*"
  else
    printf '[FAIL] %s\n' "$*"
    FAIL=$((FAIL + 1))
  fi
}

if ethtool "$FH_IF" 2>/dev/null | grep -Eq 'Port:[[:space:]]+Twisted Pair'; then
  if ethtool "$FH_IF" 2>/dev/null | grep -Eq 'Auto-negotiation:[[:space:]]+on'; then
    printf '[PASS] %s 10GBASE-T autonegotiation is on\n' "$FH_IF"
  else
    printf '[FAIL] %s 10GBASE-T autonegotiation is off\n' "$FH_IF"
    exit 1
  fi
fi

if [ "$(cat "/sys/class/net/$FH_IF/carrier" 2>/dev/null || echo 0)" = 1 ]; then
  printf '[PASS] %s has carrier\n' "$FH_IF"
else
  printf '[FAIL] %s has no carrier\n' "$FH_IF"
  printf 'Temporary GM cannot run; remaining PTP logs may belong to an earlier run.\n'
  exit 1
fi

daemon=ptp4l
pid_file="$RUN_DIR/$daemon.pid"
if [ ! -f "$pid_file" ]; then
  printf '[FAIL] %s is not running (missing %s)\n' "$daemon" "$pid_file"
  printf 'Start the temporary GM successfully before running this check.\n'
  exit 1
fi
pid="$(cat "$pid_file")"
if [ ! -r "/proc/$pid/comm" ] || [ "$(cat "/proc/$pid/comm")" != "$daemon" ]; then
  printf '[FAIL] %s is not running; PID file is stale\n' "$daemon"
  exit 1
fi

holdover_active=0
isolated_active=0
stability_log="$RUN_DIR/phc2sys.log"
if [ -f "$ISOLATED_MARKER" ]; then
  isolated_active=1
  stability_log="$ISOLATED_LOG"
  if systemctl is-active --quiet systemd-timesyncd; then
    printf '[FAIL] isolated servo is active but systemd-timesyncd is still running\n'
    FAIL=$((FAIL + 1))
  else
    printf '[PASS] WAN NTP updates are paused for the isolated PTP test\n'
  fi
  pid_file="$RUN_DIR/phc2sys.pid"
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [ -z "$pid" ] || [ ! -r "/proc/$pid/comm" ] ||
     [ "$(cat "/proc/$pid/comm")" != phc2sys ]; then
    printf '[FAIL] isolated phc2sys is not running\n'
    exit 1
  fi
  printf '[PASS] isolated E810 PHC linreg servo is active\n'
elif [ -f "$HOLDOVER_MARKER" ]; then
  holdover_active=1
  phc2sys_pid="$(cat "$RUN_DIR/phc2sys.pid" 2>/dev/null || true)"
  if [ -n "$phc2sys_pid" ] && [ -r "/proc/$phc2sys_pid/comm" ] &&
     [ "$(cat "/proc/$phc2sys_pid/comm")" = phc2sys ]; then
    printf '[FAIL] holdover marker exists but phc2sys is still running\n'
    FAIL=$((FAIL + 1))
  else
    started_epoch="$(awk -F= '$1 == "started_epoch" {print $2}' "$HOLDOVER_MARKER")"
    now_epoch="$(date +%s)"
    if [ -n "$started_epoch" ] && [ "$started_epoch" -le "$now_epoch" ] 2>/dev/null; then
      holdover_age=$((now_epoch - started_epoch))
      if [ "$holdover_age" -le "$HOLDOVER_MAX_SECONDS" ]; then
        printf '[PASS] E810 PHC holdover is active (%ss old; maximum %ss)\n' \
          "$holdover_age" "$HOLDOVER_MAX_SECONDS"
        calibrated_frequency="$(awk -F= '$1 == "calibrated_frequency_ppb" {value=$2} END {print value}' "$HOLDOVER_MARKER")"
        if [ -n "$calibrated_frequency" ]; then
          printf '[PASS] E810 PHC holdover frequency is calibrated to %s ppb\n' "$calibrated_frequency"
        fi
      else
        printf '[FAIL] E810 PHC holdover is %ss old; maximum is %ss\n' \
          "$holdover_age" "$HOLDOVER_MAX_SECONDS"
        FAIL=$((FAIL + 1))
      fi
    else
      printf '[FAIL] holdover marker has no valid start time\n'
      FAIL=$((FAIL + 1))
    fi
  fi
else
  pid_file="$RUN_DIR/phc2sys.pid"
  if [ ! -f "$pid_file" ]; then
    printf '[FAIL] phc2sys is not running (missing %s)\n' "$pid_file"
    exit 1
  fi
  pid="$(cat "$pid_file")"
  if [ ! -r "/proc/$pid/comm" ] || [ "$(cat "/proc/$pid/comm")" != phc2sys ]; then
    printf '[FAIL] phc2sys is not running; PID file is stale\n'
    exit 1
  fi
fi
if ip -4 addr show dev "$FH_IF" | grep -Fq "$RU_MGMT_ADDR"; then
  printf '[PASS] %s has %s\n' "$FH_IF" "$RU_MGMT_ADDR"
else
  printf '[FAIL] %s is missing %s\n' "$FH_IF" "$RU_MGMT_ADDR"
  FAIL=$((FAIL + 1))
fi
check ping -I "$FH_IF" -c 1 -W 1 "$RU_IP"

printf '\nPTP port data set:\n'
ptp_state="$(pmc -u -b 0 -d "$PTP_DOMAIN" -s "$RUN_DIR/ptp4l" 'GET PORT_DATA_SET' 2>/dev/null || true)"
printf '%s\n' "$ptp_state"
if printf '%s\n' "$ptp_state" | grep -Eq 'portState[[:space:]]+MASTER'; then
  printf '[PASS] host PTP port is MASTER\n'
else
  printf '[FAIL] host PTP port is not MASTER\n'
  FAIL=$((FAIL + 1))
fi

printf '\nPTP direct-link calibration:\n'
if awk '$1 == "delayAsymmetry" && $2 == "0" { found = 1 } END { exit !found }' "$CFG"; then
  printf '[PASS] delay asymmetry is reset to 0 ns pending link recalibration\n'
else
  printf '[FAIL] delay asymmetry is not reset to 0 ns\n'
  FAIL=$((FAIL + 1))
fi

printf '\nPTP default data set:\n'
default_state="$(pmc -u -b 0 -d "$PTP_DOMAIN" -s "$RUN_DIR/ptp4l" 'GET DEFAULT_DATA_SET' 2>/dev/null || true)"
printf '%s\n' "$default_state"
if printf '%s\n' "$default_state" | grep -Eq 'clockClass[[:space:]]+6'; then
  printf '[PASS] temporary GM advertises simulated clock class 6\n'
else
  printf '[FAIL] temporary GM is not advertising simulated clock class 6\n'
  FAIL=$((FAIL + 1))
fi

printf '\nPTP Grandmaster settings:\n'
gm_state="$(pmc -u -b 0 -d "$PTP_DOMAIN" -s "$RUN_DIR/ptp4l" 'GET GRANDMASTER_SETTINGS_NP' 2>/dev/null || true)"
printf '%s\n' "$gm_state"
for expected in \
  'clockClass[[:space:]]+6' \
  'currentUtcOffsetValid[[:space:]]+1' \
  'ptpTimescale[[:space:]]+1' \
  'timeTraceable[[:space:]]+1' \
  'frequencyTraceable[[:space:]]+1'; do
  if ! printf '%s\n' "$gm_state" | grep -Eq "$expected"; then
    printf '[FAIL] missing simulated GM attribute: %s\n' "$expected"
    FAIL=$((FAIL + 1))
  fi
done
if [ "$FAIL" -eq 0 ]; then
  printf '[PASS] simulated class-6 traceability attributes are active\n'
fi

printf '\nE810 PHC stability (last five samples):\n'
offsets="$(awk '/sys offset/ {print $5}' "$stability_log" 2>/dev/null | tail -n 5)"
printf '%s\n' "$offsets"
if printf '%s\n' "$offsets" | awk '
  { value = $1 + 0; if (value < 0) value = -value; if (value > 250) bad = 1 }
  END { exit !(NR == 5 && !bad) }
'; then
  if [ "$isolated_active" -eq 1 ]; then
    printf '[PASS] isolated E810 PHC servo has five consecutive offsets within +/-250 ns\n'
    printf '[WARN] WAN NTP is paused; use only for the isolated short-duration lab test\n'
  elif [ "$holdover_active" -eq 1 ]; then
    printf '[PASS] E810 PHC entered holdover after five offsets within +/-250 ns\n'
    printf '[WARN] PHC is intentionally no longer disciplined by WAN NTP; use only for the isolated short-duration lab test\n'
  else
    printf '[PASS] E810 PHC has five consecutive offsets within +/-250 ns\n'
  fi
else
  printf '[FAIL] E810 PHC is not stable within +/-250 ns\n'
  FAIL=$((FAIL + 1))
fi

printf '\nRecent ptp4l output:\n'
tail -n 20 "$RUN_DIR/ptp4l.log" 2>/dev/null || true
printf '\nRecent phc2sys output:\n'
tail -n 20 "$stability_log" 2>/dev/null || true

exit "$FAIL"
