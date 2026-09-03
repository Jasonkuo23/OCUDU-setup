#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=load-temp-gm-env.sh
source "$(cd "$(dirname "$0")" && pwd)/load-temp-gm-env.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

CFG="$PTP_CONFIG"
ISOLATED_MARKER="$RUN_DIR/isolated-servo.active"
ISOLATED_LOG="$RUN_DIR/phc2sys-isolated.log"
TIMESYNCD_WAS_ACTIVE=0
ADDRESS_ADDED=0
CARRIER_STABILITY_SECONDS="${CARRIER_STABILITY_SECONDS:-30}"
CARRIER_ACQUIRE_TIMEOUT_SECONDS="${CARRIER_ACQUIRE_TIMEOUT_SECONDS:-60}"
PHC_STABILITY_TIMEOUT_SECONDS="${PHC_STABILITY_TIMEOUT_SECONDS:-180}"
PHC_STABLE_SAMPLE_COUNT="${PHC_STABLE_SAMPLE_COUNT:-30}"
PHC_FREQUENCY_SPREAD_PPB="${PHC_FREQUENCY_SPREAD_PPB:-500}"
PHC_SANITY_FREQ_LIMIT_PPB="${PHC_SANITY_FREQ_LIMIT_PPB:-200000}"

cleanup_on_error() {
  rc="${1:-$?}"
  for name in phc2sys ptp4l; do
    pid_file="$RUN_DIR/$name.pid"
    if [ -f "$pid_file" ]; then
      pid="$(cat "$pid_file")"
      kill "$pid" 2>/dev/null || true
      rm -f "$pid_file"
    fi
  done
  if [ "$ADDRESS_ADDED" -eq 1 ]; then
    ip addr del "$RU_MGMT_ADDR" dev "$FH_IF" 2>/dev/null || true
    rm -f "$RUN_DIR/address-added-by-script"
  fi
  rm -f "$RUN_DIR/holdover.active" "$ISOLATED_MARKER"
  if [ "$TIMESYNCD_WAS_ACTIVE" -eq 1 ]; then
    systemctl start systemd-timesyncd 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup_on_error ERR
trap 'cleanup_on_error 130' INT
trap 'cleanup_on_error 143' TERM

case "$ISOLATED_SERVO" in
  0|1) ;;
  *) echo "ISOLATED_SERVO must be 0 or 1." >&2; exit 1 ;;
esac

if ! ip link show "$FH_IF" >/dev/null 2>&1; then
  echo "Fronthaul interface not found: $FH_IF" >&2
  exit 1
fi

# Legacy twisted-pair ports require autonegotiation. The replacement E810-DA4
# fronthaul is an SFP+ link and skips this block when it already reports fibre.
ip link set dev "$FH_IF" up
if ethtool "$FH_IF" 2>/dev/null | grep -Eq 'Port:[[:space:]]+Twisted Pair'; then
  link_info="$(ethtool "$FH_IF" 2>/dev/null)"
  if printf '%s\n' "$link_info" | grep -Eq 'Auto-negotiation:[[:space:]]+on' &&
     printf '%s\n' "$link_info" | grep -Eq 'Speed:[[:space:]]+10000Mb/s' &&
     printf '%s\n' "$link_info" | grep -Eq 'Link detected:[[:space:]]+yes'; then
    echo "$FH_IF already has a stable negotiated 10GBASE-T link; leaving autonegotiation unchanged."
  else
    if ! ethtool -s "$FH_IF" autoneg on; then
      echo "Could not enable 10GBASE-T autonegotiation on $FH_IF." >&2
      exit 1
    fi
    echo "Enabled 10GBASE-T autonegotiation on $FH_IF; waiting for the RU link."
  fi
fi

carrier_acquired=0
for _ in $(seq 1 "$CARRIER_ACQUIRE_TIMEOUT_SECONDS"); do
  if [ "$(cat "/sys/class/net/$FH_IF/carrier" 2>/dev/null || echo 0)" = 1 ]; then
    carrier_acquired=1
    break
  fi
  sleep 1
done
if [ "$carrier_acquired" -ne 1 ]; then
  echo "No carrier on $FH_IF after ${CARRIER_ACQUIRE_TIMEOUT_SECONDS} seconds; check the Cat6A cable and reseat the RU SRJ-10GT module." >&2
  exit 1
