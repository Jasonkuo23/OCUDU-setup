#!/usr/bin/env bash
# shellcheck shell=bash

OCUDU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCUDU_CONFIG_FILE="${OCUDU_CONFIG_FILE:-$OCUDU_DIR/config/site.env}"
if [ ! -r "$OCUDU_CONFIG_FILE" ]; then
  echo "Missing site configuration: $OCUDU_CONFIG_FILE" >&2
  echo 'Create it with: ./cudu.sh init' >&2
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
fi

set -a
# This is an administrator-controlled shell configuration file.
# shellcheck disable=SC1090
source "$OCUDU_CONFIG_FILE"
set +a

EXPECTED_DU_MAC="${EXPECTED_DU_MAC:-${DU_MAC:-}}"
MIN_HUGEPAGES="${MIN_HUGEPAGES:-${HUGEPAGES:-0}}"
export OCUDU_DIR OCUDU_CONFIG_FILE EXPECTED_DU_MAC MIN_HUGEPAGES
