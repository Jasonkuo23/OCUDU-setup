#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load-site-env.sh
source "$SCRIPT_DIR/load-site-env.sh"

"$SCRIPT_DIR/validate-site-config.sh"

if ! command -v envsubst >/dev/null 2>&1; then
  echo 'envsubst is required. Run sudo ./setup.sh or install gettext-base.' >&2
  exit 1
fi

output_dir="$SCRIPT_DIR/config/generated"
install -d -m 0755 "$output_dir" "$SCRIPT_DIR/logs"
render_dir="$(mktemp -d "$SCRIPT_DIR/config/.generated.XXXXXX")"
trap 'rm -rf -- "$render_dir"' EXIT

# Restrict envsubst to variables intentionally used by OCUDU templates. This
# prevents unrelated shell variables from changing generated configuration.
# shellcheck disable=SC2016
template_variables='${AMF_IP} ${AMF_PORT} ${N2_LOCAL_IP} ${N3_LOCAL_IP} ${PLMN} ${TAC} ${SST} ${E1_CP_IP} ${E1_UP_IP} ${F1_CP_IP} ${F1_DU_IP} ${RU_BANDWIDTH_MHZ} ${T1A_MAX_CP_DL} ${T1A_MIN_CP_DL} ${T1A_MAX_CP_UL} ${T1A_MIN_CP_UL} ${T1A_MAX_UP} ${T1A_MIN_UP} ${TA4_MAX} ${TA4_MIN} ${COMPRESSION_METHOD} ${COMPRESSION_BITWIDTH} ${FH_IF} ${OFH_MTU} ${RU_MAC} ${DU_MAC} ${VLAN_CP} ${VLAN_UP} ${PRACH_PORT_IDS} ${DL_PORT_IDS} ${UL_PORT_IDS} ${RF_ARFCN} ${RF_BAND} ${RF_BANDWIDTH_MHZ} ${RF_SCS} ${RF_DL_ANTENNAS} ${RF_UL_ANTENNAS} ${RF_PCI} ${MAIN_POOL_CPUS} ${OFH_TIMING_CPU} ${OFH_TXRX_CPUS} ${RU_CPUS}'

for template in "$SCRIPT_DIR"/config/templates/*.in; do
  output="$render_dir/$(basename "${template%.in}")"
  envsubst "$template_variables" < "$template" > "$output"
  if grep -Eq '\$\{[A-Z][A-Z0-9_]*\}' "$output"; then
    echo "Unresolved variable remains in $output" >&2
    exit 1
  fi
done

if ! grep -Eq '^[[:space:]]+enabled:[[:space:]]+false([[:space:]]*)$' \
  "$render_dir/du-ofh.yml"; then
  echo 'Generated DU configuration is not fail-closed (cell_cfg.enabled=false).' >&2
  exit 1
fi
if ! grep -Fq "du_mac_addr: $DU_MAC" "$render_dir/du-ofh.yml"; then
  echo 'Generated DU MAC does not match config/site.env.' >&2
  exit 1
fi

# Publish only after every template and invariant has passed validation.
for rendered in "$render_dir"/*.yml; do
  install -m 0644 "$rendered" "$output_dir/$(basename "$rendered")"
done

echo "Generated OCUDU configuration in $output_dir"
