#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load-site-env.sh
source "$SCRIPT_DIR/load-site-env.sh"

failures=0
fail() {
  printf '[FAIL] %s\n' "$*" >&2
  failures=$((failures + 1))
}

required=(
  COMPOSE_PROJECT_NAME OCUDU_IMAGE OCUDU_REF
  AMF_IP AMF_PORT UPF_IP
  N2_INTERFACE N2_LOCAL_CIDR N2_LOCAL_IP
  N3_INTERFACE N3_PARENT_INTERFACE N3_VLAN_ID N3_LOCAL_CIDR N3_LOCAL_IP
  PLMN TAC SST E1_CP_IP E1_UP_IP F1_CP_IP F1_DU_IP
  FH_IF RU_IP RU_MGMT_ADDR GM_IP RU_MAC DU_MAC VLAN_CP VLAN_UP OFH_MTU
  PTP_ROLE PTP_DOMAIN PTP_UDS HUGEPAGES DU_CPUSET MAIN_POOL_CPUS RU_CPUS
  OFH_TXRX_CPUS OFH_TIMING_CPU OFH_IRQ_CPU OFH_MISC_IRQ_CPU OFH_QUEUES
  RF_ARFCN RF_BAND RF_BANDWIDTH_MHZ RU_BANDWIDTH_MHZ RF_SCS
  RF_DL_ANTENNAS RF_UL_ANTENNAS RF_PCI PRACH_PORT_IDS DL_PORT_IDS
  UL_PORT_IDS COMPRESSION_METHOD COMPRESSION_BITWIDTH
  T1A_MAX_CP_DL T1A_MIN_CP_DL T1A_MAX_CP_UL T1A_MIN_CP_UL
  T1A_MAX_UP T1A_MIN_UP TA4_MAX TA4_MIN
)
for name in "${required[@]}"; do
  if [ -z "${!name:-}" ]; then
    fail "missing required value in config/site.env: $name"
  fi
done

# Avoid secondary errors while reporting all missing values in one pass.
if [ "$failures" -ne 0 ]; then
  exit 1
fi

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
uint_range() {
  local name="$1" minimum="$2" maximum="$3" value="${!1}"
  if ! is_uint "$value" || [ "$value" -lt "$minimum" ] || [ "$value" -gt "$maximum" ]; then
    fail "$name must be an integer from $minimum through $maximum (got: $value)"
  fi
}

is_ipv4() {
  local value="$1" octet
  local -a octets
  IFS=. read -r -a octets <<< "$value"
  [ "${#octets[@]}" -eq 4 ] || return 1
  for octet in "${octets[@]}"; do
    is_uint "$octet" || return 1
    [ "$((10#$octet))" -le 255 ] || return 1
  done
}

is_cidr() {
  local value="$1" ip prefix
  ip="${value%/*}"
  prefix="${value##*/}"
  [ "$ip" != "$value" ] && is_ipv4 "$ip" && is_uint "$prefix" &&
    [ "$prefix" -ge 1 ] && [ "$prefix" -le 32 ]
}

ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  printf '%u\n' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

cidr_contains() {
  local cidr="$1" candidate="$2" base prefix mask
  is_cidr "$cidr" && is_ipv4 "$candidate" || return 1
  base="$(ipv4_to_int "${cidr%/*}")"
  prefix="${cidr##*/}"
  if [ "$prefix" -eq 0 ]; then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  fi
  [ "$((base & mask))" -eq "$(( $(ipv4_to_int "$candidate") & mask ))" ]
}

for name in AMF_IP UPF_IP N2_LOCAL_IP N3_LOCAL_IP E1_CP_IP E1_UP_IP \
  F1_CP_IP F1_DU_IP RU_IP GM_IP; do
  is_ipv4 "${!name}" || fail "$name is not a valid IPv4 address: ${!name}"
done
for name in N2_LOCAL_CIDR N3_LOCAL_CIDR RU_MGMT_ADDR; do
  is_cidr "${!name}" || fail "$name is not a valid IPv4 CIDR: ${!name}"
done

[ "${N2_LOCAL_CIDR%/*}" = "$N2_LOCAL_IP" ] ||
  fail 'N2_LOCAL_CIDR address must equal N2_LOCAL_IP'
