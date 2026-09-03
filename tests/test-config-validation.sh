#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

new_site() {
  local name="$1"
  cp "$PROJECT_DIR/config/site.env.example" "$TEST_DIR/$name.env"
  sed -i 's/^RU_MGMT_ADDR=$/RU_MGMT_ADDR=192.168.2.174\/24/' "$TEST_DIR/$name.env"
}

expect_failure() {
  local description="$1" config="$2"
  if OCUDU_CONFIG_FILE="$config" "$PROJECT_DIR/validate-site-config.sh" >/dev/null 2>&1; then
    echo "Expected validation failure: $description" >&2
    exit 1
  fi
  printf '[PASS] rejected %s\n' "$description"
}

new_site valid
OCUDU_CONFIG_FILE="$TEST_DIR/valid.env" "$PROJECT_DIR/validate-site-config.sh"
OCUDU_CONFIG_FILE="$TEST_DIR/valid.env" "$PROJECT_DIR/render-config.sh"
grep -Fq 'du_mac_addr: 00:02:01:1a:73:d4' "$PROJECT_DIR/config/generated/du-ofh.yml"
grep -Fq 'addrs: 192.168.19.175' "$PROJECT_DIR/config/generated/cu-cp.yml"
grep -Fq 'bind_addrs: 192.168.22.155' "$PROJECT_DIR/config/generated/cu-cp.yml"
grep -Fq 'addrs: 127.0.10.1' "$PROJECT_DIR/config/generated/du-ofh.yml"
grep -Eq '^[[:space:]]+enabled:[[:space:]]+false([[:space:]]*)$' \
  "$PROJECT_DIR/config/generated/du-ofh.yml"
printf '[PASS] valid site renders a fail-closed DU configuration\n'

new_site missing_value
sed -i 's/^F1_DU_IP=.*/F1_DU_IP=/' "$TEST_DIR/missing_value.env"
expect_failure 'missing template value' "$TEST_DIR/missing_value.env"

new_site mutable_ref
sed -i 's/^OCUDU_REF=.*/OCUDU_REF=release_26_04/' "$TEST_DIR/mutable_ref.env"
expect_failure 'mutable OCUDU source reference' "$TEST_DIR/mutable_ref.env"

new_site mismatched_n3
sed -i 's|^N3_LOCAL_CIDR=.*|N3_LOCAL_CIDR=192.168.24.154/24|' "$TEST_DIR/mismatched_n3.env"
expect_failure 'mismatched N3 CIDR and IP' "$TEST_DIR/mismatched_n3.env"

new_site conflicting_ru_address
sed -i 's|^RU_MGMT_ADDR=.*|RU_MGMT_ADDR=192.168.2.100/24|' "$TEST_DIR/conflicting_ru_address.env"
expect_failure 'RU-management and GM address conflict' "$TEST_DIR/conflicting_ru_address.env"

new_site wrong_eaxc_count
sed -i 's/^DL_PORT_IDS=.*/DL_PORT_IDS="0, 1"/' "$TEST_DIR/wrong_eaxc_count.env"
expect_failure 'eAxC count inconsistent with antenna count' "$TEST_DIR/wrong_eaxc_count.env"

echo 'Configuration validation tests passed.'
