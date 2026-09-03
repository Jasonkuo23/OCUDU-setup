#!/usr/bin/env bash
set -u

source "$(cd "$(dirname "$0")" && pwd)/load-site-env.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if ! "$SCRIPT_DIR/validate-site-config.sh"; then
  exit 1
fi

TEST_LEVEL="${TEST_LEVEL:-smoke}"
CELL_MODE="${CELL_MODE:-disabled}"
DU_CONFIG_FILE="${DU_CONFIG_FILE:-config/generated/du-ofh.yml}"
OFH_MISC_IRQ_CPU="${OFH_MISC_IRQ_CPU:-12}"
FAIL=0

pass() { printf '[PASS] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }

if ip link show "$FH_IF" >/dev/null 2>&1; then
  pass "interface exists: $FH_IF"
else
  fail "interface missing: $FH_IF"
fi

if [ "$(cat "/sys/class/net/$FH_IF/carrier" 2>/dev/null || echo 0)" = 1 ]; then
  pass "$FH_IF has carrier"
else
  fail "$FH_IF has no carrier"
fi

speed="$(ethtool "$FH_IF" 2>/dev/null | awk -F': ' '/Speed:/ {print $2}')"
if [ "$speed" = '10000Mb/s' ]; then
  pass "$FH_IF negotiated 10 Gbps"
else
  fail "$FH_IF speed is ${speed:-unknown}; 10 Gbps required"
fi

if ethtool -T "$FH_IF" 2>/dev/null | grep -q 'hardware-raw-clock'; then
  pass "$FH_IF supports hardware timestamping"
else
  fail "$FH_IF hardware timestamping unavailable"
fi

if ip -4 addr show dev "$FH_IF" | grep -Fq "$RU_MGMT_ADDR"; then
  pass "$FH_IF has RU-management address $RU_MGMT_ADDR"
else
  fail "$FH_IF is missing $RU_MGMT_ADDR"
fi

if ping -I "$FH_IF" -c 1 -W 1 "$RU_IP" >/dev/null 2>&1; then
  pass "RU management reachable: $RU_IP"
else
  fail "RU management unreachable: $RU_IP"
fi

case "$PTP_ROLE" in
  external-gm)
    if ping -I "$FH_IF" -c 1 -W 1 "$GM_IP" >/dev/null 2>&1; then
      pass "configured GM IP reachable: $GM_IP"
    else
      warn "GM IP $GM_IP did not answer ICMP; L2 PTP may still work"
    fi
    if [ -S "$PTP_UDS" ]; then
      pass "ptp4l management socket exists: $PTP_UDS"
    else
      fail "ptp4l management socket is missing: $PTP_UDS"
    fi
    if pmc -u -b 0 -d "$PTP_DOMAIN" -s "$PTP_UDS" 'GET PORT_DATA_SET' 2>/dev/null |
       grep -Eq 'portState[[:space:]]+SLAVE'; then
      pass 'ptp4l reports SLAVE state'
    else
      fail 'ptp4l does not report SLAVE state'
    fi
    ;;
  *)
    fail "unsupported core PTP_ROLE=$PTP_ROLE (external-gm required)"
    ;;
esac

hp="$(awk '/HugePages_Total:/ {print $2}' /proc/meminfo)"
if [ "${hp:-0}" -ge "$MIN_HUGEPAGES" ]; then
  pass "2 MiB hugepages available: $hp"
else
  fail "hugepages=${hp:-0}; expected at least $MIN_HUGEPAGES"
fi

if [ "$(cat /sys/kernel/realtime 2>/dev/null || printf '0')" = 1 ] ||
   uname -a | grep -Eqi 'PREEMPT_RT|realtime'; then
  pass 'realtime/PREEMPT_RT kernel active'
elif [ "$TEST_LEVEL" = smoke ]; then
  warn 'generic kernel active; permitted only for the RF-disabled smoke diagnostic'
else
  fail 'generic kernel active; PREEMPT_RT is required for the 90-MHz/4T4R pre-rf flow'
fi

case "$DU_CONFIG_FILE" in
  config/generated/du-ofh.yml)
    cfg="$(dirname "$0")/$DU_CONFIG_FILE"
    ;;
  *)
    fail "invalid DU_CONFIG_FILE=$DU_CONFIG_FILE; use a generated DU profile"
    cfg="$(dirname "$0")/__invalid_du_config__"
    ;;
esac
if [ -r "$cfg" ]; then
  pass "selected DU configuration: $DU_CONFIG_FILE"
else
  fail "selected DU configuration is not readable: $DU_CONFIG_FILE"
fi
case "$CELL_MODE" in
  disabled)
    if [ -f "$cfg" ] && grep -Eq '^[[:space:]]+enabled:[[:space:]]+false' "$cfg"; then
      pass 'DU cell remains RF-disabled'
    else
      fail 'cannot confirm cell_cfg.enabled=false'
    fi
    ;;
  active)
    if [ -f "$cfg" ] && grep -Eq '^[[:space:]]+enabled:[[:space:]]+false' "$cfg"; then
      pass 'safe base config remains disabled; explicit CLI override is required'
    else
      fail 'safe base config is not cell_cfg.enabled=false'
    fi
    ;;
  *)
    fail "unsupported CELL_MODE=$CELL_MODE (use disabled or active)"
    ;;
