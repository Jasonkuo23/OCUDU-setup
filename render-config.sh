#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load-site-env.sh
source "$SCRIPT_DIR/load-site-env.sh"

if ! command -v envsubst >/dev/null 2>&1; then
  echo 'envsubst is required. Run sudo ./setup.sh or install gettext-base.' >&2
  exit 1
fi

required=(
  OCUDU_IMAGE AMF_IP AMF_PORT N2_LOCAL_IP N3_LOCAL_IP PLMN TAC SST
  FH_IF RU_IP RU_MGMT_ADDR GM_IP RU_MAC DU_MAC VLAN_CP VLAN_UP OFH_MTU
  RF_ARFCN RF_BAND RF_BANDWIDTH_MHZ RU_BANDWIDTH_MHZ RF_SCS
  RF_DL_ANTENNAS RF_UL_ANTENNAS RF_PCI MAIN_POOL_CPUS RU_CPUS
  OFH_TXRX_CPUS OFH_TIMING_CPU
)
for name in "${required[@]}"; do
  if [ -z "${!name:-}" ]; then
    echo "Missing required value in config/site.env: $name" >&2
    exit 1
  fi
done

case "$PLMN" in
  ''|*[!0-9]*) echo 'PLMN must contain digits only.' >&2; exit 1 ;;
esac
if [ "${#PLMN}" -ne 5 ] && [ "${#PLMN}" -ne 6 ]; then
  echo 'PLMN must contain five or six digits.' >&2
  exit 1
fi
for mac_name in RU_MAC DU_MAC; do
  if [[ ! "${!mac_name}" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]; then
    echo "$mac_name is not a valid MAC address: ${!mac_name}" >&2
    exit 1
  fi
done

output_dir="$SCRIPT_DIR/config/generated"
install -d -m 0755 "$output_dir" "$SCRIPT_DIR/logs"
for template in "$SCRIPT_DIR"/config/templates/*.in; do
  output="$output_dir/$(basename "${template%.in}")"
  envsubst < "$template" > "$output"
  if grep -Eq '\$\{[A-Z][A-Z0-9_]*\}' "$output"; then
    echo "Unresolved variable remains in $output" >&2
    exit 1
  fi
done

echo "Generated OCUDU configuration in $output_dir"