[ "${N3_LOCAL_CIDR%/*}" = "$N3_LOCAL_IP" ] ||
  fail 'N3_LOCAL_CIDR address must equal N3_LOCAL_IP'
[ "$N3_INTERFACE" != "$N3_PARENT_INTERFACE" ] ||
  fail 'N3_INTERFACE must differ from N3_PARENT_INTERFACE'
if [ "$FH_IF" = "$N2_INTERFACE" ] || [ "$FH_IF" = "$N3_INTERFACE" ] ||
   [ "$FH_IF" = "$N3_PARENT_INTERFACE" ]; then
  fail 'FH_IF must be dedicated and must not carry N2 or N3'
fi
ru_mgmt_ip="${RU_MGMT_ADDR%/*}"
if [ "$ru_mgmt_ip" = "$RU_IP" ] || [ "$ru_mgmt_ip" = "$GM_IP" ]; then
  fail 'RU_MGMT_ADDR must differ from RU_IP and GM_IP'
fi
cidr_contains "$RU_MGMT_ADDR" "$RU_IP" ||
  fail 'RU_IP must be in the RU_MGMT_ADDR subnet'
cidr_contains "$RU_MGMT_ADDR" "$GM_IP" ||
  fail 'GM_IP must be in the RU_MGMT_ADDR subnet for the supported direct L2 timing path'
cidr_contains "$N3_LOCAL_CIDR" "$UPF_IP" ||
  fail 'UPF_IP must be in the N3_LOCAL_CIDR subnet for the direct N3 VLAN path'

