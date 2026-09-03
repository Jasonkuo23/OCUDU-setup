#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load-site-env.sh
source "$SCRIPT_DIR/load-site-env.sh"
failures=0

pass() { printf '[PASS] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; failures=$((failures + 1)); }

if ! "$SCRIPT_DIR/validate-site-config.sh"; then
  fail 'site configuration is invalid; host checks were not run'
  exit 1
fi
pass 'site configuration validation completed'

for command_name in docker ip ethtool ptp4l phc2sys pmc envsubst sysctl awk grep; do
  command -v "$command_name" >/dev/null 2>&1 && pass "$command_name is installed" || fail "$command_name is missing"
done
docker compose version >/dev/null 2>&1 && pass 'Docker Compose plugin is available' || fail 'Docker Compose plugin is unavailable'

ip link show "$FH_IF" >/dev/null 2>&1 && pass "fronthaul interface exists: $FH_IF" || fail "fronthaul interface is missing: $FH_IF"
if ip link show "$FH_IF" >/dev/null 2>&1; then
  ethtool -T "$FH_IF" 2>/dev/null | grep -q 'hardware-raw-clock' && pass "$FH_IF exposes a PHC" || fail "$FH_IF has no hardware raw clock"
fi
address_on_interface() {
  local interface="$1" cidr="$2"
  ip -4 -o addr show dev "$interface" 2>/dev/null |
    awk -v expected="$cidr" '$4 == expected {found=1} END {exit !found}'
}

if address_on_interface "$N2_INTERFACE" "$N2_LOCAL_CIDR"; then
  pass "N2 address is on $N2_INTERFACE: $N2_LOCAL_CIDR"
else
  fail "N2 address is not on $N2_INTERFACE: $N2_LOCAL_CIDR"
fi
if address_on_interface "$N3_INTERFACE" "$N3_LOCAL_CIDR"; then
  pass "N3 address is on $N3_INTERFACE: $N3_LOCAL_CIDR"
else
  fail "N3 address is not on $N3_INTERFACE: $N3_LOCAL_CIDR"
fi
if address_on_interface "$FH_IF" "$RU_MGMT_ADDR"; then
  pass "RU-management address is on $FH_IF: $RU_MGMT_ADDR"
else
  fail "RU-management address is not on $FH_IF: $RU_MGMT_ADDR"
fi

if [ -e "/sys/class/net/$N3_INTERFACE/lower_$N3_PARENT_INTERFACE" ] &&
   ip -d link show dev "$N3_INTERFACE" 2>/dev/null |
     grep -Eq "vlan protocol 802\.1Q id $N3_VLAN_ID([[:space:]]|$)"; then
  pass "$N3_INTERFACE is VLAN $N3_VLAN_ID on $N3_PARENT_INTERFACE"
else
  fail "$N3_INTERFACE is not VLAN $N3_VLAN_ID on $N3_PARENT_INTERFACE"
fi

route_matches() {
  local destination="$1" source="$2" interface="$3" route
  route="$(ip route get "$destination" from "$source" 2>/dev/null || true)"
  printf '%s\n' "$route" | grep -Eq "(^|[[:space:]])dev $interface([[:space:]]|$)" &&
    printf '%s\n' "$route" | grep -Eq "(^|[[:space:]])src $source([[:space:]]|$)"
}
route_matches "$AMF_IP" "$N2_LOCAL_IP" "$N2_INTERFACE" &&
  pass "AMF route uses $N2_INTERFACE with source $N2_LOCAL_IP" ||
  fail "AMF route does not use $N2_INTERFACE with source $N2_LOCAL_IP"
route_matches "$UPF_IP" "$N3_LOCAL_IP" "$N3_INTERFACE" &&
  pass "UPF route uses $N3_INTERFACE with source $N3_LOCAL_IP" ||
  fail "UPF route does not use $N3_INTERFACE with source $N3_LOCAL_IP"

expand_cpuset() {
  local list="$1" item first last cpu
  local -a items
  IFS=, read -r -a items <<< "$list"
  for item in "${items[@]}"; do
    if [[ "$item" == *-* ]]; then
      first="${item%-*}"
      last="${item#*-}"
      for ((cpu=first; cpu<=last; cpu++)); do printf '%s\n' "$cpu"; done
    else
      printf '%s\n' "$item"
    fi
  done
}

du_cpu_list="$(expand_cpuset "$DU_CPUSET" | sort -nu)"
all_cpu_lists="$DU_CPUSET,$MAIN_POOL_CPUS,$RU_CPUS,$OFH_TXRX_CPUS,$OFH_TIMING_CPU,$OFH_IRQ_CPU,$OFH_MISC_IRQ_CPU"
cpu_failure=0
while read -r cpu_value; do
  [ -n "$cpu_value" ] || continue
  if [ ! -d "/sys/devices/system/cpu/cpu$cpu_value" ]; then
    fail "configured CPU does not exist or is offline: $cpu_value"
    cpu_failure=1
  fi
done < <(expand_cpuset "$all_cpu_lists" | sort -nu)
[ "$cpu_failure" -ne 0 ] || pass 'all configured CPUs exist on this host'

for worker_spec in "$MAIN_POOL_CPUS" "$RU_CPUS" "$OFH_TXRX_CPUS" "$OFH_TIMING_CPU"; do
  while read -r cpu_value; do
    if ! printf '%s\n' "$du_cpu_list" | grep -qx "$cpu_value"; then
      fail "DU worker CPU $cpu_value is outside DU_CPUSET=$DU_CPUSET"
    fi
  done < <(expand_cpuset "$worker_spec")
done
for reserved_cpu in "$OFH_IRQ_CPU" "$OFH_MISC_IRQ_CPU"; do
  if printf '%s\n' "$du_cpu_list" | grep -qx "$reserved_cpu"; then
    fail "IRQ CPU $reserved_cpu overlaps DU_CPUSET=$DU_CPUSET"
  fi
done
[ "$OFH_IRQ_CPU" != "$OFH_MISC_IRQ_CPU" ] || fail 'OFH_IRQ_CPU and OFH_MISC_IRQ_CPU must differ'

for generated in cu-cp.yml cu-up.yml du-ofh.yml; do
  [ -s "$SCRIPT_DIR/config/generated/$generated" ] && pass "generated/$generated exists" || fail "generated/$generated is missing; run ./cudu.sh render"
done

du_cfg="$SCRIPT_DIR/config/generated/du-ofh.yml"
if [ -s "$du_cfg" ]; then
  grep -Fq "du_mac_addr: $DU_MAC" "$du_cfg" &&
    pass 'generated DU MAC matches site configuration' ||
    fail 'generated DU MAC does not match site configuration'
  grep -Eq '^[[:space:]]+enabled:[[:space:]]+false([[:space:]]*)$' "$du_cfg" &&
    pass 'generated DU cell is fail-closed' ||
    fail 'generated DU cell is not enabled=false'
fi

if docker compose --env-file "$OCUDU_CONFIG_FILE" --profile ofh config -q >/dev/null 2>&1; then
  pass 'Compose configuration is valid'
else
  fail 'Compose configuration is invalid'
fi

if [ "$(cat /sys/kernel/realtime 2>/dev/null || printf '0')" = 1 ] ||
   uname -a | grep -Eqi 'PREEMPT_RT|realtime'; then
  pass 'PREEMPT_RT kernel is active'
else
  warn 'PREEMPT_RT is not active; CU validation can continue, but OFH pre-rf will be blocked'
fi

if [ "$failures" -ne 0 ]; then
  printf '\nEnvironment check failed: %d issue(s).\n' "$failures"
  exit 1
fi
printf '\nPortable deployment prerequisites passed. RF/PTP lock is checked separately.\n'
