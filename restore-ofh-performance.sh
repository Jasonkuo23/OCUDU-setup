#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/load-site-env.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

STATE_DIR="${STATE_DIR:-/run/ocudu-ofh-performance}"
if [ ! -f "$STATE_DIR/governors.before" ]; then
  echo "No saved OFH performance state in $STATE_DIR." >&2
  exit 1
fi

while read -r path value; do
  [ -w "$path" ] && printf '%s\n' "$value" > "$path"
done < "$STATE_DIR/governors.before"

preempt_path=/sys/kernel/debug/sched/preempt
if [ -s "$STATE_DIR/preempt.before" ] && [ -w "$preempt_path" ]; then
  cat "$STATE_DIR/preempt.before" > "$preempt_path"
fi

drm_poll=/sys/module/drm_kms_helper/parameters/poll
if [ -f "$STATE_DIR/drm-poll.before" ] && [ -w "$drm_poll" ]; then
  cat "$STATE_DIR/drm-poll.before" > "$drm_poll"
fi

if [ -f "$STATE_DIR/network.before" ]; then
  while read -r kind name value; do
    case "$kind" in
      sysctl) sysctl -q -w "$name=$value" ;;
      txqueuelen) ip link set dev "$name" txqueuelen "$value" ;;
      txring) ethtool -G "$name" tx "$value" ;;
    esac
  done < "$STATE_DIR/network.before"
fi

if [ -f "$STATE_DIR/coalesce.before" ]; then
  read -r adaptive_rx rx_usecs < "$STATE_DIR/coalesce.before"
  fh_if="$FH_IF"

  # Some NIC drivers can reject a netlink request that changes adaptive RX and the
  # fixed RX delay together.  Restore the delay first, then the adaptive mode.
  # A coalescing restore failure must not prevent IRQ affinity and irqbalance
  # from being restored below.
  if ! ethtool -C "$fh_if" rx-usecs "$rx_usecs"; then
    echo "Warning: unable to restore $fh_if rx-usecs=$rx_usecs; continuing." >&2
  fi
  if ! ethtool -C "$fh_if" adaptive-rx "$adaptive_rx"; then
    echo "Warning: unable to restore $fh_if adaptive-rx=$adaptive_rx; continuing." >&2
  fi
fi

if [ -f "$STATE_DIR/irq-affinity.before" ]; then
  while read -r irq affinity; do
    path="/proc/irq/$irq/smp_affinity_list"
    [ -w "$path" ] && printf '%s\n' "$affinity" > "$path"
  done < "$STATE_DIR/irq-affinity.before"
fi

if [ -f "$STATE_DIR/irqbalance.before" ] &&
   grep -qx active "$STATE_DIR/irqbalance.before"; then
  systemctl start irqbalance
fi

echo "Restored saved CPU, preemption, DRM polling, irqbalance, IRQ, coalescing, socket-buffer and NIC-queue state."
