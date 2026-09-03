#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load-site-env.sh
source "$SCRIPT_DIR/load-site-env.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

STATE_DIR="${STATE_DIR:-/run/ocudu-ofh-performance}"
if [ ! -d "$STATE_DIR" ]; then
  echo "No saved OFH performance state in $STATE_DIR; nothing to restore."
  exit 0
fi

failures=0
warn_failure() {
  printf 'Warning: %s\n' "$*" >&2
  failures=$((failures + 1))
}

restore_path_values() {
  local state_file="$1" description="$2" path value
  [ -f "$state_file" ] || return 0
  while read -r path value; do
    [ -n "$path" ] || continue
    if [ -w "$path" ]; then
      printf '%s\n' "$value" > "$path" ||
        warn_failure "unable to restore $description at $path"
    else
      warn_failure "cannot write $description path $path"
    fi
  done < "$state_file"
}

restore_path_values "$STATE_DIR/governors.before" 'CPU governor'
restore_path_values "$STATE_DIR/epp.before" 'energy-performance preference'

preempt_path=/sys/kernel/debug/sched/preempt
if [ -s "$STATE_DIR/preempt.before" ]; then
  if [ -w "$preempt_path" ]; then
    cat "$STATE_DIR/preempt.before" > "$preempt_path" ||
      warn_failure 'unable to restore dynamic preemption mode'
  else
    warn_failure "cannot write preemption control $preempt_path"
  fi
fi

drm_poll=/sys/module/drm_kms_helper/parameters/poll
if [ -f "$STATE_DIR/drm-poll.before" ]; then
  if [ -w "$drm_poll" ]; then
    cat "$STATE_DIR/drm-poll.before" > "$drm_poll" ||
      warn_failure 'unable to restore DRM polling'
  else
    warn_failure "cannot write DRM polling control $drm_poll"
  fi
fi

if [ -f "$STATE_DIR/network.before" ]; then
  while read -r kind name value; do
    case "$kind" in
      sysctl)
        sysctl -q -w "$name=$value" || warn_failure "unable to restore $name=$value"
        ;;
      txqueuelen)
        ip link set dev "$name" txqueuelen "$value" ||
          warn_failure "unable to restore $name txqueuelen=$value"
        ;;
      txring)
        ethtool -G "$name" tx "$value" ||
          warn_failure "unable to restore $name TX ring=$value"
        ;;
      '') ;;
      *) warn_failure "unknown saved network setting: $kind $name $value" ;;
    esac
  done < "$STATE_DIR/network.before"
fi

if [ -f "$STATE_DIR/coalesce.before" ]; then
  read -r adaptive_rx rx_usecs < "$STATE_DIR/coalesce.before"
  # Some drivers reject changing adaptive RX and the fixed delay together.
  ethtool -C "$FH_IF" rx-usecs "$rx_usecs" ||
    warn_failure "unable to restore $FH_IF rx-usecs=$rx_usecs"
  ethtool -C "$FH_IF" adaptive-rx "$adaptive_rx" ||
    warn_failure "unable to restore $FH_IF adaptive-rx=$adaptive_rx"
fi

if [ -f "$STATE_DIR/irq-affinity.before" ]; then
  while read -r irq affinity; do
    path="/proc/irq/$irq/smp_affinity_list"
    if [ -w "$path" ]; then
      printf '%s\n' "$affinity" > "$path" ||
        warn_failure "unable to restore IRQ $irq affinity=$affinity"
    else
      warn_failure "IRQ $irq no longer exists or is not writable"
    fi
  done < "$STATE_DIR/irq-affinity.before"
fi

if [ -f "$STATE_DIR/irqbalance.before" ]; then
  if grep -qx active "$STATE_DIR/irqbalance.before"; then
    systemctl start irqbalance || warn_failure 'unable to restart irqbalance'
  elif systemctl is-active --quiet irqbalance; then
    systemctl stop irqbalance || warn_failure 'unable to restore irqbalance inactive state'
  fi
fi

if [ "$failures" -ne 0 ]; then
  printf 'OFH restore completed with %d warning(s); saved state was retained in %s for retry.\n' \
    "$failures" "$STATE_DIR" >&2
  exit 1
fi

# Remove only files owned by this helper; never recursively delete a caller-
# supplied state directory.
rm -f -- \
  "$STATE_DIR/governors.before" \
  "$STATE_DIR/epp.before" \
  "$STATE_DIR/preempt.before" \
  "$STATE_DIR/drm-poll.before" \
  "$STATE_DIR/network.before" \
  "$STATE_DIR/coalesce.before" \
  "$STATE_DIR/irq-affinity.before" \
  "$STATE_DIR/irqbalance.before"
rmdir -- "$STATE_DIR" 2>/dev/null || true

echo 'Restored saved CPU, EPP, preemption, DRM polling, irqbalance, IRQ, coalescing, socket-buffer and NIC-queue state.'