endpoint_ips=(
  "$N2_LOCAL_IP" "$N3_LOCAL_IP" "$E1_CP_IP" "$E1_UP_IP"
  "$F1_CP_IP" "$F1_DU_IP" "$ru_mgmt_ip" "$RU_IP" "$GM_IP"
)
for ((i=0; i<${#endpoint_ips[@]}; i++)); do
  for ((j=i+1; j<${#endpoint_ips[@]}; j++)); do
    [ "${endpoint_ips[$i]}" != "${endpoint_ips[$j]}" ] ||
      fail "local/RU/GM endpoint addresses must be unique: ${endpoint_ips[$i]}"
  done
done

for name in N2_INTERFACE N3_INTERFACE N3_PARENT_INTERFACE FH_IF; do
  [[ "${!name}" =~ ^[[:alnum:]_.:-]+$ ]] || fail "$name is not a safe interface name: ${!name}"
done
[[ "$COMPOSE_PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] ||
  fail 'COMPOSE_PROJECT_NAME must use lowercase letters, digits, underscore or dash'
[[ "$OCUDU_IMAGE" =~ ^[[:alnum:]_.:/-]+$ ]] || fail "OCUDU_IMAGE is invalid: $OCUDU_IMAGE"
[[ "$OCUDU_REF" =~ ^[[:xdigit:]]{40}$ ]] ||
  fail 'OCUDU_REF must be a full 40-character commit SHA, not a mutable branch or tag'
[[ "$PTP_UDS" = /* ]] || fail 'PTP_UDS must be an absolute path'
[ "$PTP_ROLE" = external-gm ] || fail 'PTP_ROLE must be external-gm in the supported core flow'

case "$PLMN" in
  *[!0-9]*|'') fail 'PLMN must contain digits only' ;;
esac
if [ "${#PLMN}" -ne 5 ] && [ "${#PLMN}" -ne 6 ]; then
  fail 'PLMN must contain five or six digits'
fi

uint_range AMF_PORT 1 65535
uint_range N3_VLAN_ID 1 4094
uint_range TAC 0 16777215
uint_range SST 0 255
uint_range VLAN_CP 1 4094
uint_range VLAN_UP 1 4094
uint_range OFH_MTU 1280 9600
uint_range PTP_DOMAIN 0 255
uint_range HUGEPAGES 1 1048576
uint_range RF_ARFCN 0 3279165
uint_range RF_BAND 1 1024
uint_range RF_BANDWIDTH_MHZ 1 400
uint_range RU_BANDWIDTH_MHZ 1 400
uint_range RF_SCS 15 240
uint_range RF_DL_ANTENNAS 1 64
uint_range RF_UL_ANTENNAS 1 64
uint_range RF_PCI 0 1007
uint_range COMPRESSION_BITWIDTH 1 32
for name in T1A_MAX_CP_DL T1A_MIN_CP_DL T1A_MAX_CP_UL T1A_MIN_CP_UL \
  T1A_MAX_UP T1A_MIN_UP TA4_MAX TA4_MIN OFH_IRQ_CPU OFH_MISC_IRQ_CPU \
  OFH_TIMING_CPU; do
  uint_range "$name" 0 1000000
done

[ "$RF_BANDWIDTH_MHZ" = "$RU_BANDWIDTH_MHZ" ] ||
  fail 'RF_BANDWIDTH_MHZ and RU_BANDWIDTH_MHZ must match'
case "$RF_SCS" in
  15|30|60|120|240) ;;
  *) fail "RF_SCS is not a supported NR subcarrier spacing: $RF_SCS" ;;
esac
case "$COMPRESSION_METHOD" in
  bfp|none) ;;
  *) fail "unsupported COMPRESSION_METHOD: $COMPRESSION_METHOD" ;;
esac

for mac_name in RU_MAC DU_MAC; do
  mac="${!mac_name}"
  if [[ ! "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]; then
    fail "$mac_name is not a valid MAC address: $mac"
  elif [ $((16#${mac:0:2} & 1)) -ne 0 ]; then
    fail "$mac_name must be a unicast MAC address: $mac"
  fi
done
[ "${RU_MAC,,}" != "${DU_MAC,,}" ] || fail 'RU_MAC and DU_MAC must differ'

validate_cpuset() {
  local name="$1" value="${!1}" item first last
  local -a items
  [[ "$value" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] ||
    { fail "$name is not a valid Linux CPU list: $value"; return; }
  IFS=, read -r -a items <<< "$value"
  for item in "${items[@]}"; do
    [[ "$item" == *-* ]] || continue
    first="${item%-*}"
    last="${item#*-}"
    [ "$first" -le "$last" ] || fail "$name contains a descending CPU range: $item"
  done
}
for name in DU_CPUSET MAIN_POOL_CPUS RU_CPUS OFH_TXRX_CPUS; do
  validate_cpuset "$name"
done
[[ "$OFH_QUEUES" =~ ^[0-9]+([[:space:]]+[0-9]+)*$ ]] ||
  fail "OFH_QUEUES must be a space-separated integer list: $OFH_QUEUES"

validate_port_list() {
  local name="$1" expected_count="$2" compact item value
  local -a items
  value="${!name}"
  compact="${value//[[:space:]]/}"
  IFS=, read -r -a items <<< "$compact"
  [ "${#items[@]}" -eq "$expected_count" ] ||
    fail "$name must contain $expected_count eAxC IDs (got ${#items[@]})"
  for item in "${items[@]}"; do
    if ! is_uint "$item" || [ "$item" -gt 65535 ]; then
      fail "$name contains an invalid eAxC ID: $item"
    fi
  done
  [ "$(printf '%s\n' "${items[@]}" | sort -u | wc -l)" -eq "${#items[@]}" ] ||
    fail "$name contains duplicate eAxC IDs"
}
validate_port_list DL_PORT_IDS "$RF_DL_ANTENNAS"
validate_port_list UL_PORT_IDS "$RF_UL_ANTENNAS"
validate_port_list PRACH_PORT_IDS "$RF_UL_ANTENNAS"

for pair in \
  T1A_MIN_CP_DL:T1A_MAX_CP_DL \
  T1A_MIN_CP_UL:T1A_MAX_CP_UL \
  T1A_MIN_UP:T1A_MAX_UP \
  TA4_MIN:TA4_MAX; do
  minimum_name="${pair%:*}"
  maximum_name="${pair#*:}"
  [ "${!minimum_name}" -le "${!maximum_name}" ] ||
    fail "$minimum_name must not exceed $maximum_name"
done

if [ "$failures" -ne 0 ]; then
  printf '\nSite configuration validation failed: %d issue(s).\n' "$failures" >&2
  exit 1
fi

printf '[PASS] site configuration is internally consistent\n'
