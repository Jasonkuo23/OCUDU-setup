#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load-site-env.sh
source "$SCRIPT_DIR/load-site-env.sh"

"$SCRIPT_DIR/validate-site-config.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi
if ! ip link show "$FH_IF" >/dev/null 2>&1; then
  echo "Configured fronthaul interface does not exist: $FH_IF" >&2
  exit 1
fi

STATE_DIR="${STATE_DIR:-/run/ocudu-ofh-performance}"
# The E810 exposes 20 combined TxRx queues. Pin every queue so RSS cannot
# move fronthaul traffic onto CPUs reserved for PTP or real-time DU workers.
install -d -m 0700 "$STATE_DIR"

restore_on_error() {
  local rc="${1:-$?}"
  trap - ERR INT TERM
  echo 'Performance setup failed; restoring every saved host setting.' >&2
  STATE_DIR="$STATE_DIR" "$SCRIPT_DIR/restore-ofh-performance.sh" || true
  exit "$rc"
}
trap 'restore_on_error $?' ERR
trap 'restore_on_error 130' INT
trap 'restore_on_error 143' TERM

PTP_WAS_RUNNING=0
if pgrep -x ptp4l >/dev/null 2>&1 || pgrep -x phc2sys >/dev/null 2>&1; then
  PTP_WAS_RUNNING=1
fi

if [ ! -f "$STATE_DIR/governors.before" ]; then
  : > "$STATE_DIR/governors.before"
  for path in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    [ -r "$path" ] || continue
    printf '%s %s\n' "$path" "$(cat "$path")" >> "$STATE_DIR/governors.before"
  done
fi

while read -r path _; do
  printf '%s\n' performance > "$path"
done < "$STATE_DIR/governors.before"

# A PREEMPT_RT kernel already provides the required preemption model and may
# not expose the PREEMPT_DYNAMIC debug control. On a generic kernel, retain the
# original bounded-test behaviour and select full dynamic preemption.
preempt_path=/sys/kernel/debug/sched/preempt
preempt_mode=dynamic
if [ "$(cat /sys/kernel/realtime 2>/dev/null || printf '0')" = 1 ] ||
   uname -a | grep -Eqi 'PREEMPT_RT|realtime'; then
  preempt_mode=realtime
elif [ -r "$preempt_path" ] && [ -w "$preempt_path" ]; then
  if [ ! -f "$STATE_DIR/preempt.before" ]; then
    sed -n 's/.*(\([^)]*\)).*/\1/p' "$preempt_path" > "$STATE_DIR/preempt.before"
  fi
  printf '%s\n' full > "$preempt_path"
else
  echo "Dynamic preemption control is unavailable at $preempt_path." >&2
  exit 1
fi

if [ ! -f "$STATE_DIR/epp.before" ]; then
  : > "$STATE_DIR/epp.before"
  for path in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/energy_performance_preference; do
    [ -r "$path" ] || continue
    printf '%s %s\n' "$path" "$(cat "$path")" >> "$STATE_DIR/epp.before"
  done
fi

while read -r path _; do
  [ -w "$path" ] && printf '%s\n' performance > "$path"
done < "$STATE_DIR/epp.before"

drm_poll=/sys/module/drm_kms_helper/parameters/poll
if [ -r "$drm_poll" ] && [ ! -f "$STATE_DIR/drm-poll.before" ]; then
  cat "$drm_poll" > "$STATE_DIR/drm-poll.before"
fi
if [ -w "$drm_poll" ]; then
  printf '%s\n' N > "$drm_poll"
fi

# irqbalance spreads the high-rate E810 queues over E-cores and CPUs used by
# the DU worker pool. Stop it for this reversible real-time test before
# assigning the active fronthaul queues to reserved P-core CPUs.
if [ ! -f "$STATE_DIR/irqbalance.before" ]; then
  if systemctl is-active --quiet irqbalance; then
    printf '%s\n' active > "$STATE_DIR/irqbalance.before"
  else
    printf '%s\n' inactive > "$STATE_DIR/irqbalance.before"
  fi
fi
if systemctl is-active --quiet irqbalance; then
  systemctl stop irqbalance
