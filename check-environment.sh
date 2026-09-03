#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load-site-env.sh
source "$SCRIPT_DIR/load-site-env.sh"
failures=0

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; failures=$((failures + 1)); }

for command_name in docker ip ethtool ptp4l phc2sys pmc envsubst; do
  command -v "$command_name" >/dev/null 2>&1 && pass "$command_name is installed" || fail "$command_name is missing"
done
docker compose version >/dev/null 2>&1 && pass 'Docker Compose plugin is available' || fail 'Docker Compose plugin is unavailable'

ip link show "$FH_IF" >/dev/null 2>&1 && pass "fronthaul interface exists: $FH_IF" || fail "fronthaul interface is missing: $FH_IF"
if ip link show "$FH_IF" >/dev/null 2>&1; then
  ethtool -T "$FH_IF" 2>/dev/null | grep -q 'hardware-raw-clock' && pass "$FH_IF exposes a PHC" || fail "$FH_IF has no hardware raw clock"
fi
ip -4 addr show 2>/dev/null | grep -Fq "${N2_LOCAL_IP}/" && pass "N2 address exists: $N2_LOCAL_IP" || fail "N2 address is missing: $N2_LOCAL_IP"
ip -4 addr show 2>/dev/null | grep -Fq "${N3_LOCAL_IP}/" && pass "N3 address exists: $N3_LOCAL_IP" || fail "N3 address is missing: $N3_LOCAL_IP"

cpu_count="$(nproc)"
highest_cpu="$((cpu_count - 1))"
for cpu_value in "$OFH_IRQ_CPU" "$OFH_MISC_IRQ_CPU" "$OFH_TIMING_CPU"; do
  if [[ "$cpu_value" =~ ^[0-9]+$ ]] && [ "$cpu_value" -le "$highest_cpu" ]; then
    pass "CPU $cpu_value exists"
  else
    fail "configured CPU is invalid on this host: $cpu_value"
  fi
done

for generated in cu-cp.yml cu-up.yml du-ofh.yml; do
  [ -s "$SCRIPT_DIR/config/generated/$generated" ] && pass "generated/$generated exists" || fail "generated/$generated is missing; run ./cudu.sh render"
done

if [ "$failures" -ne 0 ]; then
  printf '\nEnvironment check failed: %d issue(s).\n' "$failures"
  exit 1
fi
printf '\nPortable deployment prerequisites passed. RF/PTP lock is checked separately.\n'