esac

if [ -f "$cfg" ] && grep -Fq "du_mac_addr: $EXPECTED_DU_MAC" "$cfg"; then
  pass "generated DU MAC matches configured value: $EXPECTED_DU_MAC"
else
  fail "generated DU MAC does not match configured value: $EXPECTED_DU_MAC"
fi

if awk -v expected="\"$OFH_TIMING_CPU\"" '
    $1 == "timing_cpu:" && $2 == expected { timing = 1 }
    $1 == "enable_busy_waiting:" && $2 == "true" { busy = 1 }
    END { exit !(timing && busy) }
  ' "$cfg"; then
  pass "OFH timing worker is pinned to configured CPU $OFH_TIMING_CPU with busy waiting"
else
  fail 'OFH timing affinity/busy-wait settings are missing'
fi

if [ "$(sysctl -n kernel.sched_rt_runtime_us 2>/dev/null)" = -1 ]; then
  pass 'RT bandwidth throttling is disabled for the dedicated timing CPU test'
else
  fail 'kernel.sched_rt_runtime_us must be -1 while OFH busy waiting is enabled; rerun setup-ofh-performance.sh'
fi

if [ "$TEST_LEVEL" = pre-rf ]; then
  if [ "$(cat /sys/kernel/realtime 2>/dev/null || printf '0')" = 1 ] ||
     uname -a | grep -Eqi 'PREEMPT_RT|realtime'; then
    pass 'PREEMPT_RT kernel is active'
  else
    preempt_state="$(cat /sys/kernel/debug/sched/preempt 2>/dev/null || true)"
    if printf '%s\n' "$preempt_state" | grep -Fq '(full)'; then
    pass 'dynamic kernel preemption is set to full'
    else
      fail 'dynamic kernel preemption is not full; rerun setup-ofh-performance.sh'
    fi
  fi

  if systemctl is-active --quiet irqbalance; then
    fail 'irqbalance is active and can move reserved OFH NIC IRQs; rerun setup-ofh-performance.sh'
  else
    pass 'irqbalance is stopped for the dedicated OFH test'
  fi

  irq_cpu_matches() {
    local queue="$1" expected_cpu="$2" irq
    local driver
    driver="$(ethtool -i "$FH_IF" 2>/dev/null | awk '/^driver:/ {print $2; exit}')"
    irq="$(awk -v name="$driver-$FH_IF-TxRx-$queue" '$0 ~ name {gsub(":", "", $1); print $1; exit}' /proc/interrupts)"
    [ -n "$irq" ] &&
      [ "$(cat "/proc/irq/$irq/effective_affinity_list" 2>/dev/null)" = "$expected_cpu" ]
  }

  irq_fail=0
  for queue in $OFH_QUEUES; do
    if ! irq_cpu_matches "$queue" "$OFH_IRQ_CPU"; then
      fail "$FH_IF combined queue $queue IRQ is not pinned to CPU $OFH_IRQ_CPU"
      irq_fail=1
    fi
  done
  if [ "$irq_fail" -eq 0 ]; then
    pass "$FH_IF configured combined queue IRQs are pinned to reserved CPU $OFH_IRQ_CPU"
  fi

  driver="$(ethtool -i "$FH_IF" 2>/dev/null | awk '/^driver:/ {print $2; exit}')"
  bus="$(ethtool -i "$FH_IF" 2>/dev/null | awk '/^bus-info:/ {print $2; exit}')"
  misc_irq="$(awk -v name="$driver-$bus:misc" '$0 ~ name {gsub(":", "", $1); print $1; exit}' /proc/interrupts)"
  if [ -n "$misc_irq" ] &&
     [ "$(cat "/proc/irq/$misc_irq/effective_affinity_list" 2>/dev/null)" = "$OFH_MISC_IRQ_CPU" ]; then
    pass "$FH_IF misc/PTP IRQ is pinned to reserved CPU $OFH_MISC_IRQ_CPU"
  else
    fail "$FH_IF misc/PTP IRQ is not pinned to CPU $OFH_MISC_IRQ_CPU; rerun setup-ofh-performance.sh"
  fi

  adaptive_rx="$(ethtool -c "$FH_IF" 2>/dev/null | awk '/Adaptive RX:/ {print $3; exit}')"
  rx_usecs="$(ethtool -c "$FH_IF" 2>/dev/null | awk '/^rx-usecs:/ {print $2; exit}')"
  if [ "$adaptive_rx" = off ] && [ "$rx_usecs" = 0 ]; then
    pass "$FH_IF adaptive RX coalescing is off and rx-usecs is 0"
  else
    fail "$FH_IF RX coalescing is adaptive=${adaptive_rx:-unknown}, rx-usecs=${rx_usecs:-unknown}; rerun setup-ofh-performance.sh"
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  printf '\nOFH gates failed: %d\n' "$FAIL"
  exit 1
fi

printf '\nAll RF-disabled OFH gates passed.\n'