fi

carrier_changes_before="$(cat "/sys/class/net/$FH_IF/carrier_changes" 2>/dev/null || echo unknown)"
for _ in $(seq 1 "$CARRIER_STABILITY_SECONDS"); do
  if [ "$(cat "/sys/class/net/$FH_IF/carrier" 2>/dev/null || echo 0)" != 1 ]; then
    echo "Carrier on $FH_IF is unstable; wait for the RU/SFP link to settle." >&2
    exit 1
  fi
  sleep 1
done
carrier_changes_after="$(cat "/sys/class/net/$FH_IF/carrier_changes" 2>/dev/null || echo unknown)"
if [ "$carrier_changes_before" != "$carrier_changes_after" ]; then
  echo "Carrier on $FH_IF changed during the ${CARRIER_STABILITY_SECONDS}-second stability gate; refusing to start." >&2
  exit 1
fi

if pgrep -x ptp4l >/dev/null || pgrep -x phc2sys >/dev/null; then
  echo "A ptp4l/phc2sys process is already running; refusing to replace it." >&2
  exit 1
fi

install -d -m 0755 "$RUN_DIR"
rm -f "$RUN_DIR/holdover.active" "$ISOLATED_MARKER"
if ! ip -4 addr show dev "$FH_IF" | grep -Fq "$RU_MGMT_ADDR"; then
  ru_mgmt_ip="${RU_MGMT_ADDR%/*}"
  if ! command -v arping >/dev/null 2>&1; then
    echo "arping is required to check that $ru_mgmt_ip is unused." >&2
    exit 1
  fi
  # This host uses the Thomas Habets arping implementation: -0 probes with
  # source 0.0.0.0. Parse its summary instead of relying on variant-specific
  # exit status semantics.
  arp_probe="$(arping -0 -i "$FH_IF" -c 3 -w 3 "$ru_mgmt_ip" 2>&1 || true)"
  if printf '%s\n' "$arp_probe" | grep -Eq '[1-9][0-9]* packets received'; then
    echo "Address conflict detected for $ru_mgmt_ip on $FH_IF; refusing to start." >&2
    exit 1
  fi
  if ! printf '%s\n' "$arp_probe" | grep -Eq '[0-9]+ packets transmitted, 0 packets received'; then
    echo "Could not verify that $ru_mgmt_ip is unused:" >&2
    printf '%s\n' "$arp_probe" >&2
    exit 1
  fi
  ip addr add "$RU_MGMT_ADDR" dev "$FH_IF"
  printf '%s\n' "$RU_MGMT_ADDR" > "$RUN_DIR/address-added-by-script"
  ADDRESS_ADDED=1
fi

if [ "$ISOLATED_SERVO" -eq 1 ]; then
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
fi

taskset -c "$PTP_CPU" ptp4l -f "$CFG" -i "$FH_IF" -m >"$RUN_DIR/ptp4l.log" 2>&1 &
echo $! > "$RUN_DIR/ptp4l.pid"
sleep 2
if ! kill -0 "$(cat "$RUN_DIR/ptp4l.pid")" 2>/dev/null; then
  echo "ptp4l failed to start:" >&2
  tail -n 40 "$RUN_DIR/ptp4l.log" >&2
  false
fi

# Lab clock chain: host CLOCK_REALTIME -> E810 PHC -> RU PTP slave.
# In isolated mode, pause WAN NTP first, use the linreg servo, and allow a PHC
# step only during initial acquisition. Normal mode retains the original PI
# behavior for compatibility.
if [ "$ISOLATED_SERVO" -eq 1 ]; then
  : > "$ISOLATED_LOG"
  taskset -c "$PHC2SYS_CPU" \
    phc2sys -s CLOCK_REALTIME -c "$FH_IF" -w -m -E linreg \
    -F 0.00002 -L "$PHC_SANITY_FREQ_LIMIT_PPB" -n "$PTP_DOMAIN" -z "$RUN_DIR/ptp4l" \
    > "$ISOLATED_LOG" 2>&1 &
  stability_log="$ISOLATED_LOG"
