#!/usr/bin/env bash
set -u

source "$(cd "$(dirname "$0")" && pwd)/load-temp-gm-env.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

FAIL=0

capture="$(timeout 4 tcpdump -eni "$FH_IF" -c 8 -vv \
  'ether proto 0x88f7 and (ether[14] & 0x0f = 0x0b)' 2>&1 || true)"
printf '%s\n' "$capture"

check_pattern() {
  description="$1"
  pattern="$2"
  if printf '%s\n' "$capture" | grep -Eqi "$pattern"; then
    printf '[PASS] %s\n' "$description"
  else
    printf '[FAIL] %s\n' "$description"
    FAIL=$((FAIL + 1))
  fi
}

check_pattern 'forwardable PTP destination MAC' '01:1b:19:00:00:00'
check_pattern 'Announce message present' 'msg type[[:space:]]*:[[:space:]]*announce'
check_pattern 'current UTC offset valid flag present' 'utc-valid|utc.*valid|utc reasonable'
check_pattern 'PTP timescale flag present' 'timescale'
check_pattern 'time traceable flag present' 'time-traceable|time traceable|time tracable'
check_pattern 'frequency traceable flag present' 'frequency-traceable|frequency traceable|frequency tracable'
check_pattern 'Grandmaster clock class 6 on wire' 'gm clock class[[:space:]]*:[[:space:]]*6([^0-9]|$)'
check_pattern 'current UTC offset 37 on wire' 'origin cur utc[[:space:]]*:[[:space:]]*37([^0-9]|$)'

exit "$FAIL"