fi

irq_state="$STATE_DIR/irq-affinity.before"
touch "$irq_state"

find_queue_irq() {
  local queue="$1"
  local driver
  driver="$(ethtool -i "$FH_IF" 2>/dev/null | awk '/^driver:/ {print $2; exit}')"
  awk -v name="$driver-$FH_IF-TxRx-$queue" '$0 ~ name {gsub(":", "", $1); print $1; exit}' /proc/interrupts
}

pin_queue_irq() {
  local queue="$1" cpu="$2" irq old_affinity
  irq="$(find_queue_irq "$queue")"
  if [ -z "$irq" ] || [ ! -w "/proc/irq/$irq/smp_affinity_list" ]; then
    echo "Unable to find or configure IRQ for $FH_IF queue $queue." >&2
    exit 1
  fi
  old_affinity="$(cat "/proc/irq/$irq/smp_affinity_list")"
  if ! awk -v target="$irq" '$1 == target {found=1} END {exit !found}' "$irq_state"; then
    printf '%s %s\n' "$irq" "$old_affinity" >> "$irq_state"
  fi
  printf '%s\n' "$cpu" > "/proc/irq/$irq/smp_affinity_list"
  printf 'Pinned %s queue %s IRQ %s to CPU %s.\n' "$FH_IF" "$queue" "$irq" "$cpu"
}

for queue in $OFH_QUEUES; do
  pin_queue_irq "$queue" "$OFH_IRQ_CPU"
done

# With PREEMPT_RT, the ice misc IRQ is threaded and carries PTP TX timestamp
# completions. irqbalance previously placed it on CPU 11, which is inside the
# DU main-worker cpuset. Starting the DU then starved the completion long
# enough for ptp4l to transition MASTER -> FAULTY. Keep it on a physical core
# outside the DU cpuset and save its previous affinity for restoration.
pin_misc_irq() {
  local cpu="$1" driver bus irq old_affinity
  driver="$(ethtool -i "$FH_IF" 2>/dev/null | awk '/^driver:/ {print $2; exit}')"
  bus="$(ethtool -i "$FH_IF" 2>/dev/null | awk '/^bus-info:/ {print $2; exit}')"
  irq="$(awk -v name="$driver-$bus:misc" '$0 ~ name {gsub(":", "", $1); print $1; exit}' /proc/interrupts)"
  if [ -z "$irq" ] || [ ! -w "/proc/irq/$irq/smp_affinity_list" ]; then
    echo "Unable to find or configure the misc/PTP IRQ for $FH_IF." >&2
    exit 1
  fi
  old_affinity="$(cat "/proc/irq/$irq/smp_affinity_list")"
  if ! awk -v target="$irq" '$1 == target {found=1} END {exit !found}' "$irq_state"; then
    printf '%s %s\n' "$irq" "$old_affinity" >> "$irq_state"
  fi
  printf '%s\n' "$cpu" > "/proc/irq/$irq/smp_affinity_list"
  printf 'Pinned %s misc/PTP IRQ %s to CPU %s.\n' "$FH_IF" "$irq" "$cpu"
}

pin_misc_irq "$OFH_MISC_IRQ_CPU"

# Interrupt moderation of 50 us is material compared with the remaining
# PRACH receive-window margin. Save and disable RX adaptive coalescing for the
# duration of the test.
coalesce_state="$STATE_DIR/coalesce.before"
if [ ! -f "$coalesce_state" ]; then
  adaptive_rx="$(ethtool -c "$FH_IF" | awk '/Adaptive RX:/ {print $3; exit}')"
  rx_usecs="$(ethtool -c "$FH_IF" | awk '/^rx-usecs:/ {print $2; exit}')"
  if [ -n "$adaptive_rx" ] && [ -n "$rx_usecs" ]; then
    printf '%s %s\n' "$adaptive_rx" "$rx_usecs" > "$coalesce_state"
  fi
fi
if ! ethtool -C "$FH_IF" adaptive-rx off rx-usecs 0; then
  echo "Unable to disable RX interrupt coalescing on $FH_IF." >&2
  exit 1