else
  taskset -c "$PHC2SYS_CPU" \
    phc2sys -s CLOCK_REALTIME -c "$FH_IF" -w -m -S 0.00002 -L 100000 \
    -n "$PTP_DOMAIN" -z "$RUN_DIR/ptp4l" \
    >"$RUN_DIR/phc2sys.log" 2>&1 &
  stability_log="$RUN_DIR/phc2sys.log"
fi
echo $! > "$RUN_DIR/phc2sys.pid"
sleep 2
if ! kill -0 "$(cat "$RUN_DIR/phc2sys.pid")" 2>/dev/null; then
  echo "phc2sys failed to start:" >&2
  tail -n 40 "$stability_log" >&2
  false
fi

# Do not advertise acceptable GM quality until the PHC has settled. Requiring
# five consecutive samples within the advertised 0x22 (250 ns) accuracy also
# prevents the RU from beginning acquisition during the initial PHC transient.
phc_stable=0
for second in $(seq 1 "$PHC_STABILITY_TIMEOUT_SECONDS"); do
  if [ "$ISOLATED_SERVO" -eq 1 ]; then
    stable_samples="$(awk '/sys offset/ && $6 == "s2" {print $5, $8}' \
      "$stability_log" | tail -n "$PHC_STABLE_SAMPLE_COUNT")"
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
        END { exit !(NR == required && !bad_offset &&
                     max_freq - min_freq <= max_spread) }
      '; then
      phc_stable=1
      break
    fi
    latest_offset="$(printf '%s\n' "$stable_samples" | tail -n 1)"
  else
    offsets="$(awk '/sys offset/ {print $5}' "$stability_log" | tail -n 5)"
    if printf '%s\n' "$offsets" | awk '
      { value = $1 + 0; if (value < 0) value = -value; if (value > 250) bad = 1 }
      END { exit !(NR == 5 && !bad) }
    '; then
      phc_stable=1
      break
    fi
    latest_offset="$(printf '%s\n' "$offsets" | tail -n 1)"
  fi
  if [ $((second % 30)) -eq 0 ]; then
    echo "Waiting for E810 PHC stability (${second}/${PHC_STABILITY_TIMEOUT_SECONDS}s, latest offset ${latest_offset:-unavailable} ns)..."
  fi
  sleep 1
done
if [ "$phc_stable" -ne 1 ]; then
  echo "E810 PHC did not pass the selected stability gate within ${PHC_STABILITY_TIMEOUT_SECONDS} seconds:" >&2
  tail -n 20 "$stability_log" >&2
  false
fi

# Simulate a fully traceable class-6 GM for the RU lock-state test. These
# attributes are intentionally false for this host and are safe only because
# the link is isolated and the RU radio/cell are disabled.
gm_settings="$(pmc -u -b 0 -d "$PTP_DOMAIN" -s "$RUN_DIR/ptp4l" \
  'SET GRANDMASTER_SETTINGS_NP clockClass 6 clockAccuracy 0x22 offsetScaledLogVariance 0x4E5D currentUtcOffset 37 leap61 0 leap59 0 currentUtcOffsetValid 1 ptpTimescale 1 timeTraceable 1 frequencyTraceable 1 timeSource 0x20' 2>&1)"
if ! printf '%s\n' "$gm_settings" | grep -q 'GRANDMASTER_SETTINGS_NP'; then
  echo "Failed to apply simulated class-6 Grandmaster settings:" >&2
  printf '%s\n' "$gm_settings" >&2
  false
fi

echo "Temporary simulated class-6 PTP GM started on $FH_IF (G.8275.1, domain $PTP_DOMAIN)."
echo "WARNING: advertised class-6 quality is simulated; radio must remain disabled."
if [ "$ISOLATED_SERVO" -eq 1 ]; then
  echo "Isolated linreg mode paused systemd-timesyncd and passed ${PHC_STABLE_SAMPLE_COUNT} s2 samples before class-6 promotion."
  echo "Logs: $RUN_DIR/ptp4l.log and $ISOLATED_LOG"
else
  echo "E810 PHC passed the five-sample +/-250 ns stability gate before class-6 promotion."
  echo "Logs: $RUN_DIR/ptp4l.log and $RUN_DIR/phc2sys.log"
fi
echo "ptp4l is pinned to CPU $PTP_CPU and phc2sys to CPU $PHC2SYS_CPU."
echo "RU management path: $RU_MGMT_ADDR -> $RU_IP"
trap - ERR INT TERM
