#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=load-temp-gm-env.sh
source "$(cd "$(dirname "$0")" && pwd)/load-temp-gm-env.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

ISOLATED_MARKER="$RUN_DIR/isolated-servo.active"
RESTORE_TIMESYNCD=0

if [ -f "$ISOLATED_MARKER" ] &&
   grep -Eq '^timesyncd_was_active=1$' "$ISOLATED_MARKER"; then
  RESTORE_TIMESYNCD=1
fi

for name in phc2sys ptp4l; do
  pid_file="$RUN_DIR/$name.pid"
  if [ -f "$pid_file" ]; then
    pid="$(cat "$pid_file")"
    if [ -r "/proc/$pid/comm" ] && [ "$(cat "/proc/$pid/comm")" = "$name" ]; then
      kill "$pid"
      # Avoid a stop/start race while linuxptp releases its PHC/socket state.
      for _ in $(seq 1 50); do
        if ! kill -0 "$pid" 2>/dev/null; then
          break
        fi
        sleep 0.1
      done
      if kill -0 "$pid" 2>/dev/null; then
        echo "$name (pid $pid) did not stop; refusing to hide the live process." >&2
        exit 1
      fi
    fi
    rm -f "$pid_file"
  fi
done

if [ -f "$RUN_DIR/address-added-by-script" ]; then
  added_addr="$(cat "$RUN_DIR/address-added-by-script")"
  # Compatibility with marker files created by older script versions.
  if [ -z "$added_addr" ]; then
    added_addr="$RU_MGMT_ADDR"
  fi
  ip addr del "$added_addr" dev "$FH_IF" 2>/dev/null || true
  rm -f "$RUN_DIR/address-added-by-script"
fi

rm -f "$RUN_DIR/holdover.active" "$ISOLATED_MARKER"

if [ "$RESTORE_TIMESYNCD" -eq 1 ]; then
  systemctl start systemd-timesyncd
  if ! systemctl is-active --quiet systemd-timesyncd; then
    echo "Failed to restore systemd-timesyncd." >&2
    exit 1
  fi
  echo "Restored systemd-timesyncd after the isolated PTP test."
fi

echo "Temporary PTP GM stopped."