fi

# The non-DPDK OFH backend uses a non-blocking AF_PACKET raw socket. Preserve
# the host values before enlarging the socket and NIC transmit queues used by
# the 90-MHz 4T4R burst traffic.
if [ ! -f "$STATE_DIR/network.before" ]; then
  : > "$STATE_DIR/network.before"
  for key in net.core.wmem_default net.core.wmem_max net.core.netdev_max_backlog; do
    if sysctl -n "$key" >/dev/null 2>&1; then
      printf 'sysctl %s %s\n' "$key" "$(sysctl -n "$key")" >> "$STATE_DIR/network.before"
    fi
  done
  if ip link show "$FH_IF" >/dev/null 2>&1; then
    printf 'txqueuelen %s %s\n' "$FH_IF" "$(cat "/sys/class/net/$FH_IF/tx_queue_len")" >> "$STATE_DIR/network.before"
  fi
  current_tx="$(ethtool -g "$FH_IF" 2>/dev/null | awk '/Current hardware settings:/{current=1; next} current && $1 == "TX:" {print $2; exit}')"
  if [ -n "$current_tx" ]; then
    printf 'txring %s %s\n' "$FH_IF" "$current_tx" >> "$STATE_DIR/network.before"
  fi
fi

# A SCHED_FIFO busy-loop otherwise reaches the default 950 ms RT quota and is
# forcibly throttled for about 50 ms every second. Save this separately for
# state directories created by older versions of this helper.
if ! grep -q '^sysctl kernel\.sched_rt_runtime_us ' "$STATE_DIR/network.before"; then
  printf 'sysctl kernel.sched_rt_runtime_us %s\n' \
    "$(sysctl -n kernel.sched_rt_runtime_us)" >> "$STATE_DIR/network.before"
fi

sysctl -q -w net.core.wmem_max=67108864
sysctl -q -w net.core.wmem_default=67108864
sysctl -q -w net.core.netdev_max_backlog=65536
sysctl -q -w kernel.sched_rt_runtime_us=-1
ip link set dev "$FH_IF" txqueuelen 10000

max_tx="$(ethtool -g "$FH_IF" 2>/dev/null | awk '/Pre-set maximums:/{maximum=1; next} /Current hardware settings:/{maximum=0} maximum && $1 == "TX:" {print $2; exit}')"
if [ -n "$max_tx" ] && [ "$max_tx" -gt 0 ]; then
  if ! ethtool -G "$FH_IF" tx "$max_tx"; then
    echo "Warning: $FH_IF driver refused TX ring $max_tx; continuing with its current ring." >&2
  fi
fi

not_performance=0
while read -r path _; do
  if [ "$(cat "$path")" != performance ]; then
    echo "Governor did not switch to performance: $path" >&2
    not_performance=$((not_performance + 1))
  fi
done < "$STATE_DIR/governors.before"
if [ "$not_performance" -ne 0 ]; then
  exit 1
fi

echo "All available CPU governors are set to performance."
if [ "$preempt_mode" = realtime ]; then
  echo "PREEMPT_RT kernel is active; dynamic preemption override is unnecessary."
else
  echo "Dynamic kernel preemption is set to full for this test."
fi
echo "DRM KMS polling is disabled when supported."
echo "OFH raw-socket buffers and $FH_IF transmit queues are enlarged."
echo "OFH E810 combined RX/TX IRQs are pinned to reserved CPU $OFH_IRQ_CPU."
echo "E810 misc/PTP IRQ is pinned to reserved CPU $OFH_MISC_IRQ_CPU."
echo "Adaptive RX interrupt coalescing is disabled on $FH_IF."
echo "RT bandwidth throttling is disabled for the dedicated OFH busy-wait test."
echo "Runtime state is saved in $STATE_DIR and is cleared by reboot."
if [ "$PTP_WAS_RUNNING" -eq 1 ]; then
  echo "WARNING: linuxptp was running while the NIC TX ring was adjusted." >&2
  echo "Restart host linuxptp and verify external-GM SLAVE lock before starting the DU." >&2
fi
trap - ERR INT TERM
