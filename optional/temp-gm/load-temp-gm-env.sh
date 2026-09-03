#!/usr/bin/env bash
# shellcheck shell=bash

TEMP_GM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$TEMP_GM_DIR/../.." && pwd)"

# Load the site's NIC, RU and PTP-domain values first.
# shellcheck source=../../load-site-env.sh
source "$PROJECT_DIR/load-site-env.sh"

TEMP_GM_CONFIG_FILE="${TEMP_GM_CONFIG_FILE:-$TEMP_GM_DIR/temp-gm.env}"
if [ ! -r "$TEMP_GM_CONFIG_FILE" ]; then
  echo "Optional temporary-GM config is missing: $TEMP_GM_CONFIG_FILE" >&2
  echo "Read $TEMP_GM_DIR/README.md; this mode must be enabled explicitly." >&2
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
fi

set -a
# shellcheck disable=SC1090
source "$TEMP_GM_CONFIG_FILE"
set +a

if [ "${PTP_ROLE:-}" != temp-gm ]; then
  echo 'Refusing to continue: optional temp-gm.env must explicitly set PTP_ROLE=temp-gm.' >&2
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
fi

RUN_DIR="$PTP_RUN_DIR"
PTP_UDS="$RUN_DIR/ptp4l"
PTP_CONFIG="$TEMP_GM_DIR/generated/temp-gm-class6.cfg"
export TEMP_GM_DIR PROJECT_DIR TEMP_GM_CONFIG_FILE RUN_DIR PTP_UDS PTP_CONFIG
