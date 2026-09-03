#!/usr/bin/env bash
set -euo pipefail

TEMP_GM_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load-temp-gm-env.sh
source "$TEMP_GM_DIR/load-temp-gm-env.sh"

if [ "$PTP_ROLE" != temp-gm ]; then
  echo 'Refusing to render: optional temp-gm.env must explicitly set PTP_ROLE=temp-gm.' >&2
  exit 1
fi

install -d -m 0755 "$TEMP_GM_DIR/generated"
envsubst < "$TEMP_GM_DIR/temp-gm-class6.cfg.in" > "$PTP_CONFIG"
echo "Generated optional profile: $PTP_CONFIG"
