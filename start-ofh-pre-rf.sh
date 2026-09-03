#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./load-site-env.sh

DU_CONFIG_FILE="${DU_CONFIG_FILE:-config/generated/du-ofh.yml}"
case "$DU_CONFIG_FILE" in
  config/generated/du-ofh.yml) ;;
  *)
    echo "Refusing invalid DU_CONFIG_FILE=$DU_CONFIG_FILE; use a generated DU profile." >&2
    exit 1
    ;;
esac
if [ ! -r "$DU_CONFIG_FILE" ]; then
  echo "Refusing to start: $DU_CONFIG_FILE is not readable." >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo and the required confirmations; see README.md." >&2
  exit 1
fi

for name in RF_ENVIRONMENT_CONFIRMED RU_RADIO_DISABLED_CONFIRMED; do
  if [ "${!name:-0}" != 1 ]; then
    echo "Refusing to start: $name=1 was not provided." >&2
    exit 1
  fi
done

if [ "${RU_PTP_LOCK_CONFIRMED:-0}" != 1 ]; then
  echo 'Refusing to start: provide RU_PTP_LOCK_CONFIRMED=1 after verifying real PTP lock.' >&2
  exit 1
fi

if find /sys/devices/system/cpu/cpu[0-9]*/cpufreq -name scaling_governor \
     -exec grep -Lx performance {} + | grep -q .; then
  echo 'Refusing to start: run sudo ./setup-ofh-performance.sh first.' >&2
  exit 1
fi

DU_CONFIG_FILE="$DU_CONFIG_FILE" CELL_MODE=active TEST_LEVEL=pre-rf ./check-cudu-ofh-gates.sh

echo "Starting a non-restarting active-cell DU with $DU_CONFIG_FILE while the RU PA remains disabled."
DU_CONFIG_FILE="$DU_CONFIG_FILE" DU_CELL_ENABLED=true docker compose --env-file "$OCUDU_CONFIG_FILE" --profile ofh up -d --force-recreate du
docker compose --env-file "$OCUDU_CONFIG_FILE" --profile ofh ps du
echo 'Verify F1/eCPRI and RU PA-off state, then stop with:'
echo '  sudo docker compose --profile ofh stop du'
